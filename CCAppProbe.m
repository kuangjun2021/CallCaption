// CCAppProbe.m — 注入通话 App（WhatsApp），抓对方语音
//
// alpha10 已经证明关键链路：
//   1) 用真正的 ElleKit（/var/jb/usr/lib/libellekit.dylib）可以钩上 AudioUnitSetProperty；
//   2) WhatsApp 通话时会设置 render callback，我们包装成功（ok=1）；
//   3) 这个 callback 是持续触发的：480 帧、约 94 次/秒 —— 就是实时通话音频。
//
// alpha10 的 RMS 出现 8e35 这种离谱值，说明 callback 的 buffer 不是 float32，
// 我们按 float 读错了。alpha11：
//   - 记录每个单元的 StreamFormat（采样率/声道/位宽/格式标志）；
//   - 按真实格式换算样本、算 RMS；
//   - 把回调音频录成 WAV 放到 App 的 Documents 里，可以直接试听确认是不是对方声音。
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <os/log.h>
#import <math.h>
#import <stdio.h>
#import <unistd.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <stdatomic.h>

typedef void (*CCMSHookFunction)(void *symbol, void *hook, void **old);
static CCMSHookFunction g_MSHook = NULL;
static os_log_t g_oslog = NULL;

#define CC_APP_LOG @"/var/mobile/Library/CallCaption/probe.log"

typedef OSStatus (*SetPropFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                              AudioUnitElement, const void *, UInt32);
typedef OSStatus (*AURenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                               const AudioTimeStamp *, UInt32, UInt32,
                               AudioBufferList *);

static SetPropFn g_origSetProp = NULL;
static AURenderFn g_origRender = NULL;

// ---------- 日志（后台/设置线程调用，不在音频渲染线程） ----------
static void CCAppLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        if (!g_oslog) g_oslog = os_log_create("net.user.callcaption", "appprobe");
        os_log_with_type(g_oslog, OS_LOG_TYPE_DEFAULT, "%{public}s", msg.UTF8String);

        NSString *shortMsg = msg.length > 90 ? [msg substringToIndex:90] : msg;
        NSString *name = [NSString stringWithFormat:@"net.user.callcaption.log hook: %@", shortMsg];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name,
                                             NULL, NULL, true);

        NSString *line = [NSString stringWithFormat:@"[%@] hook: %@\n", [NSDate date], msg];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        [paths addObject:CC_APP_LOG];
        [paths addObject:@"/tmp/ccappprobe.log"];
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length) [paths addObject:[tmp stringByAppendingPathComponent:@"ccappprobe.log"]];
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) firstObject];
        if (docs.length) [paths addObject:[docs stringByAppendingPathComponent:@"ccappprobe.log"]];
        for (NSString *p in paths) {
            @try {
                FILE *fp = fopen(p.fileSystemRepresentation, "a");
                if (!fp) continue;
                fputs(line.UTF8String, fp);
                fclose(fp);
                chmod(p.fileSystemRepresentation, 0666);
            } @catch (NSException *e) { }
        }
    }
}

static NSString *CCProcName(void) {
    return [[NSProcessInfo processInfo] processName] ?: @"?";
}

static inline uint32_t CCFloatBits(float f) {
    union { float f; uint32_t u; } v; v.f = f; return v.u;
}
static inline float CCBitsFloat(uint32_t u) {
    union { float f; uint32_t u; } v; v.u = u; return v.f;
}

// ---------- 每个单元的 StreamFormat ----------
typedef struct {
    AudioUnit unit;
    double rate;
    UInt32 ch;
    UInt32 bits;
    UInt32 flags;
    BOOL valid;
} CCFmt;
static CCFmt g_fmts[16];

static void CCStoreFmt(AudioUnit unit, AudioUnitScope scope, AudioUnitElement elem,
                       const AudioStreamBasicDescription *a) {
    int slot = -1;
    for (int i = 0; i < 16; i++) {
        if (g_fmts[i].unit == unit) { slot = i; break; }
        if (!g_fmts[i].valid && slot < 0) slot = i;
    }
    if (slot < 0) return;
    // 输出 scope 的格式才是 callback 看到的格式；这里以最后一次设置为准
    g_fmts[slot].unit = unit;
    g_fmts[slot].rate = a->mSampleRate;
    g_fmts[slot].ch = a->mChannelsPerFrame ? a->mChannelsPerFrame : 1;
    g_fmts[slot].bits = a->mBitsPerChannel;
    g_fmts[slot].flags = a->mFormatFlags;
    g_fmts[slot].valid = YES;
}

