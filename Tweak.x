#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 通用定义与沙盒穿透路径
// =======================
static NSString * GetMediaDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSString * GetPrefPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static BOOL isEnabled = NO;

static void loadPrefs() {
    // 强制使用字典读取，避免 CFPreferences 在某些高限制沙盒中失败
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefPath()];
    isEnabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : NO;
}

// 核心查找图片：支持前缀匹配 (应对 com.tencent.xin.shareextension)
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    NSString *dir = GetMediaDir();
    
    // 1. 精确匹配
    NSString *exactPath = [[dir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
        return [UIImage imageWithContentsOfFile:exactPath];
    }
    
    // 2. 智能前缀匹配
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
        if ([file hasSuffix:@".png"]) {
            NSString *confID = [file stringByDeletingPathExtension]; 
            if (confID.length > 0 && [identifier hasPrefix:confID]) {
                NSString *path = [dir stringByAppendingPathComponent:file];
                return [UIImage imageWithContentsOfFile:path];
            }
        }
    }
    return nil;
}

// =======================
// Cell UI 层拦截模块 (无视任何缓存，直接干预视图)
// =======================
static void handleCellUpdate(id cell) {
    if (!isEnabled) return;
    if (![cell respondsToSelector:@selector(activityProxy)]) return;
    
    id proxy = [cell performSelector:@selector(activityProxy)];
    if (!proxy) return;
    
    NSString *actType = nil;
    if ([proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
        actType = [proxy valueForKey:@"activityType"];
    }
    
    if (actType) {
        UIImage *custom = getCustomIconForID(actType);
        if (custom) {
            if ([cell respondsToSelector:@selector(activityImageView)]) {
                UIImageView *iv = [cell performSelector:@selector(activityImageView)];
                if (iv && [iv isKindOfClass:[UIImageView class]]) {
                    iv.image = custom; // 强行替换
                }
            }
        }
    }
}

// 宏定义：批量 Hook 各个 iOS 版本的 Cell 渲染类
#define HOOK_SHARE_CELL(CellClass) \
%hook CellClass \
- (void)setImage:(UIImage *)img { \
    if (isEnabled) { \
        id proxy = [self respondsToSelector:@selector(activityProxy)] ? [self performSelector:@selector(activityProxy)] : nil; \
        NSString *actType = proxy && [proxy respondsToSelector:NSSelectorFromString(@"activityType")] ? [proxy valueForKey:@"activityType"] : nil; \
        if (actType) { \
            UIImage *custom = getCustomIconForID(actType); \
            if (custom) { \
                %orig(custom); \
                return; \
            } \
        } \
    } \
    %orig(img); \
} \
- (void)_updateImageView { \
    %orig; \
    handleCellUpdate(self); \
} \
- (void)layoutSubviews { \
    %orig; \
    handleCellUpdate(self); \
} \
%end

// 针对 iOS 16-17 的 App 列表
HOOK_SHARE_CELL(UIShareGroupActivityCell)
// 针对 iOS 14-15 的 App 列表
HOOK_SHARE_CELL(UIActivityGroupActivityCell)
// 针对 iOS 14-17 的 动作(复制、Safari打开等) 列表
HOOK_SHARE_CELL(UIActivityActionGroupCell)


// =======================
// 数据源层拦截模块 (备用，用于兜底某些原生功能)
// =======================
@protocol CSIActivityProtocol <NSObject>
@optional
- (NSString *)containingAppBundleIdentifier;
- (NSString *)activityType;
@end

static NSString *getIdentifierForActivity(id<CSIActivityProtocol> activity) {
    NSString *identifier = nil;
    if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        identifier = [activity containingAppBundleIdentifier];
    }
    if (!identifier || identifier.length == 0) {
        if ([activity respondsToSelector:@selector(activityType)]) {
            identifier = [activity activityType];
        }
    }
    return identifier;
}

%hook UIActivity
- (UIImage *)activityImage {
    if (isEnabled) {
        UIImage *custom = getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self));
        if (custom) return custom;
    }
    return %orig;
}
- (UIImage *)_activityImage {
    if (isEnabled) {
        UIImage *custom = getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self));
        if (custom) return custom;
    }
    return %orig;
}
- (UIImage *)_actionImage {
    if (isEnabled) {
        UIImage *custom = getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self));
        if (custom) return custom;
    }
    return %orig;
}
- (NSString *)_systemImageName {
    if (isEnabled && getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self))) {
        return nil; // 强行废掉系统图标 fallback
    }
    return %orig;
}
%end

%hook UIApplicationExtensionActivity
- (UIImage *)activityImage {
    if (isEnabled) {
        UIImage *custom = getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self));
        if (custom) return custom;
    }
    return %orig;
}
- (UIImage *)_activityImage {
    if (isEnabled) {
        UIImage *custom = getCustomIconForID(getIdentifierForActivity((id<CSIActivityProtocol>)self));
        if (custom) return custom;
    }
    return %orig;
}
%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
