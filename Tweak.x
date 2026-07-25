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
static NSMutableDictionary *imageCache = nil;

static BOOL isSpringBoardProcess() {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if ([bid isEqualToString:@"com.apple.springboard"]) return YES;
    if ([[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return YES;
    return NO;
}

static void writeSharedCache(NSDictionary *icons, BOOL enabled) {
    NSDictionary *obj = @{
        @"Enabled" : @(enabled),
        @"IOSDump_CSI_Icons" : (icons ?: @{}),
        @"ts" : @([[NSDate date] timeIntervalSince1970])
    };
    [obj writeToFile:SHARED_CACHE_PATH atomically:YES];
    NSLog(@"[CustomShareIcon] 写共享缓存 enabled=%d count=%lu", enabled, (unsigned long)(icons.count));
}

static void loadPrefs() {
    if (imageCache) [imageCache removeAllObjects];
    else imageCache = [NSMutableDictionary new];

    // 1) 先读真实偏好里的 Enabled（最高优先级）
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    Boolean keyExists = false;
    Boolean enVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    if (!keyExists) {
        enVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), kCFPreferencesAnyApplication, &keyExists);
    }

    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!ref) ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
    NSDictionary *prefIcons = nil;
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        prefIcons = [(__bridge NSDictionary *)ref copy];
    }
    if (ref) CFRelease(ref);

    // 2) 读共享缓存
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    NSDictionary *cacheIcons = nil;
    BOOL cacheEnabled = YES;
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id ce = cache[@"Enabled"];
        if ([ce respondsToSelector:@selector(boolValue)]) cacheEnabled = [ce boolValue];
        id ci = cache[@"IOSDump_CSI_Icons"];
        if ([ci isKindOfClass:[NSDictionary class]]) cacheIcons = ci;
    }

    // 3) 决策：真实偏好 Enabled 存在时以它为准
    if (keyExists && !enVal) {
        isEnabled = NO;
        customIconsDict = nil;
        if (isSpringBoardProcess()) writeSharedCache(nil, NO);
        NSLog(@"[CustomShareIcon] 已关闭 (偏好)");
        return;
    }

    if (cache && !cacheEnabled) {
        isEnabled = NO;
        customIconsDict = nil;
        NSLog(@"[CustomShareIcon] 已关闭 (共享缓存)");
        return;
    }

    if (prefIcons.count > 0) {
        customIconsDict = prefIcons;
        isEnabled = YES;
    } else if (cacheIcons.count > 0 && cacheEnabled) {
        customIconsDict = [cacheIcons copy];
        isEnabled = YES;
    } else {
        customIconsDict = nil;
        isEnabled = NO;
    }

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu keys=%@", isEnabled,
          (unsigned long)customIconsDict.count, customIconsDict.allKeys ?: @[]);

    if (isSpringBoardProcess()) {
        writeSharedCache(customIconsDict, isEnabled);
    }
}

static UIImage *roundedImage(UIImage *img, CGFloat cornerRatio) {
    if (!img) return nil;
    CGSize size = img.size;
    if (size.width < 1 || size.height < 1) return img;
    CGFloat radius = MIN(size.width, size.height) * cornerRatio;
    UIGraphicsBeginImageContextWithOptions(size, NO, img.scale);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:radius] addClip];
    [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64 = nil;
    NSString *lower = identifier.lowercaseString;

    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; break;
        }
    }
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower] ||
                [lower hasPrefix:lk] || [lk hasPrefix:lower]) {
                base64 = customIconsDict[key]; break;
            }
        }
    }
    if (!base64) {
        NSArray *parts = [identifier componentsSeparatedByString:@"."];
        if (parts.count >= 2) {
            for (NSInteger len = (NSInteger)parts.count - 1; len >= 2; len--) {
                NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, len)] componentsJoinedByString:@"."];
                for (NSString *key in customIconsDict) {
                    if ([prefix caseInsensitiveCompare:key] == NSOrderedSame) {
                        base64 = customIconsDict[key]; break;
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
    if (!img) return nil;

    img = roundedImage(img, 0.2237);
    imageCache[identifier] = img;
    NSLog(@"[CustomShareIcon] ✅ %@", identifier);
    return img;
}

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
            @try {
                NSString *c = [ext valueForKey:@"_containingApplicationBundleIdentifier"];
                if (c.length) return c;
            } @catch (NSException *e) {}
            r = [ext valueForKey:@"identifier"];
            if (r.length) return r;
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

static BOOL isInShareSheetContext(UIView *view) {
    UIResponder *r = view;
    int d = 0;
    while (r && d < 16) {
        NSString *cls = NSStringFromClass([r class]);
        if ([cls containsString:@"Preferences"] || [cls containsString:@"PSList"]) return NO;
        if ([cls containsString:@"UIActivity"] || [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] || [cls containsString:@"UserDefaults"]) return YES;
        r = [r nextResponder];
        d++;
    }
    return NO;
}

static void applyToImageView(UIImageView *iv, UIImage *img) {
    if (!iv || !img) return;
    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = YES;
    iv.layer.masksToBounds = YES;
    CGFloat w = iv.bounds.size.width > 1 ? iv.bounds.size.width : iv.frame.size.width;
    if (w > 1) iv.layer.cornerRadius = w * 0.2237;
}

#pragma mark - 源头

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *c = getCustomIconForID(identifier);
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
                if (key.length && [path.lowercaseString containsString:key.lowercaseString]) {
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

#pragma mark - 主面板

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
    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];

    if (!isEnabled) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    NSString *identifier = extractIdentifier([self valueForKey:@"activityProxy"]);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!img) {
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? (UIView *)nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

    CGFloat radius = ref.layer.cornerRadius;
    if (radius < 1) radius = ref.frame.size.width * 0.2237;

    if (nativeIv) {
        nativeIv.image = img;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        nativeIv.clipsToBounds = YES;
        nativeIv.layer.cornerRadius = radius;
        nativeIv.layer.masksToBounds = YES;
    }

    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        ov.layer.masksToBounds = YES;
        ov.userInteractionEnabled = NO;
        [self.contentView addSubview:ov];
    }
    ov.frame = ref.frame;
    ov.layer.cornerRadius = radius;
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    UIView *badge = [self valueForKey:@"badgeSlotView"];
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

#pragma mark - 更多列表

%hook _UIActivityUserDefaultsViewController

- (id)cellForItemIdentifier:(id)identifier {
    id cell = %orig;
    if (!isEnabled || !cell) return cell;

    id activity = nil;
    NSDictionary *byUUID = [self valueForKey:@"activitiesByUUID"];
    if (identifier && byUUID) activity = byUUID[identifier];
    if (!activity) return cell;

    UIImage *img = getCustomIconForID(bundleIDFromActivity(activity));
    if (img && [cell respondsToSelector:@selector(imageView)]) {
        applyToImageView([cell imageView], img);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!isEnabled || !cell) return;

    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;

    UIImage *img = getCustomIconForID(bundleIDFromActivity(activity));
    if (img) applyToImageView(cell.imageView, img);
}

%end

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    if (!isEnabled || !customIconsDict.count) return;
    if (!isInShareSheetContext(self)) return;
    if (!self.imageView || self.imageView.frame.size.width < 24) return;

    // 更多列表兜底：用已缓存的自定义图无法从 cell 反查 id，这里不强制替换
    // 主要依赖 UserDefaults VC 的 willDisplay / cellForItemIdentifier
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] 完美版加载");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
