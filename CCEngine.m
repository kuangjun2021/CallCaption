// CCEngine.m — mediaserverd 侧：音频抓取（环缓冲）+ 语音识别 + TTS 播报
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

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
static atomic_long g_energySum;      // 累积能量（简易 VAD）
static atomic_int  g_energyN;
static atomic_int  g_remoteSpeaking; // 对方正在说话（能量门限）
static atomic_long g_axspeechCalls;  // AXSpeech 回调计数
static void SetCallActive(BOOL active);
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

    // 始终写入环缓冲：工作线程负责通话状态判定（音频活动自动触发，覆盖 WhatsApp 等网络通话）
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
        AudioStreamBasicDescription asbd;
        UInt32 size = sizeof(asbd);
        OSStatus st = AudioUnitGetProperty((AudioUnit)(uintptr_t)r->unit,
                                           kAudioUnitProperty_StreamFormat,
                                           kAudioUnitScope_Output, (AudioUnitElement)r->bus,
                                           &asbd, &size);
        if (st != noErr || asbd.mSampleRate < 8000) return;
        r->asbd = asbd;
        r->fmtValid = 1;
        // 统一转成标准单声道 float32 格式喂给识别器
        g_ringFormat[(int)(r - g_rings)] =
            [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                             sampleRate:asbd.mSampleRate
                                               channels:1
                                           interleaved:NO];
        CCLogf(@"ring fmt u%p/b%u sr%.0f ch%u fmt%4x bits%u",
               (void *)(uintptr_t)r->unit, r->bus, asbd.mSampleRate,
               asbd.mChannelsPerFrame, (unsigned)(asbd.mFormatID & 0xffff), asbd.mBitsPerChannel);
    } @catch (NSException *e) { }
}

// 把原始字节转成标准单声道 float32 缓冲（支持 float32 与 int16，交错/非交错皆可）
static AVAudioPCMBuffer *BuildPCM(CCRing *r, uint8_t *bytes, unsigned long len) {
    AVAudioFormat *fmt = g_ringFormat[(int)(r - g_rings)];
    if (!fmt || len == 0) return nil;
    AudioStreamBasicDescription a = r->asbd;
    @try {
        BOOL isFloat = (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        BOOL interleaved = (a.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
        UInt32 ch = a.mChannelsPerFrame ? a.mChannelsPerFrame : 1;

        unsigned long frameBytes = (a.mBitsPerChannel / 8) * (interleaved ? ch : 1);
        AVAudioFrameCount frames = (AVAudioFrameCount)(len / frameBytes);
        if (frames == 0) return nil;

        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                              frameCapacity:frames];
        if (!pcm) return nil;
        float *dst = pcm.floatChannelData[0];

        if (isFloat && a.mBitsPerChannel == 32) {
            const float *src = (const float *)bytes;
            if (interleaved) {
                for (AVAudioFrameCount f = 0; f < frames; f++) {
                    float acc = 0;
                    for (UInt32 c = 0; c < ch; c++) acc += src[f * ch + c];
                    dst[f] = acc / (float)ch;
                }
            } else {
                // 非交错时 tap 只存了第一个 AudioBuffer（第一声道平面）
                for (AVAudioFrameCount f = 0; f < frames; f++) dst[f] = src[f];
            }
        } else if (a.mBitsPerChannel == 16) {
            const int16_t *src = (const int16_t *)bytes;
            if (interleaved) {
                for (AVAudioFrameCount f = 0; f < frames; f++) {
                    int32_t acc = 0;
                    for (UInt32 c = 0; c < ch; c++) acc += src[f * ch + c];
                    dst[f] = (float)(acc / (int32_t)ch) / 32768.0f;
                }
            } else {
                for (AVAudioFrameCount f = 0; f < frames; f++)
                    dst[f] = (float)src[f] / 32768.0f;
            }
        } else {
            return nil; // 未知格式，跳过
        }
        pcm.frameLength = frames;
        return pcm;
    } @catch (NSException *e) { }
    return nil;
}

static void WorkTick(void) {
    @try {
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
            if (atomic_load(&g_callActive)) {
                AVAudioPCMBuffer *pcm = BuildPCM(r, tmp, got);
                if (pcm) [g_recog appendBuffer:pcm];
            }
        }

        // ===== 通话状态机：持续音频活动 = 通话中（蜂窝/WhatsApp/VoIP 通吃） =====
        static int s_ticks = 0; // >0: 激活累计；<0: 静默冷却
        if (totBytes > 24000) {
            if (s_ticks >= 0) s_ticks++;
            else s_ticks++;
            if (!atomic_load(&g_callActive) && s_ticks >= 8) { // ~2 秒持续音频
                SetCallActive(YES);
                CCPostNotif(@"call");
                s_ticks = 30;
                [g_recog startIfNeeded];
            }
        } else {
            if (s_ticks > 0) s_ticks -= 2;
            else if (s_ticks < 0) s_ticks++;
            if (atomic_load(&g_callActive) && s_ticks <= -180) { // ~45 秒无音频
                SetCallActive(NO);
                CCPostNotif(@"callend");
                s_ticks = -240; // 冷却，防止立即重触发
                [g_recog stopAll];
            }
        }

        // 诊断心跳（每 20 tick = 5 秒）
        static int slow;
        if ((++slow % 20) == 0) {
            CheckEnergy();
            long ax = atomic_exchange(&g_axspeechCalls, 0);
            if (ax > 0) CCPostNotif([NSString stringWithFormat:@"ax %ld", ax]);
            if (atomic_load(&g_callActive))
                CCPostNotif([NSString stringWithFormat:@"act ticks %d", s_ticks]);
        }
    } @catch (NSException *e) { }
}

// ---------- 通话状态（由通知驱动） ----------

static void SetCallActive(BOOL active) {
    atomic_store(&g_callActive, active ? 1 : 0);
    if (active) {
        [g_recog startIfNeeded];
    } else {
        for (int i = 0; i < CC_RINGS; i++) atomic_store(&g_rings[i].bound, 0);
        [g_recog stopAll];
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
    if ([n isEqualToString:CC_NOTIF_PREFIX @"call"]) SetCallActive(YES);
    else if ([n isEqualToString:CC_NOTIF_PREFIX @"callend"]) SetCallActive(NO);
    else if ([n isEqualToString:CC_NOTIF_PREFS]) CCPrefsReload();
}

void CCEngineBoot(void) {
    @try {
        CCMark(@"ms 5.1 engine boot enter");
        g_recog = [[CCRecognizer alloc] init];
        g_workQ = dispatch_queue_create("net.user.callcaption.engine", DISPATCH_QUEUE_SERIAL);
        for (int i = 0; i < CC_RINGS; i++) {
            g_rings[i].buf = (uint8_t *)malloc(CC_RING_CAP);
            atomic_store(&g_rings[i].w, 0);
            atomic_store(&g_rings[i].r, 0);
            atomic_store(&g_rings[i].bound, 0);
        }
        CCMark(@"ms 5.2 rings allocated");
        CCTTSInitIfNeeded();
        CCMark(@"ms 5.3 tts created");
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
