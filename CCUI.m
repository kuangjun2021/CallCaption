// CCUI.m — v0.12.2 通话 UI：折叠式面板 + 双字幕框（原文 / 译文）
#import "CCCommon.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>

static UIWindow *g_panelWin;
static UIButton *g_btns[5];
static UIWindow *g_miniWin;
static CXCallObserver *g_callObs;
static id g_callWatcher;
static BOOL g_callActive;
static BOOL g_panelExpanded;

static UIWindow *g_remoteWin;
static NSTimer *g_remoteHide;
static UIWindow *g_localWin;
static NSTimer *g_localHide;

static BOOL g_sessionActive;
static BOOL g_uiReady;
static BOOL g_captionBuilt;
static NSString *g_texts[4];       // 0 对方原文 / 1 对方译文 / 2 我方原文 / 3 我方译文
static NSString *g_stateText;

static UIView *g_panelCard;
static UIWindow *g_settingsWin;

static CGFloat ScreenW(void) { return [UIScreen mainScreen].bounds.size.width; }
static CGFloat ScreenH(void) { return [UIScreen mainScreen].bounds.size.height; }
static CGFloat CardWidth(void) { return MIN(ScreenW() * 0.92, 430.0); }

static UIColor *BlueTitle(void)  { return [UIColor colorWithRed:0.46 green:0.68 blue:1.00 alpha:1]; }
static UIColor *GreenTitle(void) { return [UIColor colorWithRed:0.48 green:0.90 blue:0.58 alpha:1]; }

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

static void AttachScene(UIWindow *win) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                win.windowScene = (UIWindowScene *)sc;
                break;
            }
        }
    }
}



// 在 SpringBoard 内直接弹出设置（不经过 Settings.app）
static void CCOpenSettings(void) {
    @try {
        if (!g_settingsWin) {
            Class cls = NSClassFromString(@"CCSettingsController");
            if (!cls) { CCLogf(@"settings: class missing"); return; }
            g_settingsWin = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
            g_settingsWin.windowLevel = UIWindowLevelAlert + 50;
            UIViewController *vc = [[cls alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            g_settingsWin.rootViewController = nav;
        }
        AttachScene(g_settingsWin);
        g_settingsWin.hidden = NO;
        CCLogf(@"settings: opened in SpringBoard");
    } @catch (NSException *e) { CCLogf(@"settings exc: %@", e.reason); }
}

@class CCUIHelper;
@interface CCUIHelper : NSObject
+ (void)hideCaption;
+ (void)toggleSession;
+ (void)refreshPanel;
+ (void)panelButtonTapped:(UIButton *)b;
+ (void)handlePanelPan:(UIPanGestureRecognizer *)p;
+ (void)handleBoxPan:(UIPanGestureRecognizer *)p;
+ (void)collapsePanel;
+ (void)expandPanel;
+ (void)handleMiniPan:(UIPanGestureRecognizer *)p;
+ (void)outsideTapped:(id)sender;
+ (void)openSettings:(id)sender;
@end

static void CCUIHandleCallActive(BOOL active);
static void RefreshBoxes(void);

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



@interface CCPanelBGView : UIView
@property (nonatomic, weak) UIView *card;
@end
@implementation CCPanelBGView
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    BOOL inside = (self.card && CGRectContainsPoint(self.card.frame, p));
    CCLogf(@"panel: bg touch %.0f,%.0f insideCard=%d", p.x, p.y, inside);
    if (inside) { [super touchesEnded:touches withEvent:event]; return; }
    [[CCUIHelper class] outsideTapped:nil];
}
@end

// ---------- 控制面板 ----------

static void EnsurePanelUI(void) {
    if (g_panelWin) return;
    @try {
        CGFloat w = CardWidth();
        CGFloat h = 150;
        UIWindow *win = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        win.windowLevel = UIWindowLevelAlert + 10;
        win.backgroundColor = [UIColor clearColor];

        CCPanelBGView *bg = [[CCPanelBGView alloc] initWithFrame:win.bounds];
        bg.backgroundColor = [UIColor clearColor];
        [win addSubview:bg];


        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = CGRectMake((ScreenW() - w) / 2.0, ScreenH() - h - 150, w, h);
        blur.layer.cornerRadius = 22;
        blur.layer.masksToBounds = YES;
        [bg addSubview:blur];
        bg.card = blur;

        UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
        ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.20];
        ov.userInteractionEnabled = NO;
        [blur.contentView addSubview:ov];
        blur.layer.borderWidth = 0.8;
        blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, w, 18)];
        title.text = @"CallCaption";
        title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        title.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        title.textAlignment = NSTextAlignmentCenter;
        [blur.contentView addSubview:title];

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

        AttachScene(win);
        win.hidden = YES;
        g_panelWin = win;
        g_panelCard = blur;
    } @catch (NSException *e) { }
}

