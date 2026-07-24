#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#define TAG_CUSTOM_ICON 998877
#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@interface UIShareGroupActivityCell : UICollectionViewCell
@property (nonatomic, strong) id activityProxy;
- (void)setActivityProxy:(id)proxy;
- (void)csi_forceRed;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;
static UIImage *testRedImage = nil;

static void loadPrefs() {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);

    Boolean keyExists = false;
    Boolean enabledVal = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    isEnabled = keyExists ? enabledVal : NO;

    CFPropertyListRef iconsRef = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (iconsRef && CFGetTypeID(iconsRef) == CFDictionaryGetTypeID()) {
        customIconsDict = [(__bridge NSDictionary *)iconsRef copy];
    } else {
        customIconsDict = nil;
    }
    if (iconsRef) CFRelease(iconsRef);

    NSLog(@"[CustomShareIcon] loadPrefs enabled=%d count=%lu", isEnabled, (unsigned long)(customIconsDict ? customIconsDict.count : 0));
}

static UIImage *getTestRedImage() {
    if (testRedImage) return testRedImage;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(60, 60), NO, 3.0);
    [[UIColor redColor] setFill];
    UIRectFill(CGRectMake(0, 0, 60, 60));
    [[UIColor whiteColor] setStroke];
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectMake(2, 2, 56, 56)];
    path.lineWidth = 4;
    [path stroke];
    testRedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return testRedImage;
}

// 递归把所有 UIImageView 的图片强制换成红色（暴力测试）
static void forceRedOnAllImageViews(UIView *view) {
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        iv.image = getTestRedImage();
        iv.hidden = NO;
        iv.alpha = 1.0;
        iv.backgroundColor = [UIColor redColor];
    }
    for (UIView *sub in view.subviews) {
        forceRedOnAllImageViews(sub);
    }
}

%hook UIShareGroupActivityCell

- (void)setActivityProxy:(id)proxy {
    %orig;
    NSLog(@"[CustomShareIcon] setActivityProxy 被调用 class=%@ proxy=%@", NSStringFromClass([self class]), proxy);
    [self csi_forceRed];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_forceRed];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self csi_forceRed];
    });
}

- (void)layoutSubviews {
    %orig;
    [self csi_forceRed];
}

- (void)prepareForReuse {
    %orig;
    UIView *v = [self viewWithTag:TAG_CUSTOM_ICON];
    if (v) v.hidden = YES;
}

%new
- (void)csi_forceRed {
    if (!isEnabled) return;

    // 1. 暴力把所有现有 UIImageView 换成红色
    forceRedOnAllImageViews(self);

    // 2. 自己再强制盖一层红色方块（不依赖任何私有属性）
    UIImageView *customIv = [self viewWithTag:TAG_CUSTOM_ICON];
    if (!customIv) {
        customIv = [[UIImageView alloc] init];
        customIv.tag = TAG_CUSTOM_ICON;
        customIv.contentMode = UIViewContentModeScaleAspectFit;
        customIv.clipsToBounds = YES;
        customIv.layer.cornerRadius = 13;
        customIv.backgroundColor = [UIColor redColor];
        [self addSubview:customIv];   // 直接加到 cell 上，不依赖 contentView
    }

    // 强制放在中间，尺寸固定
    CGFloat size = 58;
    customIv.frame = CGRectMake((self.bounds.size.width - size) / 2.0,
                                4,
                                size, size);
    customIv.image = getTestRedImage();
    customIv.hidden = NO;
    customIv.alpha = 1.0;
    [self bringSubviewToFront:customIv];

    NSLog(@"[CustomShareIcon] 强制红色已执行 bounds=%.0fx%.0f subviews=%lu",
          self.bounds.size.width, self.bounds.size.height, (unsigned long)self.subviews.count);
}

%end

%ctor {
    NSLog(@"[CustomShareIcon] Tweak 加载完成 (iOS14 暴力红色测试版)");
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL, (CFNotificationCallback)loadPrefs,
                                    CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorCoalesce);
}
