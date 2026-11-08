// CCAudioService.m — v0.11 音频守护进程：双通道系统级 Tap（无钩子 / 不碰 mediaserverd）
//   remote 通道：PID -2（speaker）→ 对方语言识别 → 中文 → 字幕 + SB 播报
//   local  通道：PID -3（microphone）→ 我的语言识别 → 英文 → LR| + 守护进程英文 TTS（免提外放给对方）
// 参考实现：Lessica/TrollRecorder（ATAudioTap + AudioQueue 'qtob'）
// 权限：entitlements/CallCaptionAudioService.plist
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Speech/Speech.h>
#import <objc/runtime.h>

// ---------- 私有 AudioToolbox Tap API（iOS 16+） ----------
@interface ATAudioTapDescription : NSObject
- (instancetype)initTapInternalWithFormat:(AVAudioFormat *)format PIDs:(NSArray *)pids;
- (instancetype)initProcessTapInternalWithFormat:(AVAudioFormat *)format PID:(int)pid;
@end

@interface ATAudioTap : NSObject
- (instancetype)initWithTapDescription:(ATAudioTapDescription *)desc;
@end

#define CC_TAP_PID_SPEAKER   (-2)
#define CC_TAP_PID_SYSTEM    (-1)
#define CC_TAP_PID_MIC       (-3)
#define CC_AQ_TAP_FLAG       0x800
#define CC_AQ_PROP_TAP       0x71746F62    // 'qtob'

static dispatch_queue_t g_stateQ;
static CFAbsoluteTime g_muteUntil;         // 英文 TTS 播放期间静音，防回声自激
static CFAbsoluteTime g_ttsUntil;          // SB 中文播报窗口（从 tts_until 文件读取）
static CFAbsoluteTime g_lastPrefsLoad;
static CFAbsoluteTime g_lastTransWarn;     // 翻译失败提示节流
static AVSpeechSynthesizer *g_enTTS;

static BOOL CCContainsCJK(NSString *s) {
    NSUInteger n = s.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x3400 && c <= 0x9FFF) return YES;
    }
    return NO;
}

static NSString *CCTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 最终结果平均置信度；无法判断时返回 -1
static double CCResultConfidence(SFSpeechRecognitionResult *r) {
    NSArray<SFTranscriptionSegment *> *segs = r.bestTranscription.segments;
    if (segs.count == 0) return -1;
    double sum = 0;
    float maxc = 0;
    for (SFTranscriptionSegment *s in segs) {
        float c = s.confidence;
        if (c > maxc) maxc = c;
        sum += c;
    }
    if (maxc <= 0.01f) return -1;
    return sum / (double)segs.count;
}

static void CCASendState(NSString *s) {
    CCTransportSendLine([@"S|" stringByAppendingString:s]);
}

// 英文 TTS（我方通道）：同时设置静音窗口，避免喇叭外放的英文被两路 Tap 又听回去
static void CCSpeakEnglish(NSString *text) {
    if (text.length == 0) return;
    double dur = 1.0 + 0.075 * (double)text.length;
    if (dur > 15.0) dur = 15.0;
    g_muteUntil = CFAbsoluteTimeGetCurrent() + dur;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!g_enTTS) g_enTTS = [[AVSpeechSynthesizer alloc] init];
            AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
            NSString *vid = CCPrefStr(CC_K_LOCAL_VOICE, @"");
            AVSpeechSynthesisVoice *v = vid.length ? [AVSpeechSynthesisVoice voiceWithIdentifier:vid] : nil;
            u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
            [g_enTTS speakUtterance:u];
            CCLogf(@"local tts en: %@", text);
        } @catch (NSException *e) { CCLogf(@"local tts exc: %@", e.reason); }
    });
}

// ---------- 通道 ----------