static CCFmt *CCFindFmt(AudioUnit unit) {
    for (int i = 0; i < 16; i++) {
        if (g_fmts[i].valid && g_fmts[i].unit == unit) return &g_fmts[i];
    }
    return NULL;
}

// ---------- 包装 render callback + WAV 录制 ----------

#define CC_CAP_SECONDS 1800

typedef struct {
    AURenderCallback proc;
    void *refcon;
    AudioUnit unit;
    UInt32 bus;
    CCFmt fmt;
    _Atomic(uint64_t) calls;
    _Atomic(uint32_t) frames;
    _Atomic(uint32_t) rmsBits;
    // SPSC ring（回调线程写，report 线程读）
    float *ring;
    UInt32 cap;                 // 样本数
    _Atomic(uint32_t) head;
    _Atomic(uint32_t) tail;
    _Atomic(uint32_t) done;     // 超过时长后停止
    // WAV
    FILE *fp;
    char path[512];
    uint64_t dataBytes;
} CCCB;

static CCCB *g_cbs[16];
static _Atomic(int) g_cbCount;

static void CCMixZhDownlink(CCCB *c, AudioBufferList *ioData, UInt32 frames);

static float CCReadSample(const void *data, UInt32 idx, UInt32 bits, UInt32 flags) {
    if (flags & kAudioFormatFlagIsFloat) {
        if (bits == 32) return ((const float *)data)[idx];
        if (bits == 64) return (float)((const double *)data)[idx];
        return 0;
    }
    if (bits == 16) return (float)(((const int16_t *)data)[idx]) / 32768.0f;
    if (bits == 32) return (float)(((const int32_t *)data)[idx]) / 2147483648.0f;
    if (bits == 8)  return (float)(((const int8_t *)data)[idx]) / 128.0f;
    return 0;
}

static void CCRecordCB(CCCB *c, AudioBufferList *ioData, UInt32 frames) {
    if (!c || !ioData || frames == 0) return;
    UInt32 ch = c->fmt.ch ? c->fmt.ch : 1;
    UInt32 bits = c->fmt.bits ? c->fmt.bits : 32;
    UInt32 flags = c->fmt.flags;
    UInt32 bytesPerSample = bits / 8;

    double sum = 0;
    UInt64 count = 0;
    AudioBuffer *b = &ioData->mBuffers[0];
    if (b->mData && b->mDataByteSize >= bytesPerSample) {
        UInt32 avail = b->mDataByteSize / bytesPerSample;
        UInt32 n = frames * ch;
        if (n > avail) n = avail;
        if (n > 4096) n = 4096;
        UInt32 samples = n / ch;
        uint32_t head = atomic_load_explicit(&c->head, memory_order_relaxed);
        uint32_t tail = atomic_load_explicit(&c->tail, memory_order_relaxed);
        BOOL canWrite = (c->ring && !atomic_load_explicit(&c->done, memory_order_relaxed));
        for (UInt32 i = 0; i < samples; i++) {
            float s = CCReadSample(b->mData, i * ch, bits, flags);
            sum += fabsf(s);
            count++;
            if (canWrite && (head - tail) < c->cap) {
                c->ring[head % c->cap] = s;
                head++;
            }
        }
        if (canWrite) atomic_store_explicit(&c->head, head, memory_order_relaxed);
    }
    if (count) {
        float rms = (float)(sum / (double)count);
        if (!isfinite(rms)) rms = 0;
        atomic_store_explicit(&c->rmsBits, CCFloatBits(rms), memory_order_relaxed);
    }
    atomic_store_explicit(&c->frames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->calls, 1, memory_order_relaxed);
}

static OSStatus CCWrappedRender(void *refCon, AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *ts, UInt32 bus,
                                UInt32 frames, AudioBufferList *ioData) {
    CCCB *c = (CCCB *)refCon;
    OSStatus st = (c && c->proc)
        ? c->proc(c->refcon, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr) {
        CCRecordCB(c, ioData, frames);
        CCMixZhDownlink(c, ioData, frames);
    }
    return st;
}

