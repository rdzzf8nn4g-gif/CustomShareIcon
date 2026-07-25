#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIView *badgeSlotView;
- (void)setActivityProxy:(id)proxy;
- (void)setImage:(UIImage *)image;
- (void)_updateImageView;
- (void)csi_applyCustomIcon;
@end

@interface UIApplicationExtensionActivity : UIActivity
- (NSString *)containingAppBundleIdentifier;
- (NSString *)activityType;
- (UIImage *)_activityImage;
@end

@interface UIActivity (CustomShareIcon)
+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier;
+ (id)_activityImageForBundleImageConfiguration:(id)configuration;
- (UIImage *)activityImage;
- (UIImage *)_activityImage;
- (NSString *)_systemImageName;
- (NSString *)activityType;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static NSMutableDictionary<NSString *, UIImage *> *imageCache = nil;

#pragma mark - 加载（只保留共享缓存 + 简单兜底）

static BOOL isSpringBoardProcess() {
    return [[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"] ||
           [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];
}

static void writeSharedCache(NSDictionary *icons) {
    if (!icons.count) return;
    [@{@"IOSDump_CSI_Icons": icons, @"Enabled": @YES} writeToFile:SHARED_CACHE_PATH atomically:YES];
}

static void loadPrefs() {
    // 优先共享缓存
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfFile:SHARED_CACHE_PATH];
    if ([cache isKindOfClass:[NSDictionary class]]) {
        id icons = cache[@"IOSDump_CSI_Icons"];
        if ([icons isKindOfClass:[NSDictionary class]] && [icons count] > 0) {
            customIconsDict = [icons copy];
            isEnabled = YES;
            imageCache = [NSMutableDictionary new];
            NSLog(@"[CustomShareIcon] 共享缓存 count=%lu", (unsigned long)customIconsDict.count);
            return;
        }
    }

    // 简单 CFPreferences
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
    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)(customIconsDict.count));

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

    // 精确
    for (NSString *key in customIconsDict) {
        if ([identifier caseInsensitiveCompare:key] == NSOrderedSame) {
            base64 = customIconsDict[key]; matched = key; break;
        }
    }
    // 包含 / 前缀（照顾扩展 ID：com.xxx.yyy.share → com.xxx.yyy）
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

    if (activity) {
        @try {
            if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
                r = [activity valueForKey:@"containingAppBundleIdentifier"];
                if (r.length) return r;
            }
        } @catch (NSException *e) {}

        @try {
            if ([activity respondsToSelector:@selector(applicationExtension)]) {
                id ext = [activity valueForKey:@"applicationExtension"];
                if (ext) {
                    r = [ext valueForKey:@"identifier"];
                    if (r.length) return r;
                    id bundle = [ext valueForKey:@"_bundle"];
                    if (bundle) {
                        r = [bundle bundleIdentifier];
                        if (r.length) return r;
                    }
                }
            }
        } @catch (NSException *e) {}

        @try {
            if ([activity respondsToSelector:@selector(activityType)]) {
                r = [activity valueForKey:@"activityType"];
                if (r.length) return r;
            }
        } @catch (NSException *e) {}
    }

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
        if ([cls containsString:@"UIActivityViewController"] || [cls containsString:@"SHSheet"] ||
            [cls containsString:@"ShareSheet"] || [cls containsString:@"UIActivityList"] ||
            [cls containsString:@"ActivityContent"] || [cls containsString:@"UIShareGroup"] ||
            [cls containsString:@"_UIHostActivity"]) return YES;
        r = [r nextResponder];
        d++;
    }
    return NO;
}

#pragma mark - 源头（主面板 + 更多列表共同依赖）

%hook UIActivity

+ (id)_activityImageForApplicationBundleIdentifier:(NSString *)identifier {
    UIImage *c = getCustomIconForID(identifier);
    return c ?: %orig;
}

