// CallCaptionRootListController.m — 设置面板控制器
// v0.11: PSListController 不会自动加载同名 plist，必须显式 loadSpecifiersFromPlistName:
#import <UIKit/UIKit.h>

// Preferences.framework（私有）基类
@interface PSListController : UIViewController
@property (nonatomic, copy) NSArray *specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController

- (NSArray *)specifiers {
    NSArray *cur = [super specifiers];
    if (cur.count) return cur;
    NSArray *loaded = [self loadSpecifiersFromPlistName:@"CallCaptionRootListController" target:self];
    if (loaded) [self setSpecifiers:loaded];
    return loaded ?: @[];
}

@end
