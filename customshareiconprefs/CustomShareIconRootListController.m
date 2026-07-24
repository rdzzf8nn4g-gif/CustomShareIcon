#import "CustomShareIconRootListController.h"
#import <Preferences/PSSpecifier.h>

#if __has_include(<roothide.h>)
#import <roothide.h>
#else
#define jbroot(path) path
#endif

// =======================
// 核心修复：转移到所有进程都能读取的公共目录！
// =======================
static NSString * GetCSIDir() {
    NSString *base = @"/Library/Application Support/CustomShareIcon";
#if __has_include(<roothide.h>)
    return jbroot(base);
#else
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/"]) {
        return [@"/var/jb" stringByAppendingPathComponent:base];
    }
    return base;
#endif
}

@implementation CustomShareIconRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = GetCSIDir();
    
    // 初始化沙盒公共目录
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} error:nil];
    } else {
        [fm setAttributes:@{NSFileProtectionKey: NSFileProtectionNone, NSFilePosixPermissions: @0777} ofItemAtPath:dir error:nil];
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        
        NSString *mediaDir = GetCSIDir();
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:mediaDir error:nil];
        BOOL hasIcons = NO;
        
        for (NSString *file in files) {
            if ([file hasSuffix:@".png"]) {
                if (!hasIcons) {
                    PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"已配置的图标 (点击删除)" target:self set:nil get:nil detail:Nil cell:PSGroupCell edit:Nil];
                    [specs addObject:group];
                    hasIcons = YES;
                }
                
                NSString *bundleID = [file stringByDeletingPathExtension];
                PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:bundleID target:self set:nil get:nil detail:Nil cell:PSButtonCell edit:Nil];
                spec.identifier = file; 
                [spec setProperty:file forKey:@"filename"];
                [spec setProperty:NSStringFromSelector(@selector(deleteIcon:)) forKey:@"action"];
                [specs addObject:spec];
            }
        }
        
        _specifiers = specs;
    }
    return _specifiers;
}

- (void)openTelegramChannel {
    NSURL *url = [NSURL URLWithString:@"https://t.me/iosdumpzzz"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}
- (void)openTelegramChannel:(PSSpecifier *)spec { [self openTelegramChannel]; }

- (void)addNewIcon {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加自定义图标" message:@"请输入目标App的Bundle ID\n(例如微信：com.tencent.xin)" preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"例如：com.tencent.xin";
    }];
    
    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"下一步(选图)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *input = alert.textFields.firstObject.text;
        if (input && input.length > 0) {
            self.pendingBundleID = input;
            [self presentMediaPicker];
        }
    }];
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    
    [alert addAction:confirm];
    [alert addAction:cancel];
    
    UIViewController *topVC = self.view.window.rootViewController;
    if (!topVC) topVC = self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)addNewIcon:(PSSpecifier *)spec { [self addNewIcon]; }

- (void)deleteIcon:(PSSpecifier *)spec {
    NSString *filename = [spec propertyForKey:@"filename"];
    NSString *path = [GetCSIDir() stringByAppendingPathComponent:filename];
    NSString *bundleName = [filename stringByDeletingPathExtension];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除图标" message:[NSString stringWithFormat:@"确定要删除 %@ 吗？", bundleName] preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        [self reloadSpecifiers];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, NULL, YES);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    UIViewController *topVC = self.view.window.rootViewController;
    if (!topVC) topVC = self;
    while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
    [topVC presentViewController:alert animated:YES completion:nil];
}

- (void)presentMediaPicker {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.0, *)) {
            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.selectionLimit = 1;
            config.filter = [PHPickerFilter imagesFilter];
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
            picker.delegate = self;

            UIViewController *topVC = self.view.window.rootViewController;
            if (!topVC) topVC = self;
            while (topVC.presentedViewController) { topVC = topVC.presentedViewController; }
            [topVC presentViewController:picker animated:YES completion:nil];
        }
    });
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    if (results.count == 0 || !self.pendingBundleID) {
        [picker dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    
    NSItemProvider *itemProvider = results.firstObject.itemProvider;
    [picker dismissViewControllerAnimated:YES completion:^{
        if ([itemProvider canLoadObjectOfClass:[UIImage class]]) {
            [itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id object, NSError *error) {
                if ([object isKindOfClass:[UIImage class]]) {
                    UIImage *img = (UIImage *)object;
                    NSData *data = UIImagePNGRepresentation(img);
                    NSString *path = [GetCSIDir() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.png", self.pendingBundleID]];
                    [data writeToFile:path atomically:YES];
                    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:path error:nil];
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadSpecifiers];
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, NULL, YES);
                    });
                }
                self.pendingBundleID = nil;
            }];
        }
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
    NSString *filename = [spec propertyForKey:@"filename"];
    
    if (filename) {
        NSString *path = [GetCSIDir() stringByAppendingPathComponent:filename];
        UIImage *savedImage = [UIImage imageWithContentsOfFile:path];
        if (savedImage) {
            UIImageView *previewView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 32, 32)];
            previewView.contentMode = UIViewContentModeScaleAspectFit;
            previewView.clipsToBounds = YES;
            previewView.layer.cornerRadius = 6;
            previewView.image = savedImage;
            cell.accessoryView = previewView;
        } else {
            cell.accessoryView = nil;
        }
    }
    return cell;
}

// 暴力穿透沙盒：把开关状态直接写进 Application Support 里的物理文件
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    if ([specifier.identifier isEqualToString:@"Enabled"]) {
        CFStringRef appID = CFSTR("com.iosdump.customshareicon");
        CFPreferencesSetAppValue((__bridge CFStringRef)specifier.properties[@"key"], (__bridge CFPropertyListRef)value, appID);
        CFPreferencesAppSynchronize(appID);
        
        // 生成标志文件
        NSString *flagPath = [GetCSIDir() stringByAppendingPathComponent:@"enabled.txt"];
        if ([value boolValue]) {
            [@"1" writeToFile:flagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [@"0" writeToFile:flagPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0777, NSFileProtectionKey: NSFileProtectionNone} ofItemAtPath:flagPath error:nil];
        
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.iosdump.customshareicon/ReloadPrefs"), NULL, NULL, YES);
    }
}
@end
