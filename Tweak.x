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
@end

@interface UIActivity (CustomShareIcon)
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier;
+ (id)_activityImageForBundleImageConfiguration:(id)configuration;
- (UIImage *)_activityImage;
- (NSString *)activityType;
@end

@interface _UIActivityUserDefaultsViewController : UIViewController
@property (retain, nonatomic) NSDictionary *activitiesByUUID;
- (id)activityForRowAtIndexPath:(NSIndexPath *)indexPath;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary *imageCache = nil;

static BOOL isSpringBoardProcess() {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
           [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];
}

static void writeSharedCache(NSDictionary *icons, BOOL enabled) {
    if (enabled && icons.count > 0) {
        [@{@"IOSDump_CSI_Icons": icons, @"Enabled": @YES} writeToFile:SHARED_CACHE_PATH atomically:YES];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:SHARED_CACHE_PATH error:nil];
        [@{@"IOSDump_CSI_Icons": @{}, @"Enabled": @NO} writeToFile:SHARED_CACHE_PATH atomically:YES];
    }
}

static void loadPrefs() {
    if (imageCache) [imageCache removeAllObjects];
    else imageCache = [NSMutableDictionary new];

    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id en = cache[@"Enabled"];
        id icons = cache[@"IOSDump_CSI_Icons"];
        if ([en respondsToSelector:@selector(boolValue)] && ![en boolValue]) {
            customIconsDict = nil;
            isEnabled = NO;
            NSLog(@"[CustomShareIcon] 共享缓存:已关闭");
            return;
        }
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            customIconsDict = [icons copy];
            isEnabled = YES;
            NSLog(@"[CustomShareIcon] 共享缓存 count=%lu", (unsigned long)customIconsDict.count);
            return;
        }
    }

    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    Boolean keyExists = false;
    Boolean enVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (!ref) ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);

    NSDictionary *dict = nil;
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        dict = [(__bridge NSDictionary *)ref copy];
    }
    if (ref) CFRelease(ref);

    if (keyExists && !enVal) {
        customIconsDict = nil;
        isEnabled = NO;
    } else if (dict.count > 0) {
        customIconsDict = dict;
        isEnabled = YES;
    } else {
        customIconsDict = nil;
        isEnabled = NO;
    }

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)customIconsDict.count);

    if (isSpringBoardProcess()) {
        writeSharedCache(customIconsDict, isEnabled);
    }
}

static UIImage *roundedImage(UIImage *img, CGFloat radius) {
    if (!img) return nil;
    CGSize size = img.size;
    if (size.width < 1 || size.height < 1) return img;
    UIGraphicsBeginImageContextWithOptions(size, NO, img.scale);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:radius];
    [path addClip];
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

    // 按分享图标常见圆角裁切（约 22%）
    CGFloat side = MIN(img.size.width, img.size.height);
    CGFloat radius = side * 0.2237;
    img = roundedImage(img, radius);

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
                if ([path.lowercaseString containsString:key.lowercaseString]) {
                    c = getCustomIconForID(key);
                    if (c) return c;
                }
            }
        }
    }
    return %orig;
}

- (UIImage *)_activityImage {
    UIImage *c = getCustomIconForID(bundleIDFromActivity(self));
    return c ?: %orig;
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
    if (!isEnabled) {
        UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
        if (ov) { ov.hidden = YES; ov.image = nil; }
        return;
    }
    NSString *identifier = extractIdentifier([self valueForKey:@"activityProxy"]);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!img) return;

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
    ov.layer.cornerRadius = radius;
    ov.layer.masksToBounds = YES;
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];

    UIView *badge = [self valueForKey:@"badgeSlotView"];
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

#pragma mark - 更多列表

%hook _UIActivityUserDefaultsViewController

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    %orig;
    if (!isEnabled) return;
    id activity = nil;
    if ([self respondsToSelector:@selector(activityForRowAtIndexPath:)]) {
        activity = [self activityForRowAtIndexPath:indexPath];
    }
    if (!activity) return;
    UIImage *img = getCustomIconForID(bundleIDFromActivity(activity));
    if (!img || !cell.imageView) return;
    cell.imageView.image = img;
    cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
    cell.imageView.clipsToBounds = YES;
    cell.imageView.layer.cornerRadius = cell.imageView.frame.size.width * 0.2237;
    cell.imageView.layer.masksToBounds = YES;
}

%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
