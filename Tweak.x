#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 声明要 Hook 的类
// =======================
@interface UIShareGroupActivityCell : UICollectionViewCell
- (id)activityProxy;
- (void)setActivityProxy:(id)proxy;
- (UIImageView *)activityImageView;
- (UIView *)imageSlotView;
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

static BOOL isEnabled = NO;

static void loadPrefs() {
    NSString *flagPath = [GetMediaDir() stringByAppendingPathComponent:@"enabled.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:flagPath]) {
        NSString *val = [NSString stringWithContentsOfFile:flagPath encoding:NSUTF8StringEncoding error:nil];
        isEnabled = [val isEqualToString:@"1"];
    } else {
        isEnabled = NO; // 默认关闭
    }
}

// 核心前缀匹配逻辑
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

// 全面提取 Identifier
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
    
    if (identifier) return getCustomIconForID(identifier);
    return nil;
}

// =======================
// 视图强制接管
// =======================
static void forceUpdateUI(id cell) {
    if (!isEnabled) return;
    UIImage *custom = getCustomIconForCell(cell);
    
    if (custom) {
        // 彻底摧毁原生系统图标图层
        if ([cell respondsToSelector:@selector(imageSlotView)]) {
            UIView *slotView = [cell performSelector:@selector(imageSlotView)];
            if (slotView) {
                slotView.hidden = YES;
                slotView.alpha = 0;
                [slotView removeFromSuperview]; // 从层级移除，防止重生遮挡
            }
        }
        
        // 强行渲染我们的图层
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
// 终极 Hook：封死所有可能被系统覆盖的刷新时机
// =======================
%hook UIShareGroupActivityCell

// 核心 1：在数据源赋值的一瞬间立刻干预
- (void)setActivityProxy:(id)proxy {
    %orig;
    forceUpdateUI(self);
}

// 核心 2：系统内部刷新图片时干预
- (void)_updateImageView {
    %orig;
    forceUpdateUI(self);
}

// 核心 3：视图排版时干预
- (void)layoutSubviews {
    %orig;
    forceUpdateUI(self);
}

// 核心 4：如果有直接设置图片的入口，强行拦截
- (void)setImage:(UIImage *)img {
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        %orig(custom);
        return;
    }
    %orig(img);
}

%end


%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