@interface CCChannel : NSObject {
@public
    AudioQueueRef queue;
    ATAudioTap *tap;
    AVAudioFormat *fmt;
    AVAudioFormat *mono;
    SFSpeechRecognizer *recog;
    SFSpeechAudioBufferRecognitionRequest *req;
    SFSpeechRecognitionTask *task;
    BOOL capturing;
    BOOL restartPending;
    BOOL onDevice;
    BOOL ttsPaused;              // 因 TTS 正在外放而暂停识别
    BOOL endAudioSent;           // 已请求收句，等待 final
    uint64_t frames;
    uint64_t audioBytes;         // 原始音频字节（不依赖识别请求）
    uint64_t lastAudioSeen;
    CFAbsoluteTime lastFrameChangeAt;
    CFAbsoluteTime lastRecogTry;
    CFAbsoluteTime lastAttempt;
    CFAbsoluteTime lastPartialAt;
    CFAbsoluteTime lastStatsAt;
    CFAbsoluteTime lastAuthLog;
    NSString *lastText;
    NSString *lastPartialText;
    CFAbsoluteTime lastTextAt;
}
@property (nonatomic, assign) int tapPID;
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, copy) NSString *locale;
@property (nonatomic, copy) NSString *srcLang;
@property (nonatomic, copy) NSString *dstLang;
@property (nonatomic, assign) BOOL expectCJK;     // YES: 我方通道，识别中文
@property (nonatomic, assign) BOOL speakEnglish;  // YES: 译文用英文 TTS 外放
- (void)configure;
- (BOOL)start;
- (void)stop;
- (void)pauseRecog;
- (void)recogStart;
- (void)recogRestart:(double)delay;
- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error;
- (void)deliverFinal:(NSString *)text;
- (void)translateProvisional:(NSString *)text;
@end

static CCChannel *g_remote;
static CCChannel *g_local;

// ---------- 音频回调 ----------

static void CCAQCallback(void *ud, AudioQueueRef aq, AudioQueueBufferRef buf,
                         const AudioTimeStamp *ts, UInt32 numPackets,
                         const AudioStreamPacketDescription *descs) {
    CCChannel *ch = (__bridge CCChannel *)ud;
    @autoreleasepool {
        @try {
            SFSpeechAudioBufferRecognitionRequest *r = ch->req;
            AVAudioFormat *monoFmt = ch->mono;
            AVAudioFormat *srcFmt = ch->fmt;
            if (buf->mAudioData && buf->mAudioDataByteSize > 0)
                __atomic_add_fetch(&ch->audioBytes, buf->mAudioDataByteSize, __ATOMIC_RELAXED);
            if (r && monoFmt && srcFmt && buf->mAudioData && buf->mAudioDataByteSize > 0) {
                const AudioStreamBasicDescription *sa = srcFmt.streamDescription;
                UInt32 bpf = sa->mBytesPerFrame ? sa->mBytesPerFrame : 8;
                AVAudioFrameCount nf = buf->mAudioDataByteSize / bpf;
                if (nf > 0) {
                    AVAudioPCMBuffer *pcm =
                        [[AVAudioPCMBuffer alloc] initWithPCMFormat:monoFmt frameCapacity:nf];
                    if (pcm) {
                        pcm.frameLength = nf;
                        float *dst = pcm.floatChannelData[0];
                        const float *src = (const float *)buf->mAudioData;
                        if (sa->mChannelsPerFrame >= 2) {
                            // 只取左声道：通话音频常见左右反相，平均会互相抵消
                            for (AVAudioFrameCount i = 0; i < nf; i++)
                                dst[i] = src[2 * i];
                        } else {
                            memcpy(dst, src, nf * sizeof(float));
                        }
                        [r appendAudioPCMBuffer:pcm];
                        __atomic_add_fetch(&ch->frames, nf, __ATOMIC_RELAXED);
                    }
                }
            }
        } @catch (NSException *e) { }
        if (ch->capturing && ch->queue) AudioQueueEnqueueBuffer(ch->queue, buf, 0, NULL);
    }
}

@implementation CCChannel

- (void)configure {
    if (self.tapPID == CC_TAP_PID_MIC) {
        self.locale = CCPrefStr(CC_K_LOCAL_LOCALE, @"zh-CN");
        self.srcLang = @"zh";
        self.dstLang = @"en";
        self.expectCJK = YES;
        self.speakEnglish = YES;
    } else {
        self.locale = CCPrefStr(CC_K_REMOTE_LOCALE, @"en-US");
        NSArray *parts = [self.locale componentsSeparatedByString:@"-"];
        self.srcLang = parts.count > 0 ? parts[0] : @"en";
        self.dstLang = @"zh";
        self.expectCJK = NO;
        self.speakEnglish = NO;
    }
}

