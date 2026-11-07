// CCUI.m — v0.12.1 通话中 UI：控制面板（5 圆钮）+ 分区字幕卡 + 通话自动唤起/收起
#import "CCCommon.h"
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CallKit/CallKit.h>

static UIWindow *g_panelWin;
static UIView *g_panelCard;
static UIButton *g_btns[5];

static UIWindow *g_miniWin;
static CXCallObserver *g_callObs;
static id g_callWatcher;
static BOOL g_callActive;

static UIWindow *g_capWin;
static UIView *g_capCard;
static UILabel *g_rowTitle[4];
static UILabel *g_rowText[4];
static UILabel *g_stateLabel;
static NSTimer *g_hideTimer;
static BOOL g_sessionActive;
static BOOL g_uiReady;
static BOOL g_captionBuilt;
static NSString *g_texts[4];       // 0 对方原文 / 1 对方译文 / 2 我方原文 / 3 我方译文
static NSString *g_stateText;

static CGFloat ScreenW(void) { return [UIScreen mainScreen].bounds.size.width; }
static CGFloat ScreenH(void) { return [UIScreen mainScreen].bounds.size.height; }
static CGFloat CardWidth(void) { return MIN(ScreenW() * 0.92, 430.0); }

// 与设计稿保持一致的配色
static UIColor *BlueTitle(void)  { return [UIColor colorWithRed:0.46 green:0.68 blue:1.00 alpha:1]; }
static UIColor *GreenTitle(void) { return [UIColor colorWithRed:0.48 green:0.90 blue:0.58 alpha:1]; }

static void SaveCaptionPos(CGPoint center) {
    CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_CAPTION_X,
                             (__bridge CFPropertyListRef)@(center.x),
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_CAPTION_Y,
                             (__bridge CFPropertyListRef)@(center.y),
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

static UIFont *RowFont(int i, BOOL large) {
    CGFloat base = (i == 1) ? 18.0 : ((i == 3) ? 16.0 : 15.0);
    if (large) base += 3.0;
    UIFontWeight w = (i == 1 || i == 3) ? UIFontWeightSemibold : UIFontWeightRegular;
    return [UIFont systemFontOfSize:base weight:w];
}

static NSString *RowTitle(int i) {
    switch (i) {
        case 0: return @"Recognized Remote";
        case 1: return @"Translated";
        case 2: return @"Recognized Local";
        default: return @"Did speak";
    }
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

@interface CCUIHelper : NSObject
+ (void)hideCaption;
+ (void)toggleSession;
+ (void)refreshPanel;
+ (void)panelButtonTapped:(UIButton *)b;
+ (void)handlePanelPan:(UIPanGestureRecognizer *)p;
+ (void)handleCaptionPan:(UIPanGestureRecognizer *)p;
+ (void)collapsePanel;
+ (void)expandPanel;
+ (void)handleMiniPan:(UIPanGestureRecognizer *)p;
@end

static void CCUIHandleCallActive(BOOL active);

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

static void RelayoutCaption(void);

// ---------- 控制面板 ----------

static void EnsurePanelUI(void) {
    if (g_panelWin) return;
    @try {
        CGFloat w = CardWidth();
        CGFloat h = 150;
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake((ScreenW() - w) / 2.0,
                                                                   ScreenH() - h - 150, w, h)];
        win.windowLevel = UIWindowLevelStatusBar + 102;
        win.backgroundColor = [UIColor clearColor];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = win.bounds;
        blur.layer.cornerRadius = 22;
        blur.layer.masksToBounds = YES;
        [win addSubview:blur];

        UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
        ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.28];
        ov.userInteractionEnabled = NO;
        [blur.contentView addSubview:ov];

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
            b.tintColor = [UIColor whiteColor];
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

        // 长按地球：手动开/关翻译；点按地球：收起面板
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(toggleSession)];
        [g_btns[0] addGestureRecognizer:lp];

        AttachScene(win);
        win.hidden = YES;
        g_panelWin = win;
        g_panelCard = blur;
    } @catch (NSException *e) { }
}

// ---------- 字幕卡 ----------

