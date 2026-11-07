// CCUI.m — SpringBoard 侧：悬浮字幕 + 快捷按钮（可拖动、毛玻璃、弹簧动画）
#import "CCCommon.h"
#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>

static UIWindow *g_capWin;
static UIView *g_card;
static UIVisualEffectView *g_blur;
static UILabel *g_origLabel;
static UILabel *g_capLabel;
static UILabel *g_stateLabel;
static NSTimer *g_hideTimer;
static BOOL g_collapsed;

static UIWindow *g_btnWin;
static UIButton *g_btn;
static BOOL g_sessionActive;
static BOOL g_uiReady;

static CTCallCenter *g_cc;

#define CAP_WIDTH  MIN(330.0, [UIScreen mainScreen].bounds.size.width * 0.72)

// ---------- 工具 ----------

static CGFloat ScreenW(void) { return [UIScreen mainScreen].bounds.size.width; }
static CGFloat ScreenH(void) { return [UIScreen mainScreen].bounds.size.height; }

static void SaveCaptionPos(CGPoint center) {
    CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_CAPTION_X,
                             (__bridge CFPropertyListRef)[[NSNumber alloc] initWithFloat:center.x],
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_CAPTION_Y,
                             (__bridge CFPropertyListRef)[[NSNumber alloc] initWithFloat:center.y],
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
}

// ---------- 字幕窗 ----------

@interface CCUIHelper : NSObject
+ (void)hideCaption;
+ (void)toggleSession;
+ (void)refreshButton;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)handleDoubleTap;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp;
@end

static void ResetHideTimer(void) {
    [g_hideTimer invalidate];
    g_hideTimer = [NSTimer timerWithTimeInterval:8.0 target:[CCUIHelper class]
                                        selector:@selector(hideCaption)
                                        userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:g_hideTimer forMode:NSRunLoopCommonModes];
}

static void UpdateCardLayout(void) {
    if (!g_capWin) return;
    CGFloat fontSize = CCPrefBool(CC_K_LARGE_CAPTIONS, NO) ? 22.0 : 17.0;
    g_capLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    g_origLabel.font = [UIFont systemFontOfSize:fontSize - 5.0];

    CGFloat inner = 14.0;
    CGFloat maxW = CAP_WIDTH - inner * 2;
    CGRect capRect = [g_capLabel.text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                                   options:NSStringDrawingUsesLineFragmentOrigin
                                                attributes:@{NSFontAttributeName: g_capLabel.font}
                                                   context:nil];
    CGRect origRect = g_origLabel.text.length
        ? [g_origLabel.text boundingRectWithSize:CGSizeMake(maxW, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin
                                      attributes:@{NSFontAttributeName: g_origLabel.font}
                                         context:nil]
        : CGRectZero;
    CGFloat showState = g_stateLabel.hidden ? 0 : 20.0;
    CGFloat h = inner * 2 + ceil(capRect.size.height) + ceil(origRect.size.height) + 4 + showState;
    CGFloat w = MAX(CAP_WIDTH, ceil(MAX(capRect.size.width, origRect.size.width)) + inner * 2);
    w = MIN(w, ScreenW() - 24);

    CGPoint center = g_capWin.center;
    CGRect f = CGRectMake(0, 0, w, h);
    g_card.frame = CGRectMake(0, 0, w, h);
    g_origLabel.frame = CGRectMake(inner, inner, w - inner * 2, ceil(origRect.size.height));
    g_capLabel.frame = CGRectMake(inner, inner + ceil(origRect.size.height) + 4,
                                  w - inner * 2, ceil(capRect.size.height));
    g_stateLabel.frame = CGRectMake(inner, h - inner - 14, w - inner * 2, 14);
    g_capWin.frame = f;
    g_capWin.center = center;
}

static void EnsureCaptionUI(void) {
    if (g_capWin) return;
    @try {
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, CAP_WIDTH, 90)];
        win.windowLevel = UIWindowLevelStatusBar + 100;
        win.backgroundColor = [UIColor clearColor];

        UIView *card = [[UIView alloc] initWithFrame:win.bounds];
        card.layer.cornerRadius = 16;
        card.layer.masksToBounds = YES;
        card.clipsToBounds = YES;

        UIVisualEffectView *blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.frame = card.bounds;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [card addSubview:blur];

        UILabel *orig = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, CAP_WIDTH - 28, 16)];
        orig.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        orig.font = [UIFont systemFontOfSize:12];
        orig.numberOfLines = 2;
        orig.textAlignment = NSTextAlignmentNatural;
        [card addSubview:orig];

        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(14, 30, CAP_WIDTH - 28, 24)];
        cap.textColor = [UIColor whiteColor];
        cap.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        cap.numberOfLines = 0;
        cap.textAlignment = NSTextAlignmentNatural;
        [card addSubview:cap];

        UILabel *state = [[UILabel alloc] initWithFrame:CGRectMake(14, card.bounds.size.height - 26,
                                                                   CAP_WIDTH - 28, 14)];
        state.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        state.font = [UIFont systemFontOfSize:11];
        state.text = @"● CallCaption";
        state.hidden = YES;
        [card addSubview:state];

        [win addSubview:card];

        // 拖动
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handlePan:)];
        [card addGestureRecognizer:pan];
        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handleDoubleTap)];
        dbl.numberOfTapsRequired = 2;
        [card addGestureRecognizer:dbl];

        g_origLabel = orig; g_capLabel = cap; g_stateLabel = state;
        g_card = card; g_blur = blur; g_capWin = win; g_collapsed = NO;

        // 恢复记忆位置
        NSNumber *x = CCPref(CC_K_CAPTION_X), *y = CCPref(CC_K_CAPTION_Y);
        if ([x isKindOfClass:[NSNumber class]] && [y isKindOfClass:[NSNumber class]]) {
            win.center = CGPointMake([x floatValue], [y floatValue]);
        } else {
            win.center = CGPointMake(ScreenW() / 2.0, ScreenH() - 300);
        }
        win.hidden = YES;
    } @catch (NSException *e) { }
}

