#import "CustomShareIconRootListController.h"
#import <Preferences/PSSpecifier.h>

#define PREFS_ID @"com.iosdump.customshareicon"

@implementation CustomShareIconRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
}

- (NSUserDefaults *)prefs {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:PREFS_ID];
    });
    return prefs;
}

- (NSDictionary *)getIconsDict {
    id val = [[self prefs] objectForKey:@"IOSDump_CSI_Icons"];
    return [val isKindOfClass:[NSDictionary class]] ? val : @{};
}

- (void)saveIconsDict:(NSDictionary *)icons {
    [[self prefs] setObject:icons forKey:@"IOSDump_CSI_Icons"];
    [[self prefs] synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                         NULL, NULL, YES);
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        NSDictionary *icons = [self getIconsDict];

        if (icons.count > 0) {
            PSSpecifier *group = [PSSpecifier preferenceSpecifierNamed:@"已配置的图标 (点击删除)"
                                                               target:self
                                                                  set:nil
                                                                  get:nil
                                                               detail:Nil
                                                                 cell:PSGroupCell
                                                                 edit:Nil];
            [specs addObject:group];

            for (NSString *bundleID in icons.allKeys) {
                PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:bundleID
                                                                   target:self
                                                                      set:nil
                                                                      get:nil
                                                                   detail:Nil
                                                                     cell:PSButtonCell
                                                                     edit:Nil];
                spec.identifier = bundleID;
                [spec setProperty:bundleID forKey:@"bundleID"];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加自定义图标"
                                                                   message:@"请输入目标App的Bundle ID\n(例如微信：com.tencent.xin)"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"例如：com.tencent.xin";
    }];

    UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"下一步(选图)" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *input = alert.textFields.firstObject.text;
        if (input.length > 0) {
            self.pendingBundleID = input;
            [self presentMediaPicker];
        }
    }];

    [alert addAction:confirm];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    [topVC presentViewController:alert animated:YES completion:nil];
}
- (void)addNewIcon:(PSSpecifier *)spec { [self addNewIcon]; }

- (void)deleteIcon:(PSSpecifier *)spec {
    NSString *bundleID = [spec propertyForKey:@"bundleID"];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除图标"
                                                                   message:[NSString stringWithFormat:@"确定要删除 %@ 吗？", bundleID]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        NSMutableDictionary *icons = [[self getIconsDict] mutableCopy];
        [icons removeObjectForKey:bundleID];
        [self saveIconsDict:icons];
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    UIViewController *topVC = self.view.window.rootViewController ?: self;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
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

            UIViewController *topVC = self.view.window.rootViewController ?: self;
            while (topVC.presentedViewController) topVC = topVC.presentedViewController;
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

                    CGSize size = img.size;
                    CGFloat ratio = MIN(120.0 / size.width, 120.0 / size.height);
                    if (ratio < 1.0) {
                        CGSize newSize = CGSizeMake(size.width * ratio, size.height * ratio);
                        UIGraphicsBeginImageContextWithOptions(newSize, NO, UIScreen.mainScreen.scale);
                        [img drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
                        img = UIGraphicsGetImageFromCurrentImageContext();
                        UIGraphicsEndImageContext();
                    }

                    NSData *data = UIImagePNGRepresentation(img);
                    NSString *base64String = [data base64EncodedStringWithOptions:0];

                    NSMutableDictionary *icons = [[self getIconsDict] mutableCopy];
                    icons[self.pendingBundleID] = base64String;
                    [self saveIconsDict:icons];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self reloadSpecifiers];
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
    NSString *bundleID = [spec propertyForKey:@"bundleID"];

    if (bundleID) {
        NSDictionary *icons = [self getIconsDict];
        NSString *base64 = icons[bundleID];
        if (base64) {
            NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
            UIImage *savedImage = [UIImage imageWithData:data scale:UIScreen.mainScreen.scale];

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

// 关键：用 key 判断，而不是 identifier
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"Enabled"]) {
        [[self prefs] setObject:value forKey:@"Enabled"];
        [[self prefs] synchronize];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                             NULL, NULL, YES);
    }
}

@end
