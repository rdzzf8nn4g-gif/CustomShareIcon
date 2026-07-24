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
+ (id)_imageByApplyingDefaultEffectsToImage:(id)image activityCategory:(long long)category iconFormat:(int)format;
- (UIImage *)activityImage;
- (UIImage *)_activityImage;
- (NSString *)_systemImageName;
- (NSString *)activityType;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

static void loadPrefs() {
    // 强制从磁盘重新同步
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

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier || identifier.length == 0 || !customIconsDict) return nil;

    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = customIconsDict[identifier];
    if (!base64Str) {
        for (NSString *key in customIconsDict.allKeys) {
            if (key.length > 0 && ([identifier containsString:key] || [key containsString:identifier])) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }

    if (!base64Str) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
    if (!data) return nil;

    UIImage *img = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] 加载成功 → %@", identifier);
    }
    return img;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;

    NSString *result = nil;

    // 1. iOS 16+ 
    if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
        result = [proxy valueForKey:@"applicationBundleIdentifier"];
        if (result.length > 0) return result;
    }

    // 2. 尝试拿 activity（iOS 14 头文件里有这个属性）
    id activity = nil;
    @try {
        activity = [proxy valueForKey:@"activity"];
    } @catch (NSException *e) {}

    if (activity) {
        if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
            result = [activity valueForKey:@"containingAppBundleIdentifier"];
            if (result.length > 0) return result;
        }

        if ([activity respondsToSelector:@selector(applicationExtension)]) {
            id ext = [activity valueForKey:@"applicationExtension"];
            if (ext) {
                result = [ext valueForKey:@"identifier"];
                if (result.length > 0) return result;

                id bundle = [ext valueForKey:@"_bundle"];
                if (bundle) {
                    result = [bundle bundleIdentifier];
                    if (result.length > 0) return result;
                }
            }
        }

        if ([activity respondsToSelector:@selector(activityType)]) {
            result = [activity valueForKey:@"activityType"];
            if (result.length > 0) return result;
        }
    }

    // 3. 最后兜底
    if ([proxy respondsToSelector:@selector(activityType)]) {
        result = [proxy valueForKey:@"activityType"];
        if (result.length > 0) return result;
    }

    return nil;
}

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_applyCustomIcon];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *nativeIv = [self valueForKey:@"activityImageView"];
    if (slotView) { slotView.hidden = NO; slotView.alpha = 1.0; }
    if (nativeIv) { nativeIv.hidden = NO; nativeIv.alpha = 1.0; }
}

%new
- (void)csi_applyCustomIcon {
    if (!isEnabled || !customIconsDict) return;

    __weak typeof(self) weakSelf = self;
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) return;

    id proxy = [strongSelf valueForKey:@"activityProxy"];
    if (!proxy) return;

    NSString *identifier = extractIdentifier(proxy);
    if (!identifier.length) {
        NSLog(@"[CustomShareIcon] 提取失败 proxy=%@", proxy);
        return;
    }

    NSLog(@"[CustomShareIcon] identifier = %@", identifier);

    UIImage *customImage = getCustomIconForID(identifier);

    UIView *slotView = [strongSelf valueForKey:@"imageSlotView"];
    UIImageView *nativeIv = [strongSelf valueForKey:@"activityImageView"];
    UIImageView *customIv = [strongSelf.contentView viewWithTag:TAG_CUSTOM_ICON];

    if (customImage) {
        // 路径1：直接换原生
        if (nativeIv && [nativeIv isKindOfClass:[UIImageView class]]) {
            nativeIv.image = customImage;
            nativeIv.hidden = NO;
            nativeIv.alpha = 1.0;
            nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        }

        // 路径2：强力 overlay
        if (slotView) {
            slotView.hidden = YES;
            slotView.alpha = 0.0;
        }

        if (!customIv) {
            customIv = [[UIImageView alloc] init];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            customIv.userInteractionEnabled = NO;
            [strongSelf.contentView addSubview:customIv];
        }

        [strongSelf.contentView bringSubviewToFront:customIv];

        UIView *ref = (nativeIv && !CGRectIsEmpty(nativeIv.frame)) ? nativeIv : slotView;
        if (ref && !CGRectIsEmpty(ref.frame)) {
            customIv.frame = ref.frame;
            customIv.layer.cornerRadius = ref.layer.cornerRadius > 0 ? ref.layer.cornerRadius : 13.0;
        } else {
            BOOL isAction = [NSStringFromClass([strongSelf class]) rangeOfString:@"Action"].location != NSNotFound;
            CGFloat size = isAction ? 28.0 : 60.0;
            CGFloat y = isAction ? 16.0 : 0.0;
            customIv.frame = CGRectMake((strongSelf.contentView.bounds.size.width - size) / 2.0, y, size, size);
            customIv.layer.cornerRadius = isAction ? 0.0 : 13.0;
        }

        customIv.image = customImage;
        customIv.hidden = NO;
        customIv.alpha = 1.0;

        NSLog(@"[CustomShareIcon] 已强制替换图标 → %@", identifier);
    } else {
        if (slotView) { slotView.hidden = NO; slotView.alpha = 1.0; }
        if (nativeIv) { nativeIv.hidden = NO; nativeIv.alpha = 1.0; }
        if (customIv) customIv.hidden = YES;
    }
}

%end

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    if (custom) {
        NSLog(@"[CustomShareIcon] UIActivity class 拦截 → %@", identifier);
        return custom;
    }
    return %orig;
}

+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    NSString *bid = nil;
    if ([configuration respondsToSelector:@selector(bundleIdentifier)]) {
        bid = [configuration valueForKey:@"bundleIdentifier"];
    }
    UIImage *custom = getCustomIconForID(bid);
    return custom ?: %orig;
}

+ (id)_imageByApplyingDefaultEffectsToImage:(id)image activityCategory:(long long)category iconFormat:(int)format {
    return %orig;
}

- (UIImage *)activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *custom = getCustomIconForID(type);
    if (custom) {
        NSLog(@"[CustomShareIcon] activityImage 拦截 → %@", type);
        return custom;
    }
    return %orig;
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
    if (custom) {
        NSLog(@"[CustomShareIcon] ExtensionActivity 拦截 → %@", bid);
        return custom;
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (CFPreferences 稳定版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}
