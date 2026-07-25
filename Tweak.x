#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist"

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
- (void)setActivityProxy:(id)proxy;
- (void)setImage:(UIImage *)image;
- (void)_updateImageView;
- (void)csi_applyCustomIcon;
@end

@interface UIActivityContentViewController : UIViewController
@property (retain, nonatomic) UICollectionView *activityCollectionView;
@end

@interface _UIActivityUserDefaultsViewController : UIViewController
@property (retain, nonatomic) UITableView *tableView;
- (id)activityForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

static BOOL isEnabled = YES;
static NSDictionary *customIconsDict = nil;

// 缓存池 (彻底防止卡死核心机制)
static NSMutableDictionary *imageCache = nil;

// 实时刷新收集器
static NSHashTable *activeShareVCs = nil;
static NSHashTable *activeMoreVCs = nil;
static BOOL isInitialLoad = YES;

#pragma mark - 工具与加载逻辑

static void reloadActiveUIs() {
    if (isInitialLoad) return; 
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIActivityContentViewController *vc in activeShareVCs) {
            if ([vc respondsToSelector:@selector(activityCollectionView)]) {
                [[vc activityCollectionView] reloadData];
            }
        }
        for (_UIActivityUserDefaultsViewController *vc in activeMoreVCs) {
            if ([vc respondsToSelector:@selector(tableView)]) {
                [[vc tableView] reloadData];
            }
        }
    });
}

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    
    // 1. 读取开关状态
    Boolean keyExists = false;
    Boolean isEn = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    isEnabled = keyExists ? isEn : YES;

    // 2. 尝试从 CFPreferences 读取字典
    NSDictionary *tempIcons = nil;
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        tempIcons = [(__bridge NSDictionary *)ref copy];
    }
    if (ref) CFRelease(ref);
    
    // 3. 沙盒进程兜底：如果 CFPreferences 拿不到，直接读物理文件
    if (!tempIcons || tempIcons.count == 0) {
        NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        if (fileDict) {
            if (fileDict[@"Enabled"]) isEnabled = [fileDict[@"Enabled"] boolValue];
            if (fileDict[@"IOSDump_CSI_Icons"]) tempIcons = fileDict[@"IOSDump_CSI_Icons"];
        }
    }
    customIconsDict = tempIcons ?: @{};

    // 4. 重置缓存池，让设置里的更改立即生效
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageCache = [NSMutableDictionary new];
    });
    
    @synchronized (imageCache) {
        [imageCache removeAllObjects];
    }

    NSLog(@"[CustomShareIcon] 偏好加载成功: enabled=%d, icons=%lu", isEnabled, (unsigned long)customIconsDict.count);
    reloadActiveUIs();
}

#pragma mark - 标识符安全提取与匹配 (0异常0卡死优化)

static NSString *cleanBundleID(NSString *bid) {
    if (!bid || bid.length == 0) return nil;
    NSString *lower = bid.lowercaseString;
    if ([lower hasSuffix:@".shareextension"]) return [bid substringToIndex:bid.length - 15];
    if ([lower hasSuffix:@".share"]) return [bid substringToIndex:bid.length - 6];
    if ([lower hasSuffix:@".action"]) return [bid substringToIndex:bid.length - 7];
    return bid;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    
    NSString *cleanID = cleanBundleID(identifier);
    if (!cleanID.length) return nil;
    
    // 【防卡死核心】：极速缓存，命中直接返回，包含找不到的 NSNull
    @synchronized (imageCache) {
        id cachedObj = imageCache[cleanID];
        if (cachedObj) {
            return cachedObj == [NSNull null] ? nil : (UIImage *)cachedObj;
        }
    }

    NSString *base64 = nil;
    NSString *lower = cleanID.lowercaseString;

    for (NSString *key in customIconsDict) {
        if ([lower caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; break;
        }
    }
    
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower]) {
                base64 = customIconsDict[key]; break;
            }
        }
    }
    
    // 找不到就锁死 NSNull，杜绝死循环
    if (!base64) {
        @synchronized (imageCache) { imageCache[cleanID] = [NSNull null]; }
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return nil;
    
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    
    @synchronized (imageCache) {
        if (img) {
            imageCache[cleanID] = img;
        } else {
            imageCache[cleanID] = [NSNull null];
        }
    }
    return img;
}

