// CCAudioService.m — v0.10 音频守护进程：系统级 Tap 抓取“对方声音”（无需钩子/无需 mediaserverd）
// 架构参考（开源）：Lessica/TrollRecorder cli/call-recorder.mm
//   ATAudioTapDescription(-2=speaker) + ATAudioTap + AudioQueue(kAudioQueueProperty_TapOutputBypass='qtob')
// 权限：ldid 签名 entitlements（CanTapTelephony / CanRecordWithoutSessionActivation /
//       SystemWideTap / app-tap / TCC allow）——见 entitlements/CallCaptionAudioService.plist
//
// 控制流：
//   SB 侧按钮 → 创建/删除 /var/mobile/Library/CallCaption/armed → 本进程每秒检查
//   识别结果 → CCTransportSendLine("I|原文"/"R|译文") → SB 字幕 + TTS
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Speech/Speech.h>
#import <objc/runtime.h>

// ---------- 私有 AudioToolbox Tap API（iOS 16+，来自 TrollRecorder 逆向结果） ----------
@interface ATAudioTapDescription : NSObject
- (instancetype)initTapInternalWithFormat:(AVAudioFormat *)format PIDs:(NSArray *)pids;
- (instancetype)initProcessTapInternalWithFormat:(AVAudioFormat *)format PID:(int)pid;
@end

@interface ATAudioTap : NSObject
- (instancetype)initWithTapDescription:(ATAudioTapDescription *)desc;
@end

#define CC_TAP_PID_SPEAKER   (-2)          // 对方声音（扬声器/下行）
#define CC_TAP_PID_MIC       (-3)          // 本机麦克风（预留）
#define CC_AQ_TAP_FLAG       0x800         // 私有标志：允许 Tap 接入
#define CC_AQ_PROP_TAP       0x71746F62    // 'qtob' TapOutputBypass

static AudioQueueRef g_queue;
static ATAudioTap *g_tap;
static AVAudioFormat *g_fmt;               // tap 格式：Float32 44.1k 2ch interleaved
static AVAudioFormat *g_monoFmt;           // 识别格式：Float32 44.1k 1ch
static SFSpeechRecognizer *g_recog;
static SFSpeechAudioBufferRecognitionRequest *g_req;
static SFSpeechRecognitionTask *g_task;
static dispatch_queue_t g_stateQ;
static BOOL g_capturing;
static BOOL g_restartPending;
static BOOL g_onDevice = YES;              // 优先离线识别，失败自动切服务器
static uint64_t g_frames;
static CFAbsoluteTime g_lastAttempt;
static CFAbsoluteTime g_lastStatsLog;
static CFAbsoluteTime g_lastAuthLog;
static NSString *g_lastText;
static CFAbsoluteTime g_lastTextAt;
static CFAbsoluteTime g_lastPartialAt;
static CFAbsoluteTime g_lastEngineWarnAt;

// 翻译引擎是否已就绪（只看有没有配 Key，不发送任何密钥内容）
static BOOL CCTranslationReady(void) {
    NSString *engine = CCPrefStr(CC_K_ENGINE, @"auto").lowercaseString;
    BOOL dk = CCPrefStr(CC_K_DEEPL_KEY, @"").length > 0;
    BOOL ai = CCPrefStr(CC_K_AI_URL, @"").length > 0 &&
              CCPrefStr(CC_K_AI_KEY, @"").length > 0;
    if ([engine isEqualToString:@"deepl"]) return dk;
    if ([engine isEqualToString:@"ai"]) return ai;
    return dk || ai;
}

// ---------- 工具 ----------

static void CCASendState(NSString *s) {
    CCTransportSendLine([@"S|" stringByAppendingString:s]);
}

static BOOL CCContainsCJK(NSString *s) {
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x3400 && c <= 0x9FFF) return YES;
    }
    return NO;
}

// ---------- 识别 ----------

static void CCRecogRestart(double delay);