// ---------- WAV 写入（只在 report 线程） ----------
static void CCWriteWavHeader(FILE *fp, uint32_t rate, uint64_t dataBytes) {
    if (!fp) return;
    uint32_t riff = (uint32_t)(36 + dataBytes);
    uint32_t dsz = (uint32_t)dataBytes;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    uint32_t byteRate = rate * 2;
    fseek(fp, 0, SEEK_SET);
    fwrite("RIFF", 1, 4, fp);
    fwrite(&riff, 4, 1, fp);
    fwrite("WAVEfmt ", 1, 8, fp);
    uint32_t sz16 = 16;
    fwrite(&sz16, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp);
    fwrite(&ch, 2, 1, fp);
    fwrite(&rate, 4, 1, fp);
    fwrite(&byteRate, 4, 1, fp);
    fwrite(&align, 2, 1, fp);
    fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp);
    fwrite(&dsz, 4, 1, fp);
    fseek(fp, 0, SEEK_END);
}

static void CCFlushWav(CCCB *c) {
    if (!c || !c->ring || !c->fp) return;
    uint32_t head = atomic_load(&c->head);
    uint32_t tail = atomic_load(&c->tail);
    if (head == tail) return;

    uint16_t buf[2048];
    while (tail != head) {
        uint32_t n = 0;
        while (tail != head && n < 2048) {
            float s = c->ring[tail % c->cap];
            int v = (int)lrintf(s * 32767.0f);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            buf[n++] = (uint16_t)(int16_t)v;
            tail++;
        }
        fwrite(buf, 2, n, c->fp);
        c->dataBytes += n * 2;
    }
    atomic_store(&c->tail, tail);
    CCWriteWavHeader(c->fp, (uint32_t)(c->fmt.rate ? c->fmt.rate : 48000), c->dataBytes);
    fflush(c->fp);

    if (c->fmt.rate > 0 &&
        c->dataBytes >= (uint64_t)(c->fmt.rate * CC_CAP_SECONDS * 2)) {
        atomic_store(&c->done, 1);
    }
}

static CCCB *CCMakeCB(AudioUnit unit, UInt32 bus,
                      const AURenderCallbackStruct *orig) {
    CCCB *c = calloc(1, sizeof(CCCB));
    if (!c) return NULL;
    c->proc = orig->inputProc;
    c->refcon = orig->inputProcRefCon;
    c->unit = unit;
    c->bus = bus;
    CCFmt *f = CCFindFmt(unit);
    if (f) c->fmt = *f;
    if (c->fmt.rate <= 0) c->fmt.rate = 48000;
    if (c->fmt.ch == 0) c->fmt.ch = 1;
    if (c->fmt.bits == 0) c->fmt.bits = 32;
    c->cap = (UInt32)(c->fmt.rate * 30);   // 30 秒环：报告线程偶发卡顿也不丢字
    c->ring = calloc(c->cap, sizeof(float));
    if (!c->ring) { free(c); return NULL; }

    // WAV 放到 App 的 Documents，Filza 可直接播
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (docs.length) {
        NSString *name = [NSString stringWithFormat:@"cc_remote_%04x_%d.wav",
                          (unsigned)((uintptr_t)unit & 0xffff), getpid()];
        NSString *p = [docs stringByAppendingPathComponent:name];
        snprintf(c->path, sizeof(c->path), "%s", p.fileSystemRepresentation);
        c->fp = fopen(c->path, "wb");
        if (c->fp) CCWriteWavHeader(c->fp, (uint32_t)c->fmt.rate, 0);
    }
    return c;
}

