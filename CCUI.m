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
#import <Speech/Speech.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <stdio.h>

static void CCTTSBuffer(NSString *text, NSString *lang, NSString *fileName);

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
static void CCStreamCallActive(BOOL active);
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
    // LCT 风格：面板放在屏幕中间偏上，不再贴底
    CGFloat y = (ScreenH() - h) / 2.0 - 40.0;

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
    sh.text = @"译文：";
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
    g_remoteBox = MakeBox(@"来电语音");
    NSNumber *rx = CCPref(@"RemoteBoxX"), *ry = CCPref(@"RemoteBoxY");
    if ([rx isKindOfClass:[NSNumber class]] && [ry isKindOfClass:[NSNumber class]]) {
        g_remoteBox.center = CGPointMake([rx floatValue], [ry floatValue]);
    } else {
        g_remoteBox.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 520);
    }

    g_localBox = MakeBox(@"去电语音");
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
    g_remoteHide = [NSTimer timerWithTimeInterval:5.0 target:[CCUIHelper class]
                                          selector:@selector(hideCaption)
                                          userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_remoteHide forMode:NSRunLoopCommonModes];
}
static void ResetLocalTimer(void) {
    [g_localHide invalidate];
    g_localHide = [NSTimer timerWithTimeInterval:5.0 target:[CCUIHelper class]
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
    BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, YES);

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
    // 只要字幕出现，小面板必须处于收回状态
    if (g_panelExpanded) {
        [CCUIHelper collapsePanel];   // collapsePanel 里会 RefreshBoxes
    } else {
        RefreshBoxes();
    }
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
            CCPrefBool(CC_K_LOCAL_ENABLED, YES),
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
            CCSetPrefBool(CC_K_LOCAL_ENABLED, !CCPrefBool(CC_K_LOCAL_ENABLED, YES));
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
        RefreshBoxes();   // 面板收起后按现有内容恢复字幕框（没有内容就保持隐藏）
    });
}

+ (void)expandPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_win) return;
        ShowWindow();
        CCLogf(@"panel: expand");
        g_panelExpanded = YES;
        [self hideGrabberNow];
        // 面板打开时先收起字幕框，避免面板和字幕重叠
        if (g_remoteBox) g_remoteBox.hidden = YES;
        if (g_localBox) g_localBox.hidden = YES;
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
    if (f.origin.y > ScreenH() - f.size.height - 60)
        f.origin.y = ScreenH() - f.size.height - 60;
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
    CCStreamCallActive(active);

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

// ---------- SpringBoard 内识别（自检已证明：App 进程里 SFSpeech 可用） ----------
static NSString *g_sbPath;
static unsigned long long g_sbOffset;
static NSMutableData *g_sbChunk;
static BOOL g_sbBusy;
static BOOL g_sbCloudOn = YES;   // 旧分块识别：云端优先，失败自动换本地
static BOOL g_sbCloudInit;
static NSString *g_sbLastText;
static SFSpeechRecognizer *g_sbRecog;
static SFSpeechRecognitionTask *g_sbTask;
static NSTimer *g_sbTimer;
static CFAbsoluteTime g_sbLastVoiceAt;
static BOOL g_sbHadVoice;

static void CCWriteWav16kFile(NSString *path, NSData *pcm) {
    FILE *fp = fopen(path.fileSystemRepresentation, "wb");
    if (!fp) return;
    uint32_t riff = 36 + (uint32_t)pcm.length;
    uint32_t dsz = (uint32_t)pcm.length;
    uint32_t rate = 16000, byteRate = 32000, sz16 = 16;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp);
    fwrite("WAVEfmt ", 1, 8, fp); fwrite(&sz16, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp); fwrite(&ch, 2, 1, fp);
    fwrite(&rate, 4, 1, fp); fwrite(&byteRate, 4, 1, fp);
    fwrite(&align, 2, 1, fp); fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp); fwrite(&dsz, 4, 1, fp);
    fwrite(pcm.bytes, 1, pcm.length, fp);
    fclose(fp);
    chmod(path.fileSystemRepresentation, 0666);
}

static NSString *CCWordMerge(NSString *prev, NSString *next) {
    NSArray *a = [prev componentsSeparatedByString:@" "];
    NSArray *b = [next componentsSeparatedByString:@" "];
    NSInteger maxK = MIN((NSInteger)a.count, (NSInteger)b.count);
    for (NSInteger k = maxK; k > 0; k--) {
        BOOL ok = YES;
        for (NSInteger i = 0; i < k; i++) {
            NSString *x = [a[a.count - k + i] lowercaseString];
            NSString *y = [b[i] lowercaseString];
            if (![x isEqualToString:y]) { ok = NO; break; }
        }
        if (ok) return [[b subarrayWithRange:NSMakeRange(k, b.count - k)]
                        componentsJoinedByString:@" "];
    }
    return next;
}

static void CCSBDeliverChunk(NSString *txt) {
    @try {
        NSString *part = txt;
        if (g_sbLastText.length) part = CCWordMerge(g_sbLastText, txt);
        g_sbLastText = txt;
        part = [part stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!part.length) return;
        CCLogf(@"sb recog: %@", part);
        CCUIDeliverRemoteOriginal(part);
        CCTranslateEx(part, @"en", @"zh", ^(NSString *out, NSString *engine) {
            if (!out.length) return;
            CCUIDeliverRemoteTranslated(out);
            if (engine.length) CCUIDeliverRemoteEngine(engine);
            if (CCPrefBool(CC_K_TTS_ENABLED, YES))
                CCTTSBuffer(out, @"zh-CN", @"cc_tts_zh.wav");
        });
    } @catch (NSException *e) { }
}

