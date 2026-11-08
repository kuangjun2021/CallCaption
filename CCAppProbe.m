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

#define CC_CAP_SECONDS 120

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
    if (st == noErr) CCRecordCB(c, ioData, frames);
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
    c->cap = (UInt32)(c->fmt.rate * 2);
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

// ---------- AudioUnitRender 直钩（只计数，兜底） ----------
static _Atomic(uint64_t) g_renderCalls;
static _Atomic(uint32_t) g_renderRmsBits;

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
        atomic_fetch_add(&g_renderCalls, 1);
    }
    return st;
}

// ---------- 后台汇报 ----------
static void CCReport(void) {
    int cbCount = atomic_load(&g_cbCount);
    for (int i = 0; i < cbCount; i++) {
        CCCB *c = g_cbs[i];
        if (!c) continue;
        CCFlushWav(c);
        uint64_t calls = atomic_load(&c->calls);
        static uint64_t last[16];
        if (calls == 0 || calls == last[i]) continue;
        last[i] = calls;
        CCAppLog(@"cb u%x b%u f%u rms%.5f n%llu",
                 (unsigned)((uintptr_t)c->unit & 0xffff), c->bus,
                 atomic_load(&c->frames), CCBitsFloat(atomic_load(&c->rmsBits)),
                 (unsigned long long)calls);
    }

    static CFAbsoluteTime lastBeat;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastBeat >= 5.0) {
        lastBeat = now;
        CCAppLog(@"alive %@ ctx%d rt%llu rtrms%.4f setprop%p msh%p",
                 CCProcName(), cbCount,
                 (unsigned long long)atomic_load(&g_renderCalls),
                 CCBitsFloat(atomic_load(&g_renderRmsBits)),
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
        dispatch_source_set_timer(g_reportTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
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
