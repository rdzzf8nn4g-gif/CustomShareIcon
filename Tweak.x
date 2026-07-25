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

@interface _UIActivityUserDefaultsViewController : UIViewController
@property (copy, nonatomic) NSArray *activities;
@property (retain, nonatomic) NSDictionary *activitiesByUUID;
- (id)activityForRowAtIndexPath:(NSIndexPath *)indexPath;
- (id)cellForItemIdentifier:(id)identifier;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

#pragma mark - 加载

static BOOL isSpringBoardProcess() {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
           [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];
}

static void writeSharedCache(NSDictionary *icons) {
    if (!icons.count) return;
    [@{@"IOSDump_CSI_Icons": icons, @"Enabled": @YES} writeToFile:SHARED_CACHE_PATH atomically:YES];
}

static void loadPrefs() {
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id icons = cache[@"IOSDump_CSI_Icons"];
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            customIconsDict = [icons copy];
            isEnabled = YES;
            imageCache = [NSMutableDictionary new];
            NSLog(@"[CustomShareIcon] 共享缓存 count=%lu keys=%@", (unsigned long)customIconsDict.count, customIconsDict.allKeys);
            return;
        }
    }

    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!ref) ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        customIconsDict = [(__bridge NSDictionary *)ref copy];
    } else {
        customIconsDict = nil;
    }
    if (ref) CFRelease(ref);

    isEnabled = (customIconsDict.count > 0);
    imageCache = [NSMutableDictionary new];
    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)customIconsDict.count);

    if (isSpringBoardProcess() && customIconsDict.count > 0) {
        writeSharedCache(customIconsDict);
    }
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64 = nil;
    NSString *matched = nil;
    NSString *lower = identifier.lowercaseString;

    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; matched = key; break;
        }
    }
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower] ||
                [lower hasPrefix:lk] || [lk hasPrefix:lower]) {
                base64 = customIconsDict[key]; matched = key; break;
            }
        }
    }
    if (!base64) {
        // 按段匹配：com.tencent.xin.share → com.tencent.xin
        NSArray *parts = [identifier componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            for (NSInteger len = parts.count - 1; len >= 2; len--) {
                NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, len)] componentsJoinedByString:@"."];
                for (NSString *key in customIconsDict) {
                    if ([prefix caseInsensitiveCompare:key] == NSOrderedSame) {
                        base64 = customIconsDict[key]; matched = key; break;
                    }
                }
                if (base64) break;
            }
        }
    }
    if (!base64) return nil;

    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return nil;
    UIImage *img = [UIImage imageWithData:data scale:3.0];
    if (img) {
        imageCache[identifier] = img;
        NSLog(@"[CustomShareIcon] ✅ %@ → %@", identifier, matched);
    }
    return img;
}

// 从任意 activity / extension 尽量拿出主 Bundle ID
static NSString *bundleIDFromActivity(id activity) {
    if (!activity) return nil;
    NSString *r = nil;

    @try {
        if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
            r = [activity valueForKey:@"containingAppBundleIdentifier"];
            if (r.length) return r;
        }
    } @catch (NSException *e) {}

    @try {
        id ext = [activity valueForKey:@"applicationExtension"];
        if (ext) {
            // NSExtension.identifier 常是扩展 ID
            r = [ext valueForKey:@"identifier"];
            if (r.length) {
                // 同时尝试 containing
                @try {
                    NSString *containing = [ext valueForKey:@"_containingApplicationBundleIdentifier"];
                    if (containing.length) return containing;
                } @catch (NSException *e) {}
                return r;
            }
            id bundle = [ext valueForKey:@"_bundle"];
            if (bundle) {
                r = [bundle bundleIdentifier];
                if (r.length) return r;
            }
        }
    } @catch (NSException *e) {}

    @try {
        if ([activity respondsToSelector:@selector(activityType)]) {
            r = [activity valueForKey:@"activityType"];
            if (r.length) return r;
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
            if (r.length) return r;
        }
    } @catch (NSException *e) {}

    id activity = nil;
    @try { activity = [proxy valueForKey:@"activity"]; } @catch (NSException *e) {}
    r = bundleIDFromActivity(activity);
    if (r.length) return r;

    @try {
        if ([proxy respondsToSelector:@selector(activityType)]) {
            r = [proxy valueForKey:@"activityType"];
            if (r.length) return r;
        }
    } @catch (NSException *e) {}

    return nil;
}