// 使用安全无耗时的 performSelector 替代灾难级的 @try-@catch
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
static NSString *bundleIDFromActivity(id activity) {
    if (!activity) return nil;

    if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        NSString *r = [activity performSelector:@selector(containingAppBundleIdentifier)];
        if (r.length) return cleanBundleID(r);
    }

    if ([activity respondsToSelector:@selector(applicationExtension)]) {
        id ext = [activity performSelector:@selector(applicationExtension)];
        if (ext) {
            if ([ext respondsToSelector:@selector(identifier)]) {
                NSString *r = [ext performSelector:@selector(identifier)];
                if (r.length) return cleanBundleID(r);
            }
            if ([ext respondsToSelector:@selector(_bundle)]) {
                id bundle = [ext performSelector:@selector(_bundle)];
                if (bundle && [bundle respondsToSelector:@selector(bundleIdentifier)]) {
                    NSString *r = [bundle performSelector:@selector(bundleIdentifier)];
                    if (r.length) return cleanBundleID(r);
                }
            }
        }
    }

    if ([activity respondsToSelector:@selector(activityType)]) {
        NSString *r = [activity performSelector:@selector(activityType)];
        if (r.length) return cleanBundleID(r);
    }

    return nil;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;

    if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
        NSString *r = [proxy performSelector:@selector(applicationBundleIdentifier)];
        if (r.length) return cleanBundleID(r);
    }

    id activity = nil;
    if ([proxy respondsToSelector:@selector(activity)]) {
        activity = [proxy performSelector:@selector(activity)];
    } else {
        activity = proxy;
    }

    NSString *r = bundleIDFromActivity(activity);
    if (r.length) return r;

    if ([proxy respondsToSelector:@selector(activityType)]) {
        NSString *type = [proxy performSelector:@selector(activityType)];
        if (type.length) return cleanBundleID(type);
    }

    return nil;
}
#pragma clang diagnostic pop

#pragma mark - 收集面板 VC 进行实时刷新

%hook UIActivityContentViewController
- (void)viewDidLoad {
    %orig;
    if (!activeShareVCs) activeShareVCs = [NSHashTable weakObjectsHashTable];
    [activeShareVCs addObject:self];
}
%end

%hook _UIActivityUserDefaultsViewController
- (void)viewDidLoad {
    %orig;
    if (!activeMoreVCs) activeMoreVCs = [NSHashTable weakObjectsHashTable];
    [activeMoreVCs addObject:self];
}
%end

#pragma mark - 主面板 Cell (防死锁安全覆盖)

%hook UIShareGroupActivityCell

// 【核心修复】：完全移除了 layoutSubviews 的 Hook，只在内容更新时触发，彻底斩断死循环！
- (void)setActivityProxy:(id)proxy { %orig; [self csi_applyCustomIcon]; }
- (void)setImage:(UIImage *)image { %orig; [self csi_applyCustomIcon]; }
- (void)_updateImageView { %orig; [self csi_applyCustomIcon]; }

- (void)prepareForReuse {
    %orig;
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov && !ov.hidden) {
        ov.hidden = YES;
        ov.image = nil;
    }
    
    UIView *nativeIv = nil;
    if ([self respondsToSelector:@selector(activityImageView)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        nativeIv = [self performSelector:@selector(activityImageView)];
        #pragma clang diagnostic pop
    }
    
    if (nativeIv && nativeIv.alpha != 1.0) {
        nativeIv.alpha = 1.0;
    }
}