// ---------- SetProperty 钩子 ----------
static OSStatus CCHookedSetProp(AudioUnit unit, AudioUnitPropertyID prop,
                                AudioUnitScope scope, AudioUnitElement elem,
                                const void *inData, UInt32 inDataSize) {
    @autoreleasepool {
        if (prop == kAudioUnitProperty_StreamFormat &&
            inData && inDataSize >= sizeof(AudioStreamBasicDescription)) {
            const AudioStreamBasicDescription *a =
                (const AudioStreamBasicDescription *)inData;
            CCStoreFmt(unit, scope, elem, a);
            static uint32_t seen[64][3];
            static int seenCount;
            uint32_t u = (uint32_t)((uintptr_t)unit & 0xffff);
            BOOL dup = NO;
            for (int i = 0; i < seenCount; i++) {
                if (seen[i][0] == u && seen[i][1] == scope && seen[i][2] == elem) { dup = YES; break; }
            }
            if (!dup) {
                if (seenCount < 64) {
                    seen[seenCount][0] = u; seen[seenCount][1] = scope; seen[seenCount][2] = elem;
                    seenCount++;
                }
                CCAppLog(@"fmt u%x s%u e%u rate%.0f ch%u bits%u fl0x%x",
                         u, scope, elem, a->mSampleRate, a->mChannelsPerFrame,
                         a->mBitsPerChannel, a->mFormatFlags);
            }
        }

        if (prop == kAudioUnitProperty_SetRenderCallback &&
            inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
            const AURenderCallbackStruct *orig = (const AURenderCallbackStruct *)inData;
            if (orig->inputProc) {
                CCCB *c = CCMakeCB(unit, elem, orig);
                if (c) {
                    int idx = atomic_load(&g_cbCount);
                    if (idx < 16) {
                        g_cbs[idx] = c;
                        atomic_store(&g_cbCount, idx + 1);
                        AURenderCallbackStruct wrap = *orig;
                        wrap.inputProc = CCWrappedRender;
                        wrap.inputProcRefCon = c;
                        OSStatus st = g_origSetProp(unit, prop, scope, elem,
                                                    &wrap, sizeof(wrap));
                        CCAppLog(@"renderCB u%x b%u ok%d fmt=%.0f/%u/%u fl0x%x wav=%s",
                                 (unsigned)((uintptr_t)unit & 0xffff), elem, st == noErr,
                                 c->fmt.rate, c->fmt.ch, c->fmt.bits, c->fmt.flags,
                                 c->fp ? "ok" : "none");
                        return st;
                    }
                    if (c->fp) fclose(c->fp);
                    free(c->ring);
                    free(c);
                }
            }
        }
        return g_origSetProp(unit, prop, scope, elem, inData, inDataSize);
    }
}

// ---------- AudioUnitRender 直钩 + 上行 TTS 混音 ----------
static _Atomic(uint64_t) g_renderCalls;
static _Atomic(uint32_t) g_renderRmsBits;
static _Atomic(uint64_t) g_mixCalls;

// LCT 的上行注入：把英文 TTS 的 PCM 混进麦克风上行 buffer。
// 守护进程把 TTS 写成 48k mono s16 的 Documents/cc_tts.wav，这里读到环形缓冲，
// 在 AudioUnitRender 返回后混进 ioData（仅当 buffer 是 float32 单声道时，避免弄坏通话）。
static float *g_ttsRing;
static uint32_t g_ttsCap;
static _Atomic(uint32_t) g_ttsHead, g_ttsTail;
static NSTimeInterval g_ttsMtime;

// 中文 TTS：混进“对方声音”的下行（用户听到中文，原音按设置压低）
static float *g_ttsZhRing;
static uint32_t g_ttsZhCap;
static _Atomic(uint32_t) g_ttsZhHead, g_ttsZhTail;
static NSTimeInterval g_ttsZhMtime;
static NSString *g_ttsZhLastFile;   // 0.19.0：zh 序列文件按名字递增装载

// 原音音量：0.0~1.0（0 = TTS 播放时原音静音）
static double g_duckRemote = 0.30;
static double g_duckLocal = 0.30;
static NSTimeInterval g_cfgMtime;

static void CCLoadTTSIfNeeded(void) {
    @try {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) firstObject];
        if (!docs.length) return;
        NSString *p = [docs stringByAppendingPathComponent:@"cc_tts.wav"];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!at) return;
        NSTimeInterval mt = [at[NSFileModificationDate] timeIntervalSince1970];
        if (mt <= g_ttsMtime) return;
        g_ttsMtime = mt;
        // 上一通电话遗留的旧 TTS 不播（避免新通话一接通就冒出昨天的话）
        if ([[NSDate date] timeIntervalSince1970] - mt > 120.0) return;
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d.length <= 44) return;
        if (!g_ttsRing) {
            g_ttsCap = 48000 * 30;
            g_ttsRing = calloc(g_ttsCap, sizeof(float));
        }
        if (!g_ttsRing) return;
        const int16_t *s = (const int16_t *)((const uint8_t *)d.bytes + 44);
        NSUInteger n = (d.length - 44) / 2;
        uint32_t head = atomic_load(&g_ttsHead);
        uint32_t tail = atomic_load(&g_ttsTail);
        uint32_t space = g_ttsCap - (head - tail);
        if (n > space) n = space;
        for (NSUInteger i = 0; i < n; i++) {
            g_ttsRing[head % g_ttsCap] = (float)s[i] / 32768.0f;
            head++;
        }
        atomic_store(&g_ttsHead, head);
        CCAppLog(@"tts loaded %lu samples", (unsigned long)n);
    } @catch (NSException *e) { }
}

