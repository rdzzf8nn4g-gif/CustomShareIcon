#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 声明要 Hook 的私有类，避免编译器找不到类型
// =======================
@interface UIShareGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
@end

@interface UIActivityGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
@end

@interface UIActivityActionGroupCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
@end

@protocol CSIActivityProtocol <NSObject>
@optional
- (NSString *)containingAppBundleIdentifier;
- (NSString *)activityType;
@end


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
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefPath()];
    isEnabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : NO;
}

// 核心查找图片：支持前缀匹配
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

static UIImage *getCustomIconForCell(id cell) {
    if (!isEnabled) return nil;
    if (![cell respondsToSelector:@selector(activityProxy)]) return nil;
    
    id proxy = [cell performSelector:@selector(activityProxy)];
    if (!proxy) return nil;
    
    NSString *actType = nil;
    if ([proxy respondsToSelector:NSSelectorFromString(@"activityType")]) {
        actType = [proxy valueForKey:@"activityType"];
    }
    
    if (actType) {
        return getCustomIconForID(actType);
    }
    return nil;
}

static void handleCellUpdate(id cell) {
    UIImage *custom = getCustomIconForCell(cell);
    if (custom) {
        if ([cell respondsToSelector:@selector(activityImageView)]) {
            UIImageView *iv = [cell performSelector:@selector(activityImageView)];
            if (iv && [iv isKindOfClass:[UIImageView class]]) {
                iv.image = custom; // 强行替换视图
            }
        }
    }
}


// =======================
// Cell UI 层拦截模块 (手动展开宏，完美兼容 Logos 编译器)
// =======================

%hook UIShareGroupActivityCell
- (void)setImage:(UIImage *)img {
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        %orig(custom);
        return;
    }
    %orig(img);
}
- (void)_updateImageView {
    %orig;
    handleCellUpdate(self);
}
- (void)layoutSubviews {
    %orig;
    handleCellUpdate(self);
}
%end

%hook UIActivityGroupActivityCell
- (void)setImage:(UIImage *)img {
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        %orig(custom);
        return;
    }
    %orig(img);
}
- (void)_updateImageView {
    %orig;
    handleCellUpdate(self);
}
- (void)layoutSubviews {
    %orig;
    handleCellUpdate(self);
}
%end

%hook UIActivityActionGroupCell
- (void)setImage:(UIImage *)img {
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        %orig(custom);
        return;
    }
    %orig(img);
}
- (void)_updateImageView {
    %orig;
    handleCellUpdate(self);
}
- (void)layoutSubviews {
    %orig;
    handleCellUpdate(self);
}
%end


// =======================
// 数据源层拦截模块 (备用，兜底原生功能)
// =======================

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
        return nil; // 废掉原生 SF Symbol fallback
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