- (BOOL)start {
    if (capturing) return YES;

    SFSpeechRecognizerAuthorizationStatus auth = [SFSpeechRecognizer authorizationStatus];
    if (auth != SFSpeechRecognizerAuthorizationStatusAuthorized) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - lastAuthLog > 10) {
            lastAuthLog = now;
            CCLogf(@"%@: speech NOT authorized (status=%ld)", self.tag, (long)auth);
            CCASendState(@"● 语音识别未授权（查看 probe.log）");
        }
        return NO;
    }

    Class descCls = NSClassFromString(@"ATAudioTapDescription");
    Class tapCls = NSClassFromString(@"ATAudioTap");
    if (!descCls || !tapCls) {
        CCLogf(@"%@: ATAudioTap classes not found", self.tag);
        return NO;
    }

    fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                           sampleRate:44100.0 channels:2 interleaved:YES];
    mono = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                            sampleRate:44100.0 channels:1 interleaved:NO];
    if (!fmt || !mono) { CCLogf(@"%@: format init failed", self.tag); return NO; }

    id desc = nil;
    if ([descCls instancesRespondToSelector:@selector(initTapInternalWithFormat:PIDs:)]) {
        desc = [[descCls alloc] initTapInternalWithFormat:fmt PIDs:@[ @(self.tapPID) ]];
    } else if ([descCls instancesRespondToSelector:@selector(initProcessTapInternalWithFormat:PID:)]) {
        desc = [[descCls alloc] initProcessTapInternalWithFormat:fmt PID:self.tapPID];
    }
    if (!desc) { CCLogf(@"%@: description init failed", self.tag); return NO; }

    tap = [[tapCls alloc] initWithTapDescription:desc];
    if (!tap) { CCLogf(@"%@: tap init failed", self.tag); return NO; }

    AudioStreamBasicDescription asbd = *fmt.streamDescription;
    OSStatus st = AudioQueueNewInput(&asbd, CCAQCallback, (__bridge void *)self,
                                     NULL, NULL, CC_AQ_TAP_FLAG, &queue);
    if (st != noErr) {
        CCLogf(@"%@: AudioQueueNewInput failed %d", self.tag, (int)st);
        queue = NULL;
        return NO;
    }

    st = AudioQueueSetProperty(queue, CC_AQ_PROP_TAP, (__bridge void *)tap, sizeof(void *));
    if (st != noErr) {
        CCLogf(@"%@: set TapOutputBypass failed %d", self.tag, (int)st);
        AudioQueueDispose(queue, true);
        queue = NULL;
        return NO;
    }

    UInt32 bufSize = (UInt32)(asbd.mSampleRate * asbd.mBytesPerFrame * 0.25);
    if (bufSize < 0x4000) bufSize = 0x4000;
    if (bufSize > 0x50000) bufSize = 0x50000;
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef b = NULL;
        if (AudioQueueAllocateBuffer(queue, bufSize, &b) == noErr && b)
            AudioQueueEnqueueBuffer(queue, b, 0, NULL);
    }

    capturing = YES;
    restartPending = NO;
    onDevice = YES;
    frames = 0;
    audioBytes = 0;
    lastAudioSeen = 0;
    lastFrameChangeAt = CFAbsoluteTimeGetCurrent();
    lastRecogTry = 0;
    lastStatsAt = CFAbsoluteTimeGetCurrent();
    [self recogStart];

    st = AudioQueueStart(queue, NULL);
    if (st != noErr) {
        CCLogf(@"%@: AudioQueueStart failed %d", self.tag, (int)st);
        [self stop];
        return NO;
    }
    CCLogf(@"%@: capture started (pid=%d, %@)", self.tag, self.tapPID, self.locale);
    if (!self.expectCJK) CCASendState(@"● 已开始收听对方语音");
    return YES;
}

- (void)stop {
    if (!capturing && !queue) return;
    capturing = NO;
    restartPending = NO;
    ttsPaused = NO;
    @try {
        // 不调用 [task ：本环境会在 SFLocalSpeechRecognitionClient stopSpeech 触发 SIGBUS
        if (req) { [req endAudio]; req = nil; }
        task = nil;
        if (queue) {
            AudioQueueStop(queue, true);
            AudioQueueDispose(queue, true);
            queue = NULL;
        }
        tap = nil;
        CCLogf(@"%@: capture stopped", self.tag);
    } @catch (NSException *e) { }
}