static void EnsureButtonUI(void) {
    if (g_btnWin) return;
    @try {
        CGFloat w = 64, h = 34;
        UIWindow *win = [[UIWindow alloc] initWithFrame:CGRectMake(ScreenW() - w - 16,
                                                                   ScreenH() - 220, w, h)];
        win.windowLevel = UIWindowLevelStatusBar + 101;
        win.backgroundColor = [UIColor clearColor];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = win.bounds;
        btn.layer.cornerRadius = h / 2.0;
        btn.layer.masksToBounds = YES;
        btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:0.92];
        [btn setTitle:@"译" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        btn.layer.shadowColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:1].CGColor;
        btn.layer.shadowOpacity = 0.6;
        btn.layer.shadowRadius = 6;
        btn.layer.shadowOffset = CGSizeZero;

        [btn addTarget:[CCUIHelper class] action:@selector(toggleSession)
              forControlEvents:UIControlEventTouchUpInside];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handleLongPress:)];
        [btn addGestureRecognizer:lp];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[CCUIHelper class] action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];

        [win addSubview:btn];
        UIViewController *vc = [[UIViewController alloc] init];
        win.rootViewController = vc;
        g_btn = btn; g_btnWin = win;
        win.hidden = YES;
    } @catch (NSException *e) { }
}

// ---------- 对外交付 ----------

void CCUIDeliverState(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_capWin) return;
            g_stateLabel.hidden = NO;
            g_stateLabel.text = state;
            UpdateCardLayout();
        } @catch (NSException *e) { }
    });
}

void CCUIDeliverOriginal(NSString *original) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_capWin || !g_sessionActive) return;
            g_origLabel.text = original;
            UpdateCardLayout();
            ResetHideTimer();
        } @catch (NSException *e) { }
    });
}

void CCUIDeliverCaption(NSString *translated) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_capWin || !g_sessionActive) return;
            g_capLabel.text = translated;
            g_stateLabel.hidden = YES;
            g_collapsed = NO;
            UpdateCardLayout();
            g_capWin.hidden = NO;
            g_capWin.alpha = 1.0;
            [UIView animateWithDuration:0.25
                                  delay:0
                 usingSpringWithDamping:0.85
                  initialSpringVelocity:0.5
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{
                                 g_capWin.alpha = 1.0;
                             }
                             completion:nil];
            ResetHideTimer();
        } @catch (NSException *e) { }
    });
}

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

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    @try {
        UIWindow *win = nil;
        UIView *v = pan.view;
        // 找到按钮所在的窗或字幕窗
        if (v == g_btn) win = g_btnWin; else win = g_capWin;
        if (!win) return;
        CGPoint t = [pan translationInView:win];
        if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
            CGPoint c = win.center;
            c.x += t.x; c.y += t.y;
            c.x = MAX(30, MIN(ScreenW() - 30, c.x));
            c.y = MAX(30, MIN(ScreenH() - 30, c.y));
            win.center = c;
            [pan setTranslation:CGPointZero inView:win];
            if (win == g_capWin) ResetHideTimer();
        } else if (pan.state == UIGestureRecognizerStateEnded) {
            if (win == g_capWin) SaveCaptionPos(win.center);
        }
    } @catch (NSException *e) { }
}

+ (void)handleDoubleTap {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_capWin) return;
            g_collapsed = !g_collapsed;
            if (g_collapsed) {
                g_origLabel.hidden = YES; g_capLabel.hidden = YES;
                g_stateLabel.hidden = NO;
                g_stateLabel.text = @"CallCaption";
                CGRect f = CGRectMake(0, 0, 110, 24);
                CGPoint c = g_capWin.center;
                g_card.frame = f;
                g_stateLabel.frame = CGRectMake(10, 5, 90, 14);
                g_capWin.frame = f;
                g_capWin.center = c;
            } else {
                g_origLabel.hidden = NO; g_capLabel.hidden = NO;
                UpdateCardLayout();
            }
        } @catch (NSException *e) { }
    });
}

