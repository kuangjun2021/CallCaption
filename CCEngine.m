// CCEngine.m — mediaserverd 侧：音频抓取（环缓冲）+ 语音识别 + TTS 播报
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <math.h>

// ============================================================
// 音频抓取：预分配环缓冲，音频线程只做 memcpy + 原子递增
// ============================================================

#define CC_RINGS   4
#define CC_RING_CAP (1 << 20)   // 1MB / 环

typedef struct {
    uint8_t *buf;
    _Atomic unsigned long w;
    _Atomic unsigned long r;
    _Atomic int bound;          // 0 = 空闲
    int unit;
    int bus;
    AVAudioFormat *fmt;         // 仅工作线程访问
    AudioStreamBasicDescription asbd;
    int fmtValid;
} CCRing;

static CCRing g_rings[CC_RINGS];
static dispatch_queue_t g_workQ;
static dispatch_source_t g_workTimer;
static AVAudioFormat *g_ringFormat[CC_RINGS];

// 活动状态
static atomic_int  g_callActive;
static atomic_int  g_userArmed;      // v0.7 纯手动模式：用户点"译"按钮才开始抓取
static atomic_long g_energySum;      // 累积能量（简易 VAD）
static atomic_int  g_energyN;
static atomic_int  g_remoteSpeaking; // 对方正在说话（能量门限）
static atomic_long g_axspeechCalls;  // AXSpeech 回调计数
static void SetUserArmed(BOOL armed);
static void CheckEnergy(void);

// ---------- 环缓冲读写 ----------

static unsigned long RBWrite(CCRing *r, const uint8_t *data, unsigned long len) {
    unsigned long w = atomic_load(&r->w), rd = atomic_load(&r->r);
    unsigned long used = (w >= rd) ? (w - rd) : (w + CC_RING_CAP - rd);
    unsigned long free_ = CC_RING_CAP - 1 - used;
    if (len > free_) {
        len = free_;
        if (len == 0) return 0;
    }
    unsigned long pos = w % CC_RING_CAP;
    unsigned long first = CC_RING_CAP - pos;
    if (first > len) first = len;
    memcpy(r->buf + pos, data, first);
    if (len > first) memcpy(r->buf, data + first, len - first);
    atomic_store(&r->w, w + len);
    return len;
}

static unsigned long RBRead(CCRing *r, uint8_t *out, unsigned long len) {
    unsigned long w = atomic_load(&r->w), rd = atomic_load(&r->r);
    unsigned long used = (w >= rd) ? (w - rd) : (w + CC_RING_CAP - rd);
    if (len > used) len = used;
    if (len == 0) return 0;
    unsigned long pos = rd % CC_RING_CAP;
    unsigned long first = CC_RING_CAP - pos;
    if (first > len) first = len;
    memcpy(out, r->buf + pos, first);
    if (len > first) memcpy(out + first, r->buf, len - first);
    atomic_store(&r->r, rd + len);
    return len;
}

// ---------- 音频线程入口（由 Tweak.x 的 hook 调用，实时线程） ----------

