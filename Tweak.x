#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist"

@interface UIShareGroupActivityCell : UICollectionViewCell
- (void)setActivityProxy:(id)proxy;
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
static NSCache *imageCache = nil; // 采用原生 NSCache (线程绝对安全，内存自动管理)

#pragma mark - 核心数据加载

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    
    Boolean keyExists = false;
    Boolean isEn = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    isEnabled = keyExists ? isEn : YES;

    NSDictionary *tempIcons = nil;
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        tempIcons = [(__bridge NSDictionary *)ref copy];
    }
    if (ref) CFRelease(ref);
    
    if (!tempIcons || tempIcons.count == 0) {
        NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        if (fileDict) {
            if (fileDict[@"Enabled"]) isEnabled = [fileDict[@"Enabled"] boolValue];
            if (fileDict[@"IOSDump_CSI_Icons"]) tempIcons = fileDict[@"IOSDump_CSI_Icons"];
        }
    }
    
    customIconsDict = tempIcons ?: @{};

    // 清空缓存
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        imageCache = [[NSCache alloc] init];
    });
    [imageCache removeAllObjects];

    // 发送原生应用内通知进行安全刷新
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CSIReloadDataNotification" object:nil];
    });
}

#pragma mark - 安全解析 BundleID (0 抛出异常风险)

static NSString *cleanBundleID(NSString *bid) {
    if (!bid || bid.length == 0) return nil;
    NSString *lower = bid.lowercaseString;
    if ([lower hasSuffix:@".shareextension"]) return [bid substringToIndex:bid.length - 15];
    if ([lower hasSuffix:@".share"]) return [bid substringToIndex:bid.length - 6];
    if ([lower hasSuffix:@".action"]) return [bid substringToIndex:bid.length - 7];
    return bid;
}

static NSString *safeStringValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        id val = [obj valueForKey:key];
        if ([val isKindOfClass:[NSString class]]) return val;
    } @catch(NSException *e) {}
    return nil;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;
    
    NSString *bid = safeStringValue(proxy, @"applicationBundleIdentifier");
    if (bid) return cleanBundleID(bid);

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch(NSException *e) {}
    if (!activity) activity = proxy;

    bid = safeStringValue(activity, @"containingAppBundleIdentifier");
    if (bid) return cleanBundleID(bid);
    
    bid = safeStringValue(activity, @"activityType");
    if (bid) return cleanBundleID(bid);
    
    id ext = nil;
    @try { ext = [activity valueForKey:@"applicationExtension"]; } @catch(NSException *e) {}
    if (ext) {
        bid = safeStringValue(ext, @"identifier");
        if (bid) return cleanBundleID(bid);
        
        id bundle = nil;
        @try { bundle = [ext valueForKey:@"_bundle"]; } @catch(NSException *e) {}
        if (bundle) {
            bid = safeStringValue(bundle, @"bundleIdentifier");
            if (bid) return cleanBundleID(bid);
        }
    }
    
    return nil;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    
    NSString *cleanID = cleanBundleID(identifier);
    if (!cleanID.length) return nil;
    
    // 1. 查询极速缓存
    id cachedObj = [imageCache objectForKey:cleanID];
    if (cachedObj) {
        return cachedObj == [NSNull null] ? nil : (UIImage *)cachedObj;
    }

    NSString *base64 = nil;
    NSString *lower = cleanID.lowercaseString;

    // 2. 匹配字典
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
    
    // 3. 拦截不存在的 ID 并缓存 NSNull，斩断卡死
    if (!base64) {
        [imageCache setObject:[NSNull null] forKey:cleanID];
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    UIImage *img = data ? [UIImage imageWithData:data scale:3.0] : nil;
    
    [imageCache setObject:(img ?: [NSNull null]) forKey:cleanID];
    return img;
}

#pragma mark - 自动刷新绑定

%hook UIActivityContentViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(csi_triggerReload) name:@"CSIReloadDataNotification" object:nil];
}
%new
- (void)csi_triggerReload {
    if ([self respondsToSelector:@selector(activityCollectionView)]) {
        [[self activityCollectionView] reloadData];
    }
}
%end

