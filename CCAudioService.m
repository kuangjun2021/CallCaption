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
    NSString *lastProvisional;
    CFAbsoluteTime lastTextAt;
    CFAbsoluteTime lastProvTransAt;   // 连续说话时的增量翻译节流
    CFAbsoluteTime lastLoudAt;        // 最近一次明显有声音的时间（RMS）
    CFAbsoluteTime lastResultAt;      // 最近一次识别结果/任务启动的时间
    float lastRMS;                    // 最近一帧的粗略音量
    int noSpeechCount;                // 连续 1110 次数（用于 on-device → cloud 回退）
    CFAbsoluteTime lastRealResultAt; // 最近一次真正识别出内容
    CFAbsoluteTime lastTapProbeAt;   // 最近一次静音 Tap 探测
    int tapProbeCount;               // 静音 Tap 探测次数（-2→-1→-3，最多 3 次）
    NSUInteger callGen;          // 通话/采集代际：stop/新采集递增，用于丢弃上一通的结果
    NSUInteger partialGen;       // 临时翻译代际：只接受最新 partial 的译文
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
                        float rms = 0;
                        if (sa->mChannelsPerFrame >= 2) {
                            // 通话音频可能只出现在右声道，也可能左右反相。
                            // 不能盲取左声道：先比较两路能量，选更响的那路。
                            float sl = 0, sr = 0;
                            for (AVAudioFrameCount i = 0; i < nf; i++) {
                                sl += fabsf(src[2 * i]);
                                sr += fabsf(src[2 * i + 1]);
                            }
                            BOOL useR = (sr > sl * 1.5f);
                            for (AVAudioFrameCount i = 0; i < nf; i++)
                                dst[i] = useR ? src[2 * i + 1] : src[2 * i];
                            rms = nf ? (MAX(sl, sr) / (float)nf) : 0;
                        } else {
                            memcpy(dst, src, nf * sizeof(float));
                            float sum = 0;
                            for (AVAudioFrameCount i = 0; i < nf; i++) sum += fabsf(src[i]);
                            rms = nf ? (sum / (float)nf) : 0;
                        }
                        ch->lastRMS = rms;
                        if (rms > 0.008f)
                            ch->lastLoudAt = CFAbsoluteTimeGetCurrent();
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
    lastProvTransAt = 0;
    lastLoudAt = 0;
    lastResultAt = CFAbsoluteTimeGetCurrent();
    lastRMS = 0;
    noSpeechCount = 0;
    lastRealResultAt = CFAbsoluteTimeGetCurrent();
    lastTapProbeAt = CFAbsoluteTimeGetCurrent();
    callGen++;                 // 新采集：旧通话的 final 译文一律丢弃
    lastText = nil;
    lastPartialText = nil;
    lastProvisional = nil;
    lastPartialAt = 0;
    lastTextAt = 0;
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
    // 清空识别/翻译状态：新通话不能复用上一通的 lastPartialText，否则会把旧句反复当新句
    lastText = nil;
    lastPartialText = nil;
    lastProvisional = nil;
    lastPartialAt = 0;
    lastTextAt = 0;
    lastProvTransAt = 0;
    noSpeechCount = 0;
    lastRealResultAt = 0;
    lastTapProbeAt = 0;
    endAudioSent = NO;
    callGen++;
    partialGen++;
    @try {
        // 不调用 [task ：本环境会在 SFLocalSpeechRecognitionClient stopSpeech 触发 SIGBUS
        task = nil;                 // 先置空，旧 task 的 216 取消回调会被 ch->task != t 丢弃
        if (req) { [req endAudio]; req = nil; }
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
    lastPartialText = nil;
    lastProvisional = nil;
    lastPartialAt = 0;
    lastProvTransAt = 0;
    endAudioSent = NO;
    partialGen++;
    @try {
        // 不调用 [task ：本环境会在 SFLocalSpeechRecognitionClient stopSpeech 触发 SIGBUS
        task = nil;                 // 先置空，旧 task 的 216 取消回调会被 ch->task != t 丢弃
        if (req) { [req endAudio]; req = nil; }
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
        task = nil;                 // 先置空，旧 task 的 216 取消回调会被 ch->task != t 丢弃
        if (req) { [req endAudio]; req = nil; }

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
        // 关键：新任务必须清掉上一轮的 partial，否则 CheckArm 会立刻把旧句当稳定句，
        // 触发 endAudio → final → 新任务 → 再旧句的死循环。
        lastPartialText = nil;
        lastPartialAt = CFAbsoluteTimeGetCurrent();
        lastResultAt = CFAbsoluteTimeGetCurrent();
        lastProvTransAt = 0;
        endAudioSent = NO;
        lastProvisional = nil;
        partialGen++;
        CCLogf(@"%@ recog: task start (auth=%ld avail=%d cloud=%d locale=%@)",
               self.tag, (long)[SFSpeechRecognizer authorizationStatus],
               recog.isAvailable, !CCPrefBool(CC_K_CLOUD_ASR, YES), self.locale);

        __weak CCChannel *weakSelf = self;
        __block SFSpeechRecognitionTask *t = nil;
        t = [recog recognitionTaskWithRequest:r
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                CCChannel *ch = weakSelf;
                if (!ch) return;
                // 旧 task 被 recogStart/endAudio 取消后会回调 216。
                // 如果不判断，会把刚建好的新 task 再取消，形成 1 秒一次的 task 重启死循环。
                if (ch->task != t) return;
                [ch handleResult:result error:error];
            }];
        task = t;

        // 不做任何“按时间强制切句”。说话长短、停顿、重复都由用户决定；
        // 只有检测到自然停顿（stable partial）才 endAudio 收句。
        // 如果 SFSpeech 自己因为超时/错误结束，handleResult 会重建 task。
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
            lastResultAt = now;
            lastRealResultAt = now;
            noSpeechCount = 0;
            NSString *txt = CCTrim(result.bestTranscription.formattedString);
            if (result.isFinal) {
                if (!muted && txt.length) {
                    double conf = CCResultConfidence(result);
                    if (conf >= 0 && conf < 0.45) {
                        // 低置信度不再丢弃：LCT 也不按置信度过滤。
                        // 我们有语言过滤和 lastText 去重，误识别比漏句更可接受。
                        CCLogf(@"%@: low confidence %.2f, accept anyway: %@", self.tag, conf, txt);
                    }
                    [self deliverFinal:txt];
                }
                // final 已经产出：清掉 partial 状态，防止下一次 recogStart 又被旧 partial 触发
                lastPartialText = nil;
                lastPartialAt = 0;
                lastProvisional = nil;
                endAudioSent = NO;
                if (capturing && !ttsPaused) [self recogRestart:0.25];
                return;
            }
            if (!muted && txt.length > 1 &&
                (!lastPartialText || now - lastPartialAt > 0.4)) {
                BOOL same = lastPartialText && [lastPartialText isEqualToString:txt];
                if (!same) {
                    lastPartialAt = now;
                    lastPartialText = txt;
                    BOOL cjk = CCContainsCJK(txt);
                    BOOL ok = self.expectCJK ? cjk : !cjk;
                    if (ok) {
                        NSString *prefix = self.expectCJK ? @"LI|" : @"I|";
                        CCTransportSendLine([prefix stringByAppendingString:txt]);
                        // LCT 式的流式体验：连续说话时也每隔 1.5 秒增量翻一次，
                        // 不用等到整句停顿/结束才出译文。
                        if (txt.length >= 6 && now - lastProvTransAt > 1.0)
                            [self translateProvisional:txt];
                    }
                }
            }
        }

        if (error) {
            NSInteger code = error.code;
            BOOL benign = (code == 216 /* cancelled */ || code == 1110 /* no speech */);
            CCLogf(@"%@ recog end: code=%ld benign=%d onDevice=%d %@",
                   self.tag, (long)code, benign, onDevice, error.localizedDescription);
            if (!benign) {
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
    if (lastProvisional && [lastProvisional isEqualToString:text]) return;
    if (self.expectCJK && !CCPrefBool(CC_K_LOCAL_ENABLED, NO)) return;
    if (!self.expectCJK && !CCPrefBool(CC_K_REMOTE_ENABLED, YES)) return;
    lastProvisional = text;
    lastProvTransAt = CFAbsoluteTimeGetCurrent();
    NSUInteger gen = ++partialGen;
    NSUInteger cg = callGen;
    __weak CCChannel *weakSelf = self;
    CCTranslateEx(text, self.srcLang, self.dstLang, ^(NSString *out, NSString *engine) {
        CCChannel *ch = weakSelf;
        if (!ch || out.length == 0) return;
        if (gen != ch->partialGen || cg != ch->callGen) return;  // 已经有更新的 partial / 通话已切换
        NSString *ep = ch.expectCJK ? @"LE|" : @"RE|";
        NSString *rp = ch.expectCJK ? @"LRP|" : @"RP|";
        if (engine.length) CCTransportSendLine([ep stringByAppendingString:engine]);
        CCLogf(@"%@ provisional trans[%@]: %@", ch.tag, engine ?: @"?", out);
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

    partialGen++;                 // 取消还没回来的 provisional，final 优先
    NSUInteger cg = callGen;
    __weak CCChannel *weakSelf = self;
    CCTranslateEx(t, self.srcLang, self.dstLang, ^(NSString *out, NSString *engine) {
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
        if (cg != ch->callGen) return;   // 通话已结束/切换，丢弃旧译文
        CCLogf(@"%@ trans[%@]: %@", ch.tag, engine ?: @"?", out);
        NSString *ep = ch.expectCJK ? @"LE|" : @"RE|";
        NSString *rp = ch.expectCJK ? @"LR|" : @"R|";
        if (engine.length) CCTransportSendLine([ep stringByAppendingString:engine]);
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

        static BOOL lastArmed = NO;
        BOOL armed = [[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH];
        if (armed && !lastArmed) {
            // 新通话：重置 Tap 探测，从 speaker(-2) 开始，最多试 -1 / -3。
            g_remote->tapProbeCount = 0;
            g_remote.tapPID = CC_TAP_PID_SPEAKER;
        }
        lastArmed = armed;
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

        // 自然停顿检测：partial 2 秒没变化才收句。
        // 0.8 秒太短，会把“思考一下再说”切断；2 秒更接近 LCT/Siri 的 endpointing。
        // 注意 lastPartialAt > 0：recogStart 刚启动时没有 partial，绝不能把旧 lastPartialText 当稳定句。
        for (CCChannel *ch in chans) {
            if (!ch->capturing || !ch->req || ch->endAudioSent) continue;
            if (ch->lastPartialText.length >= 4 &&
                ch->lastPartialAt > 0 &&
                now - ch->lastPartialAt > 2.0) {
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
                // 只重挂同一个 PID，不再乱换 -2/-1/-3：
                // 换到 -3 会把麦克风声音当“对方”，还会把通道语言切成中文。
                CCLogf(@"%@: audio stalled (frames=%llu), restarting tap pid=%d",
                       ch.tag, (unsigned long long)ch->frames, ch.tapPID);
                [ch stop];
                ch->lastAttempt = 0;
                ch->lastFrameChangeAt = now;
            }
        }

        // 识别健康看门狗：有真实声音、但 6 秒没有任何识别结果 → 重挂同一个 Tap。
        for (CCChannel *ch in chans) {
            if (!ch->capturing || ch->ttsPaused) continue;
            if (ch->lastLoudAt > 0 &&
                now - ch->lastLoudAt < 2.0 &&
                now - ch->lastResultAt > 6.0) {
                CCLogf(@"%@: loud(rms=%.3f) but no recognition for %.1fs, restarting tap pid=%d",
                       ch.tag, ch->lastRMS, now - ch->lastResultAt, ch.tapPID);
                ch->lastResultAt = now;
                [ch stop];
                ch->lastAttempt = 0;
                ch->lastFrameChangeAt = now;
            }
        }

        if (g_remote->capturing && now - g_remote->lastStatsAt >= 5.0) {
            g_remote->lastStatsAt = now;
            CCLogf(@"remote: alive, audio=%llu frames=%llu rms=%.4f noResult=%.1fs",
                   (unsigned long long)g_remote->audioBytes,
                   (unsigned long long)g_remote->frames,
                   g_remote->lastRMS,
                   g_remote->lastResultAt > 0 ? now - g_remote->lastResultAt : -1);
        }
        if (g_local->capturing && now - g_local->lastStatsAt >= 5.0) {
            g_local->lastStatsAt = now;
            CCLogf(@"local: alive, audio=%llu frames=%llu rms=%.4f noResult=%.1fs",
                   (unsigned long long)g_local->audioBytes,
                   (unsigned long long)g_local->frames,
                   g_local->lastRMS,
                   g_local->lastResultAt > 0 ? now - g_local->lastResultAt : -1);
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
            NSString *dk = CCPrefStr(CC_K_DEEPL_KEY, @"");
            CCLogf(@"prefs changed: engine=%@ deeplKeyLen=%lu remote=%d local=%d",
                   CCPrefStr(CC_K_ENGINE, @"auto"), (unsigned long)dk.length,
                   CCPrefBool(CC_K_REMOTE_ENABLED, YES),
                   CCPrefBool(CC_K_LOCAL_ENABLED, NO));
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
        CCLogLine(@"audioservice started (v0.14.0-alpha5)");
        {
            NSString *dk = CCPrefStr(CC_K_DEEPL_KEY, @"");
            CCLogf(@"prefs boot: engine=%@ deeplKeyLen=%lu remote=%d local=%d",
                   CCPrefStr(CC_K_ENGINE, @"auto"), (unsigned long)dk.length,
                   CCPrefBool(CC_K_REMOTE_ENABLED, YES),
                   CCPrefBool(CC_K_LOCAL_ENABLED, NO));
        }

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
