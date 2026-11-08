// CCUI.m — CallCaption v0.13.8 单窗口 UI
// 借鉴 LiveCallTranslator 的窗口模型：
//   1) LiveCallTranslatorWindow : _UIRootWindow，windowLevel = 99998
//   2) 全屏 contentView 常驻，点面板外由 hitTest 直接收起
//   3) 面板 / grabber / 双字幕框都是同一个窗口的子视图
//   4) 字幕更新时取消上一次隐藏任务并重新计时
#import "CCCommon.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>
#import <objc/runtime.h>

#pragma mark - 私有窗口类

// iOS 16 SpringBoard 里真实存在；LCT 就是 _UIRootWindow 子类。
// 如果某个系统版本没有这个类，CreateOverlayWindow 会退回普通 UIWindow。
@interface _UIRootWindow : UIWindow
- (instancetype)initWithScreen:(UIScreen *)screen;
@end

@interface CCPanelWindow : _UIRootWindow
@end

@interface CCUIHelper : NSObject
+ (void)hideCaption;
+ (void)toggleSession;
+ (void)refreshPanel;
+ (void)panelButtonTapped:(UIButton *)b;
+ (void)handlePanelPan:(UIPanGestureRecognizer *)p;
+ (void)handleBoxPan:(UIPanGestureRecognizer *)p;
+ (void)boxTapped:(id)sender;
+ (void)bgCatcherTapped:(id)sender;
+ (void)collapsePanel;
+ (void)expandPanel;
+ (void)handleGrabberPan:(UIPanGestureRecognizer *)p;
+ (void)grabberTapped:(id)sender;
+ (void)showGrabber;
+ (void)hideGrabber;
+ (void)hideGrabberNow;
+ (void)openSettings:(id)sender;
@end

@interface UIWindow (CCOrderPrivate)
- (void)orderFront:(id)sender;
- (void)orderOut:(id)sender;
- (UIView *)contentView;   // 私有：UIWindow 的全屏内容视图
@end

#pragma mark - 全局状态

static UIWindow *g_win;                 // 唯一全屏窗口
static UIViewController *g_rootVC;      // 全屏 rootViewController
static UIView *g_root;                  // 全屏透明容器
static UIControl *g_bgCatcher;          // g_root 下面的全屏兜底点击层
static UIVisualEffectView *g_panelCard; // 底部控制面板
static UILabel *g_titleLabel;
static UIButton *g_btns[5];
static UIButton *g_grabber;             // 收起后的 60x60 地球
static UIView *g_remoteBox;             // 对方双行字幕框
static UIView *g_localBox;              // 我方双行字幕框

static NSTimer *g_remoteHide;
static NSTimer *g_localHide;
static NSTimer *g_grabberHide;

static BOOL g_panelExpanded;
static BOOL g_grabberVisible;
static BOOL g_callActive;
static BOOL g_uiReady;
static BOOL g_boxesBuilt;
static BOOL g_sessionActive;

static NSString *g_texts[4];            // 0 对方原文 / 1 对方译文 / 2 我方原文 / 3 我方译文
static NSString *g_engines[2];          // 0 对方引擎 / 1 我方引擎
static CFAbsoluteTime g_textAt[4];

static CXCallObserver *g_callObs;
static id g_callWatcher;
static UIWindow *g_settingsWin;
static NSString *g_stateText;

#pragma mark - 其他窗口点击兜底

// 我们的 _UIRootWindow 在窗口服务器层面收不到空白区域的触摸；
// 面板展开时，只要触摸落在“别的窗口”上，就收起面板。
// 这是 ObjC 方法 swizzle，不是函数钩子，不会碰音频。
@interface UIWindow (CCOutsideTap)
- (UIView *)cc_outsideHitTest:(CGPoint)point withEvent:(UIEvent *)event;
@end

@implementation UIWindow (CCOutsideTap)
- (UIView *)cc_outsideHitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [self cc_outsideHitTest:point withEvent:event];
    if (g_panelExpanded && g_win && self != g_win) {
        CCLogf(@"panel: outside tap (other window %@)", NSStringFromClass([self class]));
        dispatch_async(dispatch_get_main_queue(), ^{ [CCUIHelper collapsePanel]; });
        return nil;   // 吞掉这一下，避免误触通话界面的静音/挂断
    }
    return hit;
}
@end

static BOOL g_swizzledOutsideTap;
static void InstallOutsideTapSwizzle(void) {
    if (g_swizzledOutsideTap) return;
    Method a = class_getInstanceMethod([UIWindow class], @selector(hitTest:withEvent:));
    Method b = class_getInstanceMethod([UIWindow class], @selector(cc_outsideHitTest:withEvent:));
    if (!a || !b) {
        CCLogf(@"ui: outside tap swizzle skipped a=%p b=%p", a, b);
        return;
    }

    // 关键：UIWindow 自己没实现 hitTest:withEvent: 时，class_getInstanceMethod 会
    // 返回 UIView 的实现。直接交换会把 UIView 的 hitTest 换成我们的方法，
    // 之后任何 UIView 命中测试都会 unrecognized selector → SpringBoard 崩进安全模式。
    // 先把 hitTest 复制到 UIWindow 自己的方法表，再在 UIWindow 内部交换。
    class_addMethod([UIWindow class], @selector(hitTest:withEvent:),
                    method_getImplementation(a), method_getTypeEncoding(a));
    a = class_getInstanceMethod([UIWindow class], @selector(hitTest:withEvent:));
    if (!a) return;
    method_exchangeImplementations(a, b);
    g_swizzledOutsideTap = YES;
    CCLogf(@"ui: outside tap swizzle installed (window-scope)");
}