static void EnsureCaptionUI(void) {
    if (g_captionBuilt) return;
    @try {
        CGFloat w = CardWidth();
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake((ScreenW() - w) / 2.0,
                                                                   ScreenH() - 420, w, 10)];
        win.windowLevel = UIWindowLevelStatusBar + 101;
        win.backgroundColor = [UIColor clearColor];

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
        blur.frame = win.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.layer.cornerRadius = 18;
        blur.layer.masksToBounds = YES;
        [win addSubview:blur];

        UIView *ov = [[UIView alloc] initWithFrame:blur.bounds];
        ov.backgroundColor = [UIColor colorWithWhite:0 alpha:0.30];
        ov.userInteractionEnabled = NO;
        ov.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [blur.contentView addSubview:ov];

        for (int i = 0; i < 4; i++) {
            UILabel *t = [[UILabel alloc] initWithFrame:CGRectZero];
            t.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            t.textColor = (i % 2 == 0) ? BlueTitle() : GreenTitle();
            t.text = RowTitle(i);
            [blur.contentView addSubview:t];
            g_rowTitle[i] = t;

            UILabel *x = [[UILabel alloc] initWithFrame:CGRectZero];
            x.font = RowFont(i, NO);
            x.textColor = [UIColor colorWithWhite:1 alpha:0.95];
            x.numberOfLines = 0;
            [blur.contentView addSubview:x];
            g_rowText[i] = x;
        }

        UILabel *st = [[UILabel alloc] initWithFrame:CGRectZero];
        st.font = [UIFont systemFontOfSize:11];
        st.textColor = [UIColor colorWithWhite:1 alpha:0.5];
        st.numberOfLines = 0;
        [blur.contentView addSubview:st];
        g_stateLabel = st;

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handleCaptionPan:)];
        [blur addGestureRecognizer:pan];

        NSNumber *px = CCPref(CC_K_CAPTION_X), *py = CCPref(CC_K_CAPTION_Y);
        if ([px isKindOfClass:[NSNumber class]] && [py isKindOfClass:[NSNumber class]]) {
            win.center = CGPointMake([px floatValue], [py floatValue]);
        } else {
            win.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 360);
        }

        AttachScene(win);
        win.hidden = YES;
        g_capWin = win;
        g_capCard = blur;
        g_captionBuilt = YES;
    } @catch (NSException *e) { }
}

// ---------- 迷你地球（收起态） ----------

static void EnsureMiniUI(void) {
    if (g_miniWin) return;
    @try {
        CGFloat s = 64.0;
        UIWindow *win = [[UIWindow alloc] initWithFrame:
            CGRectMake(ScreenW() - s - 16, ScreenH() * 0.52, s, s)];
        win.windowLevel = UIWindowLevelStatusBar + 103;
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

        [win addSubview:b];
        AttachScene(win);
        win.hidden = YES;
        g_miniWin = win;
    } @catch (NSException *e) { }
}

// 仅在通话中显示（或设置里开启常驻）
static void ShowPanelForState(void) {
    if (!CCPrefBool(CC_K_ENABLED, YES)) {
        if (g_panelWin) g_panelWin.hidden = YES;
        if (g_miniWin) g_miniWin.hidden = YES;
        return;
    }
    if (g_callActive || CCPrefBool(CC_K_ALWAYS_PANEL, NO)) {
        EnsurePanelUI();
        g_panelWin.hidden = NO;
        g_panelWin.alpha = 1.0;
        [[CCUIHelper class] refreshPanel];
    } else {
        if (g_panelWin) g_panelWin.hidden = YES;
        if (g_miniWin) g_miniWin.hidden = YES;
    }
}

