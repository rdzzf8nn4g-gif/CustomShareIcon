#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 声明要 Hook 的类，避免编译器找不到类型
// =======================
@interface UIShareGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
- (UIView *)imageSlotView; // iOS 16+ 跨进程映射图层
@end

@interface UIActivityGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
@end

@interface UIActivityActionGroupCell : UICollectionViewCell
- (id)activityProxy;
- (UIImageView *)activityImageView;
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

// =======================
// 核心读取与匹配逻辑
// =======================
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    NSString *dir = GetMediaDir();
    
    // 1. 精确匹配
    NSString *exactPath = [[dir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
        return [UIImage imageWithContentsOfFile:exactPath];
    }
    
    // 2. 智能前缀匹配 (针对 com.tencent.xin.shareextension)
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
    
    NSString *identifier = nil;
    
    // 优先 1：读取 iOS 16-17 _UIHostActivityProxy 特有的 applicationBundleIdentifier
    if ([proxy respondsToSelector:NSSelectorFromString(@"applicationBundleIdentifier")]) {
        identifier = [proxy valueForKey:@"applicationBundleIdentifier"];
    }
    
    // 优先 2：深入读取原始 activity 的 identifier (兼容 iOS 14-15)
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
    
    if (identifier) {
        return getCustomIconForID(identifier);
    }
    return nil;
}

// 核心杀手锏：接管视图并抹除跨进程 Slot 映射
static void handleCellUpdate(id cell) {
    UIImage *custom = getCustomIconForCell(cell);
    if (custom) {
        // 1. 隐藏 iOS 16+ 的跨进程渲染图层 (SlotView)，这是图标死活不生效的罪魁祸首！
        if ([cell respondsToSelector:@selector(imageSlotView)]) {
            UIView *slotView = [cell performSelector:@selector(imageSlotView)];
            if (slotView && [slotView isKindOfClass:[UIView class]]) {
                slotView.hidden = YES;
                slotView.alpha = 0;
            }
        }
        
        // 2. 强行把我们的图片设置给底层的 activityImageView 并确保显示
        if ([cell respondsToSelector:@selector(activityImageView)]) {
            UIImageView *iv = [cell performSelector:@selector(activityImageView)];
            if (iv && [iv isKindOfClass:[UIImageView class]]) {
                iv.image = custom;
                iv.hidden = NO;
                iv.alpha = 1.0;
            }
        }
    }
}


// =======================
// Cell UI 渲染劫持模块
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

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
