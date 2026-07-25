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
}

static void loadPrefs() {
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id icons = cache[@"IOSDump_CSI_Icons"];
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            customIconsDict = [icons copy];
            isEnabled = YES;
            if (!imageCache) imageCache = [NSMutableDictionary new];
            else [imageCache removeAllObjects];
            NSLog(@"[CustomShareIcon] 共享缓存 count=%lu keys=%@", (unsigned long)customIconsDict.count, customIconsDict.allKeys);
            return;
        }
    }

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

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)(customIconsDict ? customIconsDict.count : 0));

    if (isSpringBoardProcess() && customIconsDict.count > 0) {
        writeSharedCache(customIconsDict);
    }
}

static void ensurePrefsLoaded() {
    if (!customIconsDict.count) loadPrefs();
}

static UIImage *getCustomIconForID(NSString *identifier) {
    ensurePrefsLoaded();
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = nil;
    NSString *matchedKey = nil;
    NSString *lowerId = identifier.lowercaseString;

    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64Str = customIconsDict[key];
            matchedKey = key;
            break;
        }
    }

    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if (key.length == 0) continue;
            NSString *lowerKey = key.lowercaseString;
            if ([lowerId containsString:lowerKey] || [lowerKey containsString:lowerId] ||
                [lowerId hasPrefix:lowerKey] || [lowerKey hasPrefix:lowerId]) {
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

    if (!base64Str) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ %@ → %@", identifier, matchedKey);
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
            if (key.length && [desc containsString:key.lowercaseString]) return key;
        }
    } @catch (NSException *e) {}

    return nil;
}

static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    int depth = 0;
    while (r && depth < 18) {
        NSString *cls = NSStringFromClass([r class]);
        if ([cls containsString:@"Preferences"] || [cls containsString:@"PSList"] ||
            [cls containsString:@"CustomShareIconRoot"]) return NO;
        if ([cls containsString:@"UIActivityViewController"] || [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] || [cls containsString:@"UIActivityList"] ||
            [cls containsString:@"ActivityContent"] || [cls containsString:@"UIShareGroup"] ||
            [cls containsString:@"ActivityGroup"] || [cls containsString:@"_UIHostActivity"]) return YES;
        r = [r nextResponder];
        depth++;
    }
    return NO;
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

#pragma mark - 主面板

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

#pragma mark - 「更多」列表（重点补强）

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    ensurePrefsLoaded();
    if (!isEnabled || !customIconsDict.count) return;
    if (!isInShareSheetContext(self)) return;

    // 找到图标 ImageView
    UIImageView *targetIv = nil;
    if (self.imageView && self.imageView.frame.size.width >= 24) {
        targetIv = self.imageView;
    }
    if (!targetIv) {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)sub;
                if (iv.frame.size.width >= 24 && iv.frame.size.width <= 80) {
                    targetIv = iv;
                    break;
                }
            }
        }
    }
    if (!targetIv) return;

    // 尝试用标题文字辅助匹配（更多列表经常只有名字）
    NSString *title = self.textLabel.text;
    UIImage *customImage = nil;

    if (title.length) {
        // 用标题去碰已配置的 key 的最后一段（粗糙但有时有效）
        for (NSString *key in customIconsDict) {
            NSString *last = [[key componentsSeparatedByString:@"."] lastObject];
            if (last.length > 2 && [title.lowercaseString containsString:last.lowercaseString]) {
                customImage = getCustomIconForID(key);
                if (customImage) break;
            }
        }
    }

    // 如果源头已经把正确图片设进来了，这里也可以强制再盖一次
    // 由于更多列表很难拿到 proxy，这里主要依赖源头；若有自定义图就盖
    if (!customImage) return;

    targetIv.image = customImage;
    targetIv.contentMode = UIViewContentModeScaleAspectFit;
    targetIv.clipsToBounds = YES;
    targetIv.layer.cornerRadius = 8.0;

    UIImageView *overlay = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!overlay) {
        overlay = [UIImageView new];
        overlay.tag = TAG_CUSTOM_ICON;
        overlay.contentMode = UIViewContentModeScaleAspectFit;
        overlay.clipsToBounds = YES;
        [self.contentView addSubview:overlay];
    }
    overlay.frame = targetIv.frame;
    overlay.layer.cornerRadius = 8.0;
    overlay.image = customImage;
    overlay.hidden = NO;
    [self.contentView bringSubviewToFront:overlay];
}

- (void)prepareForReuse {
    %orig;
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) { iv.hidden = YES; iv.image = nil; }
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] 加载完成 (更多列表补强 + SB缓存)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