static void CCRemoteFileTick(void) {
    @try {
        if (!g_callActive) {
            g_sbOffset = 0; g_sbPath = nil; g_sbChunk = nil; g_sbLastText = nil;
            g_sbHadVoice = NO; g_sbLastVoiceAt = 0;
            return;
        }
        NSString *p = [CC_DIR stringByAppendingPathComponent:@"remote16k.wav"];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!at) return;
        unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
        if (size <= 44) return;
        if (!g_sbPath || ![g_sbPath isEqualToString:p] || size < g_sbOffset) {
            g_sbPath = p;
            g_sbOffset = 44;           // 文件每次通话都重新创建，从第一个字节读，不跳音频
            g_sbChunk = [NSMutableData data]; g_sbLastText = nil;
        }
        if (size <= g_sbOffset) return;
        // 识别中先不读：音频留在文件里，忙完再补，绝不裁剪丢弃
        if (g_sbBusy) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
        if (!fh) return;
        [fh seekToFileOffset:g_sbOffset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        NSUInteger n = d.length & ~(NSUInteger)1;
        if (n == 0) return;
        g_sbOffset += n;
        if (!g_sbChunk) g_sbChunk = [NSMutableData data];
        [g_sbChunk appendData:[d subdataWithRange:NSMakeRange(0, n)]];

        // 新到音频的瞬时音量
        {
            const int16_t *np = (const int16_t *)d.bytes;
            NSUInteger nn = n / 2;
            double ns = 0;
            for (NSUInteger i = 0; i < nn; i++) ns += fabs((double)np[i]);
            double nrms = nn ? ns / (double)nn / 32768.0 : 0;
            if (nrms > 0.006) {
                g_sbHadVoice = YES;
                g_sbLastVoiceAt = CFAbsoluteTimeGetCurrent();
            }
        }

        double dur = (double)g_sbChunk.length / 32000.0;
        double silence = g_sbLastVoiceAt > 0
            ? CFAbsoluteTimeGetCurrent() - g_sbLastVoiceAt : 0;
        BOOL voiceEnded = g_sbHadVoice && silence > 0.6;
        if (!(dur >= 6.0 || (dur >= 2.0 && voiceEnded))) return;

        // 积压很多时只取前 12 秒，其余留在 chunk 里下一轮继续识别（不丢弃）
        NSUInteger hardMax = 16000 * 2 * 12;
        NSData *pcm;
        if (g_sbChunk.length > hardMax) {
            pcm = [g_sbChunk subdataWithRange:NSMakeRange(0, hardMax)];
            g_sbChunk = [[g_sbChunk subdataWithRange:
                          NSMakeRange(hardMax, g_sbChunk.length - hardMax)] mutableCopy];
        } else {
            pcm = [g_sbChunk copy];
            NSUInteger keep = MIN((NSUInteger)(16000 * 2), pcm.length);  // 1 秒重叠
            g_sbChunk = [[pcm subdataWithRange:
                          NSMakeRange(pcm.length - keep, keep)] mutableCopy];
        }
        g_sbHadVoice = NO;
        g_sbLastVoiceAt = 0;

        const int16_t *sp = pcm.bytes;
        NSUInteger cnt = pcm.length / 2;
        double sum = 0;
        for (NSUInteger i = 0; i < cnt; i++) sum += fabs((double)sp[i]);
        double avg = cnt ? sum / (double)cnt / 32768.0 : 0;
        if (avg < 0.0015) return;                           // 静音块跳过

        // 音量归一：远端流经常只有 0.01 左右，SFSpeech 容易判成没说话
        double gain = avg > 0.0001 ? 0.06 / avg : 1.0;
        if (gain > 8.0) gain = 8.0;
        if (gain < 1.0) gain = 1.0;
        NSMutableData *ampl = [NSMutableData dataWithLength:pcm.length];
        int16_t *ap = (int16_t *)ampl.mutableBytes;
        for (NSUInteger i = 0; i < cnt; i++) {
            int v = (int)((double)sp[i] * gain);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            ap[i] = (int16_t)v;
        }
        pcm = ampl;
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cc_sb_chunk.wav"];
        CCWriteWav16kFile(tmp, pcm);
        if (!g_sbRecog) {
            g_sbRecog = [[SFSpeechRecognizer alloc] initWithLocale:
                         [NSLocale localeWithLocaleIdentifier:CCPrefStr(CC_K_REMOTE_LOCALE, @"en-US")]];
        }
        if (!g_sbRecog) return;
        SFSpeechURLRecognitionRequest *ur =
            [[SFSpeechURLRecognitionRequest alloc] initWithURL:[NSURL fileURLWithPath:tmp]];
        ur.shouldReportPartialResults = NO;
        if (!g_sbCloudInit) { g_sbCloudInit = YES; g_sbCloudOn = CCPrefBool(CC_K_CLOUD_ASR, YES); }
        if (@available(iOS 13.0, *)) {
            ur.taskHint = SFSpeechRecognitionTaskHintDictation;
            ur.requiresOnDeviceRecognition = !g_sbCloudOn;
        }
        g_sbBusy = YES;
        CCLogf(@"sb recog chunk %.1fs rms%.3f cloud=%d", (double)pcm.length / 32000.0, avg, g_sbCloudOn);
        g_sbTask = [g_sbRecog recognitionTaskWithRequest:ur
            resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
                if (res.isFinal) {
                    NSString *txt = [res.bestTranscription.formattedString
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (txt.length) CCSBDeliverChunk(txt);
                }
                if (err) {
                    CCLogf(@"sb recog err %ld %@ cloud=%d", (long)err.code,
                           err.localizedDescription, g_sbCloudOn);
                    if (err.code == 1110 || err.code == 1101 ||
                        err.code == 203 || err.code == 301)
                        g_sbCloudOn = !g_sbCloudOn;   // 下块换另一种识别模式
                }
                g_sbBusy = NO;
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            }];
    } @catch (NSException *e) { CCLogf(@"sb recog exc %@", e.reason); }
}

