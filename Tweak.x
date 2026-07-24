#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
@property (nonatomic, strong) UIImage *image;
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
static UIImage *testRedImage = nil;

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);

    Boolean keyExists = false;
    Boolean enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    if (!keyExists) {
        enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), kCFPreferencesAnyApplication, &keyExists);
    }

    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!iconsRef) {
        iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    }

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
    if (!isEnabled || !identifier.length || !customIconsDict) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = customIconsDict[identifier];
    if (!base64Str) {
        for (NSString *key in customIconsDict) {
            if (key.length && ([identifier caseInsensitiveCompare:key] == NSOrderedSame ||
                               [identifier containsString:key] || [key containsString:identifier])) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }
    if (!base64Str) {
        NSLog(@"[CustomShareIcon] ❌ 未找到匹配图标 key=%@ 现有keys=%@", identifier, customIconsDict.allKeys);
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;

    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ 真实图标加载成功 → %@", identifier);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *result = nil;

    // iOS 16/17 头文件：applicationBundleIdentifier
    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            result = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (result.length) {
                NSLog(@"[CustomShareIcon] 提取 applicationBundleIdentifier = %@", result);
                return result;
            }
        }
    } @catch (NSException *e) {}

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}

    if (activity) {
        @try {
            if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
                result = [activity valueForKey:@"containingAppBundleIdentifier"];
                if (result.length) {
                    NSLog(@"[CustomShareIcon] 提取 containingAppBundleIdentifier = %@", result);
                    return result;
                }
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
                if (result.length) {
                    NSLog(@"[CustomShareIcon] 提取 activityType = %@", result);
                    return result;
                }
            }
        } @catch (NSException *e) {}
    }

    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            result = [proxy valueForKey:@"activityType"];
            if (result.length) return result;
        }
    } @catch (NSException *e) {}

    // AirDrop 特殊处理
    @try {
        NSString *desc = [proxy description];
        if ([desc.lowercaseString containsString:@"airdrop"]) {
            return @"com.apple.AirDrop";
        }
    } @catch (NSException *e) {}

    NSLog(@"[CustomShareIcon] ⚠️ 提取失败 proxy=%@", proxy);
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

#pragma mark - 主面板（强制 overlay + 全方法覆盖）

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
    // 长按后连续强制重盖（对抗 slot 回写）
    [self csi_applyCustomIcon];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
    // 专门给隔空投送和异步 slot 用
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
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *customImage = nil;
    if (identifier.length) {
        customImage = getCustomIconForID(identifier);
    }
    if (!customImage) {
        customImage = getTestRedImage();  // 测试兜底
    }

    // ========== 强制使用 overlay（对抗 iOS 16/17 slot 回写）==========
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *ref = nil;

    if (nativeIv && !CGRectIsEmpty(nativeIv.frame) && nativeIv.frame.size.width > 10) {
        ref = nativeIv;
    } else if (slotView && !CGRectIsEmpty(slotView.frame)) {
        ref = slotView;
    }
    if (!ref) return;

    // 隐藏原生（防止 slot 回写后露出来）
    if (nativeIv) {
        nativeIv.hidden = YES;
        nativeIv.alpha = 0;
    }
    // 不隐藏整个 slotView，避免布局错位

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

    // badge 置顶
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

    UIImageView *targetIv = nil;
    if (self.imageView && !CGRectIsEmpty(self.imageView.frame) && self.imageView.frame.size.width >= 28) {
        targetIv = self.imageView;
    } else {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.frame.size.width >= 28 && sub.frame.size.width <= 70) {
                targetIv = (UIImageView *)sub;
                break;
            }
        }
    }
    if (!targetIv) return;

    targetIv.hidden = YES;
    targetIv.alpha = 0;

    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [UIImageView new];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        [self.contentView addSubview:customIv];
    }
    customIv.frame = targetIv.frame;
    customIv.layer.cornerRadius = 8.0;
    customIv.image = getTestRedImage();
    customIv.hidden = NO;
    [self.contentView bringSubviewToFront:customIv];
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

#pragma mark - UIActivity 拦截

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

- (UIImage *)activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    return custom ?: %orig;
}

- (UIImage *)_activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    return custom ?: %orig;
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

%ctor {
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (强制overlay + 对抗slot回写版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
