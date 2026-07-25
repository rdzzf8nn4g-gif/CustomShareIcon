#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"

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
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

// 用于保存活动的控制器，实现实时刷新
static NSHashTable *activeShareVCs = nil;
static NSHashTable *activeMoreVCs = nil;

#pragma mark - 实时刷新逻辑

static void reloadActiveUIs() {
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
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    BOOL enabledVal = YES;
    NSDictionary *iconsVal = nil;

    // 1. 尝试直接从系统偏好读取
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    Boolean keyExists = false;
    Boolean isEn = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    if (keyExists) enabledVal = isEn;

    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        iconsVal = [(__bridge NSDictionary *)ref copy];
    }
    if (ref) CFRelease(ref);

    // 2. 如果系统偏好读取失败，降级使用共享文件缓存
    if (!iconsVal && cache) {
        iconsVal = cache[@"IOSDump_CSI_Icons"];
        if (cache[@"Enabled"]) enabledVal = [cache[@"Enabled"] boolValue];
    }

    customIconsDict = [iconsVal copy] ?: @{};
    isEnabled = (enabledVal && customIconsDict.count > 0);
    
    // 【核心修复】：清空旧内存缓存！否则更换图片或关闭开关后永远显示旧图
    if (!imageCache) imageCache = [NSMutableDictionary new];
    [imageCache removeAllObjects];

    NSLog(@"[CustomShareIcon] 偏好加载成功: enabled=%d, icons_count=%lu", isEnabled, (unsigned long)customIconsDict.count);

    if ([[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"]) {
        writeSharedCache(customIconsDict, enabledVal);
    }

    // 触发当前页面的实时无缝刷新
    reloadActiveUIs();
}

#pragma mark - 标识符提取与净化 (修复 iOS14 匹配问题)

// 净化后缀，防止 App Extension ID 干扰匹配
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
    if (imageCache[cleanID]) return imageCache[cleanID];

    NSString *base64 = nil;
    NSString *matched = nil;
    NSString *lower = cleanID.lowercaseString;

    // 1. 完全匹配
    for (NSString *key in customIconsDict) {
        if ([lower caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; matched = key; break;
        }
    }
    
    // 2. 包含匹配 (处理部分特殊系统的子 BundleID)
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower]) {
                base64 = customIconsDict[key]; matched = key; break;
            }
        }
    }
    
    if (!base64) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return nil;
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[cleanID] = img; // 缓存净化后的 ID
        NSLog(@"[CustomShareIcon] 匹配成功: %@ -> 原始输入: %@", matched, identifier);
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

    // 针对 iOS 16-17 的 _UIHostActivityProxy
    @try {
        if ([proxy respondsToSelector:@selector(applicationBundleIdentifier)]) {
            r = [proxy valueForKey:@"applicationBundleIdentifier"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    // 提取内部的 activity 对象
    id activity = nil;
    @try {
        if ([proxy respondsToSelector:@selector(activity)]) {
            activity = [proxy valueForKey:@"activity"];
        } else {
            activity = proxy; // 如果传入的直接是 activity
        }
    } @catch (NSException *e) {}

    r = bundleIDFromActivity(activity);
    if (r.length) return r;

    // 针对兜底的 activityType
    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            r = [proxy valueForKey:@"activityType"];
            if (r.length) return cleanBundleID(r);
        }
    } @catch (NSException *e) {}

    return nil;
}

#pragma mark - Hook 主面板 VC 与 更多列表 VC (用于收集实例进行实时刷新)

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

#pragma mark - 源头：UIActivity & UIApplicationExtensionActivity

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

- (void)setActivityProxy:(id)proxy {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)layoutSubviews {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)setImage:(UIImage *)image {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)_updateImageView {
    %orig;
    [self csi_applyCustomIcon];
}

- (void)prepareForReuse {
    %orig;
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov) { ov.hidden = YES; ov.image = nil; }
}

%new
- (void)csi_applyCustomIcon {
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];

    // 【修复】：如果插件被关闭，立即隐藏覆盖图并返回，还原系统原生面貌
    if (!isEnabled) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    
    // 如果该应用没有自定义图片，也隐藏覆盖图
    if (!img) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? (UIView *)nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

    if (nativeIv) {
        nativeIv.image = img;
        nativeIv.layer.cornerRadius = 0; // 原生试图取消圆角
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
    // 【修复】：修改图标是正方形的，强制圆角为 0
    ov.layer.cornerRadius = 0;
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    // 确保角标（如分享提示）在最前面
    UIView *badge = [self valueForKey:@"badgeSlotView"];
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

#pragma mark - 「更多」列表：_UIActivityUserDefaultsViewController (修复 iOS 14-17 不生效问题)

%hook _UIActivityUserDefaultsViewController

// 拦截即将显示的 Cell，直接在底层强行修改图片（最稳妥的方式，不受 Diffable DataSource 干扰）
- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;

    if (!isEnabled) return; // 插件关闭时不干预

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;

    NSString *bid = extractIdentifier(activity);
    UIImage *img = getCustomIconForID(bid);
    if (img) {
        // 直接替换系统的 imageView，并保证正方形
        cell.imageView.image = img;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 0; // 更多列表也保证正方形
        
        // 标记视图重绘
        [cell setNeedsLayout];
    }
}

%end

#pragma mark - 构造器加载

%ctor {
    NSLog(@"[CustomShareIcon] 核心逻辑注入成功...");
    loadPrefs();
    
    // 监听 Darwin 通知，收到后在对应进程（分享面板进程）执行重载与实时刷新
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
