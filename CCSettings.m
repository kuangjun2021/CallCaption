// CallCaptionRootListController.m — v0.12.2 设置面板
// 宿主必须是 PSListController（否则 Settings 推入时闪退），但界面完全自绘：
// 在 PSListController 之上覆盖自己的 UITableView，不用 PSSpecifier / 子页面。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <stdio.h>

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

// ---------- 音色选择 + 试听 ----------
// 系统 AVSpeechSynthesisVoice 列表 + 点一下立即用该音色朗读示例，选中即保存。

@interface CCVoicePickerController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, AVSpeechSynthesizerDelegate>
@property (nonatomic, copy) NSArray<NSString *> *values;
@property (nonatomic, copy) NSArray<NSString *> *titles;
@property (nonatomic, copy) NSString *current;
@property (nonatomic, copy) NSString *sampleText;
@property (nonatomic, copy) NSString *fallbackLang;
@property (nonatomic, copy) void (^onPick)(NSString *value);
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) AVSpeechSynthesizer *synth;
@end

@implementation CCVoicePickerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择播报音色";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone
                                        target:self action:@selector(closeTapped)];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds
                                              style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
    self.synth = [[AVSpeechSynthesizer alloc] init];
    self.synth.delegate = self;
}

- (void)closeTapped {
    [self.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.values.count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @"点任意一行立即试听";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"试听会直接用该音色朗读一段示例；点过即选中并保存，按“完成”返回。";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"voice";
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:cid];
    NSUInteger i = (NSUInteger)ip.row;
    NSString *val = i < self.values.count ? self.values[i] : @"";
    cell.textLabel.text = i < self.titles.count ? self.titles[i] : val;
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.text = (i == 0) ? @"不指定，按语言自动选择" : @"点一下试听";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.accessoryType = [val isEqualToString:(self.current ?: @"")]
        ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSUInteger i = (NSUInteger)ip.row;
    if (i >= self.values.count) return;
    self.current = self.values[i];
    [tv reloadData];
    if (self.onPick) self.onPick(self.current);
    [self previewVoice:self.current];
}