static CGFloat ScreenW(void) { return [UIScreen mainScreen].bounds.size.width; }
static CGFloat ScreenH(void) { return [UIScreen mainScreen].bounds.size.height; }
static CGFloat CardWidth(void) { return MIN(ScreenW() * 0.92, 430.0); }

static UIColor *BlueTitle(void)  { return [UIColor colorWithRed:0.46 green:0.68 blue:1.00 alpha:1]; }
static UIColor *GreenTitle(void) { return [UIColor colorWithRed:0.48 green:0.90 blue:0.58 alpha:1]; }
static UIColor *TransColor(void) { return [UIColor colorWithRed:1.00 green:0.86 blue:0.38 alpha:1]; }

static void SavePos(NSString *kx, NSString *ky, CGPoint c) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kx, (__bridge CFPropertyListRef)@(c.x),
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesSetAppValue((__bridge CFStringRef)ky, (__bridge CFPropertyListRef)@(c.y),
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
}

static CGFloat TextHeight(NSString *s, UIFont *f, CGFloat w) {
    if (s.length == 0) return 0;
    CGRect r = [s boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                              options:NSStringDrawingUsesLineFragmentOrigin
                           attributes:@{NSFontAttributeName: f} context:nil];
    return ceil(r.size.height);
}

static BOOL DeepLKeyAvailable(void) {
    if (CCPrefStr(CC_K_DEEPL_KEY, @"").length) return YES;
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/net.limneos.livecalltranslator.plist"];
    id v = d[@"DEEPL_API_KEY"];
    return [v isKindOfClass:[NSString class]] && [v length] > 0;
}

static NSString *CCEngineName(NSString *eng) {
    NSString *e = [eng lowercaseString];
    if (e.length == 0 || [e isEqualToString:@"auto"]) {
        e = [CCPrefStr(CC_K_ENGINE, @"auto") lowercaseString];
        if ([e isEqualToString:@"auto"]) {
            if (CCPrefStr(CC_K_DEEPL_KEY, @"").length) return @"DeepL";
            if (CCPrefStr(CC_K_AI_URL, @"").length) return @"AI";
            return @"Google";
        }
    }
    if ([e isEqualToString:@"deepl"]) return @"DeepL";
    if ([e isEqualToString:@"google"]) return @"Google";
    if ([e isEqualToString:@"mymemory"] || [e isEqualToString:@"bing"]) return @"MyMemory";
    if ([e isEqualToString:@"ai"]) return @"AI";
    if ([e isEqualToString:@"cache"]) return @"缓存";
    return @"翻译服务";
}

#pragma mark - 窗口

static void ShowWindow(void) {
    if (!g_win) return;
    CGRect scr = [UIScreen mainScreen].bounds;
    g_win.frame = scr;
    UIView *cv = g_win.contentView;
    if (cv) {
        cv.frame = scr;
        cv.userInteractionEnabled = YES;
        cv.backgroundColor = [UIColor clearColor];
    }
    if (g_root) g_root.frame = scr;
    if (g_bgCatcher) g_bgCatcher.frame = scr;
    g_win.hidden = NO;
    if ([g_win respondsToSelector:@selector(orderFront:)]) {
        @try { [g_win orderFront:nil]; } @catch (NSException *e) { }
    }
    CCLogf(@"window: orderFront class=%@ scene=%@ hidden=%d frame=%@ content=%@ root=%@",
           NSStringFromClass([g_win class]), g_win.windowScene, g_win.hidden,
           NSStringFromCGRect(g_win.frame),
           NSStringFromCGRect(cv ? cv.frame : CGRectZero),
           NSStringFromCGRect(g_root ? g_root.frame : CGRectZero));
    // _UIRootWindow 可能在 orderFront/layout 时把 contentView 重置成 0x0，
    // 延迟再设一次，保证命中区域是全屏。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!g_win) return;
        UIView *c2 = g_win.contentView;
        if (c2) {
            c2.frame = [UIScreen mainScreen].bounds;
            c2.userInteractionEnabled = YES;
            CCLogf(@"ui: contentView re-layout frame=%@", NSStringFromCGRect(c2.frame));
        }
    });
}

static void HideWindow(void) {
    if (!g_win) return;
    if ([g_win respondsToSelector:@selector(orderOut:)]) {
        @try { [g_win orderOut:nil]; } @catch (NSException *e) { }
    }
    g_win.hidden = YES;
    CCLogf(@"window: orderOut");
}

static UIWindow *CreateOverlayWindow(void) {
    UIWindow *win = nil;
    Class rootCls = NSClassFromString(@"_UIRootWindow");
    if (rootCls) {
        @try {
            win = [[CCPanelWindow alloc] initWithScreen:[UIScreen mainScreen]];
        } @catch (NSException *e) {
            CCLogf(@"window: initWithScreen exc %@", e.reason);
            win = nil;
        }
    }
    if (!win) {
        win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        CCLogf(@"window: fallback UIWindow");
    }
    win.frame = [UIScreen mainScreen].bounds;
    win.windowLevel = 99998;
    win.backgroundColor = [UIColor clearColor];
    win.opaque = NO;
    CCLogf(@"window: created class=%@ level=%.0f", NSStringFromClass([win class]), win.windowLevel);
    return win;
}