// 暂停识别但保留音频队列（TTS 外放期间，避免把播报回声喂进识别器）
- (void)pauseRecog {
    @try {
        // 不调用 [task ：本环境会在 SFLocalSpeechRecognitionClient stopSpeech 触发 SIGBUS
        if (req) { [req endAudio]; req = nil; }
        task = nil;
    } @catch (NSException *e) { }
}

- (void)recogStart {
    if (!capturing) return;
    lastRecogTry = CFAbsoluteTimeGetCurrent();
    @try {
        if (!recog) {
            recog = [[SFSpeechRecognizer alloc] initWithLocale:
                     [NSLocale localeWithLocaleIdentifier:self.locale ?: @"en-US"]];
        }
        if (!recog) { CCLogf(@"%@: recognizer init failed", self.tag); return; }
        if (!recog.isAvailable) {
            CCLogf(@"%@: recognizer not available", self.tag);
            [self recogRestart:2.0];
            return;
        }
        // 不调用 [task ：本环境会在 SFLocalSpeechRecognitionClient stopSpeech 触发 SIGBUS
        if (req) { [req endAudio]; req = nil; }
        task = nil;

        SFSpeechAudioBufferRecognitionRequest *r =
            [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        r.shouldReportPartialResults = YES;
        BOOL preferCloud = CCPrefBool(CC_K_CLOUD_ASR, YES);
        if (@available(iOS 13.0, *)) {
            r.taskHint = SFSpeechRecognitionTaskHintDictation;
            if (!preferCloud && recog.supportsOnDeviceRecognition && onDevice)
                r.requiresOnDeviceRecognition = YES;
        }
        req = r;
        lastPartialAt = 0;
        endAudioSent = NO;
        CCLogf(@"%@ recog: task start (auth=%ld avail=%d cloud=%d locale=%@)",
               self.tag, (long)[SFSpeechRecognizer authorizationStatus],
               recog.isAvailable, !CCPrefBool(CC_K_CLOUD_ASR, YES), self.locale);

        __weak CCChannel *weakSelf = self;
        SFSpeechRecognitionTask *t = [recog recognitionTaskWithRequest:r
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                CCChannel *ch = weakSelf;
                if (!ch) return;
                [ch handleResult:result error:error];
            }];
        task = t;

        // 连续说话时每 12 秒强制收一段（8 秒太碎，切坏句子）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)12 * NSEC_PER_SEC),
                       g_stateQ, ^{
            CCChannel *ch = weakSelf;
            if (ch && ch->capturing && ch->task == t) {
                CCLogf(@"%@: force finalize (8s chunk)", ch.tag);
                [t finish];
            }
        });
    } @catch (NSException *e) {
        CCLogf(@"%@: recog exc %@", self.tag, e.reason);
        [self recogRestart:2.0];
    }
}

- (void)recogRestart:(double)delay {
    if (restartPending) return;
    restartPending = YES;
    __weak CCChannel *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   g_stateQ, ^{
        CCChannel *ch = weakSelf;
        if (!ch) return;
        ch->restartPending = NO;
        if (ch->capturing) [ch recogStart];
    });
}

- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error {
    @try {
        if (!capturing) return;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL muted = (now < g_muteUntil) || (now < g_ttsUntil);

        if (result) {
            NSString *txt = CCTrim(result.bestTranscription.formattedString);
            if (result.isFinal) {
                if (!muted) {
                    double conf = CCResultConfidence(result);
                    if (conf < 0 || conf >= 0.45) {
                        [self deliverFinal:txt];
                    } else {
                        CCLogf(@"%@: low confidence %.2f, skip: %@", self.tag, conf, txt);
                    }
                }
                if (capturing && !ttsPaused) [self recogRestart:0.25];
                return;
            }
            if (!muted && txt.length > 1 && now - lastPartialAt > 0.7) {
                BOOL same = lastPartialText && [lastPartialText isEqualToString:txt];
                if (!same) {
                    lastPartialAt = now;
                    lastPartialText = txt;
                    BOOL cjk = CCContainsCJK(txt);
                    BOOL ok = self.expectCJK ? cjk : !cjk;
                    if (ok) {
                        NSString *prefix = self.expectCJK ? @"LI|" : @"I|";
                        CCTransportSendLine([prefix stringByAppendingString:txt]);
                    }
                }
            }
        }

        if (error) {
            NSInteger code = error.code;
            BOOL benign = (code == 216 /* cancelled */ || code == 1110 /* no speech */);
            if (!benign) {
                CCLogf(@"%@ recog err: %@ (code=%ld onDevice=%d)",
                       self.tag, error.localizedDescription, (long)code, onDevice);
                if (onDevice) {
                    onDevice = NO;
                    CCLogf(@"%@: fallback to server recognition", self.tag);
                }
            }
            if (capturing && !ttsPaused) [self recogRestart:benign ? 0.5 : 1.5];
        }
    } @catch (NSException *e) { }
}