- (void)previewVoice:(NSString *)identifier {
    [self.synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    // 设置进程默认音频会话是 ambient：静音开关一开就完全没声。
    // 试听前显式切到 Playback（可绕过静音键），播完再交还。
    @try {
        AVAudioSession *as = [AVAudioSession sharedInstance];
        [as setCategory:AVAudioSessionCategoryPlayback
                   mode:AVAudioSessionModeDefault
                options:AVAudioSessionCategoryOptionMixWithOthers |
                        AVAudioSessionCategoryOptionDuckOthers
                  error:nil];
        [as setActive:YES error:nil];
    } @catch (NSException *e) { }
    NSString *text = self.sampleText.length ? self.sampleText
                                            : @"你好，这是语音试听。";
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
    AVSpeechSynthesisVoice *v = identifier.length
        ? [AVSpeechSynthesisVoice voiceWithIdentifier:identifier] : nil;
    if (v) u.voice = v;
    else if (self.fallbackLang.length)
        u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:self.fallbackLang];
    u.rate = 0.48;
    u.volume = 1.0;
    [self.synth speakUtterance:u];
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s
    didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    @try {
        [[AVAudioSession sharedInstance] setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];
    } @catch (NSException *e) { }
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
@property (nonatomic, assign) BOOL embedded;   // YES: 作为 Settings.app 子控制器，不显示“完成”
@end

// 自绘结果弹窗：每个端点一行，名称 + 结果左对齐
@interface CCApiResultController : UIViewController <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *rows;   // name / ok / detail
@property (nonatomic, copy) NSString *summary;
@end

@implementation CCApiResultController {
    UIView *_card;
    UIButton *_copyButton;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(bgTapped:)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];

    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
    CGFloat cardW = MIN(sw - 44.0, 400.0);
    CGFloat pad = 20.0;
    CGFloat nameW = 86.0;
    CGFloat resX = pad + nameW;
    UIFont *nameFont = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    UIFont *detFont = [UIFont systemFontOfSize:14];

    NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
    CGFloat bodyH = 0;
    for (NSDictionary *r in self.rows) {
        NSString *d = r[@"detail"] ?: @"";
        CGFloat dh = [d boundingRectWithSize:CGSizeMake(cardW - resX - pad, CGFLOAT_MAX)
                                     options:NSStringDrawingUsesLineFragmentOrigin
                                  attributes:@{NSFontAttributeName: detFont}
                                     context:nil].size.height;
        CGFloat h = MAX(22.0, ceil(dh)) + 16.0;
        [heights addObject:@(h)];
        bodyH += h;
    }

    CGFloat headH = pad + 22.0 + 14.0;
    CGFloat footH = 50.0;
    CGFloat cardH = headH + bodyH + footH + 6.0;
    CGFloat cardY = (CGRectGetHeight(self.view.bounds) - cardH) / 2.0;

    _card = [[UIView alloc] initWithFrame:CGRectMake((sw - cardW) / 2.0, cardY, cardW, cardH)];
    _card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    _card.layer.cornerRadius = 16.0;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self.view addSubview:_card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, pad, cardW - pad * 2, 22)];
    title.text = @"接口测试结果";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [UIColor labelColor];
    title.textAlignment = NSTextAlignmentCenter;
    [_card addSubview:title];

    CGFloat y = headH;
    for (NSUInteger i = 0; i < self.rows.count; i++) {
        NSDictionary *r = self.rows[i];
        CGFloat h = heights[i].doubleValue;

        if (i > 0) {
            UIView *sep = [[UIView alloc] initWithFrame:
                CGRectMake(pad, y, cardW - pad * 2, 1.0 / [UIScreen mainScreen].scale)];
            sep.backgroundColor = [UIColor separatorColor];
            [_card addSubview:sep];
        }

        BOOL ok = [r[@"ok"] boolValue];

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(pad, y + 8.0, nameW - 8.0, 20)];
        name.text = r[@"name"];
        name.font = nameFont;
        name.textColor = [UIColor labelColor];
        [_card addSubview:name];

        UILabel *det = [[UILabel alloc] initWithFrame:
            CGRectMake(resX, y + 8.0, cardW - resX - pad, h - 16.0)];
        det.text = r[@"detail"];
        det.font = detFont;
        det.numberOfLines = 0;
        det.textColor = ok ? [UIColor secondaryLabelColor] : [UIColor systemRedColor];
        [_card addSubview:det];

        y += h;
    }

    UIView *btnSep = [[UIView alloc] initWithFrame:
        CGRectMake(0, cardH - footH, cardW, 1.0 / [UIScreen mainScreen].scale)];
    btnSep.backgroundColor = [UIColor separatorColor];
    [_card addSubview:btnSep];

    _copyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _copyButton.frame = CGRectMake(0, cardH - footH, cardW / 2.0, footH - 1.0);
    [_copyButton setTitle:@"复制结果" forState:UIControlStateNormal];
    _copyButton.titleLabel.font = [UIFont systemFontOfSize:16];
    [_copyButton addTarget:self action:@selector(copyTapped)
          forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_copyButton];

    UIView *vSep = [[UIView alloc] initWithFrame:
        CGRectMake(cardW / 2.0, cardH - footH + 10.0,
                   1.0 / [UIScreen mainScreen].scale, footH - 20.0)];
    vSep.backgroundColor = [UIColor separatorColor];
    [_card addSubview:vSep];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.frame = CGRectMake(cardW / 2.0, cardH - footH, cardW / 2.0, footH - 1.0);
    [done setTitle:@"完成" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [done addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:done];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _card.center = CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

// 卡片内的点击（按钮）不拦截，只处理点击卡片外关闭
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return !CGRectContainsPoint(_card.frame, [t locationInView:self.view]);
}

- (void)bgTapped:(UITapGestureRecognizer *)g {
    if (!CGRectContainsPoint(_card.frame, [g locationInView:self.view]))
        [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyTapped {
    [UIPasteboard generalPasteboard].string = self.summary ?: @"";
    [_copyButton setTitle:@"已复制 ✓" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self->_copyButton setTitle:@"复制结果" forState:UIControlStateNormal];
    });
}

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@implementation CCSettingsController