@implementation CCPanelWindow

- (BOOL)_ignoresHitTest { return NO; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (BOOL)_isSecure { return YES; }

// LCT 的核心：全屏窗口自己判断“点的是不是空白背景”。
// 空白背景且面板展开 → 立即收起；返回 nil 让触摸继续传给通话界面。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];

    // 关键：super 返回 nil 也按“空白背景”处理。
    // 不再假设空背景一定会返回 g_root/contentView，避免点了半天什么都不发生。
    BOOL background = (!hit || hit == g_root || hit == g_root.superview ||
                       hit == g_bgCatcher || hit == self.contentView || hit == self);
    if (!background) {
        CCLogf(@"hitTest: %@", NSStringFromClass([hit class]));
        return hit;
    }
    if (!hit)
        CCLogf(@"hitTest: nil bg at %.0f,%.0f root=%@",
               point.x, point.y, NSStringFromCGRect(g_root ? g_root.frame : CGRectZero));

    if (g_panelExpanded) {
        CCLogf(@"panel: outside tap (hitTest)");
        [CCUIHelper collapsePanel];
    } else if (g_callActive && !g_grabberVisible) {
        [CCUIHelper showGrabber];
    }
    return nil;
}

@end

#pragma mark - 前向声明

static void CCUIHandleCallActive(BOOL active);
static void RefreshBoxes(void);
static void EnsureUI(void);

#pragma mark - 通话观察

@interface CCUICallWatcher : NSObject <CXCallObserverDelegate>
@end
@implementation CCUICallWatcher
- (void)callObserver:(CXCallObserver *)observer callChanged:(CXCall *)call {
    BOOL active = NO;
    for (CXCall *c in observer.calls) {
        if (!c.hasEnded) { active = YES; break; }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ CCUIHandleCallActive(active); });
}
@end

#pragma mark - 设置面板

static void AttachSceneForSettings(UIWindow *win) {
    if (@available(iOS 13.0, *)) {
        if (win.windowScene) return;
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw && kw.windowScene) { win.windowScene = kw.windowScene; return; }
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                win.windowScene = (UIWindowScene *)sc;
                break;
            }
        }
    }
}

// 长按面板/地球，兜底打开 SpringBoard 内自绘设置（正式入口仍在 Settings.app）
static void CCOpenSettingsWindow(void) {
    @try {
        if (!g_settingsWin) {
            Class cls = NSClassFromString(@"CCSettingsController");
            if (!cls) { CCLogf(@"settings: class missing"); return; }
            g_settingsWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            g_settingsWin.windowLevel = 100000;
            UIViewController *vc = [[cls alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            g_settingsWin.rootViewController = nav;
            AttachSceneForSettings(g_settingsWin);
        }
        g_settingsWin.hidden = NO;
        if ([g_settingsWin respondsToSelector:@selector(orderFront:)]) {
            @try { [g_settingsWin orderFront:nil]; } @catch (NSException *e) { }
        }
        CCLogf(@"settings: opened in SpringBoard");
    } @catch (NSException *e) { CCLogf(@"settings exc: %@", e.reason); }
}

#pragma mark - 面板 UI

static void EnsurePanelUI(void) {
    if (g_panelCard) return;
    CGFloat w = CardWidth();
    CGFloat h = 150.0;
    CGFloat y = ScreenH() - h - 100.0;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    blur.frame = CGRectMake((ScreenW() - w) / 2.0, y, w, h);
    blur.layer.cornerRadius = 22;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.8;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [g_root addSubview:blur];
    g_panelCard = blur;

    UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
    ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
    ov.userInteractionEnabled = NO;
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [blur.contentView addSubview:ov];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(w - 42, 8, 30, 30);
    UIImage *closeImg = [UIImage systemImageNamed:@"xmark"
                               withConfiguration:[UIImageSymbolConfiguration
                                   configurationWithPointSize:13 weight:UIFontWeightSemibold]];
    [closeBtn setImage:closeImg forState:UIControlStateNormal];
    closeBtn.tintColor = [UIColor colorWithWhite:1 alpha:0.65];
    [closeBtn addTarget:[CCUIHelper class] action:@selector(collapsePanel)
       forControlEvents:UIControlEventTouchUpInside];
    [blur.contentView addSubview:closeBtn];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, w, 18)];
    title.text = @"CallCaption";
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    title.textAlignment = NSTextAlignmentCenter;
    title.adjustsFontSizeToFitWidth = YES;
    title.minimumScaleFactor = 0.8;
    [blur.contentView addSubview:title];
    g_titleLabel = title;

    NSArray *symbols = @[@"globe", @"mic.fill", @"speaker.wave.2.fill",
                         @"eye.fill", @"character.bubble.fill"];
    NSArray *names = @[@"激活", @"我方", @"对方", @"原文", @"译文"];
    CGFloat bw = 56.0;
    CGFloat gap = (w - 5 * bw) / 6.0;
    for (int i = 0; i < 5; i++) {
        CGFloat x = gap + i * (bw + gap);
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, 36, bw, bw);
        b.tag = i;
        b.layer.cornerRadius = bw / 2.0;
        b.layer.masksToBounds = YES;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        UIImage *img = [UIImage systemImageNamed:symbols[i]
                           withConfiguration:[UIImageSymbolConfiguration
                               configurationWithPointSize:22 weight:UIFontWeightMedium]];
        [b setImage:img forState:UIControlStateNormal];
        b.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
        [b addTarget:[CCUIHelper class] action:@selector(panelButtonTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [blur.contentView addSubview:b];
        g_btns[i] = b;

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(x - 10, 96, bw + 20, 14)];
        l.text = names[i];
        l.font = [UIFont systemFontOfSize:11];
        l.textColor = [UIColor colorWithWhite:1 alpha:0.65];
        l.textAlignment = NSTextAlignmentCenter;
        [blur.contentView addSubview:l];
    }

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(handlePanelPan:)];
    [blur addGestureRecognizer:pan];

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(openSettings:)];
    [blur addGestureRecognizer:lp];

    blur.hidden = YES;
}