static void EnsureMiniUI(void) {
    if (g_miniWin) return;
    @try {
        CGFloat s = 64.0;
        UIWindow *win = [[UIWindow alloc] initWithFrame:
            CGRectMake(ScreenW() - s - 16, ScreenH() * 0.52, s, s)];
        win.windowLevel = UIWindowLevelAlert + 11;
        win.backgroundColor = [UIColor clearColor];

        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(0, 0, s, s);
        b.layer.cornerRadius = s / 2.0;
        b.layer.masksToBounds = YES;
        b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.95];
        UIImage *img = [UIImage systemImageNamed:@"globe"
                           withConfiguration:[UIImageSymbolConfiguration
                               configurationWithPointSize:26 weight:UIFontWeightMedium]];
        [b setImage:img forState:UIControlStateNormal];
        b.tintColor = [UIColor colorWithWhite:0.12 alpha:1];
        [b addTarget:[CCUIHelper class] action:@selector(expandPanel)
            forControlEvents:UIControlEventTouchUpInside];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handleMiniPan:)];
        [b addGestureRecognizer:pan];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(openSettings:)];
        [b addGestureRecognizer:lp];

        [win addSubview:b];
        AttachScene(win);
        win.hidden = YES;
        g_miniWin = win;
    } @catch (NSException *e) { }
}

// ---------- 双字幕框（LCT 风格：Remote / Local 各一框） ----------

static UIWindow *MakeLCTBox(NSString *recogHeader) {
    CGFloat w = CardWidth();
    UIWindow *win = [[UIWindow alloc] initWithFrame:
        CGRectMake((ScreenW() - w) / 2.0, ScreenH() - 520, w, 10)];
    win.windowLevel = UIWindowLevelStatusBar + 101;
    win.backgroundColor = [UIColor clearColor];

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = win.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 18;
    blur.layer.masksToBounds = YES;
    blur.layer.borderWidth = 0.8;
    blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    [win addSubview:blur];

    UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
    ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
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
    t.textColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.38 alpha:1.0];
    t.numberOfLines = 0;
    [blur.contentView addSubview:t];

    UILabel *c = [[UILabel alloc] initWithFrame:CGRectZero];
    c.tag = 1005;
    c.text = @"Translated by Google";
    c.font = [UIFont systemFontOfSize:11];
    c.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    c.textAlignment = NSTextAlignmentRight;
    [blur.contentView addSubview:c];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:[CCUIHelper class] action:@selector(handleBoxPan:)];
    [blur addGestureRecognizer:pan];

    AttachScene(win);
    win.hidden = YES;
    return win;
}

static void EnsureCaptionUI(void) {
    if (g_captionBuilt) return;
    @try {
        g_remoteWin = MakeLCTBox(@"Recognized Remote:");
        NSNumber *rx = CCPref(@"RemoteBoxX"), *ry = CCPref(@"RemoteBoxY");
        if ([rx isKindOfClass:[NSNumber class]] && [ry isKindOfClass:[NSNumber class]]) {
            g_remoteWin.center = CGPointMake([rx floatValue], [ry floatValue]);
        } else {
            g_remoteWin.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 520);
        }

        g_localWin = MakeLCTBox(@"Recognized Local:");
        NSNumber *lx = CCPref(@"LocalBoxX"), *ly = CCPref(@"LocalBoxY");
        if ([lx isKindOfClass:[NSNumber class]] && [ly isKindOfClass:[NSNumber class]]) {
            g_localWin.center = CGPointMake([lx floatValue], [ly floatValue]);
        } else {
            g_localWin.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 340);
        }
        g_captionBuilt = YES;
    } @catch (NSException *e) { }
}