static void RelayoutCaption(void) {
    if (!g_capWin) return;
    CGFloat w = g_capWin.bounds.size.width;
    CGFloat pad = 16.0;
    CGFloat contentW = w - pad * 2.0;
    BOOL showR = CCPrefBool(CC_K_SHOW_RECOGNIZED, YES);
    BOOL showT = CCPrefBool(CC_K_SHOW_TRANSLATED, YES);
    BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, NO);
    BOOL large = CCPrefBool(CC_K_LARGE_CAPTIONS, NO);

    CGFloat y = 14.0;
    BOOL any = NO;

    for (int i = 0; i < 4; i++) {
        BOOL vis = NO;
        if (i == 0) vis = showR && g_texts[0].length > 0;
        if (i == 1) vis = showT && g_texts[1].length > 0;
        if (i == 2) vis = localOn && showR && g_texts[2].length > 0;
        if (i == 3) vis = localOn && showT && g_texts[3].length > 0;

        UILabel *t = g_rowTitle[i];
        UILabel *x = g_rowText[i];
        if (!vis) { t.hidden = YES; x.hidden = YES; continue; }

        any = YES;
        t.hidden = NO;
        x.hidden = NO;
        t.frame = CGRectMake(pad, y, contentW, 14);
        y += 16.0;

        x.font = RowFont(i, large);
        CGFloat h = TextHeight(g_texts[i], x.font, contentW);
        x.frame = CGRectMake(pad, y, contentW, h);
        y += h + 10.0;
    }

    if (g_stateText.length > 0) {
        any = YES;
        g_stateLabel.hidden = NO;
        g_stateLabel.font = [UIFont systemFontOfSize:11];
        CGFloat h = TextHeight(g_stateText, g_stateLabel.font, contentW);
        g_stateLabel.frame = CGRectMake(pad, y, contentW, h);
        y += h + 8.0;
    } else {
        g_stateLabel.hidden = YES;
    }

    CGFloat newH = any ? (y + 6.0) : 10.0;
    CGRect f = g_capWin.frame;
    CGPoint c = g_capWin.center;
    f.size.height = newH;
    g_capWin.frame = f;
    g_capWin.center = c;
    g_capCard.frame = g_capWin.bounds;
}

static void ShowCaptionNow(void) {
    if (!g_capWin) return;
    g_capWin.hidden = NO;
    g_capWin.alpha = 1.0;
}

static void ResetHideTimer(void) {
    [g_hideTimer invalidate];
    g_hideTimer = [NSTimer timerWithTimeInterval:8.0 target:[CCUIHelper class]
                                        selector:@selector(hideCaption)
                                        userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_hideTimer forMode:NSRunLoopCommonModes];
}

static void RefreshCaptionAndShow(void) {
    RelayoutCaption();
    BOOL any = NO;
    for (int i = 0; i < 4; i++) {
        if (!g_rowText[i].hidden) { any = YES; break; }
    }
    if (!any && g_stateText.length == 0) return;
    ShowCaptionNow();
    ResetHideTimer();
}

// ---------- 交付 ----------

void CCUIDeliverRemoteOriginal(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_texts[0] = text ?: @"";
        RefreshCaptionAndShow();
    });
}
void CCUIDeliverRemoteTranslated(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_texts[1] = text ?: @"";
        RefreshCaptionAndShow();
    });
}
void CCUIDeliverLocalOriginal(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_texts[2] = text ?: @"";
        RefreshCaptionAndShow();
    });
}
void CCUIDeliverLocalTranslated(NSString *text) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_texts[3] = text ?: @"";
        RefreshCaptionAndShow();
    });
}
void CCUIDeliverState(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_stateText = state ?: @"";
        RefreshCaptionAndShow();
    });
}

// 兼容旧接口（CCMicCapture 遗留）
void CCUIDeliverCaption(NSString *translated) { CCUIDeliverRemoteTranslated(translated); }
void CCUIDeliverOriginal(NSString *original) { CCUIDeliverRemoteOriginal(original); }

void CCUIRefreshPanel(void) { [[CCUIHelper class] refreshPanel]; }

// ---------- 交互 ----------

@implementation CCUIHelper

+ (void)hideCaption {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_capWin) return;
            [UIView animateWithDuration:0.4 animations:^{
                g_capWin.alpha = 0.0;
            } completion:^(BOOL fin) {
                if (fin && g_capWin.alpha < 0.01) g_capWin.hidden = YES;
            }];
        } @catch (NSException *e) { }
    });
}