// v0.19.0：下行中文 TTS 按 cc_tts_zh_0001.wav 序号装载，一个文件装完再装下一个。
// cc_tts_reset 由守护进程在 arm/挂断时写入，用来清空上一通残留的 zh ring。
static void CCLoadZhTTSIfNeeded(void) {
    @try {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) firstObject];
        if (!docs.length) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *marker = [docs stringByAppendingPathComponent:@"cc_tts_reset"];
        if ([fm fileExistsAtPath:marker]) {
            if (!g_ttsZhRing) {
                g_ttsZhCap = 48000 * 30;
                g_ttsZhRing = calloc(g_ttsZhCap, sizeof(float));
            }
            atomic_store(&g_ttsZhHead, 0);
            atomic_store(&g_ttsZhTail, 0);
            g_ttsZhMtime = 0;
            g_ttsZhLastFile = nil;
            [fm removeItemAtPath:marker error:nil];
            CCAppLog(@"tts zh reset");
        }

        NSArray *names = [fm contentsOfDirectoryAtPath:docs error:nil];
        NSMutableArray *zh = [NSMutableArray array];
        for (NSString *f in names) {
            if ([f hasPrefix:@"cc_tts_zh_"] && [f hasSuffix:@".wav"])
                [zh addObject:f];
        }
        if (!zh.count) return;
        [zh sortUsingSelector:@selector(compare:)];
        NSString *pick = nil;
        for (NSString *f in zh) {
            if (!g_ttsZhLastFile ||
                [f compare:g_ttsZhLastFile] == NSOrderedDescending) {
                pick = f;
                break;
            }
        }
        if (!pick) return;
        NSString *p = [docs stringByAppendingPathComponent:pick];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (d.length <= 44) {
            g_ttsZhLastFile = pick;
            [fm removeItemAtPath:p error:nil];
            return;
        }
        if (!g_ttsZhRing) {
            g_ttsZhCap = 48000 * 30;
            g_ttsZhRing = calloc(g_ttsZhCap, sizeof(float));
        }
        if (!g_ttsZhRing) return;
        const int16_t *src = (const int16_t *)((const uint8_t *)d.bytes + 44);
        NSUInteger n = (d.length - 44) / 2;
        uint32_t head = atomic_load(&g_ttsZhHead);
        uint32_t tail = atomic_load(&g_ttsZhTail);
        uint32_t space = g_ttsZhCap - (head - tail);
        // 环形缓冲不够就等下一拍，绝不截断一句 TTS；保持顺序完整。
        if (n + 4800 > space) return;
        for (NSUInteger i = 0; i < n; i++) {
            g_ttsZhRing[head % g_ttsZhCap] = (float)src[i] / 32768.0f;
            head++;
        }
        atomic_store(&g_ttsZhHead, head);
        g_ttsZhLastFile = pick;
        g_ttsZhMtime = [[NSDate date] timeIntervalSince1970];
        [fm removeItemAtPath:p error:nil];
        CCAppLog(@"tts zh loaded %@ %lu samples", pick, (unsigned long)n);
    } @catch (NSException *e) { }
}

static void CCLoadConfigIfNeeded(void) {
    @try {
        NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                              NSUserDomainMask, YES) firstObject];
        if (!docs.length) return;
        NSString *p = [docs stringByAppendingPathComponent:@"cc_cfg.txt"];
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!at) return;
        NSTimeInterval mt = [at[NSFileModificationDate] timeIntervalSince1970];
        if (mt <= g_cfgMtime) return;
        g_cfgMtime = mt;
        NSString *txt = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        for (NSString *line in [txt componentsSeparatedByString:@"\n"]) {
            NSArray *kv = [line componentsSeparatedByString:@"="];
            if (kv.count != 2) continue;
            double v = [kv[1] doubleValue];
            if (v < 0) v = 0;
            if (v > 1) v = 1;
            if ([kv[0] isEqualToString:@"remote"]) g_duckRemote = v;
            if ([kv[0] isEqualToString:@"local"]) g_duckLocal = v;
        }
        CCAppLog(@"cfg remote=%.2f local=%.2f", g_duckRemote, g_duckLocal);
    } @catch (NSException *e) { }
}