static void CCDeliverFinal(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length < 2) return;
    if (CCContainsCJK(t)) {
        CCLogf(@"recog: skip CJK echo (%@)", t);
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_lastText && [g_lastText isEqualToString:t] && (now - g_lastTextAt) < 3.0) return;
    g_lastText = t;
    g_lastTextAt = now;

    CCPrefsReload();   // root 进程：每次取 mobile 域最新设置
    BOOL ready = CCTranslationReady();
    CCLogf(@"recog: %@ (translateReady=%d)", t, ready);
    CCTransportSendLine([@"I|" stringByAppendingString:t]);
    if (!CCPrefBool(CC_K_REMOTE_ENABLED, YES)) return;

    if (!ready) {
        CFAbsoluteTime now2 = CFAbsoluteTimeGetCurrent();
        if (now2 - g_lastEngineWarnAt > 20.0) {
            g_lastEngineWarnAt = now2;
            CCLogf(@"trans: engine NOT configured (DeepLKey/AIKey empty)");
            CCASendState(@"● 未配置翻译引擎：请到设置填写 DeepL Key 或 AI Key");
        }
        return;
    }

    CCTranslate(t, @"en", @"zh", ^(NSString *out) {
        @try {
            if (out.length == 0) {
                CCLogf(@"trans: FAILED (network/key rejected)");
                return;
            }
            CCLogf(@"trans: %@", out);
            CCTransportSendLine([@"R|" stringByAppendingString:out]);
        } @catch (NSException *e) { }
    });
}

static void CCRecogStart(void) {
    if (!g_capturing) return;
    @try {
        if (!g_recog) {
            g_recog = [[SFSpeechRecognizer alloc] initWithLocale:
                       [NSLocale localeWithLocaleIdentifier:@"en-US"]];
        }
        if (!g_recog) { CCLogf(@"recog: init failed"); return; }
        if (!g_recog.isAvailable) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - g_lastAuthLog > 10) {
                g_lastAuthLog = now;
                CCLogf(@"recog: recognizer not available");
                CCASendState(@"● 识别服务不可用（重试中）");
            }
            CCRecogRestart(2.0);
            return;
        }
        if (g_task) { [g_task cancel]; g_task = nil; }
        if (g_req) { [g_req endAudio]; g_req = nil; }

        SFSpeechAudioBufferRecognitionRequest *req =
            [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        req.shouldReportPartialResults = YES;   // v0.10.2: 边说边显示
        if (@available(iOS 13.0, *)) {
            req.taskHint = SFSpeechRecognitionTaskHintDictation;
            if (g_recog.supportsOnDeviceRecognition && g_onDevice)
                req.requiresOnDeviceRecognition = YES;
        }
        g_req = req;
        g_lastPartialAt = 0;

        SFSpeechRecognitionTask *task = [g_recog recognitionTaskWithRequest:req
                                       resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
            @try {
                if (result) {
                    NSString *txt = [result.bestTranscription.formattedString
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (result.isFinal) {
                        CCDeliverFinal(txt);
                        if (g_capturing) CCRecogRestart(0.25);
                        return;
                    }
                    // 实时原文（0.7s 节流），让用户先看到东西
                    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                    if (txt.length > 1 && now - g_lastPartialAt > 0.7 &&
                        !CCContainsCJK(txt)) {
                        g_lastPartialAt = now;
                        CCTransportSendLine([@"I|" stringByAppendingString:txt]);
                    }
                }
                if (error) {
                    NSInteger code = error.code;
                    BOOL benign = (code == 216 /* cancelled */ || code == 1110 /* no speech */);
                    if (!benign) {
                        CCLogf(@"recog err: %@ (code=%ld onDevice=%d)",
                               error.localizedDescription, (long)code, g_onDevice);
                        if (g_onDevice) {
                            g_onDevice = NO;
                            CCLogf(@"recog: fallback to server recognition");
                        }
                    }
                    if (g_capturing) CCRecogRestart(benign ? 0.5 : 1.5);
                }
            } @catch (NSException *e) { }
        }];
        g_task = task;

        // v0.10.2: 连续说话时也每 8 秒收一段，避免一直等不到 final
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)8 * NSEC_PER_SEC),
                       g_stateQ, ^{
            if (g_capturing && g_task == task) {
                CCLogf(@"recog: force finalize (8s chunk)");
                [task finish];
            }
        });
    } @catch (NSException *e) {
        CCLogf(@"recog exc: %@", e.reason);
        CCRecogRestart(2.0);
    }
}

