#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define PREFS_ID @"com.iosdump.customshareicon"
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"

@interface _UIActivityBundleImageConfiguration : NSObject
@property (nonatomic) long long activityCategory;
@property (copy, nonatomic) NSString *bundlePath;
@property (readonly, nonatomic) UIImage *fetchedImage;
@property (copy, nonatomic) NSString *imageName;
- (id)initWithImageName:(NSString *)name bundlePath:(NSString *)path activityCategory:(long long)category;
@end

@interface _UIActivityResourceLoader : NSObject
- (void)getResourceWithBlock:(id /* block */)block;
- (void)loadResourceIfNeeded;
@end

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIView *badgeSlotView;
- (void)setActivityProxy:(id)proxy;
- (void)setImage:(UIImage *)image;
- (void)_updateImageView;
- (void)_updateDarkening;
- (void)_configureImageViewForPlaceholder:(BOOL)placeholder;
- (void)csi_applyCustomIcon;
- (void)csi_forceApplyAfterDelay;
@end

@interface UIApplicationExtensionActivity : UIActivity
- (NSString *)containingAppBundleIdentifier;
- (NSString *)activityType;
- (UIImage *)_activityImage;
@end

@interface UIActivity (CustomShareIcon)
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier;
+ (id)_activityImageForBundleImageConfiguration:(id)configuration;
- (UIImage *)activityImage;
- (UIImage *)_activityImage;
- (NSString *)_systemImageName;
- (NSString *)activityType;
- (id)_activityImageLoader;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

#pragma mark - 工具

static BOOL isSpringBoardProcess() {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    NSString *proc = [[NSProcessInfo processInfo] processName];
    if ([proc isEqualToString:@"SpringBoard"]) return YES;
    return NO;
}

static void writeSharedCache(NSDictionary *icons, BOOL enabled) {
    if (!icons.count) return;
    NSDictionary *cache = @{
        @"IOSDump_CSI_Icons" : icons,
        @"Enabled" : @(enabled)
    };
    BOOL ok = [cache writeToFile:SHARED_CACHE_PATH atomically:YES];
    NSLog(@"[CustomShareIcon] 共享缓存写入 %@ → %@", SHARED_CACHE_PATH, ok ? @"成功" : @"失败");
}

static NSDictionary *loadFromSharedCache() {
    if (![[NSFileManager defaultManager] fileExistsAtPath:SHARED_CACHE_PATH]) return nil;
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if (![cache isKindOfClass:[NSDictionary class]]) return nil;
    id icons = cache[@"IOSDump_CSI_Icons"];
    if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
        NSLog(@"[CustomShareIcon] 共享缓存读取成功 count=%lu", (unsigned long)[icons count]);
        return [icons copy];
    }
    return nil;
}

static NSDictionary *loadIconsFromOriginalFile() {
    NSArray *paths = @[
        [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", PREFS_ID],
        [NSString stringWithFormat:@"/private/var/mobile/Library/Preferences/%@.plist", PREFS_ID],
    ];
    NSArray *libPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    if (libPaths.count) {
        NSString *p = [libPaths[0] stringByAppendingPathComponent:[NSString stringWithFormat:@"Preferences/%@.plist", PREFS_ID]];
        paths = [paths arrayByAddingObject:p];
    }
    for (NSString *path in paths) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        id icons = dict[@"IOSDump_CSI_Icons"];
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            NSLog(@"[CustomShareIcon] 原偏好文件读取成功 path=%@", path);
            return [icons copy];
        }
    }
    return nil;
}

static void loadPrefs() {
    // ========== 1. 优先读共享缓存（所有进程）==========
    NSDictionary *shared = loadFromSharedCache();
    if (shared.count > 0) {
        customIconsDict = shared;
        isEnabled = YES;
        if (!imageCache) imageCache = [NSMutableDictionary new];
        else [imageCache removeAllObjects];
        NSLog(@"[CustomShareIcon] loadPrefs(共享缓存) enabled=1 count=%lu keys=%@", (unsigned long)customIconsDict.count, customIconsDict.allKeys);
        return;
    }

    // ========== 2. CFPreferences 多路径 ==========
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.customshareicon"));
    CFPreferencesSynchronize(PREFS_DOMAIN, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    Boolean keyExists = false;
    Boolean enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    if (!keyExists) {
        enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), kCFPreferencesAnyApplication, &keyExists);
    }

    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!iconsRef) iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    if (!iconsRef) iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), CFSTR("com.iosdump.customshareicon"));
    if (!iconsRef) iconsRef = CFPreferencesCopyValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!iconsRef) iconsRef = CFPreferencesCopyValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication, kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    NSDictionary *cfDict = nil;
    if (iconsRef && CFGetTypeID(iconsRef) == CFDictionaryGetTypeID()) {
        cfDict = [(__bridge NSDictionary *)iconsRef copy];
    }
    if (iconsRef) CFRelease(iconsRef);

    // ========== 3. 直接读原偏好文件 ==========
    NSDictionary *fileDict = loadIconsFromOriginalFile();

    if (cfDict.count > 0) {
        customIconsDict = cfDict;
    } else if (fileDict.count > 0) {
        customIconsDict = fileDict;
    } else {
        customIconsDict = nil;
    }

    isEnabled = (customIconsDict.count > 0) ? YES : (keyExists ? enabledVal : NO);

    if (!imageCache) imageCache = [NSMutableDictionary new];
    else [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu keys=%@", isEnabled,
          (unsigned long)(customIconsDict ? customIconsDict.count : 0),
          customIconsDict.allKeys ?: @[]);

    // ========== 4. SpringBoard 负责写共享缓存 ==========
    if (isSpringBoardProcess() && customIconsDict.count > 0) {
        writeSharedCache(customIconsDict, isEnabled);
    }
}

