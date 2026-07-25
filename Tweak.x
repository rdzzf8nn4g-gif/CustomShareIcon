#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist"

@interface UIShareGroupActivityCell : UICollectionViewCell
- (void)csi_applyCustomIcon;
@end

@interface UIActivityContentViewController : UIViewController
@property (retain, nonatomic) UICollectionView *activityCollectionView;
@end

@interface _UIActivityUserDefaultsViewController : UIViewController
@property (retain, nonatomic) UITableView *tableView;
@end

static BOOL isEnabled = YES;
static NSDictionary *customIconsDict = nil;

// 缓存池 (现在只在主线程运行，连锁都不需要了，0死锁风险)
static NSMutableDictionary *imageCache = nil;

// 实时刷新收集器
static NSHashTable *activeShareVCs = nil;
static NSHashTable *activeMoreVCs = nil;

#pragma mark - 安全反射工具 (绝对不抛异常)

static id safePerform(id obj, NSString *selName) {
    if (!obj || !selName) return nil;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        return [obj performSelector:sel];
        #pragma clang diagnostic pop
    }
    return nil;
}

static NSString *safeString(id obj, NSString *selName) {
    id val = safePerform(obj, selName);
    return [val isKindOfClass:[NSString class]] ? val : nil;
}

#pragma mark - 加载逻辑

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
    
    // 沙盒兜底读取
    if (!tempIcons || tempIcons.count == 0) {
        NSDictionary *fileDict = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        if (fileDict) {
            if (fileDict[@"Enabled"]) isEnabled = [fileDict[@"Enabled"] boolValue];
            if (fileDict[@"IOSDump_CSI_Icons"]) tempIcons = fileDict[@"IOSDump_CSI_Icons"];
        }
    }
    customIconsDict = tempIcons ?: @{};

    // 重新初始化缓存池
    imageCache = [NSMutableDictionary new];
    
    NSLog(@"[CustomShareIcon] 纯UI模式加载成功: enabled=%d, icons=%lu", isEnabled, (unsigned long)customIconsDict.count);
    reloadActiveUIs();
}

#pragma mark - 标识符提取与缓存获取

static NSString *cleanBundleID(NSString *bid) {
    if (!bid || bid.length == 0) return nil;
    NSString *lower = bid.lowercaseString;
    if ([lower hasSuffix:@".shareextension"]) return [bid substringToIndex:bid.length - 15];
    if ([lower hasSuffix:@".share"]) return [bid substringToIndex:bid.length - 6];
    if ([lower hasSuffix:@".action"]) return [bid substringToIndex:bid.length - 7];
    return bid;
}

