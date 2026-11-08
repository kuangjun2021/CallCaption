// CallCaptionRootListController.m — v0.12.8 标准 PreferenceLoader 面板
// 使用 theos/headers 的真实 Preferences 头文件 + 标准 Root.plist，走系统原生渲染路径。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <AVFoundation/AVFoundation.h>

#define CC_DOMAIN @"net.user.callcaption"
#define CC_NOTIF  @"net.user.callcaption.prefschanged"

static void SLog(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *path = @"/var/mobile/Library/CallCaption/settings.log";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController

+ (void)load { SLog(@"bundle loaded"); }

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSBundle *b = self.bundle;
        if (!b) {
            b = [NSBundle bundleWithPath:@"/var/jb/Library/PreferenceBundles/CallCaptionPrefs.bundle"];
            if (b) self.bundle = b;
        }
        NSString *path = [b pathForResource:@"Root" ofType:@"plist"];
        NSArray *dicts = [NSArray arrayWithContentsOfFile:path];
        SLog(@"manual load path=%@ dicts=%lu", path, (unsigned long)dicts.count);

        if (dicts.count) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *d in dicts) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                NSString *cellStr = d[@"cell"] ?: @"PSGroupCell";
                PSCellType type = [PSTableCell cellTypeFromString:cellStr];
                NSString *label = d[@"label"] ?: @"";

                // 关键：开关/输入框必须挂上默认的 get/set 选择器，否则系统会把行渲染成不可用（灰掉）
                BOOL needKV = (type == PSSwitchCell || type == PSEditTextCell ||
                               type == PSTitleValueCell || type == PSListItemsCell ||
                               type == PSSecureEditTextCell);
                SEL setSel = needKV ? @selector(setPreferenceValue:specifier:) : NULL;
                SEL getSel = needKV ? @selector(readPreferenceValue:) : NULL;

                PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
                                                                target:self
                                                                   set:setSel
                                                                   get:getSel
                                                                detail:nil
                                                                  cell:type
                                                                  edit:nil];
                for (NSString *k in d) {
                    if ([k isEqualToString:@"cell"] || [k isEqualToString:@"label"]) continue;
                    [sp setProperty:d[k] forKey:k];
                }
                NSString *act = d[@"action"];
                if ([act isKindOfClass:[NSString class]] && act.length) {
                    sp.buttonAction = NSSelectorFromString(act);
                    [sp setProperty:act forKey:@"action"];
                }
                [arr addObject:sp];
            }
            _specifiers = arr;
            SLog(@"manual specs=%lu", (unsigned long)arr.count);
        }

        if (!_specifiers.count) {
            _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:b];
            SLog(@"native fallback count=%lu", (unsigned long)_specifiers.count);
        }
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