// 关键：返回空 specifiers，阻止 PSListController 自动加载同名 plist（那会导致进页面闪退）

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CallCaption";
    if (!self.embedded) {
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                             style:UIBarButtonItemStyleDone
                                            target:self
                                            action:@selector(closeSettings)];
    }
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
        MkSwitch(@"LocalEnabled", @"双向模式：我的话 → 英文播报", YES),
        MkSwitch(@"ShowRecognized", @"显示识别原文", YES),
        MkSwitch(@"ShowTranslated", @"显示译文", YES),
        MkSwitch(@"TTSEnabled", @"中文字幕语音播报", YES),
        MkSwitch(@"CloudASR", @"云端语音识别（更准，需联网）", YES),
        MkSwitch(@"LargeCaptions", @"大字幕", NO),
        MkSwitch(@"AlwaysShowPanel", @"面板常驻显示（非通话也显示）", NO),
    ];
    NSArray *tencent = @[
        MkSwitch(@"TencentTranslateEnabled", @"启用腾讯实时翻译", NO),
        MkText(@"TencentAppID", @"AppID", @"", NO, @"10 位数字"),
        MkText(@"TencentSecretID", @"SecretId", @"", NO, @"SecretId"),
        MkText(@"TencentSecretKey", @"SecretKey", @"", YES, @"SecretKey（密文）"),
        MkText(@"TencentLocalVoice", @"腾讯英文音色 ID", @"501009", NO, @"501009 / 101050"),
        MkChoice(@"EnglishTTSEngine", @"英文播报引擎", @"local",
                 @[@"local", @"tencent", @"off"],
                 @[@"本机（低延迟）", @"腾讯（音色好）", @"关闭（只显示英文字幕）"]),
        MkChoice(@"TencentLocalEngine", @"我方翻译引擎", @"sfspeech",
                 @[@"sfspeech", @"tencent"],
                 @[@"本机 SFSpeech（混合·单条腾讯 WS）", @"腾讯 lite（双条腾讯 WS）"]),
        MkChoice(@"TencentLocalSource", @"我方源语言", @"zh",
                 @[@"zh", @"zh_en"], @[@"中文", @"中文 + 英文"]),
        MkChoice(@"TencentLocalModel", @"我方翻译模型", @"hunyuan-translation-lite",
                 @[@"hunyuan-translation-lite", @"hunyuan-translation"],
                 @[@"Lite（快/省）", @"标准"]),
        MkChoice(@"TencentRemoteModel", @"对方翻译模型", @"hunyuan-translation",
                 @[@"hunyuan-translation", @"hunyuan-translation-lite"],
                 @[@"标准（en→zh 必需）", @"Lite（不支持 en→zh）"]),
        MkSlider(@"TencentLocalVolume", @"腾讯英文音量", @"6", -10, 10),
        MkSlider(@"TencentLocalSpeed", @"腾讯英文语速", @"0", -2, 6),
        MkChoice(@"TencentVadSilence", @"断句静音", @"600",
                 @[@"500", @"600", @"800", @"1000", @"1500", @"2000"],
                 @[@"500ms（最快）", @"600ms", @"800ms", @"1000ms", @"1500ms", @"2000ms"]),
        MkChoice(@"TencentMaxSpeak", @"最长句", @"6000",
                 @[@"5000", @"6000", @"8000", @"10000", @"20000", @"30000"],
                 @[@"5s（最快）", @"6s", @"8s", @"10s", @"20s", @"30s"]),
        MkChoice(@"TencentSampleRate", @"上传采样率", @"16000",
                 @[@"16000", @"8000"],
                 @[@"16k（质量优先）", @"8k（双开更稳）"]),
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
    // 接口测试紧跟 API 设置，改完 Key 直接就能测
    NSArray *apiTest = @[
        MkAction(@"testApi", @"测试翻译接口"),
    ];
    NSArray *voices = @[
        MkChoice(@"TTSVoice", @"中文播报音色", @"", zhV, zhT),
        MkChoice(@"LocalVoice", @"英文播报音色", @"", enV, enT),
    ];
    NSArray *diag = @[
        MkSwitch(@"Diagnostics", @"诊断日志", YES),
        MkAction(@"openLog", @"打开诊断日志"),
    ];

    self.sections = @[func, tencent, lang, volumes, engine, ai, apiTest, voices, diag];
    self.sectionTitles = @[@"功能开关", @"腾讯实时翻译（D+）", @"语言", @"原音音量", @"翻译引擎",
                           @"AI 自定义接口（OpenAI 兼容）", @"接口测试",
                           @"播报音色", @"诊断"];
    self.sectionFooters = @[
        @"通话接通后自动激活，屏幕出现小地球；点地球展开面板，再点面板里的地球可关闭/开启翻译。面板外任意位置点击自动收起。",
        @"启用后：对方英文→中文文本（本机中文 TTS 队列）。我方翻译引擎默认“本机 SFSpeech（混合）”：只开一条腾讯 WS，用 Apple 识别+翻译引擎，避免双条 WS 互相饿死；切到“腾讯 lite”才是我方也走腾讯（双 WS，可能被饿死）。英文播报“本机”延迟最低，“腾讯”音色更好但每句多等 2~3 秒。AppID/SecretId/SecretKey 从腾讯云 CAM 获取；SecretKey 只存本机。对方模型必须标准版。断句静音越短字幕越快但更碎。",
        @"识别语言代码（BCP-47）：对方英文 en-US、日文 ja-JP、韩文 ko-KR；我的语言通常 zh-CN。",
        @"0 = 全程静音（只播译文，TTS 前的原声也不放）；1-100 = 只在 TTS 播报时保留原音，100 = 不压低。对方原音 = 你听到的英文；我方原音 = 对方听到的你的声音。想让对方只听到英文，把我方原音设为 0。",
        @"自动 = 已填 Key 优先，失败自动切换。MyMemory 免费接口国内可用；Google 不填 Key 用免费接口，填了走 Cloud Translation。",
        @"填写 chat/completions 完整地址、Key 与模型名，例如 DeepSeek。",
        @"分别请求 DeepL / Google / AI / MyMemory 一次（Hello 英译中），检查 Key 和网络是否可用。",
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
    // 关键修复：Settings.app 里的 CFPreferences 只写进 Preferences 自己的容器，
    // SpringBoard / 守护进程读的是 /var/mobile/Library/Preferences 全局 plist，
    // 所以“云端语音识别”等开关会出现“界面开着、日志里仍是 0”。
    // 这里直接合并写全局 plist（Preferences 进程对预置偏好目录有权限）。
    @try {
        NSString *path = @"/var/mobile/Library/Preferences/net.user.callcaption.plist";
        NSMutableDictionary *m = [NSMutableDictionary dictionaryWithContentsOfFile:path];
        if (!m) m = [NSMutableDictionary dictionary];
        m[key] = value ?: @"";
        BOOL ok = [m writeToFile:path atomically:YES];
        if (ok)
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666}
                                             ofItemAtPath:path error:nil];
        FILE *fp = fopen("/tmp/ccsettings.log", "a");
        if (fp) {
            fprintf(fp, "[%s] set %s global=%d\n",
                    [[[NSDate date] description] UTF8String], key.UTF8String, ok);
            fclose(fp);
        }
    } @catch (NSException *e) { }
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
        if ([row.key isEqualToString:@"TTSVoice"] ||
            [row.key isEqualToString:@"LocalVoice"]) {
            [self presentVoicePicker:row];
        } else {
            [self presentChoices:row cell:[tv cellForRowAtIndexPath:ip]];
        }
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

