#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

// =======================
// 统一从包域名读取（彻底解决零效果的核心）
// =======================
static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);

    id enabledVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("Enabled"), PREFS_DOMAIN);
    isEnabled = enabledVal ? [enabledVal boolValue] : NO;

    id iconsVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if ([iconsVal isKindOfClass:[NSDictionary class]]) {
        customIconsDict = [iconsVal copy];
    } else {
        customIconsDict = nil;
    }

    if (!imageCache) {
        imageCache = [[NSMutableDictionary alloc] init];
    } else {
        [imageCache removeAllObjects];
    }

    NSLog(@"[CustomShareIcon] loadPrefs → enabled=%d iconsCount=%lu", isEnabled, (unsigned long)customIconsDict.count);
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier || identifier.length == 0 || !customIconsDict) return nil;

    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64Str = customIconsDict[identifier];
    if (!base64Str) {
        // 智能模糊匹配
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
        NSLog(@"[CustomShareIcon] 成功加载自定义图标 → %@", identifier);
    }
    return img;
}

// =======================
// 最强 Identifier 提取（覆盖 iOS 14 ~ 17+ 全部头文件属性）
// =======================
static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;

    NSString *result = nil;

    // iOS 16+ 最优先
    if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
        result = [proxy valueForKey:@"applicationBundleIdentifier"];
        if (result.length > 0) return result;
    }

    id activity = nil;
    if ([proxy respondsToSelector:@selector(activity)]) {
        activity = [proxy valueForKey:@"activity"];
    }

    if (activity) {
        // UIApplicationExtensionActivity
        if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
            result = [activity valueForKey:@"containingAppBundleIdentifier"];
            if (result.length > 0) return result;
        }

        // 扩展本身
        if ([activity respondsToSelector:@selector(applicationExtension)]) {
            id ext = [activity valueForKey:@"applicationExtension"];
            if (ext) {
                if ([ext respondsToSelector:@selector(identifier)]) {
                    result = [ext valueForKey:@"identifier"];
                    if (result.length > 0) return result;
                }
                // 再试 bundle
                id bundle = [ext valueForKey:@"_bundle"];
                if (bundle && [bundle respondsToSelector:@selector(bundleIdentifier)]) {
                    result = [bundle bundleIdentifier];
                    if (result.length > 0) return result;
                }
            }
        }

        // activityType（系统动作 + 兜底）
        if ([activity respondsToSelector:@selector(activityType)]) {
            result = [activity valueForKey:@"activityType"];
            if (result.length > 0) return result;
        }
    }

    // 最后兜底
    if ([proxy respondsToSelector:@selector(activityType)]) {
        result = [proxy valueForKey:@"activityType"];
        if (result.length > 0) return result;
    }

    return nil;
}

// =======================
// 核心 Cell Hook（针对 UIShareGroupActivityCell）
// =======================
%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIconWithDelay:NO];
}

- (void)setImage:(UIImage *)image {
    // iOS 16+ 有此方法
    NSString *identifier = extractIdentifier(self.activityProxy);
    UIImage *custom = getCustomIconForID(identifier);
    if (custom) {
        %orig(custom);
        return;
    }
    %orig;
}

- (void)_updateImageView {
    // iOS 16+ 关键图片更新路径
    %orig;
    [self csi_applyCustomIconWithDelay:NO];
}

- (void)_configureImageViewForPlaceholder:(_Bool)placeholder {
    // iOS 17+
    %orig;
    [self csi_applyCustomIconWithDelay:NO];
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIconWithDelay:NO];
}

- (void)prepareForReuse {
    %orig;

    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (customIv) {
        customIv.hidden = YES;
        customIv.image = nil;
    }

    // 恢复原生
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *nativeIv = [self valueForKey:@"activityImageView"];
    if (slotView) {
        slotView.hidden = NO;
        slotView.alpha = 1.0;
    }
    if (nativeIv) {
        nativeIv.hidden = NO;
        nativeIv.alpha = 1.0;
    }
}