static void ensurePrefsLoaded() {
    if (!customIconsDict || customIconsDict.count == 0) {
        loadPrefs();
    }
}

static UIImage *getCustomIconForID(NSString *identifier) {
    ensurePrefsLoaded();
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = nil;
    NSString *matchedKey = nil;

    base64Str = customIconsDict[identifier];
    if (base64Str) matchedKey = identifier;

    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
                base64Str = customIconsDict[key];
                matchedKey = key;
                break;
            }
        }
    }

    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if (key.length == 0) continue;
            if ([identifier.lowercaseString containsString:key.lowercaseString] ||
                [key.lowercaseString containsString:identifier.lowercaseString]) {
                base64Str = customIconsDict[key];
                matchedKey = key;
                break;
            }
        }
    }

    if (!base64Str) {
        NSString *last = [[identifier componentsSeparatedByString:@"."] lastObject];
        if (last.length > 2) {
            for (NSString *key in customIconsDict) {
                NSString *keyLast = [[key componentsSeparatedByString:@"."] lastObject];
                if ([last caseInsensitiveCompare:keyLast] == NSOrderedSame) {
                    base64Str = customIconsDict[key];
                    matchedKey = key;
                    break;
                }
            }
        }
    }

    if (!base64Str && [identifier containsString:@"/"]) {
        NSArray *parts = [identifier componentsSeparatedByString:@"/"];
        for (NSString *part in parts) {
            if (part.length < 3) continue;
            for (NSString *key in customIconsDict) {
                if ([part.lowercaseString containsString:key.lowercaseString] ||
                    [key.lowercaseString containsString:part.lowercaseString]) {
                    base64Str = customIconsDict[key];
                    matchedKey = key;
                    break;
                }
            }
            if (base64Str) break;
        }
    }

    if (!base64Str) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;

    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ 匹配成功 %@ → %@", identifier, matchedKey);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *result = nil;

    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            result = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (result.length) return result;
        }
    } @catch (NSException *e) {}

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}

    if (activity) {
        @try {
            if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
                result = [activity valueForKey:@"containingAppBundleIdentifier"];
                if (result.length) return result;
            }
        } @catch (NSException *e) {}

        @try {
            if ([activity respondsToSelector:@selector(applicationExtension)]) {
                id ext = [activity valueForKey:@"applicationExtension"];
                if (ext) {
                    result = [ext valueForKey:@"identifier"];
                    if (result.length) return result;
                    id bundle = [ext valueForKey:@"_bundle"];
                    if (bundle) {
                        result = [bundle bundleIdentifier];
                        if (result.length) return result;
                    }
                }
            }
        } @catch (NSException *e) {}

        @try {
            if ([activity respondsToSelector:@selector(activityType)]) {
                result = [activity valueForKey:@"activityType"];
                if (result.length) return result;
            }
        } @catch (NSException *e) {}
    }

    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            result = [proxy valueForKey:@"activityType"];
            if (result.length) return result;
        }
    } @catch (NSException *e) {}

    @try {
        NSString *desc = [[proxy description] lowercaseString];
        for (NSString *key in customIconsDict) {
            if (key.length && [desc containsString:key.lowercaseString]) {
                return key;
            }
        }
        if ([desc containsString:@"airdrop"]) return @"com.apple.AirDrop";
    } @catch (NSException *e) {}

    return nil;
}

static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    int depth = 0;
    while (r && depth < 15) {
        NSString *cls = NSStringFromClass([r class]);
        if ([cls containsString:@"Preferences"] || [cls containsString:@"PSList"] ||
            [cls containsString:@"CustomShareIconRoot"] || [cls containsString:@"PSViewController"]) {
            return NO;
        }
        if ([cls containsString:@"UIActivityViewController"] || [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] || [cls containsString:@"UIActivityList"] ||
            [cls containsString:@"_UIHostActivity"] || [cls containsString:@"UIShareGroup"] ||
            [cls containsString:@"ActivityGroup"] || [cls containsString:@"UIActivity"]) {
            return YES;
        }
        r = [r nextResponder];
        depth++;
    }
    return NO;
}

