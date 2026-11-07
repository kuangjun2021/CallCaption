// CallCaptionRootListController.m — v0.11.1 自绘设置面板（不依赖 PSListController specifiers）
// 原因：本环境下 PSListController 的 specifier 加载路径不可靠（面板空白），
// 改为自定义 UIViewController + UITableView，全部控件自建，读写 CFPreferences 域。
#import <UIKit/UIKit.h>

#define CC_DOMAIN   @"net.user.callcaption"
#define CC_NOTIF    @"net.user.callcaption.prefschanged"

typedef NS_ENUM(NSInteger, CCRowKind) {
    CCRowKindSwitch = 0,
    CCRowKindText,
    CCRowKindChoice,
};

@interface CCRow : NSObject
@property (nonatomic) CCRowKind kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *placeholder;
@property (nonatomic) BOOL defBool;
@property (nonatomic, copy) NSString *defString;
@property (nonatomic) BOOL secure;
@property (nonatomic, copy) NSArray<NSString *> *choiceValues;
@property (nonatomic, copy) NSArray<NSString *> *choiceTitles;
@end
@implementation CCRow @end

@interface CCSwitch : UISwitch
@property (nonatomic, copy) NSString *prefKey;
@end
@implementation CCSwitch @end

@interface CCRowCell : UITableViewCell
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UITextField *field;
@end

@implementation CCRowCell
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
        _field.keyboardType = UIKeyboardTypeURL;
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
@interface CallCaptionRootListController : UIViewController
    <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray<NSArray<CCRow *> *> *sections;
@property (nonatomic, strong) NSArray<NSString *> *sectionTitles;
@property (nonatomic, strong) NSArray<NSString *> *sectionFooters;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *values;
@property (nonatomic, strong) NSArray<CCRow *> *textRows;
@end

@implementation CallCaptionRootListController

- (instancetype)init {
    return [self initWithNibName:nil bundle:nil];
}
- (instancetype)initWithNibName:(NSString *)n bundle:(NSBundle *)b {
    self = [super initWithNibName:n bundle:b];
    if (self) self.title = @"CallCaption 通话翻译";
    return self;
}
- (instancetype)initWithBundle:(NSBundle *)bundle { return [self initWithNibName:nil bundle:nil]; }
- (instancetype)initForContentSize:(CGSize)size { return [self initWithNibName:nil bundle:nil]; }

// ---------- 数据模型 ----------

static CCRow *MkSwitch(NSString *key, NSString *title, BOOL def) {
    CCRow *r = [CCRow new];
    r.kind = CCRowKindSwitch; r.key = key; r.title = title; r.defBool = def;
    return r;
}
static CCRow *MkText(NSString *key, NSString *title, NSString *def, BOOL secure, NSString *ph) {
    CCRow *r = [CCRow new];
    r.kind = CCRowKindText; r.key = key; r.title = title; r.defString = def;
    r.secure = secure; r.placeholder = ph;
    return r;
}
static CCRow *MkChoice(NSString *key, NSString *title, NSString *def,
                       NSArray<NSString *> *vals, NSArray<NSString *> *titles) {
    CCRow *r = [CCRow new];
    r.kind = CCRowKindChoice; r.key = key; r.title = title; r.defString = def;
    r.choiceValues = vals; r.choiceTitles = titles;
    return r;
}

- (void)buildModel {
    NSArray *func = @[
        MkSwitch(@"Enabled", @"启用 CallCaption", YES),
        MkSwitch(@"RemoteEnabled", @"对方语音 → 中文字幕", YES),
        MkSwitch(@"LocalEnabled", @"双向模式：我的话 → 英文播报", NO),
        MkSwitch(@"TTSEnabled", @"中文字幕语音播报", YES),
        MkSwitch(@"LargeCaptions", @"大字幕", NO),
    ];
    NSArray *lang = @[
        MkText(@"RemoteLocale", @"对方语言", @"en-US", NO, @"en-US"),
        MkText(@"LocalLocale", @"我的语言", @"zh-CN", NO, @"zh-CN"),
    ];
    NSArray *engine = @[
        MkChoice(@"Engine", @"翻译引擎", @"auto",
                 @[@"auto", @"deepl", @"google", @"ai"],
                 @[@"自动（推荐）", @"DeepL", @"Google", @"AI 自定义"]),
        MkText(@"DeepLKey", @"DeepL API Key", @"", YES, @"不填则跳过 DeepL"),
        MkText(@"GoogleKey", @"Google API Key", @"", YES, @"不填则用免费接口"),
    ];
    NSArray *ai = @[
        MkText(@"AIURL", @"AI 接口地址", @"https://api.deepseek.com/v1/chat/completions", NO,
               @"https://.../chat/completions"),
        MkText(@"AIKey", @"AI API Key", @"", YES, @"sk-..."),
        MkText(@"AIModel", @"AI 模型名", @"deepseek-chat", NO, @"deepseek-chat"),
    ];
    NSArray *diag = @[
        MkSwitch(@"Diagnostics", @"诊断日志", YES),
    ];

    self.sections = @[func, lang, engine, ai, diag];
    self.sectionTitles = @[@"功能开关", @"语言", @"翻译引擎", @"AI 自定义接口（OpenAI 兼容）", @"诊断"];
    self.sectionFooters = @[
        @"通话接通后右上角出现“译”按钮，点按开/关翻译。字幕可拖动，双击折叠。",
        @"识别语言代码（BCP-47）：对方英文填 en-US，日文填 ja-JP；我的语言通常 zh-CN。",
        @"自动 = 已填 Key 优先，失败自动切下一个；Google 填了 Key 走 Cloud Translation，不填走免费接口兜底。",
        @"填写 chat/completions 完整地址、Key 与模型名。示例：DeepSeek 地址 + deepseek-chat。",
        @"日志位于 /var/mobile/Library/CallCaption/probe.log",
    ];

    NSMutableArray *tr = [NSMutableArray array];
    for (NSArray *sec in self.sections)
        for (CCRow *r in sec)
            if (r.kind == CCRowKindText) [tr addObject:r];
    self.textRows = tr;
}