// ---------- SpringBoard 内识别：本地麦克风 ----------
static NSString *g_lbPath;
static unsigned long long g_lbOffset;
static NSMutableData *g_lbChunk;
static BOOL g_lbBusy;
static BOOL g_lbCloudOn = YES;
static BOOL g_lbCloudInit;
static NSString *g_lbLastText;
static SFSpeechRecognizer *g_lbRecog;
static SFSpeechRecognitionTask *g_lbTask;
static CFAbsoluteTime g_lbLastVoiceAt;
static BOOL g_lbHadVoice;

static void CCWriteWav48kFile(NSString *path, NSData *pcm) {
    FILE *fp = fopen(path.fileSystemRepresentation, "wb");
    if (!fp) return;
    uint32_t riff = 36 + (uint32_t)pcm.length;
    uint32_t dsz = (uint32_t)pcm.length;
    uint32_t rate = 48000, byteRate = 96000, sz16 = 16;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp);
    fwrite("WAVEfmt ", 1, 8, fp); fwrite(&sz16, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp); fwrite(&ch, 2, 1, fp);
    fwrite(&rate, 4, 1, fp); fwrite(&byteRate, 4, 1, fp);
    fwrite(&align, 2, 1, fp); fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp); fwrite(&dsz, 4, 1, fp);
    fwrite(pcm.bytes, 1, pcm.length, fp);
    fclose(fp);
    chmod(path.fileSystemRepresentation, 0666);
}

// TTS 合成成 48k PCM，写到 CC_DIR/<fileName>；守护进程再复制给 App 探针做混音
static void CCTTSBuffer(NSString *text, NSString *lang, NSString *fileName) {
    if (!text.length) return;
    CCLogf(@"tts synth start %@ [%lu chars] %@", lang, (unsigned long)text.length,
           text.length > 40 ? [text substringToIndex:40] : text);
    AVSpeechSynthesizer *synth = [[AVSpeechSynthesizer alloc] init];
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
    NSString *vid = [lang hasPrefix:@"zh"] ? CCPrefStr(CC_K_TTS_VOICE, @"")
                                           : CCPrefStr(CC_K_LOCAL_VOICE, @"");
    AVSpeechSynthesisVoice *v = vid.length ? [AVSpeechSynthesisVoice voiceWithIdentifier:vid] : nil;
    u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:lang];
    NSMutableData *out = [NSMutableData data];
    __block double phase = 0;
    __block BOOL done = NO;
    __block AVSpeechSynthesizer *keep = synth;
    [synth writeUtterance:u toBufferCallback:^(AVAudioBuffer *buffer) {
        @autoreleasepool {
            if (![buffer isKindOfClass:[AVAudioPCMBuffer class]]) return;
            AVAudioPCMBuffer *b = (AVAudioPCMBuffer *)buffer;
            AVAudioFrameCount n = b.frameLength;
            if (n == 0) {
                if (!done) {
                    done = YES;
                    if (out.length) {
                        NSString *p = [CC_DIR stringByAppendingPathComponent:fileName];
                        CCWriteWav48kFile(p, out);
                    }
                    CCLogf(@"tts %@ -> %@ %lu bytes", lang, fileName,
                           (unsigned long)out.length);
                    keep = nil;
                }
                return;
            }
            const float *srcF = b.floatChannelData ? b.floatChannelData[0] : NULL;
            const int16_t *srcI = b.int16ChannelData ? b.int16ChannelData[0] : NULL;
            if (!srcF && !srcI) {
                static int logged;
                if (logged++ < 3)
                    CCLogf(@"tts buf unsupported fmt=%d ch=%u frames=%u",
                           (int)b.format.commonFormat,
                           (unsigned)b.format.channelCount, (unsigned)n);
                return;
            }
            double sr = b.format.sampleRate > 0 ? b.format.sampleRate : 22050.0;
            double step = sr / 48000.0;
            double pos = phase;
            int16_t buf[2048];
            UInt32 cnt = 0;
            while (pos < (double)n) {
                UInt32 i = (UInt32)pos;
                UInt32 i2 = (i + 1 < n ? i + 1 : i);
                float a = srcF ? srcF[i] : (float)srcI[i] / 32768.0f;
                float c = srcF ? srcF[i2] : (float)srcI[i2] / 32768.0f;
                float val = a + (c - a) * (float)(pos - (double)i);
                int iv = (int)lrintf(val * 32767.0f);
                if (iv > 32767) iv = 32767;
                if (iv < -32768) iv = -32768;
                buf[cnt++] = (int16_t)iv;
                if (cnt == 2048) { [out appendBytes:buf length:cnt * 2]; cnt = 0; }
                pos += step;
            }
            if (cnt) [out appendBytes:buf length:cnt * 2];
            phase = pos - (double)n;
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!done) {
            done = YES;
            if (out.length) {
                NSString *p = [CC_DIR stringByAppendingPathComponent:fileName];
                CCWriteWav48kFile(p, out);
            }
            CCLogf(@"tts timeout %@ %lu bytes", fileName, (unsigned long)out.length);
            keep = nil;
        }
    });
}

static void CCLBDeliverChunk(NSString *txt) {
    @try {
        NSString *part = txt;
        if (g_lbLastText.length) part = CCWordMerge(g_lbLastText, txt);
        g_lbLastText = txt;
        part = [part stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!part.length) return;
        CCLogf(@"sb local: %@", part);
        CCUIDeliverLocalOriginal(part);
        CCTranslateEx(part, @"zh", @"en", ^(NSString *out, NSString *engine) {
            if (!out.length) return;
            CCUIDeliverLocalTranslated(out);
            if (engine.length) CCUIDeliverLocalEngine(engine);
            CCTTSBuffer(out, @"en-US", @"cc_tts.wav");   // 上行注入用，不外放
        });
    } @catch (NSException *e) { }
}

