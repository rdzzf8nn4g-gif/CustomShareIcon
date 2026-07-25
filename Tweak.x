#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"
// 兼容有根和无根路径
#define IOSDUMP_LIB_PATH @"/var/jb/Library/iosdump"
#define IOSDUMP_LIB_PATH_FALLBACK @"/Library/iosdump"

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
- (void)setActivityProxy:(id)proxy;
- (void)setImage:(UIImage *)image;
- (void)_updateImageView;
- (void)csi_applyCustomIcon;
@end

@interface UIApplicationExtensionActivity : UIActivity
@property (readonly, nonatomic) NSString *containingAppBundleIdentifier;
@property (retain, nonatomic) id applicationExtension;
- (NSString *)activityType;
- (UIImage *)_activityImage;
- (UIImage *)_actionImage;
- (UIImage *)_activitySettingsImage;
@end

@interface UIActivity (CustomShareIcon)
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier;
+ (id)_activityImageForBundleImageConfiguration:(id)configuration;
- (UIImage *)activityImage;
- (UIImage *)_activityImage;
- (NSString *)_systemImageName;
- (NSString *)activityType;
@end

@interface UIActivityContentViewController : UIViewController
@property (retain, nonatomic) UICollectionView *activityCollectionView;
@end

@interface _UIActivityUserDefaultsViewController : UIViewController
@property (retain, nonatomic) UITableView *tableView;
- (id)activityForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

static BOOL isEnabled = NO;
static BOOL isInitialLoad = YES;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary *imageCache = nil;

static NSHashTable *activeShareVCs = nil;
static NSHashTable *activeMoreVCs = nil;

#pragma mark - 工具与加载逻辑

static BOOL isSpringBoardProcess() {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"] ||
           [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];
}

static void reloadActiveUIs() {
    if (isInitialLoad) return; // 防止启动阶段死锁
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

static void writeSharedCache(NSDictionary *icons, BOOL enabled) {
    if (!icons) icons = @{};
    [@{@"IOSDump_CSI_Icons": icons, @"Enabled": @(enabled)} writeToFile:SHARED_CACHE_PATH atomically:YES];
}

static void loadPrefs() {
    BOOL enabledVal = YES;
    NSMutableDictionary *loadedIcons = [NSMutableDictionary new];
    BOOL isSB = isSpringBoardProcess();

    if (isSB) {
        // SB 进程：读取开关状态，并从 /Library/iosdump 文件夹读取物理图片转 Base64 放入内存
        CFPreferencesAppSynchronize(PREFS_DOMAIN);
        Boolean keyExists = false;
        Boolean isEn = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
        if (keyExists) enabledVal = isEn;

        NSString *path = [[NSFileManager defaultManager] fileExistsAtPath:IOSDUMP_LIB_PATH] ? IOSDUMP_LIB_PATH : IOSDUMP_LIB_PATH_FALLBACK;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        for (NSString *file in files) {
            if ([file hasSuffix:@".png"] || [file hasSuffix:@".jpg"]) {
                NSString *bid = [[file lastPathComponent] stringByDeletingPathExtension];
                NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathComponent:file]];
                if (data) {
                    loadedIcons[bid] = [data base64EncodedStringWithOptions:0];
                }
            }
        }
        // 同步给沙盒进程
        writeSharedCache(loadedIcons, enabledVal);
        customIconsDict = [loadedIcons copy];
        isEnabled = enabledVal;
    } else {
        // 分享面板进程：直接从 SB 写好的共享缓存中读取数据，避开沙盒限制
        NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
        if (cache) {
            if (cache[@"Enabled"]) enabledVal = [cache[@"Enabled"] boolValue];
            id iconsVal = cache[@"IOSDump_CSI_Icons"];
            if ([iconsVal isKindOfClass:[NSDictionary class]]) {
                customIconsDict = [iconsVal copy];
            }
        }
        isEnabled = enabledVal;
    }
    
    if (!customIconsDict) customIconsDict = @{};

    // 必须清空缓存池
    if (!imageCache) imageCache = [NSMutableDictionary new];
    [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] 偏好加载成功: enabled=%d, icons_count=%lu", isEnabled, (unsigned long)customIconsDict.count);
    reloadActiveUIs();
}

#pragma mark - 标识符提取与匹配 (彻底解决卡死)

static NSString *cleanBundleID(NSString *bid) {
    if (!bid || bid.length == 0) return nil;
    NSString *lower = bid.lowercaseString;
    if ([lower hasSuffix:@".shareextension"]) {
        bid = [bid substringToIndex:bid.length - 15];
    } else if ([lower hasSuffix:@".share"]) {
        bid = [bid substringToIndex:bid.length - 6];
    } else if ([lower hasSuffix:@".action"]) {
        bid = [bid substringToIndex:bid.length - 7];
    }
    return bid;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    
    NSString *cleanID = cleanBundleID(identifier);
    
    // 【核心修复】：拦截已明确找不到结果的 BundleID，防止无限循环导致的卡死
    id cachedObj = imageCache[cleanID];
    if (cachedObj) {
        return cachedObj == [NSNull null] ? nil : (UIImage *)cachedObj;
    }

    NSString *base64 = nil;
    NSString *lower = cleanID.lowercaseString;

    // 1. 完全匹配
    for (NSString *key in customIconsDict) {
        if ([lower caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; break;
        }
    }
    
    // 2. 包含匹配
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower]) {
                base64 = customIconsDict[key]; break;
            }
        }
    }
    
    // 如果依然没找到，缓存 [NSNull null]，下次直接跳过
    if (!base64) {
        imageCache[cleanID] = [NSNull null];
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) {
        imageCache[cleanID] = [NSNull null];
        return nil;
    }
    
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[cleanID] = img;
    } else {
        imageCache[cleanID] = [NSNull null];
    }
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

#pragma mark - Hook 主面板 VC 与 更多列表 VC

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

#pragma mark - 源头：UIActivity

%hook UIActivity
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *c = getCustomIconForID(identifier);
    return c ?: %orig;
}
- (UIImage *)activityImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
}
- (UIImage *)_activityImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
}
- (NSString *)_systemImageName {
    if (getCustomIconForID(bundleIDFromActivity(self))) return nil;
    return %orig;
}
%end

%hook UIApplicationExtensionActivity
- (UIImage *)_activityImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
}
- (UIImage *)_actionImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
}
- (UIImage *)_activitySettingsImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
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
        nativeIv.image = img;
        nativeIv.layer.cornerRadius = 0; // 取消系统圆角
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
    ov.layer.cornerRadius = 0; // 强制正方形
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    @try {
        UIView *badge = [self valueForKey:@"badgeSlotView"];
        if (badge) [self.contentView bringSubviewToFront:badge];
    } @catch (NSException *e) {}
}

%end

#pragma mark - 「更多」列表：_UIActivityUserDefaultsViewController

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!isEnabled) return; 

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;

    NSString *bid = extractIdentifier(activity);
    UIImage *img = getCustomIconForID(bid);
    if (img) {
        cell.imageView.image = img;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 0; // 更多列表强制正方形
        [cell setNeedsLayout];
    }
}

%end

%ctor {
    isInitialLoad = YES;
    loadPrefs();
    isInitialLoad = NO;
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