void CCAudioTapObserve(AudioUnit unit, UInt32 bus, UInt32 frames, AudioBufferList *ioData) {
    if (!ioData) return;
    UInt32 bytes = 0;
    UInt32 nb = ioData->mNumberBuffers;
    if (nb > 2) nb = 2;
    for (UInt32 b = 0; b < nb; b++) bytes += ioData->mBuffers[b].mDataByteSize;
    if (bytes == 0 || !ioData->mBuffers[0].mData) return;

    // v0.7 纯手动模式：未手动启用时，音频线程直接返回（对系统零干扰）
    if (!atomic_load(&g_userArmed)) return;

    // 能量采样（每 16 帧取一次，只在第一 buffer 上粗算，实时线程零分配）
    static atomic_int tick;
    int t = atomic_fetch_add(&tick, 1);
    if ((t & 0xF) == 0 && ioData->mBuffers[0].mDataByteSize >= 64) {
        const int16_t *p = (const int16_t *)ioData->mBuffers[0].mData;
        long sum = 0;
        int n = 32;
        for (int i = 0; i < n; i++) sum += abs(p[i * 2]);
        atomic_fetch_add(&g_energySum, sum / n);
        atomic_fetch_add(&g_energyN, 1);
    }

    // 绑定或复用环（无锁查找，绑定时仅原子置位；首次绑定由工作线程补格式信息）
    CCRing *target = NULL;
    for (int i = 0; i < CC_RINGS; i++) {
        if (atomic_load(&g_rings[i].bound) &&
            g_rings[i].unit == (int)(uintptr_t)unit && g_rings[i].bus == (int)bus) {
            target = &g_rings[i];
            break;
        }
    }
    if (!target) {
        for (int i = 0; i < CC_RINGS; i++) {
            int expect = 0;
            if (atomic_compare_exchange_strong(&g_rings[i].bound, &expect, 1)) {
                g_rings[i].unit = (int)(uintptr_t)unit;
                g_rings[i].bus = (int)bus;
                g_rings[i].fmtValid = 0;
                target = &g_rings[i];
                CCLogf(@"tap bind slot %d unit %p bus %u", i, unit, bus);
                break;
            }
        }
    }
    if (!target) return;

    if (nb >= 1 && ioData->mBuffers[0].mDataByteSize > 0) {
        RBWrite(target, (const uint8_t *)ioData->mBuffers[0].mData, ioData->mBuffers[0].mDataByteSize);
    }
}

// ---------- 识别器 ----------

@interface CCRecognizer : NSObject <SFSpeechRecognizerDelegate>
@property (nonatomic, strong) SFSpeechRecognizer *enRecog;
@property (nonatomic, strong) SFSpeechRecognizer *zhRecog;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *enReq;
@property (nonatomic, strong) SFSpeechRecognitionTask *enTask;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *zhReq;
@property (nonatomic, strong) SFSpeechRecognitionTask *zhTask;
@property (nonatomic, assign) BOOL started;
- (void)startIfNeeded;
- (void)stopAll;
- (void)appendBuffer:(AVAudioPCMBuffer *)pcm;
@end

static CCRecognizer *g_recog;

@implementation CCRecognizer

- (instancetype)init {
    self = [super init];
    if (self) {
        _enRecog = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"en-US"]];
        _zhRecog = [[SFSpeechRecognizer alloc] initWithLocale:[[NSLocale alloc] initWithLocaleIdentifier:@"zh-CN"]];
        _enRecog.delegate = self;
        _zhRecog.delegate = self;
    }
    return self;
}

- (void)startIfNeeded {
    if (self.started) return;
    self.started = YES;
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            CCLogf(@"speech auth: %ld", (long)status);
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                // 无授权 → 识别无法工作，自动解除，避免无意义的持续占用
                CCLogf(@"auth denied, auto disarm");
                SetUserArmed(NO);
                CCPostNotif(@"disarm");
                return;
            }
            [self restartEN];
            if (CCPrefBool(CC_K_LOCAL_ENABLED, NO)) [self restartZH];
        });
    }];
}

- (void)stopAll {
    self.started = NO;
    @try {
        [self.enReq endAudio];
        [self.enTask cancel]; self.enTask = nil; self.enReq = nil;
        [self.zhReq endAudio];
        [self.zhTask cancel]; self.zhTask = nil; self.zhReq = nil;
    } @catch (NSException *e) { }
}

- (void)restartEN {
    @try {
        if (!self.enRecog.available) { CCLogf(@"en recognizer unavailable"); return; }
        if (self.enReq) { [self.enReq endAudio]; }
        self.enReq = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.enReq.shouldReportPartialResults = YES;
        if (@available(iOS 13.0, *)) self.enReq.addsPunctuation = YES;
        SFSpeechAudioBufferRecognitionRequest *req = self.enReq;
        __weak typeof(self) wself = self;
        self.enTask = [self.enRecog recognitionTaskWithRequest:req
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                [wself handleResult:result error:error lang:@"en"];
            }];
    } @catch (NSException *e) { CCLogf(@"restartEN exc %@", e); }
}