static void CCLocalFileTick(void) {
    @try {
        if (!g_callActive) {
            g_lbOffset = 0; g_lbPath = nil; g_lbChunk = nil; g_lbLastText = nil;
            g_lbHadVoice = NO; g_lbLastVoiceAt = 0;
            return;
        }
        NSString *p = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!at) return;
        unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
        if (size <= 44) return;
        if (!g_lbPath || ![g_lbPath isEqualToString:p] || size < g_lbOffset) {
            g_lbPath = p;
            g_lbOffset = 44;
            g_lbChunk = [NSMutableData data]; g_lbLastText = nil;
        }
        if (size <= g_lbOffset) return;
        if (g_lbBusy) return;              // 识别中先不读，音频留在文件里
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
        if (!fh) return;
        [fh seekToFileOffset:g_lbOffset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        NSUInteger n = d.length & ~(NSUInteger)1;
        if (n == 0) return;
        g_lbOffset += n;
        if (!g_lbChunk) g_lbChunk = [NSMutableData data];
        [g_lbChunk appendData:[d subdataWithRange:NSMakeRange(0, n)]];

        const int16_t *np = (const int16_t *)d.bytes;
        NSUInteger nn = n / 2;
        double ns = 0;
        for (NSUInteger i = 0; i < nn; i++) ns += fabs((double)np[i]);
        double nrms = nn ? ns / (double)nn / 32768.0 : 0;
        if (nrms > 0.006) {
            g_lbHadVoice = YES;
            g_lbLastVoiceAt = CFAbsoluteTimeGetCurrent();
        }

        double dur = (double)g_lbChunk.length / 32000.0;
        double silence = g_lbLastVoiceAt > 0
            ? CFAbsoluteTimeGetCurrent() - g_lbLastVoiceAt : 0;
        BOOL voiceEnded = g_lbHadVoice && silence > 0.6;
        if (!(dur >= 6.0 || (dur >= 2.0 && voiceEnded))) return;

        NSUInteger hardMax = 16000 * 2 * 12;
        NSData *pcm;
        if (g_lbChunk.length > hardMax) {
            pcm = [g_lbChunk subdataWithRange:NSMakeRange(0, hardMax)];
            g_lbChunk = [[g_lbChunk subdataWithRange:
                          NSMakeRange(hardMax, g_lbChunk.length - hardMax)] mutableCopy];
        } else {
            pcm = [g_lbChunk copy];
            NSUInteger keep = MIN((NSUInteger)(16000 * 2), pcm.length);
            g_lbChunk = [[pcm subdataWithRange:
                          NSMakeRange(pcm.length - keep, keep)] mutableCopy];
        }
        g_lbHadVoice = NO;
        g_lbLastVoiceAt = 0;

        const int16_t *sp = pcm.bytes;
        NSUInteger cnt = pcm.length / 2;
        double sum = 0;
        for (NSUInteger i = 0; i < cnt; i++) sum += fabs((double)sp[i]);
        double avg = cnt ? sum / (double)cnt / 32768.0 : 0;
        if (avg < 0.0015) return;

        double gain = avg > 0.0001 ? 0.06 / avg : 1.0;
        if (gain > 8.0) gain = 8.0;
        if (gain < 1.0) gain = 1.0;
        NSMutableData *ampl = [NSMutableData dataWithLength:pcm.length];
        int16_t *ap = (int16_t *)ampl.mutableBytes;
        for (NSUInteger i = 0; i < cnt; i++) {
            int v = (int)((double)sp[i] * gain);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            ap[i] = (int16_t)v;
        }
        pcm = ampl;
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"cc_sb_local.wav"];
        CCWriteWav16kFile(tmp, pcm);
        if (!g_lbRecog) {
            g_lbRecog = [[SFSpeechRecognizer alloc] initWithLocale:
                         [NSLocale localeWithLocaleIdentifier:CCPrefStr(CC_K_LOCAL_LOCALE, @"zh-CN")]];
        }
        if (!g_lbRecog) return;
        SFSpeechURLRecognitionRequest *ur =
            [[SFSpeechURLRecognitionRequest alloc] initWithURL:[NSURL fileURLWithPath:tmp]];
        ur.shouldReportPartialResults = NO;
        if (!g_lbCloudInit) { g_lbCloudInit = YES; g_lbCloudOn = CCPrefBool(CC_K_CLOUD_ASR, YES); }
        if (@available(iOS 13.0, *)) {
            ur.taskHint = SFSpeechRecognitionTaskHintDictation;
            ur.requiresOnDeviceRecognition = !g_lbCloudOn;
        }
        g_lbBusy = YES;
        CCLogf(@"sb local chunk %.1fs rms%.3f cloud=%d", (double)pcm.length / 32000.0, avg, g_lbCloudOn);
        g_lbTask = [g_lbRecog recognitionTaskWithRequest:ur
            resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
                if (res.isFinal) {
                    NSString *txt = [res.bestTranscription.formattedString
                        stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (txt.length) CCLBDeliverChunk(txt);
                }
                if (err) {
                    CCLogf(@"sb local err %ld %@ cloud=%d", (long)err.code,
                           err.localizedDescription, g_lbCloudOn);
                    if (err.code == 1110 || err.code == 1101 ||
                        err.code == 203 || err.code == 301)
                        g_lbCloudOn = !g_lbCloudOn;
                }
                g_lbBusy = NO;
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            }];
    } @catch (NSException *e) { CCLogf(@"sb local exc %@", e.reason); }
}

