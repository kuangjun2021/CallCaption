// CCMicCapture.m — v0.9.0 新架构：SpringBoard 进程内用系统麦克风采集
// 原理：通话开免提时，麦克风能拾取到对方的声音（扬声器外放）→ 识别英文 → 翻译 → 字幕
// 优势：完全不用函数钩子（%hookf 已被证实是毒源），纯系统 API，不碰 mediaserverd
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

static AVAudioEngine *g_engine;
static SFSpeechRecognizer *g_recog;
static SFSpeechAudioBufferRecognitionRequest *g_req;
static SFSpeechRecognitionTask *g_task;
static AVSpeechSynthesizer *g_tts;
static BOOL g_running;

static void StartRequest(void) {
    @try {
        if (!g_recog) {
            g_recog = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
        }
        if (!g_recog) { CCLogf(@"mic: recognizer init failed"); return; }
        if (!g_recog.available) { CCLogf(@"mic: en recognizer unavailable"); return; }
        if (g_req) { [g_req endAudio]; }
        g_req = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        g_req.shouldReportPartialResults = YES;
        if (@available(iOS 13.0, *)) g_req.addsPunctuation = YES;
        SFSpeechAudioBufferRecognitionRequest *req = g_req;

        g_task = [g_recog recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            @try {
                if (error) CCLogf(@"mic recog err: %@", error.localizedDescription);
                if (result && result.isFinal) {
                    NSString *text = result.bestTranscription.formattedString;
                    NSString *src = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    CCLogf(@"mic recognized: %@", src);
                    if (src.length > 0) {
                        CCUIDeliverOriginal(src);
                        CCTranslate(src, @"en", @"zh", ^(NSString *out) {
                            @try {
                                if (out.length == 0) return;
                                CCUIDeliverCaption(out);
                                if (CCPrefBool(CC_K_TTS_ENABLED, YES) && g_tts) {
                                    [g_tts stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
                                    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:out];
                                    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
                                    [g_tts speakUtterance:u];
                                }
                            } @catch (NSException *e) { }
                        });
                    }
                    // 继续下一段识别
                    if (g_running) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)300 * NSEC_PER_MSEC),
                                       dispatch_get_main_queue(), ^{
                            if (g_running) StartRequest();
                        });
                    }
                }
            } @catch (NSException *e) { }
        }];
    } @catch (NSException *e) {
        CCLogf(@"mic StartRequest exc: %@", e);
    }
}

static void StartEngine(void) {
    @try {
        if (!g_tts) g_tts = [[AVSpeechSynthesizer alloc] init];

        AVAudioSession *sess = [AVAudioSession sharedInstance];
        NSError *err = nil;
        // 与通话共存：录音类别 + 与其它音频混合，不抢通话的音频会话
        [sess setCategory:AVAudioSessionCategoryPlayAndRecord
                     mode:AVAudioSessionModeMeasurement
                  options:AVAudioSessionCategoryOptionMixWithOthers |
                          AVAudioSessionCategoryOptionDefaultToSpeaker |
                          AVAudioSessionCategoryOptionAllowBluetooth
                    error:&err];
        if (err) CCLogf(@"mic session category err: %@", err.localizedDescription);
        err = nil;
        [sess setActive:YES error:&err];
        if (err) CCLogf(@"mic session active err: %@", err.localizedDescription);

        g_engine = [[AVAudioEngine alloc] init];
        AVAudioInputNode *input = g_engine.inputNode;
        AVAudioFormat *fmt = [input inputFormatForBus:0];
        [input installTapOnBus:0 bufferSize:2048 format:fmt block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
            @try {
                SFSpeechAudioBufferRecognitionRequest *req = g_req;
                if (req && buffer) [req appendAudioPCMBuffer:buffer];
            } @catch (NSException *e) { }
        }];

        StartRequest();

        err = nil;
        if (![g_engine startAndReturnError:&err]) {
            CCLogf(@"mic engine start failed: %@", err.localizedDescription);
            return;
        }
        g_running = YES;
        CCLogf(@"mic capture running");
    } @catch (NSException *e) {
        CCLogf(@"mic StartEngine exc: %@", e);
    }
}

void CCMicStart(void) {
    if (g_running) return;
    @try {
        // v0.9.3: 绝不调用 requestAuthorization（SpringBoard 无 NSSpeechRecognitionUsageDescription，
        // 申请权限会被 tccd 直接 SIGKILL 处决）。改为只读检查——权限需预先通过 TCC 数据库授予。
        SFSpeechRecognizerAuthorizationStatus st = [SFSpeechRecognizer authorizationStatus];
        CCLogf(@"mic: speech auth status %ld", (long)st);
        if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            CCLogf(@"mic: speech recognition NOT authorized (TCC grant missing)");
            CCUIDeliverState(@"● 请在 TCC 授权后重试");
            return;
        }
        if ([[AVAudioSession sharedInstance] recordPermission] != AVAudioSessionRecordPermissionGranted) {
            CCLogf(@"mic: microphone NOT authorized (TCC grant missing)");
            CCUIDeliverState(@"● 请在 TCC 授权后重试");
            return;
        }
        StartEngine();
    } @catch (NSException *e) { }
}

void CCMicStop(void) {
    g_running = NO;
    @try {
        if (g_task) { [g_task cancel]; g_task = nil; }
        if (g_req) { [g_req endAudio]; g_req = nil; }
        if (g_engine) {
            @try { [g_engine.inputNode removeTapOnBus:0]; } @catch (NSException *e) { }
            [g_engine stop];
            g_engine = nil;
        }
        if (g_tts) [g_tts stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        [[AVAudioSession sharedInstance] setActive:NO
                                       withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                             error:nil];
        CCLogf(@"mic capture stopped");
    } @catch (NSException *e) { }
}
