#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 暴露所需的方法避免编译警告
@interface UIActivity (CustomShareIcon)
- (NSString *)activityType;
- (NSString *)containingAppBundleIdentifier; // UIApplicationExtensionActivity 的方法
@end

static NSString * GetMediaDir() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.media";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static NSString * GetPrefPath() {
    NSString *base = @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.plist";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

static BOOL isEnabled = NO;

static void loadPrefs() {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:GetPrefPath()];
    isEnabled = dict[@"Enabled"] ? [dict[@"Enabled"] boolValue] : NO;
}

// 获取自定义图片的通用方法
static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    
    NSString *path = [[GetMediaDir() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // 读取图片并返回
        return [UIImage imageWithContentsOfFile:path];
    }
    return nil;
}

// 提取当前 Activity 的标识符
static NSString *getIdentifierForActivity(UIActivity *activity) {
    NSString *identifier = nil;
    // 优先尝试获取 App 的 Bundle ID (适用于第三方 App 分享扩展)
    if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        identifier = [activity containingAppBundleIdentifier];
    }
    // 回退到 activityType (适用于系统自带功能，如 com.apple.UIKit.activity.CopyToPasteboard)
    if (!identifier || identifier.length == 0) {
        if ([activity respondsToSelector:@selector(activityType)]) {
            identifier = [activity activityType];
        }
    }
    return identifier;
}

%hook UIActivity

- (UIImage *)activityImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

- (UIImage *)_activityImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

- (UIImage *)_actionImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

- (UIImage *)_activitySettingsImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

%end

// 为了防止继承类没走父类，顺便 Hook UIApplicationExtensionActivity
%hook UIApplicationExtensionActivity

- (UIImage *)activityImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

- (UIImage *)_activityImage {
    if (!isEnabled) return %orig;
    NSString *identifier = getIdentifierForActivity(self);
    UIImage *custom = getCustomIconForID(identifier);
    return custom ?: %orig;
}

%end

%ctor {
    loadPrefs();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback)loadPrefs, CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}