// ---------- 一次性自检：SpringBoard 这个 App 进程能不能跑 SFSpeech ----------
// 守护进程里 SFSpeech 一直 1110；如果 SpringBoard 里能识别同一个 WAV，
// 就把识别搬进 SpringBoard，避开 daemon 环境限制。
static void CCRunSpeechSelfTest(BOOL onDevice) {
    static int attempts;
    NSString *p = @"/var/mobile/Library/CallCaption/selftest.wav";
    if (![[NSFileManager defaultManager] fileExistsAtPath:p]) {
        attempts++;
        CCLogf(@"selftest: no selftest.wav (attempt %d)", attempts);
        if (attempts < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ CCRunSpeechSelfTest(YES); });
        }
        return;
    }
    SFSpeechRecognizer *r = [[SFSpeechRecognizer alloc] initWithLocale:
                             [NSLocale localeWithLocaleIdentifier:@"en-US"]];
    CCLogf(@"selftest: enter onDevice=%d auth=%ld avail=%d supportOD=%d",
           onDevice, (long)[SFSpeechRecognizer authorizationStatus],
           r.isAvailable, r.supportsOnDeviceRecognition);
    SFSpeechURLRecognitionRequest *req =
        [[SFSpeechURLRecognitionRequest alloc] initWithURL:[NSURL fileURLWithPath:p]];
    req.shouldReportPartialResults = YES;
    if (@available(iOS 13.0, *)) {
        req.taskHint = SFSpeechRecognitionTaskHintDictation;
        req.requiresOnDeviceRecognition = onDevice;
    }
    __block BOOL got = NO;
    [r recognitionTaskWithRequest:req
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
            if (res) {
                got = YES;
                CCLogf(@"selftest: %@ (final=%d)",
                       res.bestTranscription.formattedString, res.isFinal);
            }
            if (err) {
                CCLogf(@"selftest: err %ld %@ code=%ld",
                       (long)err.code, err.localizedDescription,
                       (long)err.code);
                if (!got && onDevice) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        CCRunSpeechSelfTest(NO);
                    });
                }
            }
        }];
}

#pragma mark - 0.16.8 流式识别（LCT 同款 SFSpeechAudioBufferRecognitionRequest）
//
// 旧方案：每 2~6 秒切一块 WAV，串行跑 SFSpeechURLRecognitionRequest。
//   - 6 秒硬切会把单词劈成两半，重叠去重靠“单词完全相等”，识别不一致就丢词；
//   - 识别期间新音频只能排队，块被裁剪；
//   - 本地 URL 识别延迟 0.5~2 秒。
// 新方案：每个方向一个长连接，音频边到边喂，partial 实时上字幕，
// 静音/文本稳定即判一句结束，只翻译新增部分。会话每 55 秒轮换（Apple 约 1 分钟上限）。

@interface CCStream : NSObject
@property (nonatomic) BOOL isLocal;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) unsigned long long offset;
@property (nonatomic, strong) SFSpeechRecognizer *recog;
@property (nonatomic, copy) NSString *locale;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *req;
@property (nonatomic, strong) SFSpeechRecognitionTask *task;
@property (nonatomic, strong) NSMutableData *pending;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *delivered;
@property (nonatomic) CFAbsoluteTime lastVoiceAt;
@property (nonatomic) CFAbsoluteTime lastTextAt;
@property (nonatomic) CFAbsoluteTime lastDeliverAt;
@property (nonatomic) CFAbsoluteTime lastUIAt;
@property (nonatomic) CFAbsoluteTime sessionStart;
@property (nonatomic) CFAbsoluteTime callStart;
@property (nonatomic) BOOL hadVoice;
@property (nonatomic) BOOL rotating;
@property (nonatomic) BOOL starting;
@property (nonatomic) BOOL catchingUp;
@property (nonatomic) CFAbsoluteTime nextRetryAt;
@property (nonatomic) BOOL restartScheduled;
@property (nonatomic) BOOL onDevice;
@property (nonatomic) BOOL legacy;
@property (nonatomic) int failures;
@property (nonatomic) double gain;
@end

@implementation CCStream
@end

static CCStream *g_rs;
static CCStream *g_ls;
static NSTimer *g_streamTimer;
// 0.16.8 诊断：先只跑“对方”一路流式，验证单任务是否稳定。
// 本地方向的麦克风音频仍由守护进程连续写入 local16k.wav（没丢），只是暂停识别。
static BOOL g_localStreamPaused = YES;

static CCStream *CCStreamFor(BOOL local) {
    if (!g_rs) { g_rs = [CCStream new]; g_rs.gain = 1.0; }
    if (!g_ls) { g_ls = [CCStream new]; g_ls.isLocal = YES; g_ls.gain = 1.0; }
    return local ? g_ls : g_rs;
}

static NSString *CCStreamTag(CCStream *st) { return st.isLocal ? @"local" : @"remote"; }

static NSString *CCStreamLocale(CCStream *st) {
    return st.isLocal ? CCPrefStr(CC_K_LOCAL_LOCALE, @"zh-CN")
                      : CCPrefStr(CC_K_REMOTE_LOCALE, @"en-US");
}

static AVAudioFormat *CCStreamFormat(void) {
    static AVAudioFormat *f;
    if (!f) f = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                sampleRate:16000
                                                  channels:1
                                               interleaved:NO];
    return f;
}