- (void)restartZH {
    @try {
        if (!self.zhRecog.available) return;
        if (self.zhReq) { [self.zhReq endAudio]; }
        self.zhReq = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
        self.zhReq.shouldReportPartialResults = YES;
        SFSpeechAudioBufferRecognitionRequest *req = self.zhReq;
        __weak typeof(self) wself = self;
        self.zhTask = [self.zhRecog recognitionTaskWithRequest:req
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                [wself handleResult:result error:error lang:@"zh"];
            }];
    } @catch (NSException *e) { }
}

- (void)appendBuffer:(AVAudioPCMBuffer *)pcm {
    @try {
        if (self.enReq) [self.enReq appendAudioPCMBuffer:pcm];
        if (self.zhReq) [self.zhReq appendAudioPCMBuffer:pcm];
    } @catch (NSException *e) { }
}

- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error lang:(NSString *)lang {
    @try {
        if (error) {
            CCLogf(@"recog[%@] err %@", lang, error.localizedDescription);
            if (self.started) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)1 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                    if (self.started) {
                        if ([lang isEqualToString:@"en"]) [self restartEN];
                        else [self restartZH];
                    }
                });
            }
            return;
        }
        NSString *text = result.bestTranscription.formattedString;
        if (text.length == 0) return;
        BOOL final = result.isFinal;
        if (final) {
            // 结束一句话：翻译 + 下发 + 重启会话
            NSString *src = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (src.length >= 1) {
                BOOL isLocal = [lang isEqualToString:@"zh"];
                NSString *from = isLocal ? @"zh" : @"en";
                NSString *to = isLocal ? @"en" : @"zh";
                CCLogf(@"recognized[%@] %@", lang, src);
                CCTransportSendLine([NSString stringWithFormat:@"I|%@", src]);
                CCTTSStopAll();
                CCTranslate(src, from, to, ^(NSString *out) {
                    if (out.length == 0) return;
                    if (isLocal) {
                        CCLogf(@"local-> %@", out);
                        CCTransportSendLine([NSString stringWithFormat:@"L|%@", out]);
                        if (CCPrefBool(CC_K_LOCAL_ENABLED, NO))
                            CCTTSSpeak(out, @"en-US"); // 扬声器中继，对方听到
                    } else {
                        CCLogf(@"translated: %@", out);
                        CCTransportSendLine([NSString stringWithFormat:@"R|%@", out]);
                        if (CCPrefBool(CC_K_TTS_ENABLED, YES))
                            CCTTSSpeak(out, @"zh-CN");
                    }
                });
            }
            if (self.started) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!self.started) return;
                    if ([lang isEqualToString:@"en"]) [self restartEN];
                    else [self restartZH];
                });
            }
        }
    } @catch (NSException *e) { }
}

@end

// ---------- TTS ----------

static AVSpeechSynthesizer *g_tts;

void CCTTSInitIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_tts = [[AVSpeechSynthesizer alloc] init];
    });
}

void CCTTSSpeak(NSString *text, NSString *lang) {
    if (!CCIsMediaServerd() || text.length == 0) return;
    @try {
        CCTTSInitIfNeeded();
        [g_tts stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
        u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:lang];
        u.volume = 1.0;
        u.rate = AVSpeechUtteranceDefaultSpeechRate;
        [g_tts speakUtterance:u];
    } @catch (NSException *e) { CCLogf(@"tts exc %@", e); }
}

void CCTTSStopAll(void) {
    if (!g_tts) return;
    @try { [g_tts stopSpeakingAtBoundary:AVSpeechBoundaryImmediate]; } @catch (NSException *e) { }
}

// ---------- 工作线程：环缓冲 → PCM 缓冲 → 识别器 ----------

static void MakeRingFormat(CCRing *r) {
    @try {
        // v0.7.3: 不再调用 AudioUnitGetProperty（会触碰音频服务器内部锁；
        // 通话中出现新音频流时触发 → 锁竞争/死锁 → 拨号端 WhatsApp 崩溃）。
        // 格式改为 BuildPCM 数据驱动启发式探测（零锁交互）。
        r->fmtValid = 1;
    } @catch (NSException *e) { }
}

// v0.7.3: 数据驱动启发式——先按 16-bit 交错立体声解析算 RMS，合理性不足再按
// float32 解析；全程零 AudioUnit 锁交互（修复通话中触发死锁的缺陷）。
static AVAudioFormat *MonoFmt(void) {
    static AVAudioFormat *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                             sampleRate:48000 channels:1 interleaved:NO];
    });
    return f;
}