#pragma mark - Grabber

static void EnsureGrabberUI(void) {
    if (g_grabber) return;
    CGFloat s = 60.0;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, s, s);
    b.layer.cornerRadius = s / 2.0;
    b.layer.masksToBounds = YES;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.18].CGColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
    UIImage *img = [UIImage systemImageNamed:@"globe"
                       withConfiguration:[UIImageSymbolConfiguration
                           configurationWithPointSize:26 weight:UIFontWeightMedium]];
    [b setImage:img forState:UIControlStateNormal];
    b.tintColor = [UIColor colorWithWhite:0.12 alpha:1];
    [b addTarget:[CCUIHelper class] action:@selector(grabberTapped:)
        forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(handleGrabberPan:)];
    [b addGestureRecognizer:pan];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(openSettings:)];
    [b addGestureRecognizer:lp];

    NSNumber *gx = CCPref(@"GrabberX"), *gy = CCPref(@"GrabberY");
    if ([gx isKindOfClass:[NSNumber class]] && [gy isKindOfClass:[NSNumber class]]) {
        b.center = CGPointMake([gx floatValue], [gy floatValue]);
    } else {
        b.center = CGPointMake(ScreenW() - 46.0, ScreenH() * 0.55);
    }
    b.hidden = YES;
    [g_root addSubview:b];
    g_grabber = b;
    CCLogf(@"grabber: created center=%.0f,%.0f size=%.0f", b.center.x, b.center.y, s);
}

#pragma mark - 字幕框

static UIView *MakeBox(NSString *recogHeader) {
    CGFloat w = CardWidth();
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = CGRectMake(0, 0, w, 10);
    blur.layer.cornerRadius = 18;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.8;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

    UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
    ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
    ov.userInteractionEnabled = NO;
    ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [blur.contentView addSubview:ov];

    UILabel *h = [[UILabel alloc] initWithFrame:CGRectZero];
    h.tag = 1001;
    h.text = recogHeader;
    h.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    h.textColor = BlueTitle();
    h.textAlignment = NSTextAlignmentCenter;
    [blur.contentView addSubview:h];

    UILabel *r = [[UILabel alloc] initWithFrame:CGRectZero];
    r.tag = 1002;
    r.font = [UIFont systemFontOfSize:15];
    r.textColor = [UIColor colorWithWhite:1 alpha:0.96];
    r.numberOfLines = 0;
    [blur.contentView addSubview:r];

    UILabel *sh = [[UILabel alloc] initWithFrame:CGRectZero];
    sh.tag = 1003;
    sh.text = @"Did speak:";
    sh.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    sh.textColor = GreenTitle();
    sh.textAlignment = NSTextAlignmentCenter;
    [blur.contentView addSubview:sh];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
    t.tag = 1004;
    t.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    t.textColor = TransColor();
    t.numberOfLines = 0;
    [blur.contentView addSubview:t];

    UILabel *c = [[UILabel alloc] initWithFrame:CGRectZero];
    c.tag = 1005;
    c.text = @"Translated by …";
    c.font = [UIFont systemFontOfSize:11];
    c.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    c.textAlignment = NSTextAlignmentRight;
    [blur.contentView addSubview:c];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(handleBoxPan:)];
    [blur addGestureRecognizer:pan];

    // 点字幕框（面板外）也应收起面板；拖动仍走 pan。
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(boxTapped:)];
    [blur addGestureRecognizer:tap];

    [g_root addSubview:blur];
    return blur;
}

static void EnsureCaptionUI(void) {
    if (g_boxesBuilt) return;
    g_remoteBox = MakeBox(@"Recognized Remote:");
    NSNumber *rx = CCPref(@"RemoteBoxX"), *ry = CCPref(@"RemoteBoxY");
    if ([rx isKindOfClass:[NSNumber class]] && [ry isKindOfClass:[NSNumber class]]) {
        g_remoteBox.center = CGPointMake([rx floatValue], [ry floatValue]);
    } else {
        g_remoteBox.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 520);
    }

    g_localBox = MakeBox(@"Recognized Local:");
    NSNumber *lx = CCPref(@"LocalBoxX"), *ly = CCPref(@"LocalBoxY");
    if ([lx isKindOfClass:[NSNumber class]] && [ly isKindOfClass:[NSNumber class]]) {
        g_localBox.center = CGPointMake([lx floatValue], [ly floatValue]);
    } else {
        g_localBox.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 340);
    }
    g_remoteBox.hidden = YES;
    g_localBox.hidden = YES;
    g_boxesBuilt = YES;
}