// 只取“还没翻译过”的新增词。ASR 偶尔会改写前文，改写时退化为最后 12 个词。
static NSString *CCStreamNewTail(NSString *full, NSString *delivered) {
    if (!full.length) return @"";
    if (!delivered.length) return full;
    if ([full hasPrefix:delivered]) {
        return [[full substringFromIndex:delivered.length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSArray *a = [delivered componentsSeparatedByString:@" "];
    NSArray *b = [full componentsSeparatedByString:@" "];
    NSUInteger i = 0;
    while (i < a.count && i < b.count &&
           [[a[i] lowercaseString] isEqualToString:[b[i] lowercaseString]]) i++;
    if (i < b.count) {
        // 完全对不上（ASR 整段改写）：宁可整段重译一次，也不掐头去尾丢内容
        return [[b subarrayWithRange:NSMakeRange(i, b.count - i)]
                componentsJoinedByString:@" "];
    }
    return @"";
}

static void CCStreamShowPartial(CCStream *st, NSString *t) {
    if (!t.length) return;
    // 只显示“这一句还没翻译的部分”。以前显示整个 session 的累计 partial，
    // 于是第一句、第二句、第三句会在框里越堆越长（用户看到的累计字幕）。
    NSString *tail = CCStreamNewTail(t, st.delivered);
    NSString *show = tail.length ? tail : t;
    if (show.length > 200) show = [show substringFromIndex:show.length - 200];
    if (st.isLocal) CCUIDeliverLocalOriginal(show);
    else CCUIDeliverRemoteOriginal(show);
}

static BOOL CCStreamHasSentenceEnd(NSString *t) {
    if (!t.length) return NO;
    NSString *trim = [t stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trim.length) return NO;
    unichar c = [trim characterAtIndex:trim.length - 1];
    return (c == '.' || c == '?' || c == '!' ||
            c == 0x3002 || c == 0xFF1F || c == 0xFF01);   // 。？！(全角)
}

static void CCStreamDeliver(CCStream *st) {
    // 挂断后才到达的 final/error 不允许再出字幕、再合成 TTS，
    // 否则上一通的内容会拖到下一通拨通后才冒出来。
    if (!g_callActive) { st.delivered = st.text ?: @""; return; }
    NSString *full = st.text ?: @"";
    if (!full.length) return;
    NSString *tail = CCStreamNewTail(full, st.delivered);
    NSString *prevDelivered = st.delivered;
    st.delivered = full;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    st.lastDeliverAt = now;
    if (!tail.length) return;
    CCLogf(@"stream %@ deliver (silence %.2fs): %@", CCStreamTag(st),
           st.lastVoiceAt > 0 ? now - st.lastVoiceAt : 0, tail);
    // 所有引擎都失败时把 delivered 退回去，下一段继续重试，别把这句话吞掉
    void (^onFail)(void) = ^{
        if ([st.delivered isEqualToString:full]) st.delivered = prevDelivered;
        CCLogf(@"stream %@ translate failed, will retry", CCStreamTag(st));
    };
    if (st.isLocal) {
        CCTranslateEx(tail, @"zh", @"en", ^(NSString *out, NSString *engine) {
            if (!out.length) { onFail(); return; }
            CCUIDeliverLocalTranslated(out);
            if (engine.length) CCUIDeliverLocalEngine(engine);
            if (CCPrefBool(CC_K_TTS_ENABLED, YES))
                CCTTSBuffer(out, @"en-US", @"cc_tts.wav");
        });
    } else {
        CCTranslateEx(tail, @"en", @"zh", ^(NSString *out, NSString *engine) {
            if (!out.length) { onFail(); return; }
            CCUIDeliverRemoteTranslated(out);
            if (engine.length) CCUIDeliverRemoteEngine(engine);
            if (CCPrefBool(CC_K_TTS_ENABLED, YES))
                CCTTSBuffer(out, @"zh-CN", @"cc_tts_zh.wav");
        });
    }
}

static void CCStreamFeedRaw(CCStream *st, const int16_t *s, NSUInteger n) {
    if (!n || !st.req) return;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:CCStreamFormat()
                                                         frameCapacity:(AVAudioFrameCount)n];
    if (!buf) return;
    buf.frameLength = (AVAudioFrameCount)n;
    float *dst = buf.floatChannelData[0];
    double g = st.gain;
    for (NSUInteger i = 0; i < n; i++) {
        double v = (double)s[i] / 32768.0 * g;
        if (v > 1.0) v = 1.0;
        if (v < -1.0) v = -1.0;
        dst[i] = (float)v;
    }
    [st.req appendAudioPCMBuffer:buf];
}

static void CCStreamFeed(CCStream *st, const int16_t *s, NSUInteger n) {
    if (!n) return;
    // 轮换/重建会话期间 request 已 endAudio，不能再往里塞；音频进 pending，绝不丢
    if (st.req && !st.rotating) {
        CCStreamFeedRaw(st, s, n);
        return;
    }
    if (!st.pending) st.pending = [NSMutableData data];
    [st.pending appendBytes:s length:n * 2];
    NSUInteger cap = 16000 * 2 * 30;      // 最多缓存 30 秒，足够覆盖任何会话切换
    if (st.pending.length > cap) {
        st.pending = [[st.pending subdataWithRange:
                       NSMakeRange(st.pending.length - cap, cap)] mutableCopy];
    }
}

static void CCStreamFlushPending(CCStream *st) {
    if (!st.pending.length || !st.req) return;
    NSData *d = st.pending;
    st.pending = nil;
    CCStreamFeedRaw(st, (const int16_t *)d.bytes, d.length / 2);
}

static void CCStreamStart(CCStream *st);
static void CCStreamFinishSession(CCStream *st);

static void CCStreamStart(CCStream *st) {
    if (st.task || st.starting || st.legacy) return;
    NSString *loc = CCStreamLocale(st);
    if (!st.recog || ![st.locale isEqualToString:loc]) {
        st.recog = [[SFSpeechRecognizer alloc] initWithLocale:
                    [NSLocale localeWithLocaleIdentifier:loc]];
        st.locale = loc;
    }
    if (!st.recog) {
        st.failures++;
        CCLogf(@"stream %@: no recognizer for %@, retry later", CCStreamTag(st), loc);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_callActive) CCStreamStart(st);
        });
        return;
    }
    SFSpeechAudioBufferRecognitionRequest *r =
        [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    r.shouldReportPartialResults = YES;
    if (@available(iOS 13.0, *)) {
        r.taskHint = SFSpeechRecognitionTaskHintDictation;
        r.requiresOnDeviceRecognition = st.onDevice;
    }
    if (@available(iOS 16.0, *)) {
        // 让识别器自己输出标点：句末标点就是它给出的“一句话结束”，
        // 不再由我们数静音秒数/词数。
        r.addsPunctuation = YES;
    }
    st.req = r;
    st.starting = YES;
    st.restartScheduled = NO;
    st.nextRetryAt = 0;
    st.text = @"";
    st.delivered = @"";            // 新会话只包含新音频，旧文本不能用来做差集
    st.lastTextAt = 0;
    st.lastDeliverAt = CFAbsoluteTimeGetCurrent();   // 防止首个 partial 被 12s 超时立即送出
    st.rotating = NO;
    st.sessionStart = CFAbsoluteTimeGetCurrent();
    CCLogf(@"stream %@ start onDevice=%d locale=%@ avail=%d supportOD=%d auth=%ld",
           CCStreamTag(st), st.onDevice, loc, st.recog.isAvailable,
           st.recog.supportsOnDeviceRecognition,
           (long)[SFSpeechRecognizer authorizationStatus]);

    __weak CCStream *weakSt = st;
    st.task = [st.recog recognitionTaskWithRequest:r
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                CCStream *s = weakSt;
                if (!s) return;
                s.starting = NO;
                NSString *t = nil;
                if (res) {
                    t = [res.bestTranscription.formattedString
                         stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (t.length) {
                        s.failures = 0;
                        if (!s.lastTextAt)
                            CCLogf(@"stream %@ first partial after %.2fs onDevice=%d",
                                   CCStreamTag(s), CFAbsoluteTimeGetCurrent() - s.sessionStart,
                                   s.onDevice);
                        if (![t isEqualToString:(s.text ?: @"")]) {
                            s.text = t;
                            s.lastTextAt = CFAbsoluteTimeGetCurrent();
                        }
                        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                        if (now - s.lastUIAt > 0.30) {
                            s.lastUIAt = now;
                            CCStreamShowPartial(s, t);
                        }
                    }
                    if (res.isFinal) {
                        CCLogf(@"stream %@ final %lu chars onDevice=%d",
                               CCStreamTag(s), (unsigned long)t.length, s.onDevice);
                        CCStreamFinishSession(s);
                        return;
                    }
                }
                if (err) {
                    CCLogf(@"stream %@ err %ld %@ onDevice=%d",
                           CCStreamTag(s), (long)err.code,
                           err.localizedDescription ?: @"", s.onDevice);
                    s.failures++;
                    CCStreamFinishSession(s);
                }
            });
        }];
    if (!st.task) {
        st.starting = NO;
        st.req = nil;
        st.failures++;
        CCStreamFinishSession(st);
        return;
    }
    CCStreamFlushPending(st);
}