// ---------- 格式无关的 TTS 混音 ----------
// 关键：通话 buffer 不一定是 float32 单声道（可能是 int16 / 双声道 / 24k），
// 以前 bpf==4 才混音，格式一不符就完全听不到 TTS。下面按真实格式读改写，
// 目标采样率与 48k 不一致时做零阶保持重采样。
static _Atomic(uint64_t) g_zhMixCalls;

static float CCReadAt(const void *data, UInt32 idx, UInt32 bits, UInt32 flags) {
    if (flags & kAudioFormatFlagIsFloat) {
        if (bits == 32) return ((const float *)data)[idx];
        if (bits == 64) return (float)((const double *)data)[idx];
        return 0;
    }
    if (bits == 16) return (float)(((const int16_t *)data)[idx]) / 32768.0f;
    if (bits == 32) return (float)((double)((const int32_t *)data)[idx] / 2147483648.0);
    return 0;
}

static void CCWriteAt(void *data, UInt32 idx, UInt32 bits, UInt32 flags, float val) {
    if (flags & kAudioFormatFlagIsFloat) {
        if (bits == 32) { ((float *)data)[idx] = val; return; }
        if (bits == 64) { ((double *)data)[idx] = (double)val; return; }
        return;
    }
    if (bits == 16) {
        int v = (int)lrintf(val * 32767.0f);
        if (v > 32767) v = 32767;
        if (v < -32768) v = -32768;
        ((int16_t *)data)[idx] = (int16_t)v;
    } else if (bits == 32) {
        double d = (double)val * 2147483647.0;
        if (d > 2147483647.0) d = 2147483647.0;
        if (d < -2147483648.0) d = -2147483648.0;
        ((int32_t *)data)[idx] = (int32_t)llrint(d);
    }
}

// 每帧字节数 + 记录到的 ASBD 对齐，推断实际格式
static BOOL CCResolveFmt(UInt32 bpf, UInt32 fmtCh, UInt32 fmtBits, UInt32 fmtFlags,
                         UInt32 *outCh, UInt32 *outBits, UInt32 *outFlags) {
    if (bpf == 0) return NO;
    UInt32 ch = fmtCh ? fmtCh : 1;
    UInt32 bits = fmtBits ? fmtBits : 32;
    UInt32 flags = fmtBits ? fmtFlags : kAudioFormatFlagIsFloat;
    if ((bits / 8) * ch != bpf) {
        if (bpf == 2) { ch = 1; bits = 16; flags = 0; }
        else if (bpf == 4) { ch = 1; bits = 32; flags = kAudioFormatFlagIsFloat; }
        else if (bpf == 8) { ch = 2; bits = 32; flags = kAudioFormatFlagIsFloat; }
        else if (bpf == 12) { ch = 3; bits = 32; flags = kAudioFormatFlagIsFloat; }
        else return NO;
    }
    *outCh = ch; *outBits = bits; *outFlags = flags;
    return YES;
}

static void CCMixRingInto(float *ring, uint32_t cap,
                          _Atomic(uint32_t) *headp, _Atomic(uint32_t) *tailp,
                          void *data, UInt32 frames, UInt32 ch,
                          UInt32 bits, UInt32 flags, UInt32 rate,
                          double duck, double *phase,
                          _Atomic(uint64_t) *counter) {
    if (!ring || !data || frames == 0 || ch == 0) return;
    uint32_t head = atomic_load(headp);
    uint32_t tail = atomic_load(tailp);
    if (head == tail) return;
    double step = 48000.0 / (double)(rate ? rate : 48000);
    double pos = *phase;
    BOOL mixed = NO;
    for (UInt32 i = 0; i < frames && tail != head; i++) {
        while (pos >= 1.0 && tail != head) {
            tail++;
            pos -= 1.0;
        }
        if (tail == head) break;
        float t = ring[tail % cap];
        for (UInt32 c = 0; c < ch; c++) {
            UInt32 idx = i * ch + c;
            float v = CCReadAt(data, idx, bits, flags);
            CCWriteAt(data, idx, bits, flags, v * (float)duck + t);
        }
        mixed = YES;
        pos += step;
    }
    *phase = (pos >= 0 && pos < 64.0) ? pos : 0;
    atomic_store(tailp, tail);
    if (mixed && counter) atomic_fetch_add(counter, 1);
}

