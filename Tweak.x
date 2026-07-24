#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 声明我们要 Hook 的系统类的原始方法，避免编译器报错
@interface UIActivity (CustomShareIcon)
- (NSString *)activityType;
@end

@interface UIApplicationExtensionActivity : UIActivity
- (NSString *)containingAppBundleIdentifier;
@end

static BOOL isEnabled = NO;
static NSDictionary *customIconsDict = nil;

// 动态读取 Preferences，使用了 IPC + 物理文件双保险
static void loadPrefs() {
    NSString *path = @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist";
#if __has_include(<roothide.h>)
    path = jbroot(path);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        path = @"/var/jb/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist";
    }
#endif

    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!dict) {
        // 应对极端沙盒的 IPC 降级读取
        CFStringRef appID = CFSTR("com.iosdump.customshareicon");
        CFPreferencesAppSynchronize(appID);
        id enabledVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("Enabled"), appID);
        isEnabled = enabledVal ? [enabledVal boolValue] : NO;
        id iconsVal = (__bridge_transfer id)CFPreferencesCopyAppValue(CFSTR("CustomIcons"), appID);
        if ([iconsVal isKindOfClass:[NSDictionary class]]) {
            customIconsDict = iconsVal;
        }
    } else {
        isEnabled = [dict[@"Enabled"] boolValue];
        customIconsDict = dict[@"CustomIcons"];
    }
}

// 核心匹配算法：将 Base64 实时转为图片，采用 containsString 智能匹配前缀
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!isEnabled || !identifier || identifier.length == 0 || !customIconsDict) return nil;

    NSString *base64Str = customIconsDict[identifier];
    if (!base64Str) {
        // 模糊匹配：应对系统生成的如 com.apple.UIKit.activity.ApplicationExtension.com.tencent.xin
        for (NSString *key in customIconsDict.allKeys) {
            if (key.length > 0 && [identifier containsString:key]) {
                base64Str = customIconsDict[key];
                break;
            }
        }
    }

    if (base64Str) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:base64Str options:0];
        if (data) {
            // 提供原生的屏幕渲染缩放比，保证图标清晰
            return [UIImage imageWithData:data scale:[UIScreen mainScreen].scale];
        }
    }
    return nil;
}

// =======================
// 拦截 1：系统自带分享项目 (复制、Safari打开 等)
// =======================
%hook UIActivity

- (UIImage *)activityImage {
    UIImage *img = getCustomIconForID([self activityType]);
    return img ?: %orig;
}

- (UIImage *)_activityImage {
    UIImage *img = getCustomIconForID([self activityType]);
    return img ?: %orig;
}

- (UIImage *)_actionImage {
    UIImage *img = getCustomIconForID([self activityType]);
    return img ?: %orig;
}

- (UIImage *)_activitySettingsImage {
    UIImage *img = getCustomIconForID([self activityType]);
    return img ?: %orig;
}

- (NSString *)_systemImageName {
    // 强制废掉系统的 SF Symbols，强迫它走我们的图片获取流程
    if (getCustomIconForID([self activityType])) return nil;
    return %orig;
}

%end


// =======================
// 拦截 2：第三方 App 的扩展项目 (微信、QQ、微博 等)
// =======================
%hook UIApplicationExtensionActivity

- (UIImage *)activityImage {
    NSString *ident = [self respondsToSelector:@selector(containingAppBundleIdentifier)] ? [self containingAppBundleIdentifier] : [self activityType];
    UIImage *img = getCustomIconForID(ident);
    return img ?: %orig;
}

- (UIImage *)_activityImage {
    NSString *ident = [self respondsToSelector:@selector(containingAppBundleIdentifier)] ? [self containingAppBundleIdentifier] : [self activityType];
    UIImage *img = getCustomIconForID(ident);
    return img ?: %orig;
}

- (UIImage *)_actionImage {
    NSString *ident = [self respondsToSelector:@selector(containingAppBundleIdentifier)] ? [self containingAppBundleIdentifier] : [self activityType];
    UIImage *img = getCustomIconForID(ident);
    return img ?: %orig;
}

- (UIImage *)_activitySettingsImage {
    NSString *ident = [self respondsToSelector:@selector(containingAppBundleIdentifier)] ? [self containingAppBundleIdentifier] : [self activityType];
    UIImage *img = getCustomIconForID(ident);
    return img ?: %orig;
}

- (NSString *)_systemImageName {
    NSString *ident = [self respondsToSelector:@selector(containingAppBundleIdentifier)] ? [self containingAppBundleIdentifier] : [self activityType];
    if (getCustomIconForID(ident)) return nil;
    return %orig;
}

%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
