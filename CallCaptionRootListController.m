// CallCaptionRootListController.m — Settings.app 的宿主控制器
//
// 血泪教训（v0.12.4 / 2026-11-08）：
//   Settings 推入 PSListController 子类时，框架会自动加载同名 plist / 初始化内部表，
//   在这台机器上会直接闪退。唯一验证可行的做法是：
//     1) specifiers 返回空数组，阻止自动加载；
//     2) viewDidLoad 不调用 [super viewDidLoad]；
//     3) 整个设置界面用我们自己的 UITableView（CCSettingsController）画。
//   长按小地球打开的就是同一套 CCSettingsController，两边共用一份 UI 代码。
#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

// CCSettings.m 里实现；这里只需要 embedded 属性
@interface CCSettingsController : UIViewController
@property (nonatomic, assign) BOOL embedded;
@end

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController

- (NSArray *)specifiers {
    return @[];
}

- (void)viewDidLoad {
    // 不调用 [super viewDidLoad]：绕开 PSListController 的 plist/表格初始化（本环境闪退源）
    if (!self.view) self.view = [[UITableView alloc] initWithFrame:[UIScreen mainScreen].bounds style:UITableViewStyleGrouped];
#ifdef CC_PRO
    self.title = @"CallCaption Pro";
#else
    self.title = @"CallCaption";
#endif
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    CCSettingsController *vc = [[CCSettingsController alloc] init];
    vc.embedded = YES;
    [self addChildViewController:vc];
    vc.view.frame = self.view.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:vc.view];
    [vc didMoveToParentViewController:self];
}

@end