static void CCRecogRestart(double delay) {
    if (g_restartPending) return;
    g_restartPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   g_stateQ, ^{
        g_restartPending = NO;
        if (g_capturing) CCRecogStart();
    });
}

// ---------- 音频回调 ----------

static void CCAQCallback(void *ud, AudioQueueRef aq, AudioQueueBufferRef buf,
                         const AudioTimeStamp *ts, UInt32 numPackets,
                         const AudioStreamPacketDescription *descs) {
    @autoreleasepool {
        @try {
            SFSpeechAudioBufferRecognitionRequest *req = g_req;
            AVAudioFormat *mono = g_monoFmt;
            if (req && mono && buf->mAudioData && buf->mAudioDataByteSize > 0) {
                const AudioStreamBasicDescription *srcFmt = g_fmt.streamDescription;
                UInt32 srcBpf = srcFmt->mBytesPerFrame;
                if (srcBpf == 0) srcBpf = 8;
                AVAudioFrameCount frames = buf->mAudioDataByteSize / srcBpf;
                if (frames > 0) {
                    AVAudioPCMBuffer *pcm =
                        [[AVAudioPCMBuffer alloc] initWithPCMFormat:mono frameCapacity:frames];
                    if (pcm) {
                        pcm.frameLength = frames;
                        float *dst = pcm.floatChannelData[0];
                        const float *src = (const float *)buf->mAudioData;
                        if (srcFmt->mChannelsPerFrame >= 2) {
                            for (AVAudioFrameCount i = 0; i < frames; i++)
                                dst[i] = (src[2 * i] + src[2 * i + 1]) * 0.5f;
                        } else {
                            memcpy(dst, src, frames * sizeof(float));
                        }
                        [req appendAudioPCMBuffer:pcm];
                        __atomic_add_fetch(&g_frames, frames, __ATOMIC_RELAXED);
                    }
                }
            }
        } @catch (NSException *e) { }
        if (g_capturing && g_queue) AudioQueueEnqueueBuffer(g_queue, buf, 0, NULL);
    }
}

// ---------- 采集启停 ----------

static void StopCapture(void) {
    if (!g_capturing && !g_queue) return;
    g_capturing = NO;
    g_restartPending = NO;
    @try {
        if (g_task) { [g_task cancel]; g_task = nil; }
        if (g_req) { [g_req endAudio]; g_req = nil; }
        if (g_queue) { AudioQueueStop(g_queue, true); AudioQueueDispose(g_queue, true); g_queue = NULL; }
        g_tap = nil;
        CCLogf(@"tap: capture stopped");
    } @catch (NSException *e) { }
}