static AVAudioPCMBuffer *BuildPCM(CCRing *r, uint8_t *bytes, unsigned long len) {
    if (len < 128) return nil;
    @try {
        AVAudioFormat *fmt = MonoFmt();
        if (!fmt) return nil;

        // 候选 A：按 16-bit 交错立体声解析
        unsigned long frames16 = len / 4;
        double acc16 = 0; size_t nz16 = 0;
        if (frames16 >= 32) {
            const int16_t *s = (const int16_t *)bytes;
            for (unsigned long i = 0; i < frames16; i++) {
                int32_t m = (s[i*2] + s[i*2+1]) / 2;
                double v = m / 32768.0; acc16 += v*v; if (m != 0) nz16++;
            }
        }
        double rms16 = frames16 ? sqrt(acc16 / frames16) : 0;
        BOOL sane16 = frames16 >= 32 && nz16 > frames16 / 8 && rms16 > 0.0003 && rms16 < 0.95;
        // 候选 B：按 float32 交错立体声解析
        unsigned long frames32 = len / 8;
        double acc32 = 0; size_t nz32 = 0; BOOL floatSane = YES;
        if (frames32 >= 32) {
            const float *s = (const float *)bytes;
            for (unsigned long i = 0; i < frames32; i++) {
                float m = (s[i*2] + s[i*2+1]) / 2.0f;
                if (!(m > -4.0f && m < 4.0f)) { floatSane = NO; break; }
                acc32 += (double)m*m; if (m != 0.0f) nz32++;
            }
        }
        double rms32 = frames32 ? sqrt(acc32 / frames32) : 0;
        BOOL sane32 = floatSane && frames32 >= 32 && nz32 > frames32 / 8 && rms32 > 0.0003 && rms32 < 0.95;

        int use = 0;
        if (sane16) use = 1;
        else if (sane32) use = 2;
        if (!use) return nil;

        AVAudioFrameCount frames = (use == 1) ? (AVAudioFrameCount)frames16
                                              : (AVAudioFrameCount)frames32;
        if (frames > (AVAudioFrameCount)96000) frames = (AVAudioFrameCount)96000;
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                              frameCapacity:frames];
        if (!pcm) return nil;
        float *dst = pcm.floatChannelData[0];
        if (use == 1) {
            const int16_t *s = (const int16_t *)bytes;
            for (AVAudioFrameCount f = 0; f < frames; f++) {
                int32_t m = (s[f*2] + s[f*2+1]) / 2;
                dst[f] = (float)m / 32768.0f;
            }
        } else {
            const float *s = (const float *)bytes;
            for (AVAudioFrameCount f = 0; f < frames; f++)
                dst[f] = (s[f*2] + s[f*2+1]) / 2.0f;
        }
        pcm.frameLength = frames;
        return pcm;
    } @catch (NSException *e) { }
    return nil;
}

static void WorkTick(void) {
    @try {
        // v0.7 纯手动模式：未启用时只做静默计数（不碰音频线程数据）
        if (!atomic_load(&g_userArmed)) {
            if (g_recog.started) [g_recog stopAll];
            return;
        }

        long totBytes = 0;
        for (int i = 0; i < CC_RINGS; i++) {
            CCRing *r = &g_rings[i];
            if (!atomic_load(&r->bound)) continue;
            if (!r->fmtValid) MakeRingFormat(r);
            if (!r->fmtValid) continue;

            unsigned long w = atomic_load(&r->w), rd = atomic_load(&r->r);
            unsigned long avail = (w >= rd) ? (w - rd) : (w + CC_RING_CAP - rd);
            if (avail < 9600) continue; // 攒一批再喂（~0.1s@48k 16bit）

            static uint8_t tmp[1 << 17];
            unsigned long want = avail;
            if (want > sizeof(tmp)) want = sizeof(tmp);
            unsigned long got = RBRead(r, tmp, want);
            if (!got) continue;
            totBytes += got;
            AVAudioPCMBuffer *pcm = BuildPCM(r, tmp, got);
            if (pcm) [g_recog appendBuffer:pcm];
        }

        // 安全兜底：启用后连续 5 分钟无音频 → 自动解除
        static int silenceTicks = 0;
        if (totBytes > 24000) silenceTicks = 0;
        else if (++silenceTicks >= 1200) { // 250ms × 1200 = 5 分钟
            CCLogf(@"5min silence, auto disarm");
            SetUserArmed(NO);
            CCPostNotif(@"disarm");
            silenceTicks = 0;
        }

        // 诊断心跳（每 20 tick = 5 秒）
        static int slow;
        if ((++slow % 20) == 0) {
            CheckEnergy();
            long ax = atomic_exchange(&g_axspeechCalls, 0);
            if (ax > 0) CCPostNotif([NSString stringWithFormat:@"ax %ld", ax]);
        }
    } @catch (NSException *e) { }
}

