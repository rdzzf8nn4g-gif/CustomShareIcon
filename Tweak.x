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

// 缓存池与线程锁 (彻底防止卡死核心机制)
static NSMutableDictionary *imageCache = nil;
static NSLock *cacheLock = nil;

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
    
    // 3. 沙盒进程兜底：如果 CFPreferences 读取不到，直接读物理文件
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
        cacheLock = [NSLock new];
        imageCache = [NSMutableDictionary new];
    });
    
    [cacheLock lock];
    [imageCache removeAllObjects];
    [cacheLock unlock];

    NSLog(@"[CustomShareIcon] 加载成功: enabled=%d, icons=%lu", isEnabled, (unsigned long)customIconsDict.count);
    reloadActiveUIs();
}

#pragma mark - 标识符提取与匹配 (0卡死优化)

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
    
    // 【防卡死核心】：优先查询缓存，不管是图片还是未匹配标记 (NSNull)
    [cacheLock lock];
    id cachedObj = imageCache[cleanID];
    [cacheLock unlock];
    
    if (cachedObj) {
        return cachedObj == [NSNull null] ? nil : (UIImage *)cachedObj;
    }

    NSString *base64 = nil;
    NSString *lower = cleanID.lowercaseString;

    // 精确匹配
    for (NSString *key in customIconsDict) {
        if ([lower caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; break;
        }
    }
    
    // 模糊包含匹配
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower]) {
                base64 = customIconsDict[key]; break;
            }
        }
    }
    
    // 如果没有找到，将 NSNull 写入缓存，下次遇到直接跳过，杜绝死循环卡死！
    if (!base64) {
        [cacheLock lock];
        imageCache[cleanID] = [NSNull null];
        [cacheLock unlock];
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return nil;
    
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    
    [cacheLock lock];
    if (img) {
        imageCache[cleanID] = img;
    } else {
        imageCache[cleanID] = [NSNull null];
    }
    [cacheLock unlock];
    
    return img;
}

static NSString *bundleIDFromActivity(id activity) {
    if (!activity) return nil;
    NSString *r = nil;

    @try {
        if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
            r = [activity valueForKey:@"containingAppBundleIdentifier"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    @try {
        id ext = [activity valueForKey:@"applicationExtension"];
        if (ext) {
            r = [ext valueForKey:@"identifier"];
            if (r.length) return cleanBundleID(r);
            id bundle = [ext valueForKey:@"_bundle"];
            if (bundle) {
                r = [bundle bundleIdentifier];
                if (r.length) return cleanBundleID(r);
            }
        }
    } @catch (NSException *e) {}

    @try {
        if ([activity respondsToSelector:@selector(activityType)]) {
            r = [activity valueForKey:@"activityType"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    return nil;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    NSString *r = nil;

    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            r = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    id activity = nil;
    @try {
        if ([proxy respondsToSelector:@selector(activity)]) {
            activity = [proxy valueForKey:@"activity"];
        } else {
            activity = proxy;
        }
    } @catch (NSException *e) {}

    r = bundleIDFromActivity(activity);
    if (r.length) return r;

    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            r = [proxy valueForKey:@"activityType"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    return nil;
}

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

#pragma mark - 主面板 Cell (覆盖正方形图标)

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy { %orig; [self csi_applyCustomIcon]; }
- (void)layoutSubviews { %orig; [self csi_applyCustomIcon]; }
- (void)setImage:(UIImage *)image { %orig; [self csi_applyCustomIcon]; }
- (void)_updateImageView { %orig; [self csi_applyCustomIcon]; }

- (void)prepareForReuse {
    %orig;
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov) { ov.hidden = YES; ov.image = nil; }
}

%new
- (void)csi_applyCustomIcon {
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!isEnabled) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    id proxy = nil;
    @try { proxy = [self valueForKey:@"activityProxy"]; } @catch (NSException *e) {}
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    
    if (!img) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    UIImageView *nativeIv = nil;
    UIView *slotView = nil;
    @try { 
        nativeIv = [self valueForKey:@"activityImageView"];
        slotView = [self valueForKey:@"imageSlotView"];
    } @catch (NSException *e) {}
    
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? (UIView *)nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

    if (nativeIv) {
        nativeIv.hidden = YES; // 彻底隐藏系统的图片，防止圆角干扰
    }

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.userInteractionEnabled = NO;
        [self.contentView addSubview:ov];
    }
    
    ov.frame = ref.frame;
    ov.layer.cornerRadius = 0; // 强制正方形！没有任何圆角！
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    @try {
        UIView *badge = [self valueForKey:@"badgeSlotView"];
        if (badge) [self.contentView bringSubviewToFront:badge];
    } @catch (NSException *e) {}
}

%end

#pragma mark - 更多面板 Cell (列表正方形图标)

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    
    UIImageView *ov = [cell.contentView viewWithTag:TAG_CUSTOM_ICON];

    if (!isEnabled) {
        if (ov) ov.hidden = YES;
        cell.imageView.hidden = NO;
        return;
    }

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;

    NSString *bid = bundleIDFromActivity(activity);
    UIImage *img = getCustomIconForID(bid);
    
    if (!img) {
        if (ov) ov.hidden = YES;
        cell.imageView.hidden = NO;
        return;
    }

    UIImageView *sysIv = cell.imageView;
    sysIv.hidden = YES; // 必须隐藏原生 View，规避原生系统内置的图片属性束缚

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.cornerRadius = 0; // 强制正方形！
        [cell.contentView addSubview:ov];
    }
    
    // 自动抓取系统 ImageView 的位置坐标
    if (sysIv && !CGRectIsEmpty(sysIv.frame)) {
        ov.frame = sysIv.frame;
    } else {
        // 兜底坐标尺寸
        CGFloat size = 29.0;
        ov.frame = CGRectMake(16, (cell.bounds.size.height - size) / 2.0, size, size);
    }
    
    ov.image = img;
    ov.hidden = NO;
    [cell.contentView bringSubviewToFront:ov];
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
