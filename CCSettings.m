// CallCaptionRootListController.m — v0.12.2 设置面板
// 宿主必须是 PSListController（否则 Settings 推入时闪退），但界面完全自绘：
// 在 PSListController 之上覆盖自己的 UITableView，不用 PSSpecifier / 子页面。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

#define CC_DOMAIN @"net.user.callcaption"
#define CC_NOTIF  @"net.user.callcaption.prefschanged"

typedef NS_ENUM(NSInteger, CCPrefsItemKind) {
    CCPrefsItemKindSwitch = 0,
    CCPrefsItemKindText,
    CCPrefsItemKindChoice,
    CCPrefsItemKindAction,
    CCPrefsItemKindSlider,
};

@interface CCPrefsItem : NSObject
@property (nonatomic) CCPrefsItemKind kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic) BOOL defBool;
@property (nonatomic, copy) NSString *defString;
@property (nonatomic) BOOL secure;
@property (nonatomic, copy) NSArray<NSString *> *choiceValues;
@property (nonatomic, copy) NSArray<NSString *> *choiceTitles;
@property (nonatomic) double minValue;
@property (nonatomic) double maxValue;
@end
@implementation CCPrefsItem @end

@interface CCPrefsSwitch : UISwitch
@property (nonatomic, copy) NSString *prefKey;
@end
@implementation CCPrefsSwitch @end

@interface CCPrefsSlider : UISlider
@property (nonatomic, copy) NSString *prefKey;
@property (nonatomic, weak) UILabel *valueLabel;
@end
@implementation CCPrefsSlider @end

@interface CCPrefsSliderCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) CCPrefsSlider *slider;
@property (nonatomic, strong) UILabel *valueLabel;
@end

@implementation CCPrefsSliderCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.adjustsFontSizeToFitWidth = YES;
        _nameLabel.minimumScaleFactor = 0.7;
        [self.contentView addSubview:_nameLabel];

        _slider = [[CCPrefsSlider alloc] initWithFrame:CGRectZero];
        [self.contentView addSubview:_slider];

        _valueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
        _valueLabel.textColor = [UIColor secondaryLabelColor];
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self.contentView addSubview:_valueLabel];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    _nameLabel.frame = CGRectMake(16, 0, w * 0.40, h);
    CGFloat vx = w - 16 - 50;
    _valueLabel.frame = CGRectMake(vx, 0, 50, h);
    CGFloat sx = 16 + w * 0.40 + 8;
    _slider.frame = CGRectMake(sx, 0, MAX(60.0, vx - sx - 10), h);
}
@end

@interface CCPrefsTextCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UITextField *field;
@end

@implementation CCPrefsTextCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont systemFontOfSize:16];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.adjustsFontSizeToFitWidth = YES;
        _nameLabel.minimumScaleFactor = 0.75;
        [self.contentView addSubview:_nameLabel];
        _field = [[UITextField alloc] initWithFrame:CGRectZero];
        _field.font = [UIFont systemFontOfSize:15];
        _field.textAlignment = NSTextAlignmentRight;
        _field.textColor = [UIColor secondaryLabelColor];
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self.contentView addSubview:_field];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.contentView.bounds.size.width;
    CGFloat h = self.contentView.bounds.size.height;
    CGFloat nameW = MIN(180.0, w * 0.46);
    _nameLabel.frame = CGRectMake(16, 0, nameW, h);
    CGFloat fx = 16 + nameW + 12;
    _field.frame = CGRectMake(fx, 0, w - fx - 16, h);
}
@end

__attribute__((visibility("default")))
@interface CCSettingsController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *ccTable;
@property (nonatomic, strong) NSArray<NSArray<CCPrefsItem *> *> *sections;
@property (nonatomic, strong) NSArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSArray<NSString *> *sectionFooters;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *values;
@property (nonatomic, strong) NSArray<CCPrefsItem *> *textRows;
@end

@implementation CCSettingsController

