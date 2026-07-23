#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 声明可能用到的方法，避免编译器警告
@protocol CSIActivityProtocol <NSObject>
@optional
- (NSString *)containingAppBundleIdentifier;
- (NSString *)activityType;
@end

@interface UIShareGroupActivityCell : UICollectionViewCell
- (id)activityProxy; // returns _UIHostActivityProxy
- (UIImageView *)activityImageView;
@end

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
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefPath()];
    isEnabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : NO;
}

// 核心查找图片方法：支持精确匹配与前缀匹配
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    NSString *dir = GetMediaDir();
    
    // 1. 精确匹配 (比如原生分享事件: com.apple.UIKit.activity.CopyToPasteboard)
    NSString *exactPath = [[dir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
        return [UIImage imageWithContentsOfFile:exactPath];
    }
    
    // 2. 智能前缀匹配 (核心修正：第三方应用实际传入的可能是 com.tencent.xin.shareextension)
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
        if ([file hasSuffix:@".png"]) {
            NSString *confID = [file stringByDeletingPathExtension]; // 用户填入的 com.tencent.xin
            if (confID.length > 0 && [identifier hasPrefix:confID]) {
                NSString *path = [dir stringByAppendingPathComponent:file];
                return [UIImage imageWithContentsOfFile:path];
            }
        }
    }
    return nil;
}

// 通用提取标识符的方法
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

// ==========================================
// Hook 1: 暴力 Hook 负责显示的 UI 控件 (最稳妥)
// ==========================================
%hook UIShareGroupActivityCell

// iOS 14-17 通用的视图更新生命周期
- (void)layoutSubviews {
    %orig;
    if (!isEnabled) return;
    
    id proxy = [self activityProxy];
    if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
        NSString *actType = [proxy valueForKey:@"activityType"];
        UIImage *custom = getCustomIconForID(actType);
        if (custom) {
            if ([self respondsToSelector:@selector(activityImageView)]) {
                UIImageView *iv = [self activityImageView];
                if (iv) iv.image = custom;
            }
        }
    }
}

// 针对 iOS 16-17 存在的专用设值方法
- (void)setImage:(UIImage *)image {
    if (isEnabled) {
        id proxy = [self activityProxy];
        if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
            NSString *actType = [proxy valueForKey:@"activityType"];
            UIImage *custom = getCustomIconForID(actType);
            if (custom) {
                %orig(custom);
                return;
            }
        }
    }
    %orig(image);
}

// 针对 UI 更新刷新方法
- (void)_updateImageView {
    %orig;
    if (!isEnabled) return;
    
    id proxy = [self activityProxy];
    if (proxy && [proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
        NSString *actType = [proxy valueForKey:@"activityType"];
        UIImage *custom = getCustomIconForID(actType);
        if (custom) {
            if ([self respondsToSelector:@selector(activityImageView)]) {
                UIImageView *iv = [self activityImageView];
                if (iv) iv.image = custom;
            }
        }
    }
}
%end


// ==========================================
// Hook 2: 从数据源头进行拦截（覆盖原生动作和类方法）
// ==========================================
%hook UIActivity

// 拦截底层根据 Bundle ID 获取图标的类方法
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    if (isEnabled && identifier) {
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

+ (id)_activitySettingsImageForApplicationBundleIdentifier:(NSString *)identifier {
    if (isEnabled && identifier) {
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

// 拦截系统自带（如 Copy、Safari等）优先使用 SF Symbol 的机制
- (NSString *)_systemImageName {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) {
            // 如果我们有自定义图片，必须返回 nil，强迫系统回退去调用 _activityImage
            return nil;
        }
    }
    return %orig;
}

// 拦截实例方法
- (UIImage *)activityImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_actionImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

%end

// 针对扩展类的强行覆盖
%hook UIApplicationExtensionActivity

- (UIImage *)activityImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

- (UIImage *)_actionImage {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        UIImage *custom = getCustomIconForID(identifier);
        if (custom) return custom;
    }
    return %orig;
}

- (NSString *)_systemImageName {
    if (isEnabled) {
        NSString *identifier = getIdentifierForActivity((id<CSIActivityProtocol>)self);
        if (getCustomIconForID(identifier)) return nil;
    }
    return %orig;
}

%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
