#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 声明私有类
// =======================
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
// 全局常量与状态
// =======================
#define TAG_CUSTOM_ICON 998877

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
        isEnabled = NO;
    }
}

// =======================
// 核心逻辑：获取与匹配自定义图片
// =======================
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    NSString *dir = GetMediaDir();
    
    // 1. 精确匹配
    NSString *exactPath = [[dir stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:exactPath]) {
        return [UIImage imageWithContentsOfFile:exactPath];
    }
    
    // 2. 智能模糊匹配 (核心修复：使用 containsString)
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *file in files) {
        if ([file hasSuffix:@".png"]) {
            NSString *confID = [file stringByDeletingPathExtension]; 
            if (confID.length > 0 && [identifier containsString:confID]) {
                NSString *path = [dir stringByAppendingPathComponent:file];
                return [UIImage imageWithContentsOfFile:path];
            }
        }
    }
    return nil;
}

// 从 Cell 的代理层级中提取 Bundle ID
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

// =======================
// 终极 UI 覆盖大法：创建一个新图层压在上面
// =======================
static void applyCustomImageToCell(UICollectionViewCell *cell, UIImage *customImage) {
    UIView *slotView = [cell respondsToSelector:@selector(imageSlotView)] ? [cell valueForKey:@"imageSlotView"] : nil;
    UIImageView *appleIv = [cell respondsToSelector:@selector(activityImageView)] ? [cell valueForKey:@"activityImageView"] : nil;
    
    // 1. 无情打压系统的图层
    if (slotView) { slotView.hidden = YES; slotView.alpha = 0; }
    if (appleIv) { appleIv.hidden = YES; appleIv.alpha = 0; }
    
    // 2. 创建或更新我们自己的ImageView
    UIImageView *customIv = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [[UIImageView alloc] init];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        
        if ([NSStringFromClass([cell class]) containsString:@"Action"]) {
            customIv.layer.cornerRadius = 0;
        } else {
            customIv.layer.cornerRadius = 13.0; 
        }
        [cell.contentView addSubview:customIv];
    }
    
    // 3. 动态获取坐标与大小
    CGRect targetFrame = CGRectZero;
    if (slotView && !CGRectIsEmpty(slotView.frame)) {
        targetFrame = slotView.frame;
    } else if (appleIv && !CGRectIsEmpty(appleIv.frame)) {
        targetFrame = appleIv.frame;
    } else {
        if ([NSStringFromClass([cell class]) containsString:@"Action"]) {
            targetFrame = CGRectMake((cell.contentView.bounds.size.width - 28)/2, 16, 28, 28);
        } else {
            targetFrame = CGRectMake((cell.contentView.bounds.size.width - 60)/2, 0, 60, 60);
        }
    }
    
    customIv.frame = targetFrame;
    customIv.image = customImage;
    customIv.hidden = NO;
}

static void restoreCell(UICollectionViewCell *cell) {
    UIView *slotView = [cell respondsToSelector:@selector(imageSlotView)] ? [cell valueForKey:@"imageSlotView"] : nil;
    UIImageView *appleIv = [cell respondsToSelector:@selector(activityImageView)] ? [cell valueForKey:@"activityImageView"] : nil;
    
    if (slotView) { slotView.hidden = NO; slotView.alpha = 1.0; }
    if (appleIv) { appleIv.hidden = NO; appleIv.alpha = 1.0; }
    
    UIView *customIv = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (customIv) {
        customIv.hidden = YES;
    }
}

// =======================
// 手动展开 Hook (避开宏解析报错)
// =======================

%hook UIShareGroupActivityCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        applyCustomImageToCell(self, custom);
    } else {
        restoreCell(self);
    }
}
%end

%hook UIActivityGroupActivityCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        applyCustomImageToCell(self, custom);
    } else {
        restoreCell(self);
    }
}
%end

%hook UIActivityActionGroupCell
- (void)layoutSubviews {
    %orig;
    UIImage *custom = getCustomIconForCell(self);
    if (custom) {
        applyCustomImageToCell(self, custom);
    } else {
        restoreCell(self);
    }
}
%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