- (void)presentVoicePicker:(CCPrefsItem *)row {
    CCVoicePickerController *vc = [[CCVoicePickerController alloc] init];
    vc.values = row.choiceValues ?: @[];
    vc.titles = row.choiceTitles ?: @[];
    vc.current = [self stringFor:row];
    BOOL zh = [row.key isEqualToString:@"TTSVoice"];
    vc.sampleText = zh ? @"你好，这是通话翻译的语音试听，很高兴为你服务。"
                       : @"Hello, this is a preview of the call translation voice.";
    vc.fallbackLang = zh ? @"zh-CN" : @"en-US";
    __weak CCSettingsController *ws = self;
    vc.onPick = ^(NSString *val) {
        [ws setPrefValue:val forKey:row.key];
        [ws.ccTable reloadData];
    };
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
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

static NSString *CCApiShort(NSString *s, NSUInteger max) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (s.length > max) s = [[s substringToIndex:max] stringByAppendingString:@"…"];
    return s;
}

// 从各引擎返回体里提取译文，取不到返回 nil
static NSString *CCApiTextFromJSON(NSString *engine, id json) {
    if (!json) return nil;
    NSString *out = nil;
    if ([engine isEqualToString:@"DeepL"] && [json isKindOfClass:[NSDictionary class]]) {
        NSArray *arr = json[@"translations"];
        if ([arr isKindOfClass:[NSArray class]] && arr.count &&
            [arr[0] isKindOfClass:[NSDictionary class]])
            out = arr[0][@"text"];
    } else if ([engine isEqualToString:@"Google"]) {
        if ([json isKindOfClass:[NSDictionary class]]) {
            id tr = json[@"data"][@"translations"];
            if ([tr isKindOfClass:[NSArray class]] && [tr count] &&
                [tr[0] isKindOfClass:[NSDictionary class]])
                out = tr[0][@"translatedText"];
        } else if ([json isKindOfClass:[NSArray class]]) {
            // 免费接口格式：[[["你好","Hello",...],...],...]
            NSMutableString *ms = [NSMutableString string];
            id segs = [json count] ? json[0] : nil;
            if ([segs isKindOfClass:[NSArray class]]) {
                for (id seg in segs)
                    if ([seg isKindOfClass:[NSArray class]] && [seg count] &&
                        [seg[0] isKindOfClass:[NSString class]])
                        [ms appendString:seg[0]];
            }
            if (ms.length) out = ms;
        }
    } else if ([engine isEqualToString:@"AI"] && [json isKindOfClass:[NSDictionary class]]) {
        NSArray *arr = json[@"choices"];
        if ([arr isKindOfClass:[NSArray class]] && arr.count) {
            id msg = arr[0][@"message"];
            out = [msg isKindOfClass:[NSDictionary class]] ? msg[@"content"] : arr[0][@"text"];
        }
    } else if ([engine isEqualToString:@"MyMemory"] && [json isKindOfClass:[NSDictionary class]]) {
        id rd = json[@"responseData"];
        if ([rd isKindOfClass:[NSDictionary class]]) out = rd[@"translatedText"];
    }
    return [out isKindOfClass:[NSString class]] ? out : nil;
}



