#import "CustomShareIconRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#define PREFS_ID @"com.iosdump.customshareicon"
#define ICONS_KEY @"IOSDump_CSI_Icons"
#define ENABLED_KEY @"Enabled"
#define SHARED_CACHE_PATH @"/var/mobile/Library/Preferences/com.iosdump.customshareicon.shared.plist"

@implementation CustomShareIconRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self loadIconsFromPrefs];
        [self rebuildIconSpecifiers];
    }
    return _specifiers;
}

#pragma mark - 偏好读写

- (void)loadIconsFromPrefs {
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.customshareicon"));
    id obj = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), CFSTR("com.iosdump.customshareicon")));
    if ([obj isKindOfClass:[NSDictionary class]]) {
        self.iconsDict = [obj mutableCopy];
    } else {
        // 兼容 NSUserDefaults
        NSDictionary *d = [[NSUserDefaults standardUserDefaults] persistentDomainForName:PREFS_ID];
        id icons = d[ICONS_KEY];
        if ([icons isKindOfClass:[NSDictionary class]]) {
            self.iconsDict = [icons mutableCopy];
        } else {
            self.iconsDict = [NSMutableDictionary new];
        }
    }
}

- (void)saveIconsToPrefs {
    if (!self.iconsDict) self.iconsDict = [NSMutableDictionary new];

    CFPreferencesSetAppValue(CFSTR("IOSDump_CSI_Icons"), (__bridge CFPropertyListRef)self.iconsDict, CFSTR("com.iosdump.customshareicon"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.customshareicon"));

    // 同步写 NSUserDefaults 域
    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:PREFS_ID];
    if (!ud) ud = [NSUserDefaults standardUserDefaults];
    [ud setObject:self.iconsDict forKey:ICONS_KEY];
    [ud synchronize];

    // 写共享缓存（让 SpringBoard / 分享进程立刻能读到）
    Boolean keyExists = false;
    Boolean en = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("com.iosdump.customshareicon"), &keyExists);
    if (!keyExists) en = YES; // 默认开

    NSDictionary *cache = @{
        @"Enabled" : @(en),
        @"IOSDump_CSI_Icons" : self.iconsDict ?: @{},
        @"ts" : @([[NSDate date] timeIntervalSince1970])
    };
    [cache writeToFile:SHARED_CACHE_PATH atomically:YES];

    [self notifyReload];
}

- (void)notifyReload {
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
        NULL,
        NULL,
        true
    );
}

#pragma mark - 开关

- (id)readEnabled:(PSSpecifier *)specifier {
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.customshareicon"));
    Boolean keyExists = false;
    Boolean en = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), CFSTR("com.iosdump.customshareicon"), &keyExists);
    if (!keyExists) return @YES;
    return @(en);
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    BOOL on = [value boolValue];
    CFPreferencesSetAppValue(CFSTR("Enabled"), on ? kCFBooleanTrue : kCFBooleanFalse, CFSTR("com.iosdump.customshareicon"));
    CFPreferencesAppSynchronize(CFSTR("com.iosdump.customshareicon"));

    NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:PREFS_ID];
    if (!ud) ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:on forKey:ENABLED_KEY];
    [ud synchronize];

    // 立刻更新共享缓存
    NSDictionary *cache = @{
        @"Enabled" : @(on),
        @"IOSDump_CSI_Icons" : self.iconsDict ?: @{},
        @"ts" : @([[NSDate date] timeIntervalSince1970])
    };
    [cache writeToFile:SHARED_CACHE_PATH atomically:YES];

    [self notifyReload];
}

#pragma mark - 动态列表

- (void)rebuildIconSpecifiers {
    // 删掉旧的图标相关 specifier（保留开关和按钮）
    NSMutableArray *keep = [NSMutableArray new];
    for (PSSpecifier *sp in _specifiers) {
        NSString *name = [sp propertyForKey:PSIDKey];
        if ([name isEqualToString:@"Enabled"] ||
            [name isEqualToString:@"AddButton"] ||
            [name isEqualToString:@"GroupMain"] ||
            [name isEqualToString:@"GroupList"] ||
            [name isEqualToString:@"FooterHelp"]) {
            [keep addObject:sp];
        }
    }
    _specifiers = keep;

    // 插入已有图标条目
    NSInteger insertAt = _specifiers.count;
    for (PSSpecifier *sp in _specifiers) {
        if ([[sp propertyForKey:PSIDKey] isEqualToString:@"GroupList"]) {
            insertAt = [_specifiers indexOfObject:sp] + 1;
            break;
        }
    }

    NSArray *keys = [[self.iconsDict allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    for (NSString *key in keys) {
        PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:key
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:Nil
                                                            cell:PSButtonCell
                                                            edit:Nil];
        [sp setProperty:key forKey:PSIDKey];
        [sp setProperty:key forKey:@"iconKey"];
        sp.buttonAction = @selector(iconTapped:);
        // 长按或点击删除在 iconTapped 里处理
        [_specifiers insertObject:sp atIndex:insertAt++];
    }
}

- (void)iconTapped:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"iconKey"];
    if (!key.length) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
                                                                   message:@"选择操作"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"更换图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self pickImageForKey:key];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.iconsDict removeObjectForKey:key];
        [self saveIconsToPrefs];
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, 100, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addNewIcon {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加自定义图标"
                                                                   message:@"输入 Bundle ID\n(如 com.tencent.xin)"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"com.example.app";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.keyboardType = UIKeyboardTypeASCIICapable;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"下一步：选图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *bid = alert.textFields.firstObject.text;
        bid = [bid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (bid.length < 3) return;
        self.pendingBundleID = bid;
        [self pickImageForKey:bid];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pickImageForKey:(NSString *)key {
    self.pendingBundleID = key;
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    picker.allowsEditing = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIImagePickerController

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    UIImage *img = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
    if (!img || !self.pendingBundleID.length) return;

    // 缩放到合适尺寸再转 base64
    CGFloat maxSide = 180.0;
    CGFloat scale = MIN(1.0, maxSide / MAX(img.size.width, img.size.height));
    CGSize newSize = CGSizeMake(img.size.width * scale, img.size.height * scale);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 3.0);
    [img drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *png = UIImagePNGRepresentation(resized);
    if (!png) png = UIImageJPEGRepresentation(resized, 0.92);
    if (!png) return;

    NSString *b64 = [png base64EncodedStringWithOptions:0];
    if (!b64.length) return;

    if (!self.iconsDict) self.iconsDict = [NSMutableDictionary new];
    self.iconsDict[self.pendingBundleID] = b64;
    self.pendingBundleID = nil;

    [self saveIconsToPrefs];
    [self reloadSpecifiers];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    self.pendingBundleID = nil;
}

- (void)reloadSpecifiers {
    _specifiers = nil;
    [super reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self loadIconsFromPrefs];
}

@end
