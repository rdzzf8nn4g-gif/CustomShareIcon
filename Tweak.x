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
          customIconsDict.allKeys);
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
            if (key.length && ([identifier containsString:key] || [key containsString:identifier])) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }
    if (!base64Str) return nil;

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

    // 1. iOS 16/17 头文件明确属性
    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            result = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (result.length) {
                NSLog(@"[CustomShareIcon] 提取到 applicationBundleIdentifier = %@", result);
                return result;
            }
        }
    } @catch (NSException *e) {}

    // 2. activity 对象
    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}

    if (activity) {
        @try {
            if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
                result = [activity valueForKey:@"containingAppBundleIdentifier"];
                if (result.length) {
                    NSLog(@"[CustomShareIcon] 提取到 containingAppBundleIdentifier = %@", result);
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
                    NSLog(@"[CustomShareIcon] 提取到 activityType = %@", result);
                    return result;
                }
            }
        } @catch (NSException *e) {}
    }

    // 3. 直接从 proxy 拿 activityType
    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            result = [proxy valueForKey:@"activityType"];
            if (result.length) return result;
        }
    } @catch (NSException *e) {}

    // 4. 最后尝试 description 里找
    @try {
        NSString *desc = [proxy description];
        if ([desc containsString:@"AirDrop"] || [desc containsString:@"airdrop"]) {
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
        if ([cls containsString:@"Preferences"] ||
            [cls containsString:@"PSList"] ||
            [cls containsString:@"CustomShareIconRoot"] ||
            [cls containsString:@"PSViewController"]) {
            return NO;
        }
        if ([cls containsString:@"UIActivityViewController"] ||
            [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] ||
            [cls containsString:@"UIActivityList"] ||
            [cls containsString:@"_UIHostActivity"] ||
            [cls containsString:@"UIShareGroup"] ||
            [cls containsString:@"ActivityGroup"] ||
            [cls containsString:@"UIActivity"]) {
            return YES;
        }
        r = [r nextResponder];
        depth++;
    }
    return NO;
}

#pragma mark - 主面板（完整对应 iOS 14-17 头文件）

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    // 隔空投送等需要更长等待
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

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

// iOS 16+ 
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

// iOS 17
- (void)_configureImageViewForPlaceholder:(BOOL)placeholder {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    // 长按后强制重新覆盖
    dispatch_async(dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

- (void)setSelected:(BOOL)selected {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
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
- (void)csi_applyCustomIcon {
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *customImage = nil;
    if (identifier.length) {
        customImage = getCustomIconForID(identifier);
    }
    // 没匹配到真实图标时用红色（测试路径）
    if (!customImage) {
        customImage = getTestRedImage();
    }

    UIImageView *targetIv = nil;
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];

    if (nativeIv && [nativeIv isKindOfClass:[UIImageView class]] && !CGRectIsEmpty(nativeIv.frame) && nativeIv.frame.size.width > 10) {
        targetIv = nativeIv;
    } else if (slotView) {
        for (UIView *sub in slotView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.frame.size.width >= 20) {
                targetIv = (UIImageView *)sub;
                break;
            }
        }
    }

    // 优先改原生
    if (targetIv) {
        targetIv.image = customImage;
        targetIv.contentMode = UIViewContentModeScaleAspectFit;
        targetIv.clipsToBounds = YES;
        targetIv.hidden = NO;
        targetIv.alpha = 1.0;

        UIImageView *old = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (old) old.hidden = YES;
        return;
    }

    // 兜底 overlay
    UIView *ref = targetIv ?: slotView ?: nativeIv;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

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

    targetIv.image = getTestRedImage();
    targetIv.contentMode = UIViewContentModeScaleAspectFit;
    targetIv.clipsToBounds = YES;

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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (iOS17 + 长按/隔空投送强化版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
