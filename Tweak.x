#import <UIKit/UIKit.h>

#define TAG_CUSTOM_ICON 998877

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil; // 性能优化：防止滑动卡顿

// =======================
// 核心：从全局域拉取数据 (完全免疫沙盒拦截)
// =======================
static void loadPrefs() {
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    
    id enabledVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Enabled"), kCFPreferencesAnyApplication);
    isEnabled = enabledVal ? [enabledVal boolValue] : NO;
    
    id iconsVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    if ([iconsVal isKindOfClass:[NSDictionary class]]) {
        customIconsDict = iconsVal;
    } else {
        customIconsDict = nil;
    }
    
    // 初始化/清空缓存
    if (!imageCache) {
        imageCache = [[NSMutableDictionary alloc] init];
    } else {
        [imageCache removeAllObjects];
    }
}

// 解析并缓存 Base64 图片，智能匹配 BundleID
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier || identifier.length == 0 || !customIconsDict) return nil;
    
    // 如果缓存里有，直接秒回
    if (imageCache[identifier]) return imageCache[identifier];
    
    NSString *base64Str = customIconsDict[identifier];
    if (!base64Str) {
        // 智能模糊匹配 (修复 com.apple.UIKit...com.tencent.xin 问题)
        for (NSString *key in customIconsDict.allKeys) {
            if (key.length > 0 && [identifier containsString:key]) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }
    
    if (base64Str) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
        if (data) {
            UIImage *img = [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
            if (img) {
                imageCache[identifier] = img; // 存入缓存
                return img;
            }
        }
    }
    return nil;
}

// =======================
// UI 强制覆写：拦截所有 UICollectionViewCell
// =======================
%hook UICollectionViewCell

- (void)layoutSubviews {
    %orig;
    if (!isEnabled || !customIconsDict) return;
    
    // 识别是否为分享面板图标
    if (![self respondsToSelector:@selector(activityProxy)]) return;
    id proxy = [self performSelector:@selector(activityProxy)];
    if (!proxy) return;
    
    // 疯狂榨取标识符
    NSString *identifier = nil;
    if ([proxy respondsToSelector:NSSelectorFromString(@"applicationBundleIdentifier")]) {
        identifier = [proxy valueForKey:@"applicationBundleIdentifier"];
    }
    if ((!identifier || identifier.length == 0) && [proxy respondsToSelector:NSSelectorFromString(@"activity")]) {
        id activity = [proxy valueForKey:@"activity"];
        if (activity) {
            if ([activity respondsToSelector:NSSelectorFromString(@"containingAppBundleIdentifier")]) {
                identifier = [activity valueForKey:@"containingAppBundleIdentifier"];
            }
            if (!identifier || identifier.length == 0) {
                if ([activity respondsToSelector:NSSelectorFromString(@"activityType")]) {
                    identifier = [activity valueForKey:@"activityType"];
                }
            }
        }
    }
    if ((!identifier || identifier.length == 0) && [proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
        identifier = [proxy valueForKey:@"activityType"];
    }
    if (!identifier || identifier.length == 0) return;
    
    // 获取自定义图片
    UIImage *customImage = getCustomIconForID(identifier);
    
    // 获取原生图层
    UIView *slotView = [self respondsToSelector:@selector(imageSlotView)] ? [self valueForKey:@"imageSlotView"] : nil;
    UIView *nativeIv = [self respondsToSelector:@selector(activityImageView)] ? [self valueForKey:@"activityImageView"] : nil;
    UIImageView *customIv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    
    if (customImage) {
        // 1. 无情隐藏系统原生图层，防止遮挡
        if (slotView) { slotView.hidden = YES; slotView.alpha = 0; }
        if (nativeIv) { nativeIv.hidden = YES; nativeIv.alpha = 0; }
        
        // 2. 创建或更新我们的专属图层
        if (!customIv) {
            customIv = [[UIImageView alloc] init];
            customIv.tag = TAG_CUSTOM_ICON;
            customIv.contentMode = UIViewContentModeScaleAspectFit;
            customIv.clipsToBounds = YES;
            [self.contentView addSubview:customIv];
        }
        
        [self.contentView bringSubviewToFront:customIv];
        
        // 3. 对齐位置
        UIView *referenceView = slotView ?: nativeIv;
        if (referenceView && !CGRectIsEmpty(referenceView.frame)) {
            customIv.frame = referenceView.frame;
            customIv.layer.cornerRadius = referenceView.layer.cornerRadius > 0 ? referenceView.layer.cornerRadius : 13.0;
        } else {
            if ([NSStringFromClass([self class]) containsString:@"Action"]) {
                customIv.frame = CGRectMake((self.contentView.bounds.size.width - 28)/2, 16, 28, 28);
                customIv.layer.cornerRadius = 0;
            } else {
                customIv.frame = CGRectMake((self.contentView.bounds.size.width - 60)/2, 0, 60, 60);
                customIv.layer.cornerRadius = 13.0;
            }
        }
        
        customIv.image = customImage;
        customIv.hidden = NO;
        
    } else {
        // 如果没有配置图片，必须恢复原状 (处理复用)
        if (slotView) { slotView.hidden = NO; slotView.alpha = 1.0; }
        if (nativeIv) { nativeIv.hidden = NO; nativeIv.alpha = 1.0; }
        if (customIv) { customIv.hidden = YES; }
    }
}

%end


// =======================
// 数据源 Hook (兜底)
// =======================
%hook UIActivity
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}
- (UIImage *)activityImage {
    UIImage *custom = getCustomIconForID([self respondsToSelector:@selector(activityType)] ? [self performSelector:@selector(activityType)] : nil);
    return custom ?: %orig;
}
- (NSString *)_systemImageName {
    if (getCustomIconForID([self respondsToSelector:@selector(activityType)] ? [self performSelector:@selector(activityType)] : nil)) return nil;
    return %orig;
}
%end


%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