static void CCStreamFinishSession(CCStream *st) {
    if (st.task) [st.task cancel];
    st.task = nil;
    st.req = nil;
    st.starting = NO;
    st.rotating = NO;
    CCStreamDeliver(st);                   // 会话结束/轮换/出错前，先把已识别的部分送出去
    if (st.failures > 0) {
        // 只换识别模式重试：绝不回落到“按时间切块”。
        // 用户铁律：宁可暂时没有识别结果，也不切用户说的话。
        st.onDevice = !st.onDevice;
        CCLogf(@"stream %@ retry with onDevice=%d (failures=%d)",
               CCStreamTag(st), st.onDevice, st.failures);
    }
    if (st.restartScheduled) return;   // final 和 error 可能同时来，只排一次重启
    double delay = st.failures ? MIN(3.0, 0.5 * (double)st.failures) : 0.05;
    st.nextRetryAt = CFAbsoluteTimeGetCurrent() + delay;
    st.restartScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        st.restartScheduled = NO;
        if (g_callActive) CCStreamStart(st);
    });
}

static void CCStreamReset(CCStream *st) {
    if (st.task) [st.task cancel];
    st.task = nil; st.req = nil;
    st.path = nil; st.offset = 0;
    st.text = @""; st.delivered = @"";
    st.pending = nil;
    st.hadVoice = NO; st.rotating = NO; st.starting = NO; st.catchingUp = NO;
    st.failures = 0; st.legacy = NO;
    st.nextRetryAt = 0; st.restartScheduled = NO;
    st.lastVoiceAt = 0; st.lastTextAt = 0; st.lastDeliverAt = 0; st.lastUIAt = 0;
    st.sessionStart = 0; st.gain = 1.0;
}

static void CCStreamStop(CCStream *st) {
    if (st.task) [st.task cancel];
    st.task = nil; st.req = nil; st.pending = nil;
    st.path = nil; st.offset = 0;
    st.text = @""; st.delivered = @"";
    st.hadVoice = NO; st.rotating = NO; st.starting = NO; st.catchingUp = NO;
    st.nextRetryAt = 0; st.restartScheduled = NO;
}