static NSString *extractIdentifier(id proxy) {
    if (!proxy) return nil;

    NSString *bid = safeString(proxy, @"applicationBundleIdentifier");
    if (bid.length) return cleanBundleID(bid);

    id activity = safePerform(proxy, @"activity") ?: proxy;

    bid = safeString(activity, @"containingAppBundleIdentifier");
    if (bid.length) return cleanBundleID(bid);

    id ext = safePerform(activity, @"applicationExtension");
    if (ext) {
        bid = safeString(ext, @"identifier");
        if (bid.length) return cleanBundleID(bid);
        
        id bundle = safePerform(ext, @"_bundle");
        bid = safeString(bundle, @"bundleIdentifier");
        if (bid.length) return cleanBundleID(bid);
    }

    bid = safeString(activity, @"activityType");
    if (bid.length) return cleanBundleID(bid);

    return nil;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    
    NSString *cleanID = cleanBundleID(identifier);
    if (!cleanID.length) return nil;
    
    // 极速返回缓存 (含未命中的 NSNull)
    id cachedObj = imageCache[cleanID];
    if (cachedObj) {
        return cachedObj == [NSNull null] ? nil : (UIImage *)cachedObj;
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
    
    if (!base64) {
        imageCache[cleanID] = [NSNull null];
        return nil;
    }

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    UIImage *img = data ? [UIImage imageWithData:data scale:3.0] : nil;
    
    imageCache[cleanID] = img ?: [NSNull null];
    return img;
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

#pragma mark - 主面板 Cell (纯视觉遮盖，0死循环，直角正方形)

%hook UIShareGroupActivityCell

// 在图像更新的必经之路上打补丁
- (void)setActivityProxy:(id)proxy { %orig; [self csi_applyCustomIcon]; }
- (void)setImage:(UIImage *)image { %orig; [self csi_applyCustomIcon]; }
- (void)_updateImageView { %orig; [self csi_applyCustomIcon]; }

- (void)prepareForReuse {
    %orig;
    UIImageView *ov = (UIImageView *)[self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (ov && !ov.hidden) {
        ov.hidden = YES;
        ov.image = nil;
    }
    
    UIView *nativeIv = safePerform(self, @"activityImageView");
    if (nativeIv && nativeIv.alpha != 1.0) {
        nativeIv.alpha = 1.0;
    }
}

%new
- (void)csi_applyCustomIcon {
    // 强制回到主线程执行 UI 更新，绝对安全
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self csi_applyCustomIcon];
        });
        return;
    }

    UIImageView *ov = (UIImageView *)[self.contentView viewWithTag:TAG_CUSTOM_ICON];
    
    UIView *nativeIv = safePerform(self, @"activityImageView");
    UIView *slotView = safePerform(self, @"imageSlotView");
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? nativeIv : slotView;
    
    if (!isEnabled) {
        if (ov && !ov.hidden) { ov.hidden = YES; ov.image = nil; }
        if (nativeIv && nativeIv.alpha != 1.0) { nativeIv.alpha = 1.0; }
        return;
    }

    id proxy = safePerform(self, @"activityProxy");
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    
    if (!img) {
        if (ov && !ov.hidden) { ov.hidden = YES; ov.image = nil; }
        if (nativeIv && nativeIv.alpha != 1.0) { nativeIv.alpha = 1.0; }
        return;
    }

    if (!ref || CGRectIsEmpty(ref.frame)) return;

    // 隐藏系统图片 (使用 alpha=0 不触发死循环)
    if (nativeIv && nativeIv.alpha != 0.0) {
        nativeIv.alpha = 0.0; 
    }

    if (!ov) {
        ov = [[UIImageView alloc] initWithFrame:ref.frame];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.userInteractionEnabled = NO;
        ov.layer.cornerRadius = 0; // 强制绝对正方形
        [self.contentView addSubview:ov]; 
    }
    
    if (!CGRectEqualToRect(ov.frame, ref.frame)) ov.frame = ref.frame;
    if (ov.image != img) ov.image = img;
    if (ov.hidden) ov.hidden = NO;
    
    // 维持层级：我们叠加的图层在顶端，但要留给角标空间
    if ([self.contentView.subviews lastObject] != ov) {
        [self.contentView bringSubviewToFront:ov];
    }
    UIView *badge = safePerform(self, @"badgeSlotView");
    if (badge && [self.contentView.subviews lastObject] != badge) {
        [self.contentView bringSubviewToFront:badge];
    }
}

%end

#pragma mark - 更多面板 Cell (列表绝对正方形覆盖)

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    
    UIImageView *ov = (UIImageView *)[cell.contentView viewWithTag:TAG_CUSTOM_ICON];

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

    NSString *bid = extractIdentifier(activity);
    UIImage *img = getCustomIconForID(bid);
    
    if (!img) {
        if (ov && !ov.hidden) ov.hidden = YES;
        if (cell.imageView.alpha != 1.0) cell.imageView.alpha = 1.0;
        return;
    }

    UIImageView *sysIv = cell.imageView;
    if (sysIv && sysIv.alpha != 0.0) sysIv.alpha = 0.0; 

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.cornerRadius = 0; // 列表页依然强制绝对正方形
        [cell.contentView addSubview:ov];
    }
    
    CGRect targetFrame;
    if (sysIv && !CGRectIsEmpty(sysIv.frame)) {
        targetFrame = sysIv.frame;
    } else {
        CGFloat size = 29.0;
        targetFrame = CGRectMake(16, (cell.bounds.size.height - size) / 2.0, size, size);
    }
    
    if (!CGRectEqualToRect(ov.frame, targetFrame)) ov.frame = targetFrame;
    if (ov.image != img) ov.image = img;
    if (ov.hidden) ov.hidden = NO;
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