- (void)translateProvisional:(NSString *)text {
    if (text.length < 4) return;
    __weak CCChannel *weakSelf = self;
    CCTranslate(text, self.srcLang, self.dstLang, ^(NSString *out) {
        CCChannel *ch = weakSelf;
        if (!ch || out.length == 0) return;
        NSString *rp = ch.expectCJK ? @"LR|" : @"R|";
        CCLogf(@"%@ provisional trans: %@", ch.tag, out);
        CCTransportSendLine([rp stringByAppendingString:out]);
    });
}

- (void)deliverFinal:(NSString *)text {
    NSString *t = CCTrim(text);
    if (t.length < 2) return;
    BOOL cjk = CCContainsCJK(t);
    if (self.expectCJK && !cjk) return;      // 我方通道只收中文（滤掉英文回声）
    if (!self.expectCJK && cjk) return;      // 对方通道只收非中文（滤掉中文播报回声）

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (lastText && [lastText isEqualToString:t] && (now - lastTextAt) < 3.0) return;
    lastText = t;
    lastTextAt = now;

    CCPrefsReload();
    CCLogf(@"%@ recog: %@", self.tag, t);
    NSString *ip = self.expectCJK ? @"LI|" : @"I|";
    CCTransportSendLine([ip stringByAppendingString:t]);

    if (self.expectCJK && !CCPrefBool(CC_K_LOCAL_ENABLED, NO)) return;
    if (!self.expectCJK && !CCPrefBool(CC_K_REMOTE_ENABLED, YES)) return;

    __weak CCChannel *weakSelf = self;
    CCTranslate(t, self.srcLang, self.dstLang, ^(NSString *out) {
        CCChannel *ch = weakSelf;
        if (!ch) return;
        if (out.length == 0) {
            CCLogf(@"%@ trans FAILED", ch.tag);
            CFAbsoluteTime n2 = CFAbsoluteTimeGetCurrent();
            if (n2 - g_lastTransWarn > 30.0) {
                g_lastTransWarn = n2;
                CCASendState(@"● 翻译服务暂不可用，正在自动重试");
            }
            return;
        }
        CCLogf(@"%@ trans: %@", ch.tag, out);
        NSString *rp = ch.expectCJK ? @"LR|" : @"R|";
        CCTransportSendLine([rp stringByAppendingString:out]);
        if (ch.expectCJK) CCSpeakEnglish(out);   // 我方译文：英文外放给对方
    });
}

@end

// ---------- armed 文件监视 ----------