static void StartCapture(void) {
    if (g_capturing) return;
    @try {
        SFSpeechRecognizerAuthorizationStatus auth = [SFSpeechRecognizer authorizationStatus];
        if (auth != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - g_lastAuthLog > 4) {
                g_lastAuthLog = now;
                CCLogf(@"tap: speech NOT authorized (status=%ld)", (long)auth);
                CCASendState(@"● 语音识别未授权（service.log 查看详情）");
            }
            return;
        }

        Class descCls = NSClassFromString(@"ATAudioTapDescription");
        Class tapCls = NSClassFromString(@"ATAudioTap");
        if (!descCls || !tapCls) {
            CCLogf(@"tap: ATAudioTap classes not found");
            CCASendState(@"● 系统不支持音频 Tap");
            return;
        }

        g_fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                 sampleRate:44100.0
                                                   channels:2
                                                interleaved:YES];
        g_monoFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                     sampleRate:44100.0
                                                       channels:1
                                                    interleaved:NO];
        if (!g_fmt || !g_monoFmt) { CCLogf(@"tap: format init failed"); return; }

        id desc = nil;
        if ([descCls instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
            desc = [[descCls alloc] initTapInternalWithFormat:g_fmt
                                                         PIDs:@[ @(CC_TAP_PID_SPEAKER) ]];
        } else if ([descCls instancesRespondToSelector:@selector(initProcessTapInternalWithFormat:PID:)]) {
            desc = [[descCls alloc] initProcessTapInternalWithFormat:g_fmt
                                                                 PID:CC_TAP_PID_SPEAKER];
        }
        if (!desc) { CCLogf(@"tap: description init failed"); return; }

        g_tap = [[tapCls alloc] initWithTapDescription:desc];
        if (!g_tap) { CCLogf(@"tap: tap init failed"); return; }

        AudioStreamBasicDescription asbd = *g_fmt.streamDescription;
        OSStatus st = AudioQueueNewInput(&asbd, CCAQCallback, NULL, NULL, NULL,
                                         CC_AQ_TAP_FLAG, &g_queue);
        if (st != noErr) {
            CCLogf(@"tap: AudioQueueNewInput failed %d", (int)st);
            CCASendState(@"● 音频队列创建失败");
            g_queue = NULL;
            return;
        }

        st = AudioQueueSetProperty(g_queue, CC_AQ_PROP_TAP, (__bridge void *)g_tap, sizeof(void *));
        if (st != noErr) {
            CCLogf(@"tap: set TapOutputBypass failed %d", (int)st);
            CCASendState(@"● Tap 挂载失败（权限不足？）");
            AudioQueueDispose(g_queue, true);
            g_queue = NULL;
            return;
        }

        UInt32 bufSize = (UInt32)(asbd.mSampleRate * asbd.mBytesPerFrame * 0.25);
        if (bufSize < 0x4000) bufSize = 0x4000;
        if (bufSize > 0x50000) bufSize = 0x50000;
        for (int i = 0; i < 3; i++) {
            AudioQueueBufferRef b = NULL;
            if (AudioQueueAllocateBuffer(g_queue, bufSize, &b) == noErr && b)
                AudioQueueEnqueueBuffer(g_queue, b, 0, NULL);
        }

        g_capturing = YES;
        g_restartPending = NO;
        g_frames = 0;
        g_lastStatsLog = CFAbsoluteTimeGetCurrent();
        CCRecogStart();

        st = AudioQueueStart(g_queue, NULL);
        if (st != noErr) {
            CCLogf(@"tap: AudioQueueStart failed %d", (int)st);
            CCASendState(@"● 音频启动失败");
            StopCapture();
            return;
        }
        CCLogf(@"tap: capture started (pid=%d %.0fHz %uch)", CC_TAP_PID_SPEAKER,
               asbd.mSampleRate, asbd.mChannelsPerFrame);
        CCASendState(@"● 已开始收听对方语音");
    } @catch (NSException *e) {
        CCLogf(@"tap: start exc %@", e.reason);
    }
}

// ---------- armed 文件监视 ----------

static void CheckArm(void) {
    @try {
        BOOL armed = [[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH];
        if (!armed) {
            if (g_capturing) StopCapture();
            return;
        }
        if (g_capturing) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - g_lastStatsLog >= 5.0) {
                g_lastStatsLog = now;
                CCLogf(@"tap: alive, PCM frames=%llu", (unsigned long long)g_frames);
            }
            return;
        }
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - g_lastAttempt < 3.0) return;
        g_lastAttempt = now;
        StartCapture();
    } @catch (NSException *e) { }
}

// ---------- 通知 ----------

static void CCDaemonNotifCB(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        NSString *n = (__bridge NSString *)name;
        if (![n hasPrefix:CC_NOTIF_PREFIX]) return;
        NSString *suffix = [n substringFromIndex:CC_NOTIF_PREFIX.length];
        if ([suffix isEqualToString:@"prefschanged"]) {
            CCPrefsReload();
        } else if ([suffix isEqualToString:@"arm"] || [suffix isEqualToString:@"disarm"]) {
            dispatch_async(g_stateQ, ^{ CheckArm(); });
        }
    } @catch (NSException *e) { }
}

// ---------- 入口 ----------

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CCProcessInit();
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:CC_DIR]) {
            [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0777} error:nil];
        }
        CCPrefsReload();
        CCLogLine(@"audioservice started (v0.10.2)");

        g_stateQ = dispatch_queue_create("net.user.callcaption.audio", DISPATCH_QUEUE_SERIAL);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &CCDaemonNotifCB, NULL, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                         0, 0, g_stateQ);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                                  (uint64_t)1 * NSEC_PER_SEC,
                                  (uint64_t)200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ CheckArm(); });
        dispatch_resume(timer);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