// 关键：返回空 specifiers，阻止 PSListController 自动加载同名 plist（那会导致进页面闪退）

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CallCaption";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(closeSettings)];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    // 隐藏 PSListController 自带的表格，避免空白页/白屏
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UITableView class]]) v.hidden = YES;
    }

    @try {
        [self buildModel];
        [self loadValues];
    } @catch (NSException *e) { }

    self.ccTable = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStyleInsetGrouped];
    self.ccTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.ccTable.dataSource = self;
    self.ccTable.delegate = self;
    self.ccTable.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.ccTable.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self.view addSubview:self.ccTable];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(kbChange:)
        name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)kbChange:(NSNotification *)n {
    CGRect end = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    CGFloat overlap = MAX(0, self.view.bounds.size.height - local.origin.y);
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, overlap, 0);
    self.ccTable.contentInset = insets;
    self.ccTable.scrollIndicatorInsets = insets;
}

// ---------- 模型 ----------

static CCPrefsItem *MkSwitch(NSString *key, NSString *title, BOOL def) {
    CCPrefsItem *r = [CCPrefsItem new];
    r.kind = CCPrefsItemKindSwitch; r.key = key; r.title = title; r.defBool = def;
    return r;
}
static CCPrefsItem *MkText(NSString *key, NSString *title, NSString *def, BOOL secure, NSString *ph) {
    CCPrefsItem *r = [CCPrefsItem new];
    r.kind = CCPrefsItemKindText; r.key = key; r.title = title; r.defString = def;
    r.secure = secure; r.placeholder = ph;
    return r;
}
static CCPrefsItem *MkSlider(NSString *key, NSString *title, NSString *def,
                       double minV, double maxV) {
    CCPrefsItem *r = [CCPrefsItem new];
    r.kind = CCPrefsItemKindSlider; r.key = key; r.title = title; r.defString = def;
    r.minValue = minV; r.maxValue = maxV;
    return r;
}
static CCPrefsItem *MkChoice(NSString *key, NSString *title, NSString *def,
                       NSArray<NSString *> *vals, NSArray<NSString *> *titles) {
    CCPrefsItem *r = [CCPrefsItem new];
    r.kind = CCPrefsItemKindChoice; r.key = key; r.title = title; r.defString = def;
    r.choiceValues = vals; r.choiceTitles = titles;
    return r;
}
static CCPrefsItem *MkAction(NSString *key, NSString *title) {
    CCPrefsItem *r = [CCPrefsItem new];
    r.kind = CCPrefsItemKindAction; r.title = title; r.key = key;
    return r;
}

static void VoiceLists(NSString *prefix,
                       NSMutableArray<NSString *> *vals,
                       NSMutableArray<NSString *> *titles) {
    [vals addObject:@""];
    [titles addObject:@"系统默认"];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if ([[v.language lowercaseString] hasPrefix:prefix]) {
            [vals addObject:v.identifier];
            NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @" · 增强" : @"";
            [titles addObject:[NSString stringWithFormat:@"%@（%@%@）", v.name, v.language, q]];
        }
    }
}

