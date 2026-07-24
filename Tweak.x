#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

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
static UIImage *testRedImage = nil;

static void loadPrefs() {
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
    if (!keyExists) {
        enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("com.iosdump.customshareicon"), &keyExists);
    }

    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!iconsRef) iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    if (!iconsRef) iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), CFSTR("com.iosdump.customshareicon"));
    if (!iconsRef) iconsRef = CFPreferencesCopyValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!iconsRef) iconsRef = CFPreferencesCopyValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    if (!iconsRef) iconsRef = CFPreferencesCopyValue(CFSTR("IOSDump_CSI_Icons"), CFSTR("com.iosdump.customshareicon"), kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    if (iconsRef && CFGetTypeID(iconsRef) == CFDictionaryGetTypeID()) {
        customIconsDict = [(__bridge NSDictionary *)iconsRef copy];
    } else {
        customIconsDict = nil;
    }
    if (iconsRef) CFRelease(iconsRef);

    isEnabled = (customIconsDict.count > 0) ? YES : (keyExists ? enabledVal : NO);

    if (!imageCache) imageCache = [NSMutableDictionary new];
    else [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu keys=%@", isEnabled,
          (unsigned long)(customIconsDict ? customIconsDict.count : 0),
          customIconsDict.allKeys ?: @[]);
}

static UIImage *getTestRedImage() {
    if (testRedImage) return testRedImage;
    CGFloat size = 60.0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(size, size), NO, 3.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:13.0];
    [[UIColor redColor] setFill];
    [path fill];
    testRedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return testRedImage;
}

static UIImage *getCustomIconForID(NSString *identifier) {
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

    if (!base64Str) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;

    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ 源头匹配成功 %@ → %@", identifier, matchedKey);
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

#pragma mark - ========== 源头拦截（核心）==========

%hook UIActivity

// 最重要的源头：根据 Bundle ID 生成图标
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    if (custom) {
        NSLog(@"[CustomShareIcon] 源头拦截 BundleID → %@", identifier);
        return custom;
    }
    return %orig;
}

// 通过 BundleImageConfiguration 生成图标
+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    if ([configuration isKindOfClass:NSClassFromString(@"_UIActivityBundleImageConfiguration")]) {
        NSString *bundlePath = [configuration valueForKey:@"bundlePath"];
        NSString *imageName = [configuration valueForKey:@"imageName"];

        // 从 bundlePath 提取可能的 Bundle ID
        if (bundlePath.length) {
            NSString *last = [[bundlePath lastPathComponent] stringByDeletingPathExtension];
            UIImage *custom = getCustomIconForID(last);
            if (custom) {
                NSLog(@"[CustomShareIcon] 源头拦截 BundlePath → %@", last);
                return custom;
            }
            // 再试完整路径里是否包含配置的 key
            for (NSString *key in customIconsDict) {
                if ([bundlePath.lowercaseString containsString:key.lowercaseString]) {
                    custom = getCustomIconForID(key);
                    if (custom) {
                        NSLog(@"[CustomShareIcon] 源头拦截 BundlePath包含 → %@", key);
                        return custom;
                    }
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
    NSString *type = nil;
    if ([self respondsToSelector:@selector(activityType)]) {
        type = [self activityType];
    }
    UIImage *custom = getCustomIconForID(type);
    if (custom) return custom;

    // 尝试 containingAppBundleIdentifier（ExtensionActivity）
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        NSString *bid = [self valueForKey:@"containingAppBundleIdentifier"];
        custom = getCustomIconForID(bid);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    NSString *type = nil;
    if ([self respondsToSelector:@selector(activityType)]) {
        type = [self activityType];
    }
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
    NSString *type = nil;
    if ([self respondsToSelector:@selector(activityType)]) {
        type = [self activityType];
    }
    if (getCustomIconForID(type)) return nil; // 阻止系统 SF Symbol
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
        NSLog(@"[CustomShareIcon] Extension源头拦截 → %@", bid);
        return custom;
    }
    return %orig;
}

%end

#pragma mark - 主面板（轻量兜底，防止 slot 回写）

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

%new
- (void)csi_applyCustomIcon {
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *customImage = nil;
    if (identifier.length) {
        customImage = getCustomIconForID(identifier);
    }
    // 源头已经替换成功时，这里可以不强制盖红色
    if (!customImage) return;   // 不再无脑盖红色，避免干扰

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

    // 直接改原生（源头已经给了正确图片时更稳）
    if (nativeIv) {
        nativeIv.image = customImage;
        nativeIv.hidden = NO;
        nativeIv.alpha = 1.0;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        nativeIv.clipsToBounds = YES;
    }

    // 轻量 overlay 兜底
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
}

%end

#pragma mark - 「更多」列表轻量兜底

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    if (!isEnabled || !isInShareSheetContext(self)) return;

    // 源头已经处理，这里只做极轻量检查
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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (源头拦截 + 轻量兜底版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