%new
- (void)csi_applyCustomIcon {
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    
    UIView *nativeIv = nil;
    UIView *slotView = nil;
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    if ([self respondsToSelector:@selector(activityImageView)]) {
        nativeIv = [self performSelector:@selector(activityImageView)];
    }
    if ([self respondsToSelector:@selector(imageSlotView)]) {
        slotView = [self performSelector:@selector(imageSlotView)];
    }
    #pragma clang diagnostic pop
    
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? nativeIv : slotView;
    
    if (!isEnabled) {
        if (ov && !ov.hidden) { ov.hidden = YES; ov.image = nil; }
        if (nativeIv && nativeIv.alpha != 1.0) { nativeIv.alpha = 1.0; }
        return;
    }

    id proxy = nil;
    if ([self respondsToSelector:@selector(activityProxy)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        proxy = [self performSelector:@selector(activityProxy)];
        #pragma clang diagnostic pop
    }
    
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    
    if (!img) {
        if (ov && !ov.hidden) { ov.hidden = YES; ov.image = nil; }
        if (nativeIv && nativeIv.alpha != 1.0) { nativeIv.alpha = 1.0; }
        return;
    }

    if (!ref || CGRectIsEmpty(ref.frame)) return;

    // 【防死锁核心】：改用 alpha = 0 来隐藏原图，绝不触发 layoutSubviews
    if (nativeIv && nativeIv.alpha != 0.0) {
        nativeIv.alpha = 0.0; 
    }

    if (!ov) {
        ov = [[UIImageView alloc] initWithFrame:ref.frame];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.userInteractionEnabled = NO;
        ov.layer.cornerRadius = 0; // 强制无圆角（直角正方形）
        [self.contentView addSubview:ov]; 
    }
    
    if (!CGRectEqualToRect(ov.frame, ref.frame)) {
        ov.frame = ref.frame;
    }
    
    if (ov.image != img) {
        ov.image = img;
    }
    
    if (ov.hidden) {
        ov.hidden = NO;
    }
    
    // 提升层级前先检查，避免不必要的重绘引发卡死
    if ([self.contentView.subviews lastObject] != ov) {
        [self.contentView bringSubviewToFront:ov];
    }
    
    UIView *badge = nil;
    if ([self respondsToSelector:@selector(badgeSlotView)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        badge = [self performSelector:@selector(badgeSlotView)];
        #pragma clang diagnostic pop
    }
    if (badge && [self.contentView.subviews lastObject] != badge) {
        [self.contentView bringSubviewToFront:badge];
    }
}

%end

#pragma mark - 更多面板 Cell (列表正方形图标)

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    
    UIImageView *ov = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];

    if (!isEnabled) {
        if (ov && !ov.hidden) ov.hidden = YES;
        if (cell.imageView.alpha != 1.0) cell.imageView.alpha = 1.0;
        return;
    }

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        activity = [self performSelector:@selector(activityForRowAtIndexPath:) withObject:indexPath];
        #pragma clang diagnostic pop
    }
    if (!activity) return;

    NSString *bid = bundleIDFromActivity(activity);
    UIImage *img = getCustomIconForID(bid);
    
    if (!img) {
        if (ov && !ov.hidden) ov.hidden = YES;
        if (cell.imageView.alpha != 1.0) cell.imageView.alpha = 1.0;
        return;
    }

    UIImageView *sysIv = cell.imageView;
    if (sysIv && sysIv.alpha != 0.0) {
        sysIv.alpha = 0.0; // 同样使用 alpha 规避重绘卡顿
    }

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.cornerRadius = 0; // 强制正方形！
        [cell.contentView addSubview:ov];
    }
    
    CGRect targetFrame;
    if (sysIv && !CGRectIsEmpty(sysIv.frame)) {
        targetFrame = sysIv.frame;
    } else {
        CGFloat size = 29.0;
        targetFrame = CGRectMake(16, (cell.bounds.size.height - size) / 2.0, size, size);
    }
    
    if (!CGRectEqualToRect(ov.frame, targetFrame)) {
        ov.frame = targetFrame;
    }
    
    if (ov.image != img) {
        ov.image = img;
    }
    
    if (ov.hidden) {
        ov.hidden = NO;
    }
}

%end

#pragma mark - 构造与监听

%ctor {
    isInitialLoad = YES;
    loadPrefs();
    isInitialLoad = NO;
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
