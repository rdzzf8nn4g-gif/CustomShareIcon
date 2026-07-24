#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

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

// =======================
// 通用定义与沙盒穿透路径 (与设置一致)
// =======================
static NSString * GetMediaDir() {
    NSString *base = @"/Library/Application Support/CustomShareIcon";
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

// 直接读取物理文件判断开关，彻底避开 cfprefsd 沙盒权限！
static void loadPrefs() {
    NSString *flagPath = [GetMediaDir() stringByAppendingPathComponent:@"enabled.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:flagPath]) {
        NSString *val = [NSString stringWithContentsOfFile:flagPath encoding:NSUTF8StringEncoding error:nil];
        isEnabled = [val isEqualToString:@"1"];
    } else {
        isEnabled = NO;
    }
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    NSString *dir = GetMediaDir();
    
    NSString *exactPath = [[dir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
        return [UIImage imageWithContentsOfFile:exactPath];
    }
    
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
    
    if (identifier) {
        return getCustomIconForID(identifier);
    }
    return nil;
}

// 核心强杀跨进程图层：处理复用，抹除 slot
static void handleCellUpdate(id cell) {
    if (!isEnabled) return;
    UIImage *custom = getCustomIconForCell(cell);
    
    if (custom) {
        if ([cell respondsToSelector:@selector(imageSlotView)]) {
            UIView *slotView = [cell performSelector:@selector(imageSlotView)];
            if (slotView) {
                slotView.hidden = YES;
                slotView.alpha = 0;
            }
        }
        
        if ([cell respondsToSelector:@selector(activityImageView)]) {
            UIImageView *iv = [cell performSelector:@selector(activityImageView)];
            if (iv && [iv isKindOfClass:[UIImageView class]]) {
                iv.image = custom;
                iv.hidden = NO;
                iv.alpha = 1.0;
            }
        }
    } else {
        // 如果没有自定义图标，必须恢复原状，否则 Cell 复用时图标会丢失！
        if ([cell respondsToSelector:@selector(imageSlotView)]) {
            UIView *slotView = [cell performSelector:@selector(imageSlotView)];
            if (slotView) {
                slotView.hidden = NO;
                slotView.alpha = 1.0;
            }
        }
    }
}

// =======================
// UI 渲染劫持
// =======================
%hook UIShareGroupActivityCell
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
