// CallCaptionRootListController.m — v0.12.8 标准 PreferenceLoader 面板
// 使用 theos/headers 的真实 Preferences 头文件 + 标准 Root.plist，走系统原生渲染路径。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AVFoundation/AVFoundation.h>

#define CC_DOMAIN @"net.user.callcaption"
#define CC_NOTIF  @"net.user.callcaption.prefschanged"

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSBundle *b = self.bundle;
        if (!b) {
            b = [NSBundle bundleWithPath:@"/var/jb/Library/PreferenceBundles/CallCaptionPrefs.bundle"];
            if (b) self.bundle = b;
        }
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:b];
        NSLog(@"[CallCaption] specifiers=%lu bundle=%@", (unsigned long)_specifiers.count, b.bundlePath);
    }
    return _specifiers;
}

// ---------- 设置读写 ----------

static NSString *CCObjString(NSString *key, NSString *def) {
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
               (__bridge CFStringRef)key, (__bridge CFStringRef)CC_DOMAIN);
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return def;
}

- (void)saveValue:(id)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CC_NOTIF, NULL, NULL, YES);
}

- (void)presentSheet:(UIAlertController *)sheet {
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// ---------- 引擎 ----------

- (void)chooseEngine {
    NSArray *vals = @[@"auto", @"deepl", @"bing", @"google", @"ai"];
    NSArray *titles = @[@"自动（推荐）", @"DeepL", @"Bing（免费·国内推荐）",
                        @"Google（免费 / Key）", @"AI 自定义"];
    NSString *cur = CCObjString(@"Engine", @"auto");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"翻译引擎"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < vals.count; i++) {
        NSString *mark = [vals[i] isEqualToString:cur] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[mark stringByAppendingString:titles[i]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self saveValue:vals[i] forKey:@"Engine"];
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

// ---------- 音色 ----------

- (void)chooseVoiceForPrefix:(NSString *)prefix key:(NSString *)key title:(NSString *)title {
    NSMutableArray *vals = [NSMutableArray arrayWithObject:@""];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"系统默认"];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if ([[v.language lowercaseString] hasPrefix:prefix]) {
            [vals addObject:v.identifier];
            NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @" · 增强" : @"";
            [titles addObject:[NSString stringWithFormat:@"%@（%@%@）", v.name, v.language, q]];
        }
    }
    NSString *cur = CCObjString(key, @"");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < vals.count; i++) {
        NSString *mark = [vals[i] isEqualToString:cur] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[mark stringByAppendingString:titles[i]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self saveValue:vals[i] forKey:key];
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)chooseZhVoice { [self chooseVoiceForPrefix:@"zh" key:@"TTSVoice" title:@"中文播报音色"]; }
- (void)chooseEnVoice { [self chooseVoiceForPrefix:@"en" key:@"LocalVoice" title:@"英文播报音色"]; }

// ---------- 日志 ----------

- (void)openLog {
    NSString *path = @"/var/mobile/Library/CallCaption/probe.log";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"诊断日志"
                                                                  message:path
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"用 Filza 打开" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:@"filza://view/var/mobile/Library/CallCaption/probe.log"];
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = path;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

@end