- (void)buildModel {
    NSArray *func = @[
        MkSwitch(@"Enabled", @"启用 CallCaption", YES),
        MkSwitch(@"RemoteEnabled", @"对方语音 → 中文字幕", YES),
        MkSwitch(@"LocalEnabled", @"双向模式：我的话 → 英文播报", NO),
        MkSwitch(@"ShowRecognized", @"显示识别原文", YES),
        MkSwitch(@"ShowTranslated", @"显示译文", YES),
        MkSwitch(@"TTSEnabled", @"中文字幕语音播报", YES),
        MkSwitch(@"CloudASR", @"云端语音识别（更准，需联网）", YES),
        MkSwitch(@"LargeCaptions", @"大字幕", NO),
        MkSwitch(@"AlwaysShowPanel", @"面板常驻显示（非通话也显示）", NO),
    ];
    NSArray *lang = @[
        MkText(@"RemoteLocale", @"对方语言", @"en-US", NO, @"en-US"),
        MkText(@"LocalLocale", @"我的语言", @"zh-CN", NO, @"zh-CN"),
    ];

    NSArray *volumes = @[
        MkSlider(@"RemoteOriginalVolume", @"对方原音", @"30", 0, 100),
        MkSlider(@"LocalOriginalVolume", @"我方原音", @"30", 0, 100),
    ];

    NSMutableArray *zhV = [NSMutableArray array], *zhT = [NSMutableArray array];
    NSMutableArray *enV = [NSMutableArray array], *enT = [NSMutableArray array];
    VoiceLists(@"zh", zhV, zhT);
    VoiceLists(@"en", enV, enT);

    NSArray *engine = @[
        MkChoice(@"Engine", @"引擎", @"auto",
                 @[@"auto", @"deepl", @"bing", @"google", @"ai"],
                 @[@"自动（推荐）", @"DeepL", @"Bing（免费·国内推荐）",
                   @"Google（免费 / Key）", @"AI 自定义"]),
        MkText(@"DeepLKey", @"DeepL API Key", @"", NO, @"不填则跳过 DeepL"),
        MkText(@"GoogleKey", @"Google API Key", @"", NO, @"不填则用免费接口"),
    ];
    NSArray *ai = @[
        MkText(@"AIURL", @"AI 接口地址", @"https://api.deepseek.com/v1/chat/completions", NO,
               @"https://.../chat/completions"),
        MkText(@"AIKey", @"AI API Key", @"", NO, @"sk-..."),
        MkText(@"AIModel", @"AI 模型名", @"deepseek-chat", NO, @"deepseek-chat"),
    ];
    NSArray *voices = @[
        MkChoice(@"TTSVoice", @"中文播报音色", @"", zhV, zhT),
        MkChoice(@"LocalVoice", @"英文播报音色", @"", enV, enT),
    ];
    NSArray *diag = @[
        MkSwitch(@"Diagnostics", @"诊断日志", YES),
        MkAction(@"testApi", @"测试翻译接口"),
        MkAction(@"openLog", @"打开诊断日志"),
    ];

    self.sections = @[func, lang, volumes, engine, ai, voices, diag];
    self.sectionTitles = @[@"功能开关", @"语言", @"原音音量", @"翻译引擎",
                           @"AI 自定义接口（OpenAI 兼容）", @"播报音色", @"诊断"];
    self.sectionFooters = @[
        @"通话接通后自动激活，屏幕出现小地球；点地球展开面板，再点面板里的地球可关闭/开启翻译。面板外任意位置点击自动收起。",
        @"识别语言代码（BCP-47）：对方英文 en-US、日文 ja-JP、韩文 ko-KR；我的语言通常 zh-CN。",
        @"TTS 播报时原音保留多少：0 = 原音静音，100 = 不压低。对方原音 = 你听到的英文；我方原音 = 对方听到的你的声音。",
        @"自动 = 已填 Key 优先，失败自动切换。MyMemory 免费接口国内可用；Google 不填 Key 用免费接口，填了走 Cloud Translation。",
        @"填写 chat/completions 完整地址、Key 与模型名，例如 DeepSeek。",
        @"列表来自系统已安装语音。中文用于对方字幕播报，英文用于我方双向播报。",
        @"日志：/var/mobile/Library/CallCaption/probe.log",
    ];

    NSMutableArray *tr = [NSMutableArray array];
    for (NSArray *sec in self.sections)
        for (CCPrefsItem *r in sec)
            if (r.kind == CCPrefsItemKindText) [tr addObject:r];
    self.textRows = tr;
}

// ---------- 读写 ----------

- (void)loadValues {
    self.values = [NSMutableDictionary dictionary];
    for (NSArray *sec in self.sections) {
        for (CCPrefsItem *r in sec) {
            if (r.key.length == 0) continue;
            id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
                       (__bridge CFStringRef)r.key, (__bridge CFStringRef)CC_DOMAIN);
            if (!v) v = (r.kind == CCPrefsItemKindSwitch) ? @(r.defBool) : (r.defString ?: @"");
            self.values[r.key] = v;
        }
    }
}

- (NSString *)stringFor:(CCPrefsItem *)r {
    id v = self.values[r.key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return r.defString ?: @"";
}

- (BOOL)boolFor:(CCPrefsItem *)r {
    id v = self.values[r.key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue] || [v isEqualToString:@"YES"] || [v isEqualToString:@"1"];
    return r.defBool;
}

- (void)setPrefValue:(id)value forKey:(NSString *)key {
    if (key.length == 0) return;
    self.values[key] = value ?: @"";
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)(value ?: @""),
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CC_NOTIF, NULL, NULL, YES);
}