static void applyImageToImageView(UIImageView *iv, UIImage *img) {
    if (!iv || !img) return;
    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = YES;
    if (iv.layer.cornerRadius < 1) iv.layer.cornerRadius = 8;
}

#pragma mark - 源头：UIActivity

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *c = getCustomIconForID(identifier);
    if (c) NSLog(@"[CustomShareIcon] 源头 BundleID → %@", identifier);
    return c ?: %orig;
}

+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    if (configuration) {
        NSString *path = [configuration valueForKey:@"bundlePath"];
        if (path.length) {
            NSString *last = [[path lastPathComponent] stringByDeletingPathExtension];
            UIImage *c = getCustomIconForID(last);
            if (c) return c;
            for (NSString *key in customIconsDict) {
                if ([path.lowercaseString containsString:key.lowercaseString]) {
                    c = getCustomIconForID(key);
                    if (c) return c;
                }
            }
        }
    }
    return %orig;
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

#pragma mark - 源头：UIApplicationExtensionActivity（App Store 核心）

%hook UIApplicationExtensionActivity

- (UIImage *)_activityImage {
    NSString *bid = bundleIDFromActivity(self);
    UIImage *c = getCustomIconForID(bid);
    if (c) {
        NSLog(@"[CustomShareIcon] Extension _activityImage → %@", bid);
        return c;
    }
    // 打印未匹配，方便你对照设置里的 key
    if (bid.length) NSLog(@"[CustomShareIcon] Extension未匹配 _activityImage id=%@", bid);
    return %orig;
}

- (UIImage *)_actionImage {
    NSString *bid = bundleIDFromActivity(self);
    UIImage *c = getCustomIconForID(bid);
    if (c) {
        NSLog(@"[CustomShareIcon] Extension _actionImage → %@", bid);
        return c;
    }
    return %orig;
}

- (UIImage *)_activitySettingsImage {
    NSString *bid = bundleIDFromActivity(self);
    UIImage *c = getCustomIconForID(bid);
    if (c) return c;
    return %orig;
}

%end

#pragma mark - 主面板 cell

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
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) { iv.hidden = YES; iv.image = nil; }
}

%new
- (void)csi_applyCustomIcon {
    if (!isEnabled) return;
    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!img) return;

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? (UIView *)nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

    if (nativeIv) applyImageToImageView(nativeIv, img);

    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.userInteractionEnabled = NO;
        [self.contentView addSubview:ov];
    }
    ov.frame = ref.frame;
    CGFloat radius = ref.layer.cornerRadius;
    if (radius < 1) radius = 13;
    ov.layer.cornerRadius = radius;
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    UIView *badge = [self valueForKey:@"badgeSlotView"];
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

#pragma mark - 「更多」列表：_UIActivityUserDefaultsViewController

%hook _UIActivityUserDefaultsViewController

- (id)cellForItemIdentifier:(id)identifier {
    UITableViewCell *cell = %orig;
    if (!isEnabled || !cell) return cell;

    // 从 activitiesByUUID / activities 找对应 activity
    id activity = nil;
    NSDictionary *byUUID = [self valueForKey:@"activitiesByUUID"];
    if (identifier && byUUID) {
        activity = byUUID[identifier];
    }
    if (!activity) {
        // 兜底：遍历 activities
        NSArray *acts = [self valueForKey:@"activities"];
        for (id a in acts) {
            NSString *bid = bundleIDFromActivity(a);
            if (bid && getCustomIconForID(bid)) {
                // 无法精确对应行时不乱改
            }
        }
    }

    if (activity) {
        NSString *bid = bundleIDFromActivity(activity);
        UIImage *img = getCustomIconForID(bid);
        if (img) {
            applyImageToImageView(cell.imageView, img);
            NSLog(@"[CustomShareIcon] 更多列表 cell → %@", bid);
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!isEnabled) return;

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;

    NSString *bid = bundleIDFromActivity(activity);
    UIImage *img = getCustomIconForID(bid);
    if (!img) {
        if (bid.length) NSLog(@"[CustomShareIcon] 更多列表未匹配 id=%@", bid);
        return;
    }
    applyImageToImageView(cell.imageView, img);
    NSLog(@"[CustomShareIcon] 更多列表 willDisplay → %@", bid);
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] 加载完成 (源头+UserDefaults更多列表)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