static void LayoutBox(UIView *box, NSString *recog, NSString *trans, NSString *engine,
                      BOOL showRecog, BOOL showTrans) {
    if (!box) return;
    UILabel *h = (UILabel *)[box viewWithTag:1001];
    UILabel *r = (UILabel *)[box viewWithTag:1002];
    UILabel *sh = (UILabel *)[box viewWithTag:1003];
    UILabel *t = (UILabel *)[box viewWithTag:1004];
    UILabel *c = (UILabel *)[box viewWithTag:1005];
    CGFloat w = box.bounds.size.width;
    CGFloat pad = 16.0;
    CGFloat cw = w - pad * 2.0;
    CGFloat y = 14.0;
    BOOL any = NO;

    if (showRecog && recog.length) {
        any = YES;
        h.hidden = NO; r.hidden = NO;
        h.frame = CGRectMake(0, y, w, 16); y += 20.0;
        r.text = recog;
        r.font = [UIFont systemFontOfSize:15];
        CGFloat hh = TextHeight(recog, r.font, cw);
        r.frame = CGRectMake(pad, y, cw, hh); y += hh + 12.0;
    } else {
        h.hidden = YES; r.hidden = YES;
    }

    if (showTrans && trans.length) {
        any = YES;
        sh.hidden = NO; t.hidden = NO; c.hidden = NO;
        sh.frame = CGRectMake(0, y, w, 16); y += 20.0;
        t.text = trans;
        t.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        CGFloat hh = TextHeight(trans, t.font, cw);
        t.frame = CGRectMake(pad, y, cw, hh); y += hh + 14.0;
        c.text = [NSString stringWithFormat:@"Translated by %@", CCEngineName(engine)];
        c.frame = CGRectMake(pad, y, cw, 14); y += 18.0;
    } else {
        sh.hidden = YES; t.hidden = YES; c.hidden = YES;
    }

    if (!any) { box.hidden = YES; return; }
    CGRect f = box.frame;
    CGPoint cen = box.center;
    f.size.height = y;
    box.frame = f;
    box.center = cen;
    box.hidden = NO;
    box.alpha = 1.0;
}

static void ResetRemoteTimer(void) {
    [g_remoteHide invalidate];
    g_remoteHide = [NSTimer timerWithTimeInterval:15.0 target:[CCUIHelper class]
                                          selector:@selector(hideCaption)
                                          userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_remoteHide forMode:NSRunLoopCommonModes];
}
static void ResetLocalTimer(void) {
    [g_localHide invalidate];
    g_localHide = [NSTimer timerWithTimeInterval:15.0 target:[CCUIHelper class]
                                         selector:@selector(hideCaption)
                                         userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_localHide forMode:NSRunLoopCommonModes];
}

static void RefreshBoxes(void) {
    if (!g_boxesBuilt) return;
    BOOL active = g_callActive || CCPrefBool(CC_K_ALWAYS_PANEL, NO);
    if (!active) {
        g_remoteBox.hidden = YES;
        g_localBox.hidden = YES;
        return;
    }
    BOOL showR = CCPrefBool(CC_K_SHOW_RECOGNIZED, YES);
    BOOL showT = CCPrefBool(CC_K_SHOW_TRANSLATED, YES);
    BOOL remoteOn = CCPrefBool(CC_K_REMOTE_ENABLED, YES);
    BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, NO);

    LayoutBox(g_remoteBox, g_texts[0], g_texts[1], g_engines[0], showR, showT);
    if (!remoteOn) g_remoteBox.hidden = YES;
    LayoutBox(g_localBox, g_texts[2], g_texts[3], g_engines[1], showR, showT);
    if (!localOn) g_localBox.hidden = YES;

    if (!g_remoteBox.hidden) ResetRemoteTimer();
    if (!g_localBox.hidden) ResetLocalTimer();
}

#pragma mark - 交付

static void DeliverText(int idx, NSString *text) {
    if (idx < 0 || idx > 3) return;
    text = text ?: @"";
    if (!g_boxesBuilt) return;
    if (!g_callActive && !CCPrefBool(CC_K_ALWAYS_PANEL, NO)) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (text.length && [g_texts[idx] isEqualToString:text] && now - g_textAt[idx] < 1.5)
        return;   // 同一句短时间重复：不要反复重置隐藏计时器

    g_texts[idx] = text;
    g_textAt[idx] = now;
    RefreshBoxes();
}

void CCUIDeliverRemoteOriginal(NSString *text)  { DeliverText(0, text); }
void CCUIDeliverRemoteTranslated(NSString *text){ DeliverText(1, text); }
void CCUIDeliverLocalOriginal(NSString *text)   { DeliverText(2, text); }
void CCUIDeliverLocalTranslated(NSString *text) { DeliverText(3, text); }

void CCUIDeliverRemoteEngine(NSString *engine) {
    if (!engine.length) return;
    if ([g_engines[0] isEqualToString:engine]) return;
    g_engines[0] = engine;
    if (g_boxesBuilt) RefreshBoxes();
}
void CCUIDeliverLocalEngine(NSString *engine) {
    if (!engine.length) return;
    if ([g_engines[1] isEqualToString:engine]) return;
    g_engines[1] = engine;
    if (g_boxesBuilt) RefreshBoxes();
}

void CCUIDeliverState(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_stateText = state ?: @"";
        CCLogf(@"ui state: %@", g_stateText);
    });
}

void CCUIDeliverCaption(NSString *translated) { CCUIDeliverRemoteTranslated(translated); }
void CCUIDeliverOriginal(NSString *original)  { CCUIDeliverRemoteOriginal(original); }