static void LayoutLCTBox(UIWindow *win, NSString *recog, NSString *trans,
                         BOOL showRecog, BOOL showTrans) {
    if (!win) return;
    UILabel *h = (UILabel *)[win viewWithTag:1001];
    UILabel *r = (UILabel *)[win viewWithTag:1002];
    UILabel *sh = (UILabel *)[win viewWithTag:1003];
    UILabel *t = (UILabel *)[win viewWithTag:1004];
    UILabel *c = (UILabel *)[win viewWithTag:1005];
    CGFloat w = win.bounds.size.width;
    CGFloat pad = 16.0;
    CGFloat cw = w - pad * 2.0;
    CGFloat y = 14.0;
    BOOL any = NO;

    if (showRecog && recog.length) {
        any = YES;
        h.hidden = NO; r.hidden = NO;
        h.frame = CGRectMake(0, y, w, 16); y += 20.0;
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
        t.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
        CGFloat hh = TextHeight(trans, t.font, cw);
        t.frame = CGRectMake(pad, y, cw, hh); y += hh + 14.0;
        c.frame = CGRectMake(pad, y, cw, 14); y += 18.0;
    } else {
        sh.hidden = YES; t.hidden = YES; c.hidden = YES;
    }

    if (!any) { win.hidden = YES; return; }
    CGRect f = win.frame;
    CGPoint cen = win.center;
    f.size.height = y;
    win.frame = f;
    win.center = cen;
    UIVisualEffectView *blur = (UIVisualEffectView *)win.subviews.firstObject;
    blur.frame = win.bounds;
    win.hidden = NO;
    win.alpha = 1.0;
}

static void ResetRemoteTimer(void) {
    [g_remoteHide invalidate];
    g_remoteHide = [NSTimer timerWithTimeInterval:8.0 target:[CCUIHelper class]
                                          selector:@selector(hideCaption)
                                          userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_remoteHide forMode:NSRunLoopCommonModes];
}
static void ResetLocalTimer(void) {
    [g_localHide invalidate];
    g_localHide = [NSTimer timerWithTimeInterval:8.0 target:[CCUIHelper class]
                                         selector:@selector(hideCaption)
                                         userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_localHide forMode:NSRunLoopCommonModes];
}

static void RefreshBoxes(void) {
    if (!g_captionBuilt) return;
    BOOL showR = CCPrefBool(CC_K_SHOW_RECOGNIZED, YES);
    BOOL showT = CCPrefBool(CC_K_SHOW_TRANSLATED, YES);
    BOOL remoteOn = CCPrefBool(CC_K_REMOTE_ENABLED, YES);
    BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, NO);

    LayoutLCTBox(g_remoteWin, g_texts[0], g_texts[1], showR, showT);
    if (!remoteOn) g_remoteWin.hidden = YES;
    LayoutLCTBox(g_localWin, g_texts[2], g_texts[3], showR, showT);
    if (!localOn) g_localWin.hidden = YES;

    if (!g_remoteWin.hidden) ResetRemoteTimer();
    if (!g_localWin.hidden) ResetLocalTimer();
}

// ---------- 交付 ----------

