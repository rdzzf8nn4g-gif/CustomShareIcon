#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
- (void)setActivityProxy:(id)proxy;
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

    // 有配置就强制开启，保证多进程一致
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

    // iOS 16/17 头文件明确有 applicationBundleIdentifier
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

// 严格判断，防止在 Preferences 设置页误触发
static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    int depth = 0;
    while (r && depth < 12) {
        NSString *cls = NSStringFromClass([r class]);
        // 只认真正的分享相关类
        if ([cls isEqualToString:@"UIActivityViewController"] ||
            [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] ||
            [cls containsString:@"UIActivityList"] ||
            [cls containsString:@"_UIHostActivity"] ||
            [cls containsString:@"UIShareGroup"]) {
            return YES;
        }
        // 明确排除 Preferences
        if ([cls containsString:@"Preferences"] || [cls containsString:@"PSList"] || [cls containsString:@"CustomShareIcon"]) {
            return NO;
        }
        r = [r nextResponder];
        depth++;
    }
    return NO;
}

#pragma mark - 主面板（iOS 14-17 通用）

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    // iOS 16/17 slot 异步更重，多延迟几次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
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

    UIImage *customImage = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!customImage) customImage = getTestRedImage();

    // 寻找最准确的图标 view（优先 activityImageView，其次 imageSlotView 内部）
    UIImageView *targetIv = nil;
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];

    if (nativeIv && [nativeIv isKindOfClass:[UIImageView class]] && !CGRectIsEmpty(nativeIv.frame)) {
        targetIv = nativeIv;
    } else if (slotView) {
        for (UIView *sub in slotView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] && sub.frame.size.width >= 20) {
                targetIv = (UIImageView *)sub;
                break;
            }
        }
    }

    // 方案1：直接改原生 image（最不容易错位、不盖 badge）
    if (targetIv) {
        targetIv.image = customImage;
        targetIv.contentMode = UIViewContentModeScaleAspectFit;
        targetIv.hidden = NO;
        targetIv.alpha = 1.0;

        // 隐藏旧 overlay
        UIImageView *old = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (old) old.hidden = YES;
        return;
    }

    // 方案2：精确 overlay（严格使用目标 frame，绝不放大）
    UIView *ref = targetIv ?: (slotView ?: nativeIv);
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

    // 关键：完全使用 ref 的 frame，不 inset、不放大
    customIv.frame = ref.frame;
    customIv.layer.cornerRadius = ref.layer.cornerRadius > 0 ? ref.layer.cornerRadius : 13.0;
    customIv.image = customImage;
    customIv.hidden = NO;
    customIv.alpha = 1.0;

    [self.contentView bringSubviewToFront:customIv];

    // 把可能的 badge 重新置顶
    for (UIView *sub in self.contentView.subviews) {
        NSString *n = NSStringFromClass([sub class]).lowercaseString;
        if ([n containsString:@"badge"] || [n containsString:@"dot"]) {
            [self.contentView bringSubviewToFront:sub];
        }
    }
}

%end

#pragma mark - 「更多」列表（严格限制 + 精确大小）

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;

    if (!isEnabled) return;
    if (!isInShareSheetContext(self)) return;   // 严格排除设置页

    UIImageView *targetIv = nil;
    if (self.imageView && !CGRectIsEmpty(self.imageView.frame) && self.imageView.frame.size.width >= 28) {
        targetIv = self.imageView;
    } else {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.frame.size.width >= 28 && sub.frame.size.width <= 64) {
                targetIv = (UIImageView *)sub;
                break;
            }
        }
    }

    if (!targetIv) return;

    // 优先直接改图
    targetIv.image = getTestRedImage();
    targetIv.contentMode = UIViewContentModeScaleAspectFit;

    // 精确 overlay（只盖住图标本身）
    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [UIImageView new];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        [self.contentView addSubview:customIv];
    }
    customIv.frame = targetIv.frame;          // 完全一致的大小
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

#pragma mark - UIActivity 图片拦截

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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (精确大小 + 严格场景 + iOS14-17)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
