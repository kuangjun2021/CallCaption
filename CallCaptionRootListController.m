// CallCaptionRootListController.m — 真 bundle 设置面板控制器（Choicy/Crane 同款结构）
#import <UIKit/UIKit.h>

// Preferences.framework（私有）中的列表控制器基类
@interface PSListController : UIViewController
@property (nonatomic, copy) NSArray *specifiers;
@end

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController
// 空实现即可：PSListController 会自动加载 bundle 内与本类同名的
// CallCaptionRootListController.plist 并把条目字典转换为 PSSpecifier
@end
