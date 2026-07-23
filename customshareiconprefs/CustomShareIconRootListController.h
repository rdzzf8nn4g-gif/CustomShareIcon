#import <Preferences/PSListController.h>
#import <PhotosUI/PhotosUI.h>

@interface CustomShareIconRootListController : PSListController <PHPickerViewControllerDelegate>
@property (nonatomic, strong) NSString *pendingBundleID;
@end
