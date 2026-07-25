#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"

@interface _UIActivityBundleImageConfiguration : NSObject
@property (nonatomic) long long activityCategory;
@property (copy, nonatomic) NSString *bundlePath;
@property (readonly, nonatomic) UIImage *fetchedImage;
@property (copy, nonatomic) NSString *imageName;
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
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

#pragma mark - 简化加载（共享缓存优先）

static BOOL isSpringBoardProcess() {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return YES;
    return NO;
}

static void writeSharedCache(NSDictionary *icons) {
    if (!icons.count) return;
    NSDictionary *cache = @{@"IOSDump_CSI_Icons" : icons, @"Enabled" : @YES};
    [cache writeToFile:SHARED_CACHE_PATH atomically:YES];
    NSLog(@"[CustomShareIcon] 共享缓存已写入 count=%lu", (unsigned long)icons.count);
}

static void loadPrefs() {
    // 1. 优先共享缓存
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id icons = cache[@"IOSDump_CSI_Icons"];
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            customIconsDict = [icons copy];
            isEnabled = YES;
            if (!imageCache) imageCache = [NSMutableDictionary new];
            else [imageCache removeAllObjects];
            NSLog(@"[CustomShareIcon] 共享缓存读取成功 count=%lu keys=%@", (unsigned long)customIconsDict.count, customIconsDict.allKeys);
            return;
        }
    }

    // 2. 简单 CFPreferences 兜底
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!iconsRef) iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);

    if (iconsRef && CFGetTypeID(iconsRef) == CFDictionaryGetTypeID()) {
        customIconsDict = [(__bridge NSDictionary *)iconsRef copy];
    } else {
        customIconsDict = nil;
    }
    if (iconsRef) CFRelease(iconsRef);

    isEnabled = (customIconsDict.count > 0);

    if (!imageCache) imageCache = [NSMutableDictionary new];
    else [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu keys=%@", isEnabled,
          (unsigned long)(customIconsDict ? customIconsDict.count : 0),
          customIconsDict.allKeys ?: @[]);

    // SpringBoard 写共享缓存
    if (isSpringBoardProcess() && customIconsDict.count > 0) {
        writeSharedCache(customIconsDict);
    }
}

static void ensurePrefsLoaded() {
    if (!customIconsDict.count) loadPrefs();
}

// 加强版匹配（专门照顾 App Store 扩展 ID）
static UIImage *getCustomIconForID(NSString *identifier) {
    ensurePrefsLoaded();
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = nil;
    NSString *matchedKey = nil;
    NSString *lowerId = identifier.lowercaseString;

    // 1. 精确 / 忽略大小写
    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64Str = customIconsDict[key];
            matchedKey = key;
            break;
        }
    }

    // 2. 包含匹配（App Store 扩展最常见：com.xxx.yyy.share → com.xxx.yyy）
    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if (key.length == 0) continue;
            NSString *lowerKey = key.lowercaseString;
            if ([lowerId containsString:lowerKey] || [lowerKey containsString:lowerId]) {
                base64Str = customIconsDict[key];
                matchedKey = key;
                break;
            }
        }
    }

    // 3. 前缀匹配（com.tencent.mqq.xxx → com.tencent.mqq）
    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if (key.length == 0) continue;
            if ([lowerId hasPrefix:key.lowercaseString] || [key.lowercaseString hasPrefix:lowerId]) {
                base64Str = customIconsDict[key];
                matchedKey = key;
                break;
            }
        }
    }

    // 4. 最后一段
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

    if (!base64Str) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;

    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ 匹配 %@ → %@", identifier, matchedKey);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *result = nil;

    // iOS 16+
    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            result = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (result.length) return result;
        }
    } @catch (NSException *e) {}

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}

    if (activity) {
        // App Store 应用最关键：containingAppBundleIdentifier
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
                    // 先试扩展自己的 identifier
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
            if (key.length && [desc containsString:key.lowercaseString]) return key;
        }
    } @catch (NSException *e) {}

    return nil;
}

#pragma mark - 源头

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    if ([configuration isKindOfClass:NSClassFromString(@"_UIActivityBundleImageConfiguration")]) {
        NSString *bundlePath = [configuration valueForKey:@"bundlePath"];
        if (bundlePath.length) {
            NSString *last = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
            UIImage *custom = getCustomIconForID(last);
            if (custom) return custom;
            for (NSString *key in customIconsDict) {
                if ([bundlePath.lowercaseString containsString:key.lowercaseString]) {
                    custom = getCustomIconForID(key);
                    if (custom) return custom;
                }
            }
        }
        NSString *imageName = [configuration valueForKey:@"imageName"];
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
        custom = getCustomIconForID([self valueForKey:@"containingAppBundleIdentifier"]);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    if (custom) return custom;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        custom = getCustomIconForID([self valueForKey:@"containingAppBundleIdentifier"]);
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
    // App Store 应用核心路径
    NSString *bid = nil;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        bid = [self containingAppBundleIdentifier];
    }
    if (!bid.length && [self respondsToSelector:@selector(activityType)]) {
        bid = [self activityType];
    }
    UIImage *custom = getCustomIconForID(bid);
    return custom ?: %orig;
}

%end

#pragma mark - 主面板兜底

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

- (void)prepareForReuse {
    %orig;
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) { iv.hidden = YES; iv.image = nil; }
}

%new
- (void)csi_forceApplyAfterDelay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

%new
- (void)csi_applyCustomIcon {
    ensurePrefsLoaded();
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);
    UIImage *customImage = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!customImage) return;

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

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

    UIView *badge = [self valueForKey:@"badgeSlotView"];
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] 简化版加载完成 (SB共享缓存 + AppStore加强匹配)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