// ---------- 通话状态（由通知驱动） ----------

static void SetUserArmed(BOOL armed) {
    atomic_store(&g_userArmed, armed ? 1 : 0);
    if (armed) {
        // v0.8.2: 按需创建识别器（不在启动时常驻）+ 延迟 2 秒启动（避开拨号敏感窗口）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            if (!atomic_load(&g_userArmed)) return;
            if (!g_recog) g_recog = [[CCRecognizer alloc] init];
            [g_recog startIfNeeded];
        });
        CCMark(@"user ARMED (recognition in 2s)");
    } else {
        for (int i = 0; i < CC_RINGS; i++) atomic_store(&g_rings[i].bound, 0);
        [g_recog stopAll];
        CCMark(@"user DISARMED");
    }
}

static void CheckEnergy(void) {
    long n = atomic_load(&g_energyN);
    if (n == 0) return;
    long avg = atomic_exchange(&g_energySum, 0) / n;
    atomic_store(&g_energyN, 0);
    // 门限粗定：静音~<300，说话~>1500（int16 幅度）
    atomic_store(&g_remoteSpeaking, avg > 800 ? 1 : 0);
    if (avg > 200)
        CCPostNotif([NSString stringWithFormat:@"act lvl %ld", avg]); // 诊断心跳
}

// ---------- 启动 ----------

static void MSDarwinCB(CFNotificationCenterRef center, void *observer,
                       CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    if ([n isEqualToString:CC_NOTIF_PREFIX @"arm"]) SetUserArmed(YES);
    else if ([n isEqualToString:CC_NOTIF_PREFIX @"disarm"]) SetUserArmed(NO);
    else if ([n isEqualToString:CC_NOTIF_PREFS]) CCPrefsReload();
}

void CCEngineBoot(void) {
    @try {
        CCMark(@"ms 5.1 engine boot enter");
        // v0.8.2: SFSpeechRecognizer / AVSpeechSynthesizer 不在启动时创建（按需 arm 时创建），
        // 避免在 mediaserverd（音频会话管理进程）空闲状态下引入 Speech 框架的音频副作用
        g_workQ = dispatch_queue_create("net.user.callcaption.engine", DISPATCH_QUEUE_SERIAL);
        for (int i = 0; i < CC_RINGS; i++) {
            g_rings[i].buf = (uint8_t *)malloc(CC_RING_CAP);
            atomic_store(&g_rings[i].w, 0);
            atomic_store(&g_rings[i].r, 0);
            atomic_store(&g_rings[i].bound, 0);
        }
        CCMark(@"ms 5.2 rings allocated");
        g_workTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_workQ);
        dispatch_source_set_timer(g_workTimer, dispatch_walltime(NULL, 2 * NSEC_PER_SEC),
                                  250 * NSEC_PER_MSEC, 0); // 250ms
        dispatch_source_set_event_handler(g_workTimer, ^{
            WorkTick();
            static int slow;
            if ((++slow % 20) == 0) CheckEnergy(); // 每 5 秒报一次能量
        });
        dispatch_resume(g_workTimer);
        CCMark(@"ms 5.4 timer resumed");

        // 通话状态：来自 SB 的广播
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            MSDarwinCB, NULL, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CCMark(@"ms 5.5 observer added");
        CCLogf(@"engine booted");
    } @catch (NSException *e) {
        CCMark(@"engine BOOT EXCEPTION!");
    }
}