%hook _UIActivityUserDefaultsViewController
- (void)viewDidLoad {
    %orig;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(csi_triggerReload) name:@"CSIReloadDataNotification" object:nil];
}
%new
- (void)csi_triggerReload {
    if ([self respondsToSelector:@selector(tableView)]) {
        [[self tableView] reloadData];
    }
}
%end

#pragma mark - 主面板 Cell (0 卡死隔离架构)

%hook UIShareGroupActivityCell

- (void)prepareForReuse {
    %orig;
    UIImageView *ov = (UIImageView *)[self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov) {
        ov.hidden = YES;
        ov.image = nil;
    }
    UIView *nativeIv = nil;
    @try { nativeIv = [self valueForKey:@"activityImageView"]; } @catch(NSException *e) {}
    if (nativeIv && nativeIv.alpha != 1.0) {
        nativeIv.alpha = 1.0;
    }
}

// 数据绑定阶段 (此时不触发排版)
- (void)setActivityProxy:(id)proxy {
    %orig;
    
    UIImageView *ov = (UIImageView *)[self.contentView viewWithTag:TAG_CUSTOM_ICON];
    UIView *nativeIv = nil;
    @try { nativeIv = [self valueForKey:@"activityImageView"]; } @catch(NSException *e) {}
    
    if (!isEnabled) {
        if (ov) ov.hidden = YES;
        if (nativeIv) nativeIv.alpha = 1.0;
        return;
    }

    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    
    if (!img) {
        if (ov) ov.hidden = YES;
        if (nativeIv) nativeIv.alpha = 1.0;
        return;
    }

    if (!ov) {
        ov = [[UIImageView alloc] init];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.cornerRadius = 0; // 强制绝对正方形
        // 利用 Z 轴高度置顶，绝不触发 layoutSubviews 的死循环！
        ov.layer.zPosition = 999;
        [self.contentView addSubview:ov]; 
    }
    
    ov.image = img;
    ov.hidden = NO;
    if (nativeIv) nativeIv.alpha = 0.0;
}

// 布局同步阶段 (只做 Frame 同步)
- (void)layoutSubviews {
    %orig;
    
    UIImageView *ov = (UIImageView *)[self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov && !ov.hidden) {
        UIView *nativeIv = nil;
        UIView *slotView = nil;
        @try {
            if ([self respondsToSelector:@selector(activityImageView)]) nativeIv = [self valueForKey:@"activityImageView"];
            if ([self respondsToSelector:@selector(imageSlotView)]) slotView = [self valueForKey:@"imageSlotView"];
        } @catch(NSException *e) {}
        
        UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? nativeIv : slotView;
        // 同步位置
        if (ref && !CGRectIsEmpty(ref.frame)) {
            ov.frame = ref.frame;
        }
    }
}

%end

#pragma mark - 更多面板 Cell (列表正方形图标)

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    
    UIImageView *ov = (UIImageView *)[cell.contentView viewWithTag:TAG_CUSTOM_ICON];

    if (!isEnabled) {
        if (ov) ov.hidden = YES;
        if (cell.imageView) cell.imageView.alpha = 1.0;
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

    NSString *bid = extractIdentifier(activity);
    UIImage *img = getCustomIconForID(bid);
    
    if (!img) {
        if (ov) ov.hidden = YES;
        if (cell.imageView) cell.imageView.alpha = 1.0;
        return;
    }

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.cornerRadius = 0; // 绝对正方形
        ov.layer.zPosition = 999;  // 利用 Z 轴置顶
        [cell.contentView addSubview:ov];
    }
    
    cell.imageView.alpha = 0.0;
    
    if (cell.imageView && !CGRectIsEmpty(cell.imageView.frame)) {
        ov.frame = cell.imageView.frame;
    } else {
        CGFloat size = 29.0;
        ov.frame = CGRectMake(16, (cell.bounds.size.height - size) / 2.0, size, size);
    }
    
    ov.image = img;
    ov.hidden = NO;
}

%end

#pragma mark - 初始化监听

%ctor {
    loadPrefs();
    
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