void CCUIDeliverRemoteOriginal(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ g_texts[0] = text ?: @""; RefreshBoxes(); });
}
void CCUIDeliverRemoteTranslated(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ g_texts[1] = text ?: @""; RefreshBoxes(); });
}
void CCUIDeliverLocalOriginal(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ g_texts[2] = text ?: @""; RefreshBoxes(); });
}
void CCUIDeliverLocalTranslated(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{ g_texts[3] = text ?: @""; RefreshBoxes(); });
}
void CCUIDeliverState(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_stateText = state ?: @"";
        CCLogf(@"ui state: %@", g_stateText);
    });
}
void CCUIDeliverCaption(NSString *translated) { CCUIDeliverRemoteTranslated(translated); }
void CCUIDeliverOriginal(NSString *original) { CCUIDeliverRemoteOriginal(original); }
void CCUIRefreshPanel(void) { [[CCUIHelper class] refreshPanel]; }

// ---------- 交互 ----------

@implementation CCUIHelper

+ (void)hideCaption {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray *wins = @[g_remoteWin ?: [NSNull null], g_localWin ?: [NSNull null]];
        for (id obj in wins) {
            if (![obj isKindOfClass:[UIWindow class]]) continue;
            UIWindow *w = (UIWindow *)obj;
            if (w.hidden) continue;
            [UIView animateWithDuration:0.4 animations:^{ w.alpha = 0; }
                             completion:^(BOOL f) { if (f) w.hidden = YES; }];
        }
    });
}

+ (void)toggleSession {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_sessionActive = !g_sessionActive;
        CCSetArmed(g_sessionActive);
        [self refreshPanel];
        CCLogf(@"session %@", g_sessionActive ? @"ARMED" : @"DISARMED");
        if (!g_sessionActive) {
            g_texts[0] = g_texts[1] = g_texts[2] = g_texts[3] = @"";
            [self hideCaption];
        }
    });
}

+ (void)refreshPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_panelWin) return;
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
    });
}

+ (void)panelButtonTapped:(UIButton *)b {
    switch (b.tag) {
        case 0:
            [self toggleSession];
            break;
        case 1:
            CCSetPrefBool(CC_K_LOCAL_ENABLED, !CCPrefBool(CC_K_LOCAL_ENABLED, NO));
            break;
        case 2:
            CCSetPrefBool(CC_K_REMOTE_ENABLED, !CCPrefBool(CC_K_REMOTE_ENABLED, YES));
            break;
        case 3:
            CCSetPrefBool(CC_K_SHOW_RECOGNIZED, !CCPrefBool(CC_K_SHOW_RECOGNIZED, YES));
            break;
        case 4:
            CCSetPrefBool(CC_K_SHOW_TRANSLATED, !CCPrefBool(CC_K_SHOW_TRANSLATED, YES));
            break;
    }
    [self refreshPanel];
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshBoxes(); });
}

+ (void)collapsePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCLogf(@"panel: collapse");
        if (!g_panelWin) return;
        EnsureMiniUI();
        g_miniWin.center = g_panelCard.center;
        g_miniWin.hidden = NO;
        g_miniWin.alpha = 0.0;
        [UIView animateWithDuration:0.18 animations:^{
            g_miniWin.alpha = 1.0;
            g_panelWin.alpha = 0.0;
        } completion:^(BOOL finished) {
            g_panelWin.hidden = YES;
            g_panelWin.alpha = 1.0;
        }];
        g_panelExpanded = NO;
    });
}

+ (void)expandPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        CCLogf(@"panel: expand");
        if (g_miniWin) g_miniWin.hidden = YES;
        EnsurePanelUI();
        g_panelWin.hidden = NO;
        g_panelExpanded = YES;
        [self refreshPanel];
    });
}

+ (void)outsideTapped:(id)sender {
    CCLogf(@"panel: outside tap (expanded=%d)", g_panelExpanded);
    [self collapsePanel];
}

+ (void)openSettings:(id)sender {
    CCOpenSettings();
}

+ (void)handlePanelPan:(UIPanGestureRecognizer *)p {
    UIView *card = g_panelCard;
    if (!card) return;
    CGPoint t = [p translationInView:nil];
    CGRect f = card.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    if (f.origin.x < 0) f.origin.x = 0;
    if (f.origin.x > ScreenW() - f.size.width) f.origin.x = ScreenW() - f.size.width;
    if (f.origin.y < 60) f.origin.y = 60;
    if (f.origin.y > ScreenH() - 120) f.origin.y = ScreenH() - 120;
    card.frame = f;
    [p setTranslation:CGPointZero inView:nil];
}