void CCUIClearCaptions(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int i = 0; i < 4; i++) {
            g_texts[i] = @"";
            g_textAt[i] = 0;
        }
        g_engines[0] = nil;
        g_engines[1] = nil;
        [g_remoteHide invalidate]; g_remoteHide = nil;
        [g_localHide invalidate];  g_localHide = nil;
        if (g_remoteBox) { g_remoteBox.hidden = YES; g_remoteBox.alpha = 1.0; }
        if (g_localBox)  { g_localBox.hidden = YES;  g_localBox.alpha = 1.0; }
    });
}

void CCUIRefreshPanel(void) { [[CCUIHelper class] refreshPanel]; }

#pragma mark - 交互

@implementation CCUIHelper

+ (void)hideCaption {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_remoteHide invalidate]; g_remoteHide = nil;
        [g_localHide invalidate];  g_localHide = nil;
        // 30 秒隐藏后把文本也清掉，避免再点地球/面板时旧字幕“复活”。
        for (int i = 0; i < 4; i++) { g_texts[i] = @""; g_textAt[i] = 0; }
        g_engines[0] = nil;
        g_engines[1] = nil;
        if (g_remoteBox && !g_remoteBox.hidden) {
            [UIView animateWithDuration:0.25 animations:^{ g_remoteBox.alpha = 0; }];
        }
        if (g_localBox && !g_localBox.hidden) {
            [UIView animateWithDuration:0.25 animations:^{ g_localBox.alpha = 0; }];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_remoteBox && g_remoteBox.alpha < 0.05) { g_remoteBox.hidden = YES; g_remoteBox.alpha = 1.0; }
            if (g_localBox && g_localBox.alpha < 0.05)  { g_localBox.hidden = YES;  g_localBox.alpha = 1.0; }
        });
    });
}

+ (void)toggleSession {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_sessionActive && !g_callActive) {
            CCLogf(@"session: no active call, ignore arm");
            return;
        }
        if (!g_sessionActive && !CCPrefBool(CC_K_ENABLED, YES)) {
            CCLogf(@"session: master disabled, ignore arm");
            return;
        }
        g_sessionActive = !g_sessionActive;
        CCSetArmed(g_sessionActive);
        [self refreshPanel];
        CCLogf(@"session %@", g_sessionActive ? @"ARMED" : @"DISARMED");
        if (!g_sessionActive) {
            CCUIClearCaptions();
        }
    });
}

+ (void)refreshPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        BOOL enabled = CCPrefBool(CC_K_ENABLED, YES);
        if (!enabled && g_sessionActive) {
            g_sessionActive = NO;
            CCSetArmed(NO);
            CCUIClearCaptions();
        }
        BOOL st[5] = {
            g_sessionActive,
            CCPrefBool(CC_K_LOCAL_ENABLED, NO),
            CCPrefBool(CC_K_REMOTE_ENABLED, YES),
            CCPrefBool(CC_K_SHOW_RECOGNIZED, YES),
            CCPrefBool(CC_K_SHOW_TRANSLATED, YES),
        };
        for (int i = 0; i < 5; i++) {
            UIButton *b = g_btns[i];
            if (!b) continue;
            if (st[i]) {
                b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
                b.tintColor = [UIColor colorWithWhite:0.12 alpha:1];
            } else {
                b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
                b.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
            }
        }
        if (g_titleLabel) {
            NSString *eng = [CCPrefStr(CC_K_ENGINE, @"auto") lowercaseString];
            if ([eng isEqualToString:@"deepl"] && !DeepLKeyAvailable()) {
                g_titleLabel.text = @"CallCaption · DeepL Key 未填";
                g_titleLabel.textColor = [UIColor colorWithRed:1.0 green:0.76 blue:0.30 alpha:1];
            } else {
                g_titleLabel.text = @"CallCaption";
                g_titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
            }
        }
        RefreshBoxes();
    });
}

+ (void)panelButtonTapped:(UIButton *)b {
    CCLogf(@"panel button tag=%ld", (long)b.tag);
    switch (b.tag) {
        case 0:
            [self toggleSession];
            break;
        case 1:
            CCSetPrefBool(CC_K_LOCAL_ENABLED, !CCPrefBool(CC_K_LOCAL_ENABLED, NO));
            g_texts[2] = g_texts[3] = @"";
            g_engines[1] = nil;
            break;
        case 2:
            CCSetPrefBool(CC_K_REMOTE_ENABLED, !CCPrefBool(CC_K_REMOTE_ENABLED, YES));
            g_texts[0] = g_texts[1] = @"";
            g_engines[0] = nil;
            break;
        case 3:
            CCSetPrefBool(CC_K_SHOW_RECOGNIZED, !CCPrefBool(CC_K_SHOW_RECOGNIZED, YES));
            break;
        case 4:
            CCSetPrefBool(CC_K_SHOW_TRANSLATED, !CCPrefBool(CC_K_SHOW_TRANSLATED, YES));
            break;
    }
    [self refreshPanel];
}

+ (void)collapsePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_panelExpanded) return;
        CCLogf(@"panel: collapse");
        g_panelExpanded = NO;
        [UIView animateWithDuration:0.20 animations:^{ g_panelCard.alpha = 0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!g_panelExpanded) { g_panelCard.hidden = YES; g_panelCard.alpha = 1.0; }
        });
        [self showGrabber];
    });
}

