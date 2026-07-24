#import <UIKit/UIKit.h>

@interface UIShareGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
- (UIView *)imageSlotView;
@end

@interface UIActivityGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
- (UIView *)imageSlotView;
@end

@interface UIActivityActionGroupCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
- (UIView *)imageSlotView;
@end

#define TAG_CUSTOM_ICON 998877

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;

// =======================
// 核心：使用 IPC (CFPreferences) 获取数据，沙盒无法拦截！
// =======================
static void loadPrefs() {
    CFStringRef appID = CFSTR("com.iosdump.customshareicon");
    CFPreferencesAppSynchronize(appID);
    
    // 读取开关
    id enabledVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("Enabled"), appID);
    isEnabled = enabledVal ? [enabledVal boolValue] : NO;
    
    // 读取 Base64 图片字典
    id iconsVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("CustomIcons"), appID);
    if ([iconsVal isKindOfClass:[NSDictionary class]]) {
        customIconsDict = iconsVal;
    } else {
        customIconsDict = nil;
    }
}

// 从 Base64 还原图片并智能匹配 BundleID
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0 || !customIconsDict) return nil;
    
    NSString *base64Str = nil;
    
    if (customIconsDict[identifier]) {
        base64Str = customIconsDict[identifier]; // 精确匹配
    } else {
        for (NSString *key in customIconsDict.allKeys) { // 智能包含匹配 (比如微信)
            if (key.length > 0 && [identifier containsString:key]) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }
    
    if (base64Str) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
        if (data) return [UIImage imageWithData:data];
    }
    return nil;
}

static UIImage *getCustomIconForCell(id cell) {
    if (!isEnabled) return nil;
    if (![cell respondsToSelector:@selector(activityProxy)]) return nil;
    
    id proxy = [cell performSelector:@selector(activityProxy)];
    if (!proxy) return nil;
    
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
    
    if (identifier) {
        return getCustomIconForID(identifier);
    }
    return nil;
}

// 暴力摧毁所有可能导致原生图层显示的系统控件
static void killSystemLayers(UICollectionViewCell *cell) {
    // 隐藏指定属性图层
    if ([cell respondsToSelector:@selector(imageSlotView)]) {
        UIView *sv = [cell valueForKey:@"imageSlotView"];
        if (sv) { sv.hidden = YES; sv.alpha = 0; }
    }
    if ([cell respondsToSelector:@selector(activityImageView)]) {
        UIView *iv = [cell valueForKey:@"activityImageView"];
        if (iv) { iv.hidden = YES; iv.alpha = 0; }
    }
    
    // 循环遍历揪出所有跨进程 Remote 图层并干掉
    for (UIView *subview in cell.contentView.subviews) {
        NSString *className = NSStringFromClass([subview class]);
        if ([className containsString:@"Slot"] || [className containsString:@"Remote"] || [className containsString:@"Host"]) {
            subview.hidden = YES;
            subview.alpha = 0;
        }
    }
}

static void applyCustomImageToCell(UICollectionViewCell *cell, UIImage *customImage) {
    killSystemLayers(cell);
    
    UIImageView *customIv = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [[UIImageView alloc] init];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        
        if ([NSStringFromClass([cell class]) containsString:@"Action"]) {
            customIv.layer.cornerRadius = 0;
            customIv.frame = CGRectMake((cell.contentView.bounds.size.width - 28)/2, 16, 28, 28);
        } else {
            customIv.layer.cornerRadius = 13.0; 
            customIv.frame = CGRectMake((cell.contentView.bounds.size.width - 60)/2, 0, 60, 60);
        }
        [cell.contentView addSubview:customIv];
    }
    
    [cell.contentView bringSubviewToFront:customIv]; // 强行拉到最顶层
    customIv.image = customImage;
    customIv.hidden = NO;
}

static void restoreCell(UICollectionViewCell *cell) {
    if ([cell respondsToSelector:@selector(imageSlotView)]) {
        UIView *sv = [cell valueForKey:@"imageSlotView"];
        if (sv) { sv.hidden = NO; sv.alpha = 1.0; }
    }
    if ([cell respondsToSelector:@selector(activityImageView)]) {
        UIView *iv = [cell valueForKey:@"activityImageView"];
        if (iv) { iv.hidden = NO; iv.alpha = 1.0; }
    }
    
    UIView *customIv = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (customIv) {
        customIv.hidden = YES;
    }
}

%hook UIShareGroupActivityCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) { applyCustomImageToCell(self, custom); } else { restoreCell(self); }
}
%end

%hook UIActivityGroupActivityCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) { applyCustomImageToCell(self, custom); } else { restoreCell(self); }
}
%end

%hook UIActivityActionGroupCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) { applyCustomImageToCell(self, custom); } else { restoreCell(self); }
}
%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
