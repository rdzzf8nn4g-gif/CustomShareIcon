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
static UIImage *testRedImage = nil;   // 懒加载，绝不在 %ctor 里创建

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);

    Boolean keyExists = false;
    Boolean enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    isEnabled = keyExists ? enabledVal : NO;

    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (iconsRef && CFGetTypeID(iconsRef) == CFDictionaryGetTypeID()) {
        customIconsDict = [(__bridge NSDictionary *)iconsRef copy];
    } else {
        customIconsDict = nil;
    }
    if (iconsRef) CFRelease(iconsRef);

    if (!imageCache) {
        imageCache = [[NSMutableDictionary alloc] init];
    } else {
        [imageCache removeAllObjects];
    }

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)(customIconsDict ? customIconsDict.count : 0));
}

// 懒加载红色测试图（只在真正需要时、主线程创建）
static UIImage *getTestRedImage() {
    if (testRedImage) return testRedImage;

    // 使用固定 scale，避免依赖 UIScreen
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

    UIImage *img = [UIImage imageWithData:data scale:3.0]; // 固定 scale，安全
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] 加载成功 → %@", identifier);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *result = nil;

    // iOS 16+
    if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
        result = [proxy valueForKey:@"applicationBundleIdentifier"];
        if (result.length) return result;
    }

    // iOS 14 头文件里的 activity 属性
    id activity = nil;
    @try {
        activity = [proxy valueForKey:@"activity"];
    } @catch (NSException *e) {}

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

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)prepareForReuse {
    %orig;
    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (customIv) {
        customIv.hidden = YES;
        customIv.image = nil;
    }
}

%new
- (void)csi_applyCustomIcon {
    if (!isEnabled) return;

    __weak typeof(self) weakSelf = self;
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    id proxy = [strongSelf valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);

    UIImage *customImage = nil;
    if (identifier.length) {
        customImage = getCustomIconForID(identifier);
        NSLog(@"[CustomShareIcon] identifier=%@ custom=%@", identifier, customImage ? @"YES" : @"NO");
    } else {
        NSLog(@"[CustomShareIcon] 提取失败，使用红色测试图 proxy=%@", proxy);
    }

    // 没匹配到就用红色测试图（懒加载，安全）
    if (!customImage) {
        customImage = getTestRedImage();
    }

    UIView *slotView = [strongSelf valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [strongSelf valueForKey:@"activityImageView"];
    UIImageView *customIv = [strongSelf.contentView viewWithTag:TAG_CUSTOM_ICON];

    // 隐藏原生
    if (slotView) {
        slotView.hidden = YES;
        slotView.alpha = 0;
    }
    if (nativeIv) {
        nativeIv.hidden = YES;
        nativeIv.alpha = 0;
    }

    if (!customIv) {
        customIv = [UIImageView new];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        [strongSelf.contentView addSubview:customIv];
    }

    [strongSelf.contentView bringSubviewToFront:customIv];

    UIView *ref = (nativeIv && !CGRectIsEmpty(nativeIv.frame)) ? nativeIv : slotView;
    if (ref && !CGRectIsEmpty(ref.frame)) {
        customIv.frame = ref.frame;
        customIv.layer.cornerRadius = ref.layer.cornerRadius > 0 ? ref.layer.cornerRadius : 13.0;
    } else {
        customIv.frame = CGRectMake((strongSelf.contentView.bounds.size.width - 60)/2.0, 0, 60, 60);
        customIv.layer.cornerRadius = 13.0;
    }

    customIv.image = customImage;
    customIv.hidden = NO;
    customIv.alpha = 1.0;
}

%end

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
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (安全懒加载红色测试版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
