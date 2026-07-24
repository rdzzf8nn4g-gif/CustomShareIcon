#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
@property (nonatomic, strong) UIImageView *activityImageView;
@property (nonatomic, strong) UIView *imageSlotView;
@property (nonatomic, strong) UIView *badgeSlotView;
@property (nonatomic, strong) UIImage *image; // iOS 16+
- (void)setActivityProxy:(id)proxy;
- (void)setImage:(UIImage *)image; // iOS 16+
- (void)_updateImageView; // iOS 16+
- (void)_configureImageViewForPlaceholder:(BOOL)placeholder; // iOS 17
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

    // 有配置就强制开启，保证所有进程一致
    isEnabled = (customIconsDict.count > 0) ? YES : (keyExists ? enabledVal : NO);

    if (!imageCache) imageCache = [NSMutableDictionary new];
    else [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)(customIconsDict ? customIconsDict.count : 0));
}

static UIImage *getTestRedImage() {
    if (testRedImage) return testRedImage;
    // 用较小尺寸生成，实际显示时会按目标 frame 缩放
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(60, 60), NO, 3.0);
    [[UIColor redColor] setFill];
    UIRectFill(CGRectMake(0, 0, 60, 60));
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
        NSLog(@"[CustomShareIcon] 加载成功 → %@", identifier);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *result = nil;

    // iOS 16/17 优先（头文件有 applicationBundleIdentifier）
    if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
        result = [proxy valueForKey:@"applicationBundleIdentifier"];
        if (result.length) return result;
    }

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}

    if (activity) {
        if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
            result = [activity valueForKey:@"containingAppBundleIdentifier"];
            if (result.length) return result;
        }
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
        if ([activity respondsToSelector:@selector(activityType)]) {
            result = [activity valueForKey:@"activityType"];
            if (result.length) return result;
        }
    }

    if ([proxy respondsToSelector:@selector(activityType)]) {
        result = [proxy valueForKey:@"activityType"];
        if (result.length) return result;
    }
    return nil;
}

// 严格判断是否在真正的分享界面（排除 Preferences 设置页）
static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    while (r) {
        NSString *cls = NSStringFromClass([r class]);
        // 明确排除设置相关
        if ([cls containsString:@"Preference"] || [cls containsString:@"PSList"] ||
            [cls containsString:@"CustomShareIcon"]) {
            return NO;
        }
        if ([cls containsString:@"Activity"] || [cls containsString:@"ShareSheet"] ||
            [cls containsString:@"SHSheet"] || [cls containsString:@"UIActivity"] ||
            [cls containsString:@"Share"]) {
            return YES;
        }
        r = [r nextResponder];
    }
    return NO;
}

#pragma mark - 主面板（严格按头文件）

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

// iOS 16+ 头文件有此方法
- (void)setImage:(UIImage *)image {
    %orig;
    [self csi_applyCustomIcon];
}

// iOS 16 头文件
- (void)_updateImageView {
    %orig;
    [self csi_applyCustomIcon];
}

// iOS 17 头文件
- (void)_configureImageViewForPlaceholder:(BOOL)placeholder {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    [self csi_applyCustomIcon];
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
- (void)csi_applyCustomIcon {
    if (!isEnabled) return;

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *targetImage = nil;
    if (identifier.length) {
        targetImage = getCustomIconForID(identifier);
    }
    if (!targetImage) targetImage = getTestRedImage();

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *badgeView = [self valueForKey:@"badgeSlotView"]; // 头文件明确有，绝不隐藏

    // 1. 优先直接改原生图片（最干净，尺寸自动正确）
    BOOL applied = NO;
    if (nativeIv && [nativeIv isKindOfClass:[UIImageView class]]) {
        nativeIv.image = targetImage;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        nativeIv.hidden = NO;
        nativeIv.alpha = 1.0;
        applied = YES;
    }

    // 2. 尝试改 slot 内部的 imageView
    if (!applied && slotView) {
        for (UIView *sub in slotView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]]) {
                ((UIImageView *)sub).image = targetImage;
                ((UIImageView *)sub).contentMode = UIViewContentModeScaleAspectFit;
                applied = YES;
                break;
            }
        }
    }

    // 3. 兜底 overlay（严格使用原生 frame，不再 inset 或写死尺寸）
    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!applied) {
        if (!customIv) {
            customIv = [UIImageView new];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            customIv.userInteractionEnabled = NO;
            [self.contentView addSubview:customIv];
        }

        UIView *ref = nil;
        if (nativeIv && !CGRectIsEmpty(nativeIv.frame) && nativeIv.frame.size.width > 10) {
            ref = nativeIv;
        } else if (slotView && !CGRectIsEmpty(slotView.frame) && slotView.frame.size.width > 10) {
            ref = slotView;
        }

        if (ref) {
            // 完全跟随原生尺寸和位置，不再缩小或写死
            customIv.frame = ref.frame;
            customIv.layer.cornerRadius = ref.layer.cornerRadius;
        } else {
            // 最后兜底（极少走到）
            CGFloat size = 60.0;
            customIv.frame = CGRectMake((self.contentView.bounds.size.width - size) / 2.0, 0, size, size);
            customIv.layer.cornerRadius = 13.0;
        }

        customIv.image = targetImage;
        customIv.hidden = NO;
        customIv.alpha = 1.0;
        [self.contentView bringSubviewToFront:customIv];
    } else {
        // 已用原生方式成功，隐藏旧 overlay
        if (customIv) customIv.hidden = YES;
    }

    // 强制把 badge 放最前面（头文件有 badgeSlotView）
    if (badgeView) {
        [self.contentView bringSubviewToFront:badgeView];
    }
}

%end

#pragma mark - 更多列表（严格限制上下文 + 尺寸跟随）

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;

    if (!isEnabled) return;
    if (!isInShareSheetContext(self)) return; // 已排除 Preferences

    UIView *imageRef = self.imageView;
    if (!imageRef || CGRectIsEmpty(imageRef.frame) || imageRef.frame.size.width < 20) {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.frame.size.width >= 28 && sub.frame.size.width <= 70) {
                imageRef = sub;
                break;
            }
        }
    }

    if (imageRef && [imageRef isKindOfClass:[UIImageView class]]) {
        // 直接改图，尺寸自动正确
        ((UIImageView *)imageRef).image = getTestRedImage();
        ((UIImageView *)imageRef).contentMode = UIViewContentModeScaleAspectFit;

        // 如果系统又盖回来，再用精确 frame 的 overlay
        UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (!customIv) {
            customIv = [UIImageView new];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            [self.contentView addSubview:customIv];
        }
        // 严格使用原生 frame
        customIv.frame = imageRef.frame;
        customIv.layer.cornerRadius = imageRef.layer.cornerRadius;
        customIv.image = getTestRedImage();
        customIv.hidden = NO;
        [self.contentView bringSubviewToFront:customIv];
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    %orig;
    if (isEnabled && isInShareSheetContext(self)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsLayout];
        });
    }
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

#pragma mark - UIActivity 图片拦截（全版本）

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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (头文件严格对齐 + 尺寸精确跟随版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