static void CCMixZhDownlink(CCCB *c, AudioBufferList *ioData, UInt32 frames) {
    if (!g_ttsZhRing || !c || !ioData || frames == 0 || ioData->mNumberBuffers == 0) return;
    AudioBuffer *b = &ioData->mBuffers[0];
    if (!b->mData || b->mDataByteSize < 2) return;
    UInt32 ch, bits, flags;
    if (!CCResolveFmt(b->mDataByteSize / frames, c->fmt.ch, c->fmt.bits, c->fmt.flags,
                      &ch, &bits, &flags)) return;
    UInt32 rate = c->fmt.rate > 0 ? (UInt32)c->fmt.rate : 48000;
    static double phase;
    CCMixRingInto(g_ttsZhRing, g_ttsZhCap, &g_ttsZhHead, &g_ttsZhTail,
                  b->mData, frames, ch, bits, flags, rate,
                  g_duckRemote, &phase, &g_zhMixCalls);
}

static void CCMixEnUplink(AudioUnit unit, AudioBufferList *ioData, UInt32 frames) {
    if (!g_ttsRing || !ioData || frames == 0 || ioData->mNumberBuffers == 0) return;
    AudioBuffer *b = &ioData->mBuffers[0];
    if (!b->mData || b->mDataByteSize < 2) return;
    CCFmt *f = CCFindFmt(unit);
    UInt32 ch, bits, flags;
    if (!CCResolveFmt(b->mDataByteSize / frames, f ? f->ch : 0, f ? f->bits : 0,
                      f ? f->flags : 0, &ch, &bits, &flags)) return;
    UInt32 rate = (f && f->rate > 0) ? (UInt32)f->rate : 48000;
    static double phase;
    CCMixRingInto(g_ttsRing, g_ttsCap, &g_ttsHead, &g_ttsTail,
                  b->mData, frames, ch, bits, flags, rate,
                  g_duckLocal, &phase, &g_mixCalls);
}

static OSStatus CCHookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *ioData) {
    OSStatus st = g_origRender ? g_origRender(unit, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr && ioData && frames) {
        AudioBuffer *b = &ioData->mBuffers[0];
        if (b->mData && b->mDataByteSize >= 4) {
            const float *f = (const float *)b->mData;
            UInt32 n = b->mDataByteSize / 4;
            if (n > 2048) n = 2048;
            double sum = 0;
            for (UInt32 i = 0; i < n; i++) sum += fabsf(f[i]);
            float rms = n ? (float)(sum / n) : 0;
            if (!isfinite(rms)) rms = 0;
            atomic_store(&g_renderRmsBits, CCFloatBits(rms));
        }
        CCMixEnUplink(unit, ioData, frames);
        atomic_fetch_add(&g_renderCalls, 1);
    }
    return st;
}

// ---------- 后台汇报 ----------
static void CCReport(void) {
    CCLoadTTSIfNeeded();
    CCLoadZhTTSIfNeeded();
    CCLoadConfigIfNeeded();
    int cbCount = atomic_load(&g_cbCount);
    for (int i = 0; i < cbCount; i++) {
        CCCB *c = g_cbs[i];
        if (!c) continue;
        CCFlushWav(c);
        uint64_t calls = atomic_load(&c->calls);
        static uint64_t last[16];
        static CFAbsoluteTime lastLog[16];
        CFAbsoluteTime nowCb = CFAbsoluteTimeGetCurrent();
        if (calls == 0 || calls == last[i]) continue;
        if (nowCb - lastLog[i] < 5.0) continue;
        lastLog[i] = nowCb;
        last[i] = calls;
        CCAppLog(@"cb u%x b%u f%u rms%.5f n%llu",
                 (unsigned)((uintptr_t)c->unit & 0xffff), c->bus,
                 atomic_load(&c->frames), CCBitsFloat(atomic_load(&c->rmsBits)),
                 (unsigned long long)calls);
    }

    static CFAbsoluteTime lastTtsLog;
    static CFAbsoluteTime lastBeat;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastTtsLog >= 5.0) {
        lastTtsLog = now;
        uint32_t eh = atomic_load(&g_ttsHead), et = atomic_load(&g_ttsTail);
        uint32_t zh = atomic_load(&g_ttsZhHead), zt = atomic_load(&g_ttsZhTail);
        uint64_t mc = atomic_load(&g_mixCalls), zc = atomic_load(&g_zhMixCalls);
        if (eh != et || zh != zt || mc || zc)
            CCAppLog(@"tts en(%u) zh(%u) mix up%llu down%llu duck %.2f/%.2f",
                     (unsigned)(eh - et), (unsigned)(zh - zt),
                     (unsigned long long)mc, (unsigned long long)zc,
                     g_duckLocal, g_duckRemote);
    }
    if (now - lastBeat >= 30.0) {
        lastBeat = now;
        CCAppLog(@"alive %@ ctx%d rt%llu rtrms%.4f mix%llu setprop%p msh%p",
                 CCProcName(), cbCount,
                 (unsigned long long)atomic_load(&g_renderCalls),
                 CCBitsFloat(atomic_load(&g_renderRmsBits)),
                 (unsigned long long)atomic_load(&g_mixCalls),
                 (void *)g_origSetProp, (void *)g_MSHook);
    }
}