static void CCStreamTick(CCStream *st) {
    if (!g_callActive) return;
    if (st.isLocal && g_localStreamPaused) return;
    if (!g_sessionActive) {              // 面板关闭/未启用：不要空跑识别会话
        if (st.task || st.req) CCStreamStop(st);
        return;
    }
    if (st.isLocal && !CCPrefBool(CC_K_LOCAL_ENABLED, YES)) {
        if (st.task || st.req) CCStreamStop(st);
        return;
    }
    if (st.legacy) return;                 // 旧分块识别由 1 秒定时器接管

    NSString *p = [CC_DIR stringByAppendingPathComponent:
                   (st.isLocal ? @"local16k.wav" : @"remote16k.wav")];
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!at) return;
    unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
    if (size <= 44) return;

    // 通话刚开始时，上一通的桥文件可能还在盘上（守护进程 0.5 秒后才 arm 重建）。
    // 先等它变成新文件，别把上一通的话喂进新会话（日志里 1110 连败的根因）。
    if (!st.path) {
        NSTimeInterval mt = [at[NSFileModificationDate] timeIntervalSince1970];
        NSTimeInterval nowEpoch = [[NSDate date] timeIntervalSince1970];
        CFAbsoluteTime nowAbs = CFAbsoluteTimeGetCurrent();
        if (mt > 0 && nowEpoch - mt > 1.5 && st.callStart > 0 &&
            nowAbs - st.callStart < 3.0) {
            return;
        }
    }

    if (!st.path || ![st.path isEqualToString:p] || size < st.offset) {
        st.path = p;
        // 文件在通话开始（arm）时由守护进程重新创建并截断，44 起就是本通电话的第一个字节。
        // 不按“文件已经多大”判断新旧——那会吞掉开头真实说的话。
        st.offset = 44;
        if (st.task) [st.task cancel];
        st.task = nil; st.req = nil;
        st.text = @""; st.delivered = @"";
        st.pending = nil;
        st.hadVoice = NO; st.failures = 0;
        st.lastVoiceAt = 0; st.lastTextAt = 0; st.lastDeliverAt = 0;
        st.sessionStart = 0; st.gain = 1.0;
        CCStreamStart(st);
    }
    if (st.legacy) return;
    if (!st.task && !st.starting && !st.restartScheduled &&
        CFAbsoluteTimeGetCurrent() >= st.nextRetryAt)
        CCStreamStart(st);
    if (size <= st.offset) return;

    // 积压（例如 SpringBoard 重启后文件里已有整通录音）时按约 5 倍实时补读，
    // 只是分几次喂，绝不跳过、绝不丢样本。
    unsigned long long backlog = size - st.offset;
    unsigned long long maxRead = 32000ULL * 3;      // 每拍最多 3 秒
    if (backlog > 32000ULL * 4) {
        maxRead = 32000ULL;                         // 积压 >4 秒时每拍 1 秒
        if (!st.catchingUp) {
            st.catchingUp = YES;
            CCLogf(@"stream %@ backlog %.1fs, catching up", CCStreamTag(st),
                   (double)backlog / 32000.0);
        }
    } else {
        st.catchingUp = NO;
    }
    if (backlog > maxRead) backlog = maxRead;

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
    if (!fh) return;
    [fh seekToFileOffset:st.offset];
    NSData *d = [fh readDataOfLength:(NSUInteger)backlog];
    [fh closeFile];
    NSUInteger n = d.length & ~(NSUInteger)1;
    if (n == 0) return;
    st.offset += n;

    const int16_t *s = (const int16_t *)d.bytes;
    NSUInteger cnt = n / 2;

    // VAD + 音量归一（电话音频常只有 0.01 左右）
    double sum = 0;
    for (NSUInteger i = 0; i < cnt; i++) sum += fabs((double)s[i]);
    double avg = cnt ? sum / (double)cnt / 32768.0 : 0;
    if (avg > 0.002) {
        double want = 0.05 / avg;
        if (want > 8.0) want = 8.0;
        if (want < 1.0) want = 1.0;
        st.gain = st.gain * 0.70 + want * 0.30;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (avg > 0.006) { st.hadVoice = YES; st.lastVoiceAt = now; }

    CCStreamFeed(st, s, cnt);

    // 断句完全交给识别结果自己：只认句末标点。
    // 不再按静音时长、文本稳定时长或词数做任何判断（用户铁律：不干预）。
    if (st.text.length) {
        NSString *tail = CCStreamNewTail(st.text, st.delivered);
        if (tail.length && CCStreamHasSentenceEnd(tail)) {
            CCStreamDeliver(st);
        }
    }

    // Apple 单会话约 1 分钟：55 秒时收句并轮换，间隙音频进 pending
    if (st.task && now - st.sessionStart > 55.0 && !st.rotating) {
        CCLogf(@"stream %@ rotate at 55s", CCStreamTag(st));
        CCStreamDeliver(st);
        st.rotating = YES;
        [st.req endAudio];
    }
}

static void CCStreamCallActive(BOOL active) {
    CCStream *r = CCStreamFor(NO);
    CCStream *l = CCStreamFor(YES);
    if (active) {
        CCStreamReset(r);
        CCStreamReset(l);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        r.callStart = now;
        l.callStart = now;
        BOOL cloud = CCPrefBool(CC_K_CLOUD_ASR, YES);
        r.onDevice = !cloud;
        l.onDevice = !cloud;
        CCLogf(@"stream: call active, cloud=%d localPaused=%d", cloud,
               g_localStreamPaused);
    } else {
        CCStreamStop(r);
        CCStreamStop(l);
        CCLogf(@"stream: call ended");
    }
}

static void CCStreamTimerTick(void) {
    if (!g_uiReady || !g_callActive) return;
    CCStreamTick(CCStreamFor(NO));
    CCStreamTick(CCStreamFor(YES));
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
                if (!g_sbTimer) {
                    g_sbTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                repeats:YES
                                                                  block:^(NSTimer *t) {
                        // 旧分块识别只在流式识别连续失败后才兜底启用
                        if (g_rs && g_rs.legacy) CCRemoteFileTick();
                        if (g_ls && g_ls.legacy) CCLocalFileTick();
                    }];
                }
                if (!g_streamTimer) {
                    g_streamTimer = [NSTimer scheduledTimerWithTimeInterval:0.2
                                                                    repeats:YES
                                                                      block:^(NSTimer *t) {
                        CCStreamTimerTick();
                    }];
                }
            } @catch (NSException *e) {
                CCLogf(@"ui boot exc: %@", e.reason);
            }
        });
        CCLogLine(@"CallCaption UI booted (single window v0.16.8)");
    } @catch (NSException *e) {
        CCMark(@"ui BOOT EXCEPTION!");
    }
}
