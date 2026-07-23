#import <UIKit/UIKit.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// 声明可能用到的私有或公开方法
@interface UIActivity (CustomShareIcon)
- (NSString *)activityType;
- (NSString *)containingAppBundleIdentifier;
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

static UIImage *getCustomIconForID(NSString *identifier) {
    if (!identifier || identifier.length == 0) return nil;
    
    NSString *path = [[GetMediaDir() stringByAppendingPathComponent:identifier] stringByAppendingPathExtension:@"png"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [UIImage imageWithContentsOfFile:path];
    }
    return nil;
}

// 参数改为 id 类型，兼容 UIActivity 及其所有子类（如 UIApplicationExtensionActivity）
static NSString *getIdentifierForActivity(id activity) {
    NSString *identifier = nil;
    if ([activity respondsToSelector:@selector(containingAppBundleIdentifier)]) {
        identifier = [activity containingAppBundleIdentifier];
    }
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