// ---------- MSHookFunction 解析（必须避开 App 包里的假 libsubstrate） ----------
static BOOL CCHookSymOK(void *sym, NSString **implPath) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (!sym || !dladdr(sym, &info) || !info.dli_fname) return NO;
    NSString *p = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    if (implPath) *implPath = p;
    if ([p containsString:@".app/"]) return NO;
    if ([p containsString:@"/var/containers/"]) return NO;
    return YES;
}

static void *CCFindMSHook(NSString **src, NSString **impl) {
    void *sym = dlsym(RTLD_DEFAULT, "MSHookFunction");
    NSString *p = nil;
    if (sym && CCHookSymOK(sym, &p)) {
        if (src) *src = @"RTLD_DEFAULT";
        if (impl) *impl = p;
        return sym;
    }
    if (sym) CCAppLog(@"RTLD_DEFAULT MSHookFunction rejected (%@)", p ?: @"?");

    const char *paths[] = {
        "/var/jb/usr/lib/libellekit.dylib",
        "/var/jb/usr/lib/libsubstrate.dylib",
        "/var/jb/usr/lib/libhooker.dylib",
        "libellekit.dylib",
        "libsubstrate.dylib",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_NOW | RTLD_NOLOAD);
        if (!h) h = dlopen(paths[i], RTLD_NOW);
        if (!h) continue;
        sym = dlsym(h, "MSHookFunction");
        if (sym && CCHookSymOK(sym, &p)) {
            if (src) *src = [NSString stringWithUTF8String:paths[i]];
            if (impl) *impl = p;
            return sym;
        }
    }
    return NULL;
}

static dispatch_queue_t g_reportQ;
static dispatch_source_t g_reportTimer;

__attribute__((constructor))
static void CCAppProbeBoot(void) {
    @autoreleasepool {
        NSString *proc = CCProcName();
        CCAppLog(@"dylib loaded proc=%@ bundle=%@ pid=%d",
                 proc, [[NSBundle mainBundle] bundleIdentifier] ?: @"?", getpid());
        if (![proc isEqualToString:@"WhatsApp"]) return;

        g_reportQ = dispatch_queue_create("cc.appprobe.report", DISPATCH_QUEUE_SERIAL);
        g_reportTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_reportQ);
        dispatch_source_set_timer(g_reportTimer, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                                  500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(g_reportTimer, ^{ @autoreleasepool { CCReport(); } });
        dispatch_resume(g_reportTimer);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                if ([[NSFileManager defaultManager] fileExistsAtPath:
                     @"/var/mobile/Library/CallCaption/appprobe.off"]) {
                    CCAppLog(@"appprobe disabled by appprobe.off");
                    return;
                }
                NSString *src = nil, *impl = nil;
                g_MSHook = (CCMSHookFunction)CCFindMSHook(&src, &impl);
                if (!g_MSHook) {
                    CCAppLog(@"MSHookFunction not found (all rejected)");
                    return;
                }
                CCAppLog(@"mshook src=%@ impl=%@", src ?: @"?", impl ?: @"?");

                void *setProp = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
                if (setProp) {
                    g_MSHook(setProp, (void *)CCHookedSetProp, (void **)&g_origSetProp);
                    CCAppLog(@"setprop hook sym=%p old=%p %@",
                             setProp, g_origSetProp,
                             g_origSetProp ? @"OK" : @"FAILED(old=0)");
                }

                void *render = dlsym(RTLD_DEFAULT, "AudioUnitRender");
                if (render) {
                    g_MSHook(render, (void *)CCHookedRender, (void **)&g_origRender);
                    CCAppLog(@"render hook sym=%p old=%p %@",
                             render, g_origRender,
                             g_origRender ? @"OK" : @"FAILED(old=0)");
                }
            }
        });
    }
}
