#import "CustomShareIconRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

#define PREFS_DOMAIN CFSTR("com.iosdump.customshareicon")

@implementation CustomShareIconRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        [self loadIconsFromPrefs];
        [self rebuildIconSpecifiers];
    }
    return _specifiers;
}

- (void)loadIconsFromPrefs {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("IOSDump_CSI_Icons"), PREFS_DOMAIN);
    if (ref && CFGetTypeID(ref) == CFDictionaryGetTypeID()) {
        self.iconsDict = [(__bridge NSDictionary *)ref mutableCopy];
    } else {
        self.iconsDict = [NSMutableDictionary new];
    }
    if (ref) CFRelease(ref);
}

- (void)saveIconsToPrefs {
    if (!self.iconsDict) self.iconsDict = [NSMutableDictionary new];
    CFPreferencesSetAppValue(CFSTR("IOSDump_CSI_Icons"), (__bridge CFPropertyListRef)self.iconsDict, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    [self notifyReload];
}

- (void)notifyReload {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.iosdump.customshareicon/ReloadPrefs"),
                                         NULL, NULL, true);
}

#pragma mark - 开关

- (id)readEnabled:(PSSpecifier *)specifier {
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    Boolean keyExists = false;
    Boolean en = CFPreferencesGetAppBooleanValue(CFSTR("Enabled"), PREFS_DOMAIN, &keyExists);
    if (!keyExists) return @YES;
    return @(en);
}

- (void)setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    BOOL on = [value boolValue];
    CFPreferencesSetAppValue(CFSTR("Enabled"), on ? kCFBooleanTrue : kCFBooleanFalse, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    [self notifyReload];
}

#pragma mark - 动态列表

- (void)rebuildIconSpecifiers {
    NSMutableArray *keep = [NSMutableArray new];
    for (PSSpecifier *sp in _specifiers) {
        NSString *name = [sp propertyForKey:PSIDKey];
        if ([name isEqualToString:@"Enabled"] ||
            [name isEqualToString:@"AddButton"] ||
            [name isEqualToString:@"GroupMain"] ||
            [name isEqualToString:@"GroupList"]) {
            [keep addObject:sp];
        }
    }
    _specifiers = keep;

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
        [_specifiers insertObject:sp atIndex:insertAt++];
    }
}

- (void)iconTapped:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"iconKey"];
    if (!key.length) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:key message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"更换图片" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [self pickImageForKey:key];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self.iconsDict removeObjectForKey:key];
        [self saveIconsToPrefs];
        [self reloadSpecifiers];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, 100.0, 1.0, 1.0);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addNewIcon {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加自定义图标"
                                                                   message:@"输入 App 的 Bundle ID\n(如 com.tencent.xin)"
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

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    UIImage *img = info[UIImagePickerControllerEditedImage] ?: info[UIImagePickerControllerOriginalImage];
    if (!img || !self.pendingBundleID.length) return;

    CGFloat maxSide = 180.0;
    CGFloat scale = MIN(1.0, maxSide / MAX(img.size.width, img.size.height));
    CGSize newSize = CGSizeMake(img.size.width * scale, img.size.height * scale);
    UIGraphicsBeginImageContextWithOptions(newSize, NO, 3.0);
    [img drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
    UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();

    NSData *png = UIImagePNGRepresentation(resized);
    if (!png) png = UIImageJPEGRepresentation(resized, 0.92);

    if (png) {
        NSString *b64 = [png base64EncodedStringWithOptions:0];
        if (b64.length) {
            self.iconsDict[self.pendingBundleID] = b64;
            [self saveIconsToPrefs];
        }
    }
    
    self.pendingBundleID = nil;
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
