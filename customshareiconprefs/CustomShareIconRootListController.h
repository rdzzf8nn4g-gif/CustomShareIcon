#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface CustomShareIconRootListController : PSListController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) NSMutableDictionary *iconsDict;
@property (nonatomic, copy) NSString *pendingBundleID;

- (void)loadIconsFromPrefs;
- (void)saveIconsToPrefs;
- (void)notifyReload;
- (void)addNewIcon;
- (void)pickImageForKey:(NSString *)key;

@end