// ---------- 读写设置 ----------

- (void)loadValues {
    self.values = [NSMutableDictionary dictionary];
    for (NSArray *sec in self.sections) {
        for (CCRow *r in sec) {
            id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
                       (__bridge CFStringRef)r.key, (__bridge CFStringRef)CC_DOMAIN);
            if (!v) {
                v = (r.kind == CCRowKindSwitch) ? @(r.defBool) : (r.defString ?: @"");
            }
            self.values[r.key] = v;
        }
    }
}

- (NSString *)stringFor:(CCRow *)r {
    id v = self.values[r.key];
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return r.defString ?: @"";
}

- (BOOL)boolFor:(CCRow *)r {
    id v = self.values[r.key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue] || [v isEqualToString:@"YES"] || [v isEqualToString:@"1"];
    return r.defBool;
}

- (void)setPrefValue:(id)value forKey:(NSString *)key {
    if (!key) return;
    self.values[key] = value ?: @"";
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)(value ?: @""),
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CC_NOTIF, NULL, NULL, YES);
}

// ---------- 生命周期 ----------

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self buildModel];
    [self loadValues];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.table];

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
    self.table.contentInset = insets;
    self.table.scrollIndicatorInsets = insets;
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
    CCRow *row = self.sections[(NSUInteger)ip.section][(NSUInteger)ip.row];

    if (row.kind == CCRowKindSwitch) {
        static NSString *cid = @"sw";
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            CCSwitch *sw = [[CCSwitch alloc] initWithFrame:CGRectMake(0, 0, 51, 31)];
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        }
        cell.textLabel.text = row.title;
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        CCSwitch *sw = (CCSwitch *)cell.accessoryView;
        sw.prefKey = row.key;
        sw.on = [self boolFor:row];
        return cell;
    }

    if (row.kind == CCRowKindText) {
        static NSString *cid = @"txt";
        CCRowCell *cell = [tv dequeueReusableCellWithIdentifier:cid];
        if (!cell) cell = [[CCRowCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.nameLabel.text = row.title;
        cell.field.placeholder = row.placeholder;
        cell.field.secureTextEntry = row.secure;
        cell.field.text = [self stringFor:row];
        cell.field.delegate = self;
        cell.field.tag = (NSInteger)[self.textRows indexOfObject:row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    // Choice
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

- (NSString *)titleForChoice:(CCRow *)row value:(NSString *)val {
    NSUInteger i = [row.choiceValues indexOfObject:val];
    if (i != NSNotFound && i < row.choiceTitles.count) return row.choiceTitles[i];
    return row.choiceTitles.firstObject ?: val;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CCRow *row = self.sections[(NSUInteger)ip.section][(NSUInteger)ip.row];
    if (row.kind == CCRowKindText) {
        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
        if ([cell isKindOfClass:[CCRowCell class]])
            [[(CCRowCell *)cell field] becomeFirstResponder];
        return;
    }
    if (row.kind == CCRowKindChoice) {
        [self presentChoices:row cell:[tv cellForRowAtIndexPath:ip]];
    }
}

// ---------- 交互 ----------

- (void)switchChanged:(CCSwitch *)sw {
    [self setPrefValue:@(sw.on) forKey:sw.prefKey];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    if (tf.tag >= 0 && (NSUInteger)tf.tag < self.textRows.count) {
        CCRow *r = self.textRows[(NSUInteger)tf.tag];
        [self setPrefValue:(tf.text ?: @"") forKey:r.key];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

- (void)presentChoices:(CCRow *)row cell:(UITableViewCell *)cell {
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
            [self.table reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = cell ?: self.view;
        sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