%new
- (void)csi_applyCustomIconWithDelay:(BOOL)needDelay {
    if (!isEnabled || !customIconsDict) return;

    void (^applyBlock)(void) = ^{
        id proxy = nil;
        if ([self respondsToSelector:@selector(activityProxy)]) {
            proxy = [self valueForKey:@"activityProxy"];
        }
        if (!proxy) return;

        NSString *identifier = extractIdentifier(proxy);
        if (!identifier || identifier.length == 0) {
            NSLog(@"[CustomShareIcon] 无法提取 identifier，proxy = %@", proxy);
            return;
        }

        NSLog(@"[CustomShareIcon] 提取到 identifier = %@", identifier);

        UIImage *customImage = getCustomIconForID(identifier);

        UIView *slotView = [self valueForKey:@"imageSlotView"];
        UIView *nativeIv = [self valueForKey:@"activityImageView"];
        UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];

        if (customImage) {
            // 隐藏系统原生
            if (slotView) {
                slotView.hidden = YES;
                slotView.alpha = 0.0;
            }
            if (nativeIv) {
                nativeIv.hidden = YES;
                nativeIv.alpha = 0.0;
            }

            if (!customIv) {
                customIv = [[UIImageView alloc] init];
                customIv.tag = TAG_CUSTOM_ICON;
                customIv.contentMode = UIViewContentModeScaleAspectFit;
                customIv.clipsToBounds = YES;
                customIv.userInteractionEnabled = NO;
                [self.contentView addSubview:customIv];
            }

            [self.contentView bringSubviewToFront:customIv];

            // 对齐位置
            UIView *referenceView = slotView ?: nativeIv;
            if (referenceView && !CGRectIsEmpty(referenceView.frame)) {
                customIv.frame = referenceView.frame;
                CGFloat radius = referenceView.layer.cornerRadius;
                customIv.layer.cornerRadius = radius > 0 ? radius : 13.0;
            } else {
                BOOL isActionStyle = [NSStringFromClass([self class]) rangeOfString:@"Action"].location != NSNotFound;
                CGFloat size = isActionStyle ? 28.0 : 60.0;
                CGFloat y = isActionStyle ? 16.0 : 0.0;
                customIv.frame = CGRectMake((self.contentView.bounds.size.width - size) / 2.0, y, size, size);
                customIv.layer.cornerRadius = isActionStyle ? 0.0 : 13.0;
            }

            customIv.image = customImage;
            customIv.hidden = NO;
            customIv.alpha = 1.0;

            NSLog(@"[CustomShareIcon] 已应用自定义图标 → %@", identifier);
        } else {
            // 恢复原状
            if (slotView) {
                slotView.hidden = NO;
                slotView.alpha = 1.0;
            }
            if (nativeIv) {
                nativeIv.hidden = NO;
                nativeIv.alpha = 1.0;
            }
            if (customIv) {
                customIv.hidden = YES;
            }
        }
    };

    if (needDelay) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), applyBlock);
    } else {
        applyBlock();
        // 异步加载兜底（非常关键）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self csi_applyCustomIconWithDelay:NO];
        });
    }
}

%end

// =======================
// UIActivity 兜底 Hook（加强版）
// =======================
%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    if (custom) {
        NSLog(@"[CustomShareIcon] UIActivity class method 拦截成功 → %@", identifier);
        return custom;
    }
    return %orig;
}

- (UIImage *)activityImage {
    NSString *type = nil;
    if ([self respondsToSelector:@selector(activityType)]) {
        type = [self activityType];
    }
    UIImage *custom = getCustomIconForID(type);
    if (custom) {
        NSLog(@"[CustomShareIcon] activityImage 拦截成功 → %@", type);
        return custom;
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
    return %orig;
}

- (NSString *)_systemImageName {
    NSString *type = nil;
    if ([self respondsToSelector:@selector(activityType)]) {
        type = [self activityType];
    }
    if (getCustomIconForID(type)) {
        return nil; // 强制禁用系统 SF Symbol
    }
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
        NSLog(@"[CustomShareIcon] UIApplicationExtensionActivity 拦截成功 → %@", bid);
        return custom;
    }
    return %orig;
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] Tweak 已加载");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL,
                                    CFNotificationSuspensionBehaviorCoalesce);
}
