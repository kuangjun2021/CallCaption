// CallCaptionRootListController.m — v0.12 设置面板
// 方案：PSListController 子类（宿主类型正确，不闪退）+ 代码动态创建 PSSpecifier（不依赖 plist 加载）
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#define CC_DOMAIN @"net.user.callcaption"
#define CC_NOTIF  @"net.user.callcaption.prefschanged"

// PSCellType 数值（Preferences.framework 私有枚举）
enum {
    CCPSGroupCell          = 0,
    CCPSLinkListCell       = 2,
    CCPSPSTitleValueCell   = 4,
    CCPSPSSwitchCell       = 6,
    CCPSPSEditTextCell     = 8,
    CCPSPSSecureEditCell   = 12,
    CCPSPSButtonCell       = 13,
    CCPSPSListItemsCell    = 14,
};

@interface PSListController : UIViewController
@property (nonatomic, copy) NSArray *specifiers;
- (void)setSpecifiers:(NSArray *)specifiers;
@end

@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@property (nonatomic, strong) NSArray *mySpecs;
@end

@implementation CallCaptionRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CallCaption";
    if (!self.mySpecs) self.mySpecs = [self buildSpecifiers];
    [self setSpecifiers:self.mySpecs];
}

- (NSArray *)specifiers {
    if (!self.mySpecs) self.mySpecs = [self buildSpecifiers];
    return self.mySpecs;
}

// ---------- 构建 ----------

- (PSSpecifier *)group:(NSString *)title footer:(NSString *)footer {
    PSSpecifier *g = [PSSpecifier preferenceSpecifierNamed:title
                                                    target:nil set:nil get:nil detail:nil
                                                      cell:CCPSGroupCell edit:nil];
    if (footer) [g setProperty:footer forKey:@"footerText"];
    return g;
}

- (PSSpecifier *)toggle:(NSString *)title key:(NSString *)key def:(BOOL)def {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self
                                                        set:@selector(setPrefValue:specifier:)
                                                        get:@selector(getPrefValue:)
                                                     detail:nil
                                                       cell:CCPSPSSwitchCell
                                                       edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:@(def) forKey:@"default"];
    return sp;
}

- (PSSpecifier *)text:(NSString *)title key:(NSString *)key def:(NSString *)def secure:(BOOL)secure {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self
                                                        set:@selector(setPrefValue:specifier:)
                                                        get:@selector(getPrefValue:)
                                                     detail:nil
                                                       cell:(secure ? CCPSPSSecureEditCell : CCPSPSEditTextCell)
                                                       edit:nil];
    [sp setProperty:key forKey:@"key"];
    if (def) [sp setProperty:def forKey:@"default"];
    if (secure) [sp setProperty:@YES forKey:@"isSecure"];
    return sp;
}

- (PSSpecifier *)choice:(NSString *)title key:(NSString *)key def:(NSString *)def
                 values:(NSArray *)vals titles:(NSArray *)titles {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self
                                                        set:@selector(setPrefValue:specifier:)
                                                        get:@selector(getPrefValue:)
                                                     detail:nil
                                                       cell:CCPSLinkListCell
                                                       edit:nil];
    [sp setProperty:key forKey:@"key"];
    [sp setProperty:def forKey:@"default"];
    [sp setProperty:vals forKey:@"validValues"];
    [sp setProperty:titles forKey:@"validTitles"];
    [sp setProperty:vals forKey:@"values"];
    [sp setProperty:titles forKey:@"titles"];
    return sp;
}

// 音色列表：值 = voice identifier，标题 = 系统给出的名字
- (PSSpecifier *)voiceChoice:(NSString *)title key:(NSString *)key prefix:(NSString *)prefix {
    NSMutableArray *vals = [NSMutableArray arrayWithObject:@""];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"系统默认"];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if ([[v.language lowercaseString] hasPrefix:prefix]) {
            [vals addObject:v.identifier];
            NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @" · 增强" : @"";
            [titles addObject:[NSString stringWithFormat:@"%@（%@%@）", v.name, v.language, q]];
        }
    }
    return [self choice:title key:key def:@"" values:vals titles:titles];
}