+ (void)toggleSession {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            g_sessionActive = !g_sessionActive;
            CCSetArmed(g_sessionActive);
            [self refreshPanel];
            CCLogf(@"session %@", g_sessionActive ? @"ARMED" : @"DISARMED");
            if (!g_sessionActive) {
                g_stateText = nil;
                [self hideCaption];
            } else {
                g_stateText = @"● 已开启，等待语音";
                RelayoutCaption();
                ShowCaptionNow();
                ResetHideTimer();
            }
        } @catch (NSException *e) { }
    });
}

+ (void)refreshPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
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
        } @catch (NSException *e) { }
    });
}

+ (void)collapsePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_panelWin) return;
            EnsureMiniUI();
            g_miniWin.center = g_panelWin.center;
            g_miniWin.hidden = NO;
            g_panelWin.hidden = YES;
        } @catch (NSException *e) { }
    });
}

+ (void)expandPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (g_miniWin) g_miniWin.hidden = YES;
            EnsurePanelUI();
            g_panelWin.hidden = NO;
            [self refreshPanel];
        } @catch (NSException *e) { }
    });
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

+ (void)panelButtonTapped:(UIButton *)b {
    switch (b.tag) {
        case 0:
            [self collapsePanel];
            return;
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
    dispatch_async(dispatch_get_main_queue(), ^{
        RefreshCaptionAndShow();
    });
}

+ (void)handlePanelPan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:nil];
    CGRect f = g_panelWin.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    if (f.origin.y < 60) f.origin.y = 60;
    if (f.origin.y > ScreenH() - 120) f.origin.y = ScreenH() - 120;
    if (f.origin.x < -f.size.width * 0.4) f.origin.x = -f.size.width * 0.4;
    if (f.origin.x > ScreenW() - f.size.width * 0.6)
        f.origin.x = ScreenW() - f.size.width * 0.6;
    g_panelWin.frame = f;
    [p setTranslation:CGPointZero inView:nil];
}

+ (void)handleCaptionPan:(UIPanGestureRecognizer *)p {
    CGPoint t = [p translationInView:nil];
    CGPoint c = g_capWin.center;
    c.x += t.x;
    c.y += t.y;
    if (c.y < 80) c.y = 80;
    if (c.y > ScreenH() - 60) c.y = ScreenH() - 60;
    g_capWin.center = c;
    [p setTranslation:CGPointZero inView:nil];
    if (p.state == UIGestureRecognizerStateEnded) SaveCaptionPos(c);
}

@end

// ---------- 通话自动唤起 ----------

static void CCUIHandleCallActive(BOOL active) {
    if (g_callActive == active) return;
    g_callActive = active;
    CCLogf(@"call state: %@", active ? @"ACTIVE" : @"NONE");
    if (active) {
        if (!g_sessionActive && CCPrefBool(CC_K_ENABLED, YES)) {
            g_sessionActive = YES;
            CCSetArmed(YES);
            g_stateText = @"● 已开启，等待语音";
        }
        ShowPanelForState();
    } else {
        if (g_sessionActive) {
            g_sessionActive = NO;
            CCSetArmed(NO);
        }
        g_stateText = nil;
        if (g_panelWin) g_panelWin.hidden = YES;
        if (g_miniWin) g_miniWin.hidden = YES;
        [CCUIHelper hideCaption];
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

// ---------- 通话状态 ----------

void CCUICallStateChanged(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([state isEqualToString:@"CALL ENDED"]) {
                CCUIHandleCallActive(NO);
            }
        } @catch (NSException *e) { }
    });
}

// ---------- 启动 ----------

void CCUIBoot(void) {
    @try {
        if (!CCIsSpringBoard() || g_uiReady) return;
        g_uiReady = YES;
        CCMark(@"ui 6.1 boot enter");
        CCTransportBoot();
        CCMark(@"ui 6.2 transport ready");
        // 清理上次残留的采集开关
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
                if (active && CCPrefBool(CC_K_ENABLED, YES) && !g_sessionActive) {
                    g_sessionActive = YES;
                    CCSetArmed(YES);
                    g_stateText = @"● 已开启，等待语音";
                }
                ShowPanelForState();
            } @catch (NSException *e) { }
        });
        CCLogLine(@"CallCaption UI booted (panel + cards)");
    } @catch (NSException *e) {
        CCMark(@"ui BOOT EXCEPTION!");
    }
}