+ (void)expandPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        ShowWindow();
        CCLogf(@"panel: expand");
        g_panelExpanded = YES;
        [self hideGrabberNow];
        g_panelCard.hidden = NO;
        g_panelCard.alpha = 0;
        [UIView animateWithDuration:0.20 animations:^{ g_panelCard.alpha = 1.0; }];
        [self refreshPanel];
    });
}

+ (void)showGrabber {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_grabber) return;
        if (!g_callActive && !CCPrefBool(CC_K_ALWAYS_PANEL, NO)) return;
        [g_grabberHide invalidate];
        g_grabber.hidden = NO;
        g_grabber.alpha = 1.0;
        g_grabberVisible = YES;
        CCLogf(@"grabber: show persistent center=%.0f,%.0f alpha=%.2f",
               g_grabber.center.x, g_grabber.center.y, g_grabber.alpha);
    });
}

+ (void)hideGrabber {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_grabberHide invalidate]; g_grabberHide = nil;
        if (!g_grabber || g_grabber.hidden) { g_grabberVisible = NO; return; }
        [UIView animateWithDuration:0.25 animations:^{ g_grabber.alpha = 0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_grabber.alpha < 0.05) {
                g_grabber.hidden = YES;
                g_grabber.alpha = 1.0;
                g_grabberVisible = NO;
            }
        });
    });
}

+ (void)hideGrabberNow {
    [g_grabberHide invalidate]; g_grabberHide = nil;
    if (g_grabber) {
        g_grabber.hidden = YES;
        g_grabber.alpha = 1.0;
    }
    g_grabberVisible = NO;
}

+ (void)grabberTapped:(id)sender {
    [g_grabberHide invalidate]; g_grabberHide = nil;
    [self expandPanel];
}

+ (void)openSettings:(id)sender {
    CCOpenSettingsWindow();
}

+ (void)handlePanelPan:(UIPanGestureRecognizer *)p {
    UIView *card = g_panelCard;
    if (!card) return;
    CGPoint t = [p translationInView:g_root];
    CGRect f = card.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    if (f.origin.x < 0) f.origin.x = 0;
    if (f.origin.x > ScreenW() - f.size.width) f.origin.x = ScreenW() - f.size.width;
    if (f.origin.y < 60) f.origin.y = 60;
    if (f.origin.y > ScreenH() - 120) f.origin.y = ScreenH() - 120;
    card.frame = f;
    [p setTranslation:CGPointZero inView:g_root];
}

+ (void)handleGrabberPan:(UIPanGestureRecognizer *)p {
    if (!g_grabber) return;
    [g_grabberHide invalidate]; g_grabberHide = nil;
    CGPoint t = [p translationInView:g_root];
    CGPoint c = g_grabber.center;
    c.x += t.x;
    c.y += t.y;
    if (c.x < 30) c.x = 30;
    if (c.x > ScreenW() - 30) c.x = ScreenW() - 30;
    if (c.y < 70) c.y = 70;
    if (c.y > ScreenH() - 40) c.y = ScreenH() - 40;
    g_grabber.center = c;
    [p setTranslation:CGPointZero inView:g_root];
    if (p.state == UIGestureRecognizerStateEnded) {
        SavePos(@"GrabberX", @"GrabberY", c);
        [self showGrabber];
    }
}

+ (void)bgCatcherTapped:(id)sender {
    CCLogf(@"panel: outside tap (catcher)");
    if (g_panelExpanded) [self collapsePanel];
    else if (g_callActive && !g_grabberVisible) [self showGrabber];
}

+ (void)boxTapped:(id)sender {
    if (g_panelExpanded) {
        CCLogf(@"panel: outside tap (box)");
        [self collapsePanel];
    } else if (g_callActive && !g_grabberVisible) {
        [self showGrabber];
    }
}

+ (void)handleBoxPan:(UIPanGestureRecognizer *)p {
    UIView *box = p.view;
    if (!box) return;
    CGPoint t = [p translationInView:g_root];
    CGPoint c = box.center;
    c.x += t.x;
    c.y += t.y;
    if (c.x < 80) c.x = 80;
    if (c.x > ScreenW() - 80) c.x = ScreenW() - 80;
    if (c.y < 80) c.y = 80;
    if (c.y > ScreenH() - 60) c.y = ScreenH() - 60;
    box.center = c;
    [p setTranslation:CGPointZero inView:g_root];
    if (p.state == UIGestureRecognizerStateEnded) {
        if (box == g_remoteBox) SavePos(@"RemoteBoxX", @"RemoteBoxY", c);
        else SavePos(@"LocalBoxX", @"LocalBoxY", c);
    }
}

@end

#pragma mark - 通话状态

static void CCUIHandleCallActive(BOOL active) {
    if (g_callActive == active) return;
    g_callActive = active;
    CCLogf(@"call state: %@", active ? @"ACTIVE" : @"NONE");
    EnsureUI();

    if (active) {
        if (!g_sessionActive && CCPrefBool(CC_K_ENABLED, YES)) {
            g_sessionActive = YES;
            CCSetArmed(YES);
        }
        CCUIClearCaptions();
        ShowWindow();
        g_panelExpanded = NO;
        g_panelCard.hidden = YES;
        g_panelCard.alpha = 1.0;
        [CCUIHelper showGrabber];
        if (CCPrefBool(CC_K_ALWAYS_PANEL, NO)) [CCUIHelper expandPanel];
        [CCUIHelper refreshPanel];
    } else {
        if (g_sessionActive) {
            g_sessionActive = NO;
            CCSetArmed(NO);
        }
        CCUIClearCaptions();
        [g_grabberHide invalidate]; g_grabberHide = nil;
        if (g_grabber) { g_grabber.hidden = YES; g_grabber.alpha = 1.0; }
        g_grabberVisible = NO;
        g_panelExpanded = NO;
        g_panelCard.hidden = YES;
        g_panelCard.alpha = 1.0;
        if (CCPrefBool(CC_K_ALWAYS_PANEL, NO)) {
            ShowWindow();
            [CCUIHelper expandPanel];
        } else {
            HideWindow();
        }
    }
}