+ (void)handleMiniPan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:nil];
    CGRect f = g_miniWin.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    if (f.origin.y < 60) f.origin.y = 60;
    if (f.origin.y > ScreenH() - 80) f.origin.y = ScreenH() - 80;
    g_miniWin.frame = f;
    [p setTranslation:CGPointZero inView:nil];
}

+ (void)handleBoxPan:(UIPanGestureRecognizer *)p {
    UIWindow *win = p.view.window;
    CGPoint t = [p translationInView:nil];
    CGPoint c = win.center;
    c.x += t.x;
    c.y += t.y;
    if (c.y < 80) c.y = 80;
    if (c.y > ScreenH() - 60) c.y = ScreenH() - 60;
    win.center = c;
    [p setTranslation:CGPointZero inView:nil];
    if (p.state == UIGestureRecognizerStateEnded) {
        if (win == g_remoteWin) SavePos(@"RemoteBoxX", @"RemoteBoxY", c);
        else SavePos(@"LocalBoxX", @"LocalBoxY", c);
    }
}

@end

// ---------- 通话状态 ----------

static void CCUIHandleCallActive(BOOL active) {
    if (g_callActive == active) return;
    g_callActive = active;
    CCLogf(@"call state: %@", active ? @"ACTIVE" : @"NONE");
    if (active) {
        // 通话开始：自动激活（面板保持收起，点小地球展开后可手动关）
        if (!g_sessionActive && CCPrefBool(CC_K_ENABLED, YES)) {
            g_sessionActive = YES;
            CCSetArmed(YES);
        }
        EnsureMiniUI();
        g_miniWin.hidden = NO;
        g_panelWin.hidden = YES;
        g_panelExpanded = NO;
        if (CCPrefBool(CC_K_ALWAYS_PANEL, NO)) [[CCUIHelper class] expandPanel];
    } else {
        if (g_sessionActive) {
            g_sessionActive = NO;
            CCSetArmed(NO);
        }
        g_texts[0] = g_texts[1] = g_texts[2] = g_texts[3] = @"";
        if (g_panelWin) g_panelWin.hidden = YES;
        if (g_miniWin) g_miniWin.hidden = YES;
        g_panelExpanded = NO;
        [[CCUIHelper class] hideCaption];
    }
}

// ---------- TTS ----------

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

// ---------- 启动 ----------

void CCUIBoot(void) {
    @try {
        if (!CCIsSpringBoard() || g_uiReady) return;
        g_uiReady = YES;
        CCMark(@"ui 7.1 boot enter");
        CCTransportBoot();
        @try { [[NSFileManager defaultManager] removeItemAtPath:CC_ARM_PATH error:nil]; }
        @catch (NSException *e) { }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            @try {
                if (!g_callObs) {
                    g_callWatcher = [CCUICallWatcher new];
                    g_callObs = [[CXCallObserver alloc] init];
                    [g_callObs setDelegate:g_callWatcher queue:dispatch_get_main_queue()];
                }
                BOOL active = NO;
                for (CXCall *c in g_callObs.calls) {
                    if (!c.hasEnded) { active = YES; break; }
                }
                g_callActive = active;
                EnsureCaptionUI();
                if (active) {
                    if (CCPrefBool(CC_K_ENABLED, YES) && !g_sessionActive) {
                        g_sessionActive = YES;
                        CCSetArmed(YES);
                    }
                    EnsureMiniUI();
                    g_miniWin.hidden = NO;
                    if (CCPrefBool(CC_K_ALWAYS_PANEL, NO)) [[CCUIHelper class] expandPanel];
                }
            } @catch (NSException *e) { }
        });
        CCLogLine(@"CallCaption UI booted (dual boxes)");
    } @catch (NSException *e) {
        CCMark(@"ui BOOT EXCEPTION!");
    }
}