- (PSSpecifier *)button:(NSString *)title action:(NSString *)action {
    PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:title
                                                     target:self set:nil get:nil detail:nil
                                                       cell:CCPSPSButtonCell edit:nil];
    [sp setProperty:action forKey:@"action"];
    return sp;
}

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
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (NSArray *)buildSpecifiers {
    NSMutableArray *a = [NSMutableArray array];

    [a addObject:[self group:@"功能开关"
                      footer:@"通话接通后屏幕出现 CallCaption 控制面板：🌐 总开关、我方、对方、原文、译文。"]];
    [a addObject:[self toggle:@"启用 CallCaption" key:@"Enabled" def:YES]];
    [a addObject:[self toggle:@"对方语音 → 中文字幕" key:@"RemoteEnabled" def:YES]];
    [a addObject:[self toggle:@"双向模式：我的话 → 英文播报" key:@"LocalEnabled" def:NO]];
    [a addObject:[self toggle:@"显示识别原文" key:@"ShowRecognized" def:YES]];
    [a addObject:[self toggle:@"显示译文" key:@"ShowTranslated" def:YES]];
    [a addObject:[self toggle:@"中文字幕语音播报" key:@"TTSEnabled" def:YES]];
    [a addObject:[self toggle:@"大字幕" key:@"LargeCaptions" def:NO]];
    [a addObject:[self toggle:@"面板常驻显示（非通话也显示）" key:@"AlwaysShowPanel" def:NO]];

    [a addObject:[self group:@"语言"
                      footer:@"识别语言代码（BCP-47）：对方英文填 en-US，日文 ja-JP，韩文 ko-KR；我的语言通常 zh-CN。"]];
    [a addObject:[self text:@"对方语言" key:@"RemoteLocale" def:@"en-US" secure:NO]];
    [a addObject:[self text:@"我的语言" key:@"LocalLocale" def:@"zh-CN" secure:NO]];

    [a addObject:[self group:@"翻译引擎"
                      footer:@"自动 = 已填 Key 优先，失败自动切换；Google 不填 Key 用免费接口，填了用 Cloud Translation。"]];
    [a addObject:[self choice:@"引擎" key:@"Engine" def:@"auto"
                        values:@[@"auto", @"deepl", @"bing", @"google", @"ai"]
                        titles:@[@"自动（推荐）", @"DeepL", @"Bing（免费·国内推荐）",
                                 @"Google（免费 / Key）", @"AI 自定义"]]];
    [a addObject:[self text:@"DeepL API Key" key:@"DeepLKey" def:nil secure:YES]];
    [a addObject:[self text:@"Google API Key" key:@"GoogleKey" def:nil secure:YES]];

    [a addObject:[self group:@"AI 自定义接口（OpenAI 兼容）"
                      footer:@"填写 chat/completions 完整地址、Key 与模型名，例如 DeepSeek。"]];
    [a addObject:[self text:@"AI 接口地址" key:@"AIURL"
                        def:@"https://api.deepseek.com/v1/chat/completions" secure:NO]];
    [a addObject:[self text:@"AI API Key" key:@"AIKey" def:nil secure:YES]];
    [a addObject:[self text:@"AI 模型名" key:@"AIModel" def:@"deepseek-chat" secure:NO]];

    [a addObject:[self group:@"播报音色"
                      footer:@"中文播报用于对方字幕，英文播报用于我方翻译（双向模式）。列表由系统已安装语音生成。"]];
    [a addObject:[self voiceChoice:@"中文播报音色" key:@"TTSVoice" prefix:@"zh"]];
    [a addObject:[self voiceChoice:@"英文播报音色" key:@"LocalVoice" prefix:@"en"]];

    [a addObject:[self group:@"识别与诊断"
                      footer:@"日志：/var/mobile/Library/CallCaption/probe.log"]];
    [a addObject:[self toggle:@"云端语音识别（更准，需联网）" key:@"CloudASR" def:YES]];
    [a addObject:[self toggle:@"诊断日志" key:@"Diagnostics" def:YES]];
    [a addObject:[self button:@"打开诊断日志" action:@"openLog"]];

    return a;
}

// ---------- 读写 ----------

- (id)getPrefValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return nil;
    id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
               (__bridge CFStringRef)key, (__bridge CFStringRef)CC_DOMAIN);
    if (v) return v;
    return [spec propertyForKey:@"default"];
}

- (void)setPrefValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CC_NOTIF, NULL, NULL, YES);
}

@end