#pragma mark - TTS

static AVSpeechSynthesizer *g_tts;

void CCUISpeakText(NSString *text) {
    if (text.length == 0) return;
    @try {
        double dur = 0.9 + 0.075 * (double)text.length;
        if (dur > 20.0) dur = 20.0;
        double until = [[NSDate date] timeIntervalSince1970] + dur;
        NSString *s = [NSString stringWithFormat:@"%.3f", until];
        [s writeToFile:@"/var/mobile/Library/CallCaption/tts_until"
             atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) { }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_tts) g_tts = [[AVSpeechSynthesizer alloc] init];
            [g_tts stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
            AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
            NSString *vid = CCPrefStr(CC_K_TTS_VOICE, @"");
            AVSpeechSynthesisVoice *v = vid.length ? [AVSpeechSynthesisVoice voiceWithIdentifier:vid] : nil;
            u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
            [g_tts speakUtterance:u];
        } @catch (NSException *e) { }
    });
}

void CCUICallStateChanged(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([state isEqualToString:@"CALL ENDED"]) CCUIHandleCallActive(NO);
    });
}

#pragma mark - 启动

static void EnsureUI(void) {
    if (g_win) return;
    @try {
        InstallOutsideTapSwizzle();
        g_win = CreateOverlayWindow();
        CGRect scr = [UIScreen mainScreen].bounds;
        g_win.frame = scr;

        // 关键：直接用 window.contentView 作为全屏容器。
        // 0.13.15 日志里 contentView 是 {{0,0},{0,0}}，窗口命中区域为 0，
        // 所以满屏点击都进不了 hitTest；按钮因为渲染在窗口子视图里还能点到。
        g_win.rootViewController = nil;
        UIView *cv = g_win.contentView;
        if (!cv) {
            cv = [[UIView alloc] initWithFrame:scr];
            [g_win addSubview:cv];
        }
        cv.frame = scr;
        cv.backgroundColor = [UIColor clearColor];
        cv.userInteractionEnabled = YES;
        cv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // 全屏兜底点击层：放在 g_root 下面，g_root 不接管空白区域时由它接。
        g_bgCatcher = [[UIControl alloc] initWithFrame:scr];
        g_bgCatcher.backgroundColor = [UIColor clearColor];
        g_bgCatcher.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [g_bgCatcher addTarget:[CCUIHelper class] action:@selector(bgCatcherTapped:)
              forControlEvents:UIControlEventTouchUpInside];
        [cv addSubview:g_bgCatcher];

        g_root = [[UIView alloc] initWithFrame:scr];
        g_root.backgroundColor = [UIColor clearColor];
        g_root.userInteractionEnabled = YES;
        g_root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [cv addSubview:g_root];
        CCLogf(@"ui: windowFrame=%@ rootFrame=%@ catcherFrame=%@ contentFrame=%@",
               NSStringFromCGRect(g_win.frame), NSStringFromCGRect(g_root.frame),
               NSStringFromCGRect(g_bgCatcher.frame), NSStringFromCGRect(cv.frame));

        EnsurePanelUI();
        EnsureGrabberUI();
        EnsureCaptionUI();

        g_panelExpanded = NO;
        g_grabberVisible = NO;
        g_panelCard.hidden = YES;
        g_grabber.hidden = YES;
        HideWindow();
    } @catch (NSException *e) {
        CCLogf(@"ui ensure exc: %@", e.reason);
    }
}

void CCUIBoot(void) {
    @try {
        if (!CCIsSpringBoard() || g_uiReady) return;
        g_uiReady = YES;
        CCMark(@"ui 8.1 boot enter");
        CCTransportBoot();
        @try { [[NSFileManager defaultManager] removeItemAtPath:CC_ARM_PATH error:nil]; }
        @catch (NSException *e) { }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            @try {
                EnsureUI();
                if (!g_callObs) {
                    g_callWatcher = [CCUICallWatcher new];
                    g_callObs = [[CXCallObserver alloc] init];
                    [g_callObs setDelegate:g_callWatcher queue:dispatch_get_main_queue()];
                }
                BOOL active = NO;
                for (CXCall *c in g_callObs.calls) {
                    if (!c.hasEnded) { active = YES; break; }
                }
                // 强制走一次状态处理（g_callActive 初值不是真实状态）
                g_callActive = !active;
                CCUIHandleCallActive(active);
                if (!active && CCPrefBool(CC_K_ALWAYS_PANEL, NO)) {
                    ShowWindow();
                    [CCUIHelper expandPanel];
                }
            } @catch (NSException *e) {
                CCLogf(@"ui boot exc: %@", e.reason);
            }
        });
        CCLogLine(@"CallCaption UI booted (single window v0.14.0-alpha9)");
    } @catch (NSException *e) {
        CCMark(@"ui BOOT EXCEPTION!");
    }
}