+ (id)_activityImageForBundleImageConfiguration:(id)configuration {
    if ([configuration isKindOfClass:NSClassFromString(@"_UIActivityBundleImageConfiguration")]) {
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
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *c = getCustomIconForID(type);
    if (c) return c;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        c = getCustomIconForID([self valueForKey:@"containingAppBundleIdentifier"]);
        if (c) return c;
    }
    return %orig;
}

- (UIImage *)_activityImage {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    UIImage *c = getCustomIconForID(type);
    if (c) return c;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        c = getCustomIconForID([self valueForKey:@"containingAppBundleIdentifier"]);
        if (c) return c;
    }
    return %orig;
}

- (NSString *)_systemImageName {
    NSString *type = [self respondsToSelector:@selector(activityType)] ? [self activityType] : nil;
    if (getCustomIconForID(type)) return nil;
    return %orig;
}

%end

%hook UIApplicationExtensionActivity

- (UIImage *)_activityImage {
    NSString *bid = nil;
    if ([self respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        bid = [self containingAppBundleIdentifier];
    }
    if (!bid.length && [self respondsToSelector:@selector(activityType)]) {
        bid = [self activityType];
    }
    UIImage *c = getCustomIconForID(bid);
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
    if (!isEnabled) return;
    id proxy = [self valueForKey:@"activityProxy"];
    NSString *identifier = extractIdentifier(proxy);
    UIImage *img = identifier.length ? getCustomIconForID(identifier) : nil;
    if (!img) return;

    UIImageView *nativeIv = [self valueForKey:@"activityImageView"];
    UIView *slotView = [self valueForKey:@"imageSlotView"];
    UIView *ref = (nativeIv && nativeIv.frame.size.width > 10) ? (UIView *)nativeIv : slotView;
    if (!ref || CGRectIsEmpty(ref.frame)) return;

    if (nativeIv) {
        nativeIv.image = img;
        nativeIv.hidden = NO;
        nativeIv.alpha = 1;
        nativeIv.contentMode = UIViewContentModeScaleAspectFit;
        nativeIv.clipsToBounds = YES;
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

#pragma mark - 「更多」列表

%hook UITableViewCell

- (void)layoutSubviews {
    %orig;
    if (!isEnabled || !customIconsDict.count) return;
    if (!isInShareSheetContext(self)) return;

    UIImageView *iv = self.imageView;
    if (!iv || iv.frame.size.width < 24) {
        for (UIView *sub in self.contentView.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.frame.size.width >= 24 && sub.frame.size.width <= 80) {
                iv = (UIImageView *)sub;
                break;
            }
        }
    }
    if (!iv) return;

    // 更多列表很难拿到 proxy，只能尝试用标题最后一段碰 key
    NSString *title = self.textLabel.text;
    if (!title.length) return;

    UIImage *img = nil;
    for (NSString *key in customIconsDict) {
        NSString *last = [[key componentsSeparatedByString:@"."] lastObject];
        if (last.length > 2 && [title.lowercaseString containsString:last.lowercaseString]) {
            img = getCustomIconForID(key);
            if (img) break;
        }
    }
    if (!img) return;

    iv.image = img;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = YES;
    iv.layer.cornerRadius = 8;

    UIImageView *ov = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (!ov) {
        ov = [UIImageView new];
        ov.tag = TAG_CUSTOM_ICON;
        ov.contentMode = UIViewContentModeScaleAspectFit;
        ov.clipsToBounds = YES;
        [self.contentView addSubview:ov];
    }
    ov.frame = iv.frame;
    ov.layer.cornerRadius = 8;
    ov.image = img;
    ov.hidden = NO;
    [self.contentView bringSubviewToFront:ov];
}

- (void)prepareForReuse {
    %orig;
    UIImageView *iv = [self.contentView viewWithTag:TAG_CUSTOM_ICON];
    if (iv) { iv.hidden = YES; iv.image = nil; }
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] 精简版加载");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