#pragma mark - ========== 源头拦截 ==========

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    if (custom) {
        NSLog(@"[CustomShareIcon] 源头 BundleID → %@", identifier);
        return custom;
    }
    return %orig;
}

+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    if ([configuration isKindOfClass:NSClassFromString(@"_UIActivityBundleImageConfiguration")]) {
        NSString *bundlePath = [configuration valueForKey:@"bundlePath"];
        NSString *imageName = [configuration valueForKey:@"imageName"];

        if (bundlePath.length) {
            NSString *last = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
            UIImage *custom = getCustomIconForID(last);
            if (custom) {
                NSLog(@"[CustomShareIcon] 源头 BundlePath last → %@", last);
                return custom;
            }
            for (NSString *key in customIconsDict) {
                if ([bundlePath.lowercaseString containsString:key.lowercaseString]) {
                    custom = getCustomIconForID(key);
                    if (custom) {
                        NSLog(@"[CustomShareIcon] 源头 BundlePath 包含 → %@", key);
                        return custom;
                    }
                }
            }
            NSArray *parts = [bundlePath componentsSeparatedByString:@"/"];
            for (NSString *part in parts) {
                if (part.length < 3) continue;
                custom = getCustomIconForID(part);
                if (custom) {
                    NSLog(@"[CustomShareIcon] 源头 BundlePath 分段 → %@", part);
                    return custom;
                }
            }
        }
        if (imageName.length) {
            UIImage *custom = getCustomIconForID(imageName);
            if (custom) return custom;
        }
    }
    return %orig;
}

- (UIImage *)activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    if (custom) return custom;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        NSString *bid = [self valueForKey:@"containingAppBundleIdentifier"];
        custom = getCustomIconForID(bid);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    if (custom) return custom;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        NSString *bid = [self valueForKey:@"containingAppBundleIdentifier"];
        custom = getCustomIconForID(bid);
        if (custom) return custom;
    }
    return %orig;
}

- (NSString *)_systemImageName {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    if (getCustomIconForID(type)) return nil;
    return %orig;
}

%end

%hook UIApplicationExtensionActivity

- (UIImage *)_activityImage {
    NSString *bid = nil;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        bid = [self containingAppBundleIdentifier];
    }
    if (!bid.length && [self respondsToSelector:@selector(activityType)]) {
        bid = [self activityType];
    }
    UIImage *custom = getCustomIconForID(bid);
    if (custom) {
        NSLog(@"[CustomShareIcon] Extension源头 → %@", bid);
        return custom;
    }
    return %orig;
}

%end

#pragma mark - 主面板强制兜底

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    [self csi_forceApplyAfterDelay];
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)setImage:(UIImage *)image {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)_updateImageView {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)_updateDarkening {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)_configureImageViewForPlaceholder:(BOOL)placeholder {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    [self csi_applyCustomIcon];
    dispatch_async(dispatch_get_main_queue(), ^{ [self csi_applyCustomIcon]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

- (void)setSelected:(BOOL)selected {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)prepareForReuse {
    %orig;
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) {
        iv.hidden = YES;
        iv.image = nil;
    }
}

%new
- (void)csi_forceApplyAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

%new
- (void)csi_applyCustomIcon {
    ensurePrefsLoaded();
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *customImage = nil;
    if (identifier.length) {
        customImage = getCustomIconForID(identifier);
    }
    if (!customImage) return;

    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *badgeView = [self valueForKey:@"badgeSlotView"];

    UIView *ref = nil;
    if (nativeIv && !CGRectIsEmpty(nativeIv.frame) && nativeIv.frame.size.width > 10) {
        ref = nativeIv;
    } else if (slotView && !CGRectIsEmpty(slotView.frame)) {
        ref = slotView;
    }
    if (!ref) return;

    if (nativeIv) {
        nativeIv.image = customImage;
        nativeIv.hidden = NO;
        nativeIv.alpha = 1.0;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        nativeIv.clipsToBounds = YES;
    }

    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [UIImageView new];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        customIv.userInteractionEnabled = NO;
        [self.contentView addSubview:customIv];
    }

    customIv.frame = ref.frame;
    CGFloat radius = ref.layer.cornerRadius;
    if (radius < 1.0) radius = 13.0;
    customIv.layer.cornerRadius = radius;
    customIv.image = customImage;
    customIv.hidden = NO;
    customIv.alpha = 1.0;

    [self.contentView bringSubviewToFront:customIv];

    if (badgeView) {
        [self.contentView bringSubviewToFront:badgeView];
    }
    for (UIView *sub in self.contentView.subviews) {
        NSString *n = NSStringFromClass([sub class]).lowercaseString;
        if ([n containsString:@"badge"] || [n containsString:@"dot"]) {
            [self.contentView bringSubviewToFront:sub];
        }
    }
}

%end

#pragma mark - 「更多」列表

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    if (!isEnabled || !isInShareSheetContext(self)) return;
}

- (void)prepareForReuse {
    %orig;
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) {
        iv.hidden = YES;
        iv.image = nil;
    }
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (SB共享缓存 + 源头 + slot强制版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