+ (void)toggleSession {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            g_sessionActive = !g_sessionActive;
            [self refreshButton];
            CCLogf(@"session %@", g_sessionActive ? @"ON" : @"OFF");
            if (!g_sessionActive) [self hideCaption];
        } @catch (NSException *e) { }
    });
}

+ (void)refreshButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_btn) return;
            if (g_sessionActive) {
                g_btn.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.45 alpha:0.92];
                [g_btn setTitle:@"译" forState:UIControlStateNormal];
            } else {
                g_btn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.85];
                [g_btn setTitle:@"✕" forState:UIControlStateNormal];
            }
        } @catch (NSException *e) { }
    });
}

+ (void)handleLongPress:(UILongPressGestureRecognizer *)lp {
    if (lp.state != UIGestureRecognizerStateBegan) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_btnWin || !g_btnWin.rootViewController) return;
            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"CallCaption 通话翻译"
                                                    message:nil
                                             preferredStyle:UIAlertControllerStyleActionSheet];
            BOOL tts = CCPrefBool(CC_K_TTS_ENABLED, YES);
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"语音播报：%@", tts ? @"开（点击关闭）" : @"关（点击开启）"]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *a) {
                CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_TTS_ENABLED,
                                         (__bridge CFPropertyListRef)[[NSNumber alloc] initWithBool:!tts],
                                         (__bridge CFStringRef)CC_DOMAIN);
                CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
                CCPostNotif(@"prefschanged");
            }]];
            BOOL large = CCPrefBool(CC_K_LARGE_CAPTIONS, NO);
            [alert addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"大字幕：%@", large ? @"开（点击关闭）" : @"关（点击开启）"]
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *a) {
                CFPreferencesSetAppValue((__bridge CFStringRef)CC_K_LARGE_CAPTIONS,
                                         (__bridge CFPropertyListRef)[[NSNumber alloc] initWithBool:!large],
                                         (__bridge CFStringRef)CC_DOMAIN);
                CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
                CCPostNotif(@"prefschanged");
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:g_sessionActive ? @"暂停翻译" : @"恢复翻译"
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *a) {
                [self toggleSession];
            }]];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                      style:UIAlertActionStyleCancel
                                                    handler:nil]];
            [g_btnWin.rootViewController presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) { }
    });
}

@end

// ---------- 通话状态 ----------

void CCUICallStateChanged(NSString *state) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if ([state isEqualToString:@"CALL CONNECTED"]) {
                EnsureButtonUI();
                EnsureCaptionUI();
                g_sessionActive = CCPrefBool(CC_K_ENABLED, YES);
                [CCUIHelper refreshButton];
                g_btnWin.hidden = NO;
                [UIView animateWithDuration:0.3 animations:^{ g_btnWin.alpha = 1.0; }];
                CCUIDeliverState(@"● 正在聆听…");
            } else if ([state isEqualToString:@"CALL ENDED"]) {
                [CCUIHelper hideCaption];
                if (g_btnWin) {
                    [UIView animateWithDuration:0.3 animations:^{ g_btnWin.alpha = 0.0; }
                     completion:^(BOOL fin) { if (fin) g_btnWin.hidden = YES; }];
                }
            } else if ([state isEqualToString:@"CALL INCOMING"] || [state isEqualToString:@"CALL DIALING"]) {
                EnsureButtonUI();
                EnsureCaptionUI();
            }
        } @catch (NSException *e) { }
    });
}

void CCUIBoot(void) {
    @try {
        if (!CCIsSpringBoard() || g_uiReady) return;
        CCMark(@"ui 5.1 boot enter");
        g_uiReady = YES;
        CCTransportBoot();
        CCMark(@"ui 5.2 transport ready");
        g_cc = [[CTCallCenter alloc] init];
        CCMark(@"ui 5.3 ctcallcenter created");
        g_cc.callEventHandler = ^(CTCall *call) {
            @try {
                NSString *s = call.callState;
                NSString *info = [s isEqualToString:CTCallStateDialing]     ? @"CALL DIALING"
                               : [s isEqualToString:CTCallStateIncoming]    ? @"CALL INCOMING"
                               : [s isEqualToString:CTCallStateConnected]   ? @"CALL CONNECTED"
                               : [s isEqualToString:CTCallStateDisconnected]? @"CALL ENDED"
                                                                            : s;
                CCLogLine(info);
                CCUICallStateChanged(info);
            } @catch (NSException *e) { }
        };
        CCMark(@"ui 5.4 CTCallCenter handler set");
        CCLogLine(@"CallCaption UI booted");
    } @catch (NSException *e) {
        CCMark(@"ui BOOT EXCEPTION!");
    }
}
