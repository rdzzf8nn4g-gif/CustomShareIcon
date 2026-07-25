#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

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
static BOOL prefsLoaded = NO;

// 只读 CFPreferences，不碰任何文件路径（daemon 安全）
static void loadPrefs(void) {
    if (imageCache) [imageCache removeAllObjects];
    else imageCache = [NSMutableDictionary new];

    isEnabled = NO;
    customIconsDict = nil;
    prefsLoaded = YES;

    @try {
        CFPreferencesAppSynchronize(PREFS_DOMAIN);
    } @catch (NSException *e) {}

    Boolean keyExists = false;
    Boolean enVal = true;
    @try {
        enVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
        if (!keyExists) {
            enVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), kCFPreferencesAnyApplication, &keyExists);
        }
    } @catch (NSException *e) {}

    if (keyExists && !enVal) {
        isEnabled = NO;
        return;
    }

    NSDictionary *icons = nil;
    @try {
        CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
        if (!ref) {
            ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), kCFPreferencesAnyApplication);
        }
        if (ref) {
            if (CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
                icons = [(__bridge NSDictionary *)ref copy];
            }
            CFRelease(ref);
        }
    } @catch (NSException *e) {}

    if (icons.count > 0) {
        customIconsDict = icons;
        isEnabled = YES;
    }
}

static void ensurePrefs(void) {
    if (!prefsLoaded) loadPrefs();
}

static UIImage *roundedImage(UIImage *img, CGFloat ratio) {
    if (!img) return nil;
    CGSize size = img.size;
    if (size.width < 1 || size.height < 1) return img;
    CGFloat radius = MIN(size.width, size.height) * ratio;
    UIGraphicsBeginImageContextWithOptions(size, NO, img.scale);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:radius] addClip];
    [img drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

static UIImage *getCustomIconForID(NSString *identifier) {
    ensurePrefs();
    if (!isEnabled || !identifier.length || !customIconsDict.count) return nil;
    if (imageCache[identifier]) return imageCache[identifier];

    NSString *base64 = nil;
    NSString *lower = identifier.lowercaseString;

    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key];
            break;
        }
    }
    if (!base64) {
        for (NSString *key in customIconsDict) {
            if (key.length < 3) continue;
            NSString *lk = key.lowercaseString;
            if ([lower containsString:lk] || [lk containsString:lower] ||
                [lower hasPrefix:lk] || [lk hasPrefix:lower]) {
                base64 = customIconsDict[key];
                break;
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
                        base64 = customIconsDict[key];
                        break;
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
        NSString *path = nil;
        @try { path = [configuration valueForKey:@"bundlePath"]; } @catch (NSException *e) {}
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

    UIImageView *nativeIv = nil;
    UIView *slotView = nil;
    @try { nativeIv = [self valueForKey:@"activityImageView"]; } @catch (NSException *e) {}
    @try { slotView = [self valueForKey:@"imageSlotView"]; } @catch (NSException *e) {}
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

    UIView *badge = nil;
    @try { badge = [self valueForKey:@"badgeSlotView"]; } @catch (NSException *e) {}
    if (badge) [self.contentView bringSubviewToFront:badge];
}

%end

#pragma mark - 更多列表

%hook _UIActivityUserDefaultsViewController

- (id)cellForItemIdentifier:(id)identifier {
    id cell = %orig;
    if (!isEnabled || !cell) return cell;
    id activity = nil;
    NSDictionary *byUUID = nil;
    @try { byUUID = [self valueForKey:@"activitiesByUUID"]; } @catch (NSException *e) {}
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
        @try { activity = [self activityForRowAtIndexPath:indexPath]; } @catch (NSException *e) {}
    }
    if (!activity) return;
    UIImage *img = getCustomIconForID(bundleIDFromActivity(activity));
    if (img) applyToImageView(cell.imageView, img);
}

%end

static void prefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    prefsLoaded = NO;
    // 延迟到主线程，避免在 notify 回调里碰偏好导致问题
    dispatch_async(dispatch_get_main_queue(), ^{
        loadPrefs();
    });
}

%ctor {
    // 关键：不要在 dyld 加载阶段立刻读偏好（sharingd 会 SANDBOX kill）
    // 只注册通知；真正读偏好放到主队列 / 第一次用图标时
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        prefsChanged,
        CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );

    dispatch_async(dispatch_get_main_queue(), ^{
        loadPrefs();
    });
}
