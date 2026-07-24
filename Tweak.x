#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
- (void)setActivityProxy:(id)proxy;
- (void)csi_applyCustomIcon;
- (void)_updateImageView;                          // iOS 16+
- (void)_configureImageViewForPlaceholder;         // iOS 17
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

    // iOS 16+ 优先
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

static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    while (r) {
        NSString *cls = NSStringFromClass([r class]);
        if ([cls containsString:@"Activity"] || [cls containsString:@"ShareSheet"] ||
            [cls containsString:@"SHSheet"] || [cls containsString:@"UIActivity"] ||
            [cls containsString:@"Share"]) {
            return YES;
        }
        r = [r nextResponder];
    }
    return NO;
}

#pragma mark - 主面板 UIShareGroupActivityCell（iOS 14-17）

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

// iOS 16+
- (void)_updateImageView {
    %orig;
    [self csi_applyCustomIcon];
}

// iOS 17
- (void)_configureImageViewForPlaceholder {
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

    UIImage *customImage = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!customImage) customImage = getTestRedImage();

    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];

    // ========== 优先方案：直接改原生图片（减少错位和 badge 遮挡）==========
    BOOL applied = NO;
    if (nativeIv && [nativeIv isKindOfClass:[UIImageView class]]) {
        nativeIv.image = customImage;
        nativeIv.hidden = NO;
        nativeIv.alpha = 1.0;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        applied = YES;
    }

    // 如果原生改不了，再用 overlay（但尽量不碰 badge）
    if (!applied) {
        if (slotView) {
            // 不隐藏整个 slotView，只尝试找里面的 imageView
            for (UIView *sub in slotView.subviews) {
                if ([sub isKindOfClass:[UIImageView class]]) {
                    ((UIImageView *)sub).image = customImage;
                    applied = YES;
                    break;
                }
            }
        }
    }

    // 最终兜底 overlay（缩小范围，减少盖 badge）
    if (!applied) {
        UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (!customIv) {
            customIv = [UIImageView new];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            customIv.userInteractionEnabled = NO;
            [self.contentView addSubview:customIv];
        }
        [self.contentView bringSubviewToFront:customIv];

        UIView *ref = nativeIv ?: slotView;
        if (ref && !CGRectIsEmpty(ref.frame)) {
            // 明显内缩，给 badge 留位置
            CGFloat inset = 3.0;
            customIv.frame = CGRectInset(ref.frame, inset, inset);
            customIv.layer.cornerRadius = MAX(0, (ref.layer.cornerRadius > 0 ? ref.layer.cornerRadius : 13.0) - inset);
        } else {
            customIv.frame = CGRectMake((self.contentView.bounds.size.width - 52)/2.0, 4, 52, 52);
            customIv.layer.cornerRadius = 11.0;
        }
        customIv.image = customImage;
        customIv.hidden = NO;
        customIv.alpha = 1.0;
    } else {
        // 已经用原生方式成功，把旧的 overlay 隐藏
        UIImageView *old = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (old) old.hidden = YES;
    }

    // 尝试把 badge 相关 view 重新置顶（避免被盖）
    for (UIView *sub in self.contentView.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls.lowercaseString containsString:@"badge"] ||
            [cls.lowercaseString containsString:@"dot"] ||
            sub.tag == 999) {   // 有些 badge 用特殊 tag
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

    UIView *imageRef = self.imageView;
    if (!imageRef || CGRectIsEmpty(imageRef.frame) || imageRef.frame.size.width < 24) {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.frame.size.width >= 28 && sub.frame.size.width <= 70) {
                imageRef = sub;
                break;
            }
        }
    }

    if (imageRef && [imageRef isKindOfClass:[UIImageView class]]) {
        // 优先直接改图，不隐藏，减少错位
        ((UIImageView *)imageRef).image = getTestRedImage();
        ((UIImageView *)imageRef).contentMode = UIViewContentModeScaleAspectFit;

        // 如果改完后还是被系统覆盖，再用小 overlay
        UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (!customIv) {
            customIv = [UIImageView new];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            [self.contentView addSubview:customIv];
        }
        customIv.frame = CGRectInset(imageRef.frame, 1.5, 1.5);
        customIv.layer.cornerRadius = 7.0;
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

#pragma mark - UIActivity 图片拦截（全版本通用）

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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (iOS14-17 优化 + 优先原生改图版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