static void CheckArm(void) {
    @try {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - g_lastPrefsLoad > 2.0) {
            g_lastPrefsLoad = now;
            CCPrefsReload();
        }

        // SB 中文播报窗口：tts_until 文件里是结束时刻（epoch 秒）
        @try {
            NSString *s = [NSString stringWithContentsOfFile:
                           @"/var/mobile/Library/CallCaption/tts_until"
                                              encoding:NSUTF8StringEncoding error:nil];
            // 文件里是 epoch 秒；CFAbsoluteTime 起点是 2001-01-01，必须减去 978307200
            g_ttsUntil = s.length ? ([s doubleValue] - 978307200.0) : 0;
        } @catch (NSException *e) { }

        BOOL armed = [[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH];
        if (!armed) {
            [g_remote stop];
            [g_local stop];
            return;
        }

        // 对方通道
        NSString *oldRemoteLocale = g_remote.locale;
        [g_remote configure];
        if (g_remote->capturing && oldRemoteLocale &&
            ![oldRemoteLocale isEqualToString:g_remote.locale]) {
            CCLogf(@"remote: locale changed %@ -> %@, restart", oldRemoteLocale, g_remote.locale);
            [g_remote stop];
        }
        if (!g_remote->capturing && now - g_remote->lastAttempt > 3.0) {
            g_remote->lastAttempt = now;
            [g_remote start];
        }

        // 我方通道（双向模式）
        BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, NO);
        if (localOn) {
            NSString *oldLocalLocale = g_local.locale;
            [g_local configure];
            if (g_local->capturing && oldLocalLocale &&
                ![oldLocalLocale isEqualToString:g_local.locale]) {
                CCLogf(@"local: locale changed %@ -> %@, restart", oldLocalLocale, g_local.locale);
                [g_local stop];
            }
            if (!g_local->capturing && now - g_local->lastAttempt > 3.0) {
                g_local->lastAttempt = now;
                [g_local start];
            }
        } else if (g_local->capturing) {
            [g_local stop];
        }

        // TTS 外放期间暂停两路识别，避免把播报回声当成人声
        BOOL speaking = (now < g_ttsUntil) || (now < g_muteUntil);
        NSArray<CCChannel *> *chans = @[g_remote, g_local];
        for (CCChannel *ch in chans) {
            if (!ch->capturing) continue;
            if (speaking && ch->task) {
                [ch pauseRecog];
                ch->ttsPaused = YES;
            } else if (!speaking && ch->ttsPaused) {
                ch->ttsPaused = NO;
                [ch recogStart];
            }
        }

        // 说话停顿检测：partial 1.5 秒没变化就主动 endAudio 收句，尽快拿到 final 去翻译
        for (CCChannel *ch in chans) {
            if (!ch->capturing || !ch->req || ch->endAudioSent) continue;
            if (ch->lastPartialText.length >= 4 &&
                now - ch->lastPartialAt > 1.5) {
                ch->endAudioSent = YES;
                CCLogf(@"%@: stable partial, requesting final", ch.tag);
                [ch translateProvisional:ch->lastPartialText];
                [ch->req endAudio];
            }
        }

        // 帧停滞看门狗：换通话/音频会话重建后 Tap 可能不再送音频，自动重挂
        for (CCChannel *ch in chans) {
            if (!ch->capturing) continue;
            if (ch->audioBytes != ch->lastAudioSeen) {
                ch->lastAudioSeen = ch->audioBytes;
                ch->lastFrameChangeAt = now;
                if (!ch->req && now - ch->lastRecogTry > 5.0) {
                    CCLogf(@"%@: audio flowing but no recognition request, restarting recog", ch.tag);
                    [ch recogStart];
                }
            } else if (now - ch->lastFrameChangeAt > 8.0) {
                if ([ch.tag isEqualToString:@"remote"]) {
                    ch.tapPID = (ch.tapPID == CC_TAP_PID_SPEAKER)
                                 ? CC_TAP_PID_SYSTEM : CC_TAP_PID_SPEAKER;
                }
                CCLogf(@"%@: audio stalled (frames=%llu), restarting tap pid=%d",
                       ch.tag, (unsigned long long)ch->frames, ch.tapPID);
                [ch stop];
                ch->lastAttempt = 0;
                ch->lastFrameChangeAt = now;
            }
        }

        if (g_remote->capturing && now - g_remote->lastStatsAt >= 5.0) {
            g_remote->lastStatsAt = now;
            CCLogf(@"remote: alive, audio=%llu frames=%llu",
                   (unsigned long long)g_remote->audioBytes,
                   (unsigned long long)g_remote->frames);
        }
        if (g_local->capturing && now - g_local->lastStatsAt >= 5.0) {
            g_local->lastStatsAt = now;
            CCLogf(@"local: alive, audio=%llu frames=%llu",
                   (unsigned long long)g_local->audioBytes,
                   (unsigned long long)g_local->frames);
        }
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
        CCLogLine(@"audioservice started (v0.13.5)");

        g_stateQ = dispatch_queue_create("net.user.callcaption.audio", DISPATCH_QUEUE_SERIAL);

        g_remote = [[CCChannel alloc] init];
        g_remote.tapPID = CC_TAP_PID_SPEAKER;
        g_remote.tag = @"remote";
        [g_remote configure];

        g_local = [[CCChannel alloc] init];
        g_local.tapPID = CC_TAP_PID_MIC;
        g_local.tag = @"local";
        [g_local configure];

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