// ---------- Table ----------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return self.sections[(NSUInteger)s].count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return self.sectionTitles[(NSUInteger)s];
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.sectionFooters[(NSUInteger)s];
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CCPrefsItem *row = self.sections[(NSUInteger)ip.section][(NSUInteger)ip.row];

    if (row.kind == CCPrefsItemKindSwitch) {
        static NSString *cid = @"sw";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            CCPrefsSwitch *sw = [[CCPrefsSwitch alloc] initWithFrame:CGRectMake(0, 0, 51, 31)];
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        cell.textLabel.text = row.title;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        CCPrefsSwitch *sw = (CCPrefsSwitch *)cell.accessoryView;
        sw.prefKey = row.key;
        sw.on = [self boolFor:row];
        return cell;
    }

    if (row.kind == CCPrefsItemKindText) {
        static NSString *cid = @"txt";
        CCPrefsTextCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) cell = [[CCPrefsTextCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.nameLabel.text = row.title;
        cell.field.placeholder = row.placeholder;
        cell.field.secureTextEntry = row.secure;
        cell.field.text = [self stringFor:row];
        cell.field.delegate = self;
        cell.field.tag = (NSInteger)[self.textRows indexOfObject:row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (row.kind == CCPrefsItemKindSlider) {
        static NSString *cid = @"slider";
        CCPrefsSliderCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) {
            cell = [[CCPrefsSliderCell alloc] initWithStyle:UITableViewCellStyleDefault
                                            reuseIdentifier:cid];
            [cell.slider addTarget:self action:@selector(sliderChanged:)
                  forControlEvents:UIControlEventValueChanged];
        }
        cell.nameLabel.text = row.title;
        double v = [[self stringFor:row] doubleValue];
        if (v < row.minValue) v = row.minValue;
        if (v > row.maxValue) v = row.maxValue;
        cell.slider.minimumValue = (float)row.minValue;
        cell.slider.maximumValue = (float)row.maxValue;
        cell.slider.value = (float)v;
        cell.slider.prefKey = row.key;
        cell.slider.valueLabel = cell.valueLabel;
        cell.valueLabel.text = [NSString stringWithFormat:@"%d%%", (int)lround(v)];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (row.kind == CCPrefsItemKindChoice) {
        static NSString *cid = @"choice";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
        cell.textLabel.text = row.title;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.text = [self titleForChoice:row value:[self stringFor:row]];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    // Action
    static NSString *cid = @"action";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    cell.textLabel.text = row.title;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
}

- (NSString *)titleForChoice:(CCPrefsItem *)row value:(NSString *)val {
    NSUInteger i = [row.choiceValues indexOfObject:val];
    if (i != NSNotFound && i < row.choiceTitles.count) return row.choiceTitles[i];
    return row.choiceTitles.firstObject ?: val;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CCPrefsItem *row = self.sections[(NSUInteger)ip.section][(NSUInteger)ip.row];

    if (row.kind == CCPrefsItemKindText) {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if ([cell isKindOfClass:[CCPrefsTextCell class]]) [[(CCPrefsTextCell *)cell field] becomeFirstResponder];
        return;
    }
    if (row.kind == CCPrefsItemKindChoice) {
        [self presentChoices:row cell:[tv cellForRowAtIndexPath:ip]];
        return;
    }
    if (row.kind == CCPrefsItemKindAction) {
        if ([row.key isEqualToString:@"openLog"]) {
            [self presentLogMenu:[tv cellForRowAtIndexPath:ip]];
        } else if ([row.key isEqualToString:@"testApi"]) {
            [self runApiTest];
        }
    }
}

// ---------- 交互 ----------

- (void)switchChanged:(CCPrefsSwitch *)sw {
    [self setPrefValue:@(sw.on) forKey:sw.prefKey];
}

- (void)sliderChanged:(CCPrefsSlider *)sl {
    int v = (int)lround(sl.value);
    sl.valueLabel.text = [NSString stringWithFormat:@"%d%%", v];
    [self setPrefValue:@(v) forKey:sl.prefKey];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf.tag >= 0 && (NSUInteger)tf.tag < self.textRows.count) {
        CCPrefsItem *r = self.textRows[(NSUInteger)tf.tag];
        [self setPrefValue:(tf.text ?: @"") forKey:r.key];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)presentChoices:(CCPrefsItem *)row cell:(UITableViewCell *)cell {
    NSString *cur = [self stringFor:row];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:row.title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < row.choiceValues.count; i++) {
        NSString *val = row.choiceValues[i];
        NSString *title = i < row.choiceTitles.count ? row.choiceTitles[i] : val;
        NSString *mark = [val isEqualToString:cur] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[mark stringByAppendingString:title]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self setPrefValue:val forKey:row.key];
            [self.ccTable reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

static NSString *CCApiSnippet2(NSData *data) {
    if (!data) return @"";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (s.length > 100) s = [s substringToIndex:100];
    return s;
}

- (NSString *)valForKey:(NSString *)key def:(NSString *)def {
    id v = self.values[key];
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return def;
}

- (void)runApiTest {
    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"接口测试"
        message:@"正在请求 DeepL / Google / AI / MyMemory…"
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();

    NSString *dk = [self valForKey:@"DeepLKey" def:@""];
    NSString *gk = [self valForKey:@"GoogleKey" def:@""];
    NSString *aiURL = [self valForKey:@"AIURL" def:@""];
    NSString *aiKey = [self valForKey:@"AIKey" def:@""];
    NSString *aiModel = [self valForKey:@"AIModel" def:@"deepseek-chat"];

    if (!dk.length) {
        res[@"DeepL"] = @"未填 Key";
    } else {
        dispatch_group_enter(group);
        NSString *body = [NSString stringWithFormat:@"text=Hello&source_lang=EN&target_lang=ZH"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://api-free.deepl.com/v2/translate"]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", dk]
   forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
        req.timeoutInterval = 5.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                 ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line;
                id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString *out = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *arr = json[@"translations"];
                    if ([arr isKindOfClass:[NSArray class]] && arr.count) out = arr[0][@"text"];
                }
                if (err) line = [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, err.localizedDescription];
                else if (out.length) line = [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, out];
                else line = [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, CCApiSnippet2(data)];
                @synchronized(res) { res[@"DeepL"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_enter(group);
    {
        NSString *urlStr;
        if (gk.length) {
            urlStr = [NSString stringWithFormat:
                @"https://translation.googleapis.com/language/translate/v2?key=%@&q=Hello&source=en&target=zh",
                gk];
        } else {
            urlStr = @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh&dt=t&q=Hello";
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.timeoutInterval = 5.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                 ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line = err ? [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, err.localizedDescription]
                                     : [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, CCApiSnippet2(data)];
                @synchronized(res) { res[@"Google"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    if (!aiURL.length || !aiKey.length) {
        res[@"AI"] = @"未配置 URL/Key";
    } else {
        dispatch_group_enter(group);
        NSDictionary *body = @{
            @"model": aiModel.length ? aiModel : @"deepseek-chat",
            @"temperature": @0,
            @"max_tokens": @40,
            @"messages": @[
                @{@"role": @"system", @"content": @"Translate to Chinese. Output only the translation."},
                @{@"role": @"user", @"content": @"Hello"},
            ],
        };
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:aiURL]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", aiKey] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        req.timeoutInterval = 7.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                 ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line = err ? [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, err.localizedDescription]
                                     : [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, CCApiSnippet2(data)];
                @synchronized(res) { res[@"AI"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_enter(group);
    {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://api.mymemory.translated.net/get?q=Hello&langpair=en%7Czh"]];
        req.timeoutInterval = 5.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                 ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line = err ? [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, err.localizedDescription]
                                     : [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, CCApiSnippet2(data)];
                @synchronized(res) { res[@"MyMemory"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *order = @[@"DeepL", @"Google", @"AI", @"MyMemory"];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *k in order)
            [lines addObject:[NSString stringWithFormat:@"%@：%@", k, res[k] ?: @"未测试"]];
        NSString *summary = [lines componentsJoinedByString:@"\n"];
        [loading dismissViewControllerAnimated:YES completion:^{
            UIAlertController *result = [UIAlertController alertControllerWithTitle:@"接口测试结果"
                message:summary preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"复制结果"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [UIPasteboard generalPasteboard].string = summary;
            }]];
            [result addAction:[UIAlertAction actionWithTitle:@"确定"
                style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:result animated:YES completion:nil];
        }];
    });
}

- (void)presentLogMenu:(UITableViewCell *)cell {
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
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)closeSettings {
    self.view.window.hidden = YES;
}

@end
