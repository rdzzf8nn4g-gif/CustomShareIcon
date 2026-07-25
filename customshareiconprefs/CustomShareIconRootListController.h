#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface CustomShareIconRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableDictionary *iconsDict;
@property (nonatomic, copy) NSString *pendingBundleID;

// 修改为读取文件的声明
- (void)loadIconsFromFiles;
- (void)notifyReload;
- (void)addNewIcon;
- (void)pickImageForKey:(NSString *)key;

@end