- (void)ccRecordResult:(NSMutableDictionary *)res engine:(NSString *)engine
                  data:(NSData *)data resp:(NSURLResponse *)resp err:(NSError *)err {
    NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                     ? [(NSHTTPURLResponse *)resp statusCode] : 0;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *text = CCApiTextFromJSON(engine, json);
    BOOL httpOK = (status == 0 || (status >= 200 && status < 300));
    BOOL ok = NO;
    NSString *detail;
    if (err) {
        detail = status
            ? [NSString stringWithFormat:@"✗ HTTP %ld · %@", (long)status, CCApiShort(err.localizedDescription, 60)]
            : [NSString stringWithFormat:@"✗ %@", CCApiShort(err.localizedDescription, 60)];
    } else if (text.length && httpOK) {
        ok = YES;
        detail = [NSString stringWithFormat:@"✓ %@", CCApiShort(text, 80)];
    } else if (httpOK) {
        ok = YES;   // 接口可达，只是返回格式没解析出来
        detail = [NSString stringWithFormat:@"✓ HTTP %ld · %@", (long)status, CCApiShort(CCApiSnippet2(data), 60)];
    } else {
        detail = [NSString stringWithFormat:@"✗ HTTP %ld · %@", (long)status, CCApiShort(CCApiSnippet2(data), 60)];
    }
    @synchronized(res) { res[engine] = @{@"ok": @(ok), @"detail": detail}; }
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
        res[@"DeepL"] = @{@"ok": @NO, @"detail": @"未填 Key（上方可填）"};
    } else {
        dispatch_group_enter(group);
        NSString *body = @"text=Hello&source_lang=EN&target_lang=ZH";
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
                // 403 多为免费/付费域名用反了，换 api.deepl.com 再试一次
                if (!err && status == 403) {
                    NSMutableURLRequest *req2 = [req mutableCopy];
                    req2.URL = [NSURL URLWithString:@"https://api.deepl.com/v2/translate"];
                    [[[NSURLSession sharedSession] dataTaskWithRequest:req2
                        completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2) {
                            [self ccRecordResult:res engine:@"DeepL" data:d2 resp:r2 err:e2];
                            dispatch_group_leave(group);
                        }] resume];
                    return;
                }
                [self ccRecordResult:res engine:@"DeepL" data:data resp:resp err:err];
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
                [self ccRecordResult:res engine:@"Google" data:data resp:resp err:err];
                dispatch_group_leave(group);
            }] resume];
    }

    if (!aiURL.length || !aiKey.length) {
        res[@"AI"] = @{@"ok": @NO, @"detail": @"未配置 URL / Key"};
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
                [self ccRecordResult:res engine:@"AI" data:data resp:resp err:err];
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
                [self ccRecordResult:res engine:@"MyMemory" data:data resp:resp err:err];
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *order = @[@"DeepL", @"Google", @"AI", @"MyMemory"];
        NSMutableArray *rows = [NSMutableArray array];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *k in order) {
            NSDictionary *r = res[k] ?: @{@"ok": @NO, @"detail": @"未测试"};
            [rows addObject:@{@"name": k, @"ok": r[@"ok"], @"detail": r[@"detail"]}];
            [lines addObject:[NSString stringWithFormat:@"%@：%@", k, r[@"detail"]]];
        }
        NSString *summary = [lines componentsJoinedByString:@"\n"];
        [loading dismissViewControllerAnimated:YES completion:^{
            CCApiResultController *vc = [[CCApiResultController alloc] init];
            vc.rows = rows;
            vc.summary = summary;
            vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
            vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:vc animated:YES completion:nil];
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
    if (self.embedded) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.view.window.hidden = YES;
}

@end
