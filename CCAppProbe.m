// CCAppProbe.m — 注入通话 App（WhatsApp），探测它的音频链路
// 目的：mediaserverd 注入在这台 14PM 上不生效（alpha4 已证明：
//       SpringBoard 有注入日志，mediaserverd 连心跳都没有），
//       所以换到 App 进程内抓：WebRTC/语音通话最终都要走 AudioUnit，
//       我们包住它设置给 AudioUnit 的 render callback，就能拿到对方语音的 PCM。
//
// 渲染回调里只做纯 C 的 RMS 统计；字符串/日志全部在后台定时器里做。
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

// ---------- 日志（后台线程调用） ----------
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

// ---------- 包装 render callback ----------

typedef struct {
    AURenderCallback proc;
    void *refcon;
    AudioUnit unit;
    UInt32 bus;
    _Atomic(uint64_t) calls;
    _Atomic(uint32_t) frames;
    _Atomic(uint32_t) rmsBits;
} CCWrapCtx;

static CCWrapCtx *g_ctx[16];
static _Atomic(int) g_ctxCount;

static void CCRecordRender(CCWrapCtx *ctx, AudioBufferList *ioData, UInt32 frames) {
    if (!ctx || !ioData || frames == 0) return;
    double sum = 0;
    UInt64 count = 0;
    UInt32 nb = ioData->mNumberBuffers;
    if (nb > 8) nb = 8;
    for (UInt32 i = 0; i < nb; i++) {
        AudioBuffer *b = &ioData->mBuffers[i];
        if (!b->mData || b->mDataByteSize < 4) continue;
        float *f = (float *)b->mData;
        UInt32 n = b->mDataByteSize / 4;
        if (n > 4096) n = 4096;
        for (UInt32 j = 0; j < n; j++) sum += fabsf(f[j]);
        count += n;
    }
    if (count) {
        float rms = (float)(sum / (double)count);
        if (!isfinite(rms)) rms = 0;
        atomic_store(&ctx->rmsBits, CCFloatBits(rms));
    }
    atomic_store(&ctx->frames, frames);
    atomic_fetch_add(&ctx->calls, 1);
}

static OSStatus CCWrappedRender(void *refCon, AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *ts, UInt32 bus,
                                UInt32 frames, AudioBufferList *ioData) {
    CCWrapCtx *ctx = (CCWrapCtx *)refCon;
    OSStatus st = ctx && ctx->proc
        ? ctx->proc(ctx->refcon, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr) CCRecordRender(ctx, ioData, frames);
    return st;
}

// ---------- SetProperty 钩子 ----------

static void CCNoteProperty(AudioUnit unit, AudioUnitPropertyID prop,
                           AudioUnitScope scope, AudioUnitElement elem, UInt32 size) {
    static uint32_t seen[64][4];   // unit低16位, prop, scope, elem
    static int seenCount;
    uint32_t u = (uint32_t)((uintptr_t)unit & 0xffff);
    for (int i = 0; i < seenCount; i++) {
        if (seen[i][0] == u && seen[i][1] == prop &&
            seen[i][2] == scope && seen[i][3] == elem) return;
    }
    if (seenCount < 64) {
        seen[seenCount][0] = u; seen[seenCount][1] = prop;
        seen[seenCount][2] = scope; seen[seenCount][3] = elem;
        seenCount++;
    }
    CCAppLog(@"setprop u%x p%u s%u e%u sz%u", u, prop, scope, elem, size);
}

static OSStatus CCHookedSetProp(AudioUnit unit, AudioUnitPropertyID prop,
                                AudioUnitScope scope, AudioUnitElement elem,
                                const void *inData, UInt32 inDataSize) {
    @autoreleasepool {
        if (prop == kAudioUnitProperty_SetRenderCallback &&
            inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
            const AURenderCallbackStruct *orig = (const AURenderCallbackStruct *)inData;
            int idx = atomic_load(&g_ctxCount);
            if (idx < 16 && orig->inputProc) {
                CCWrapCtx *ctx = calloc(1, sizeof(CCWrapCtx));
                if (ctx) {
                    ctx->proc = orig->inputProc;
                    ctx->refcon = orig->inputProcRefCon;
                    ctx->unit = unit;
                    ctx->bus = elem;
                    g_ctx[idx] = ctx;
                    atomic_store(&g_ctxCount, idx + 1);

                    AURenderCallbackStruct wrap = *orig;
                    wrap.inputProc = CCWrappedRender;
                    wrap.inputProcRefCon = ctx;
                    OSStatus st = g_origSetProp(unit, prop, scope, elem,
                                                &wrap, sizeof(wrap));
                    CCAppLog(@"renderCB unit=%p bus=%u proc=%p ok=%d",
                             unit, elem, orig->inputProc, st == noErr);
                    return st;
                }
            }
        }
        if (prop == kAudioOutputUnitProperty_SetInputCallback) {
            CCAppLog(@"inputCB unit=%p bus=%u sz%u", unit, elem, inDataSize);
        } else if (prop == kAudioUnitProperty_StreamFormat ||
                   prop == kAudioOutputUnitProperty_EnableIO ||
                   prop == kAudioUnitProperty_MaximumFramesPerSlice) {
            CCNoteProperty(unit, prop, scope, elem, inDataSize);
        }
        return g_origSetProp(unit, prop, scope, elem, inData, inDataSize);
    }
}

// ---------- AudioUnitRender 直钩（兜底） ----------
static _Atomic(uint64_t) g_renderCalls;
static _Atomic(uint32_t) g_renderRmsBits;
static _Atomic(uint32_t) g_renderFrames;

static OSStatus CCHookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *ioData) {
    OSStatus st = g_origRender ? g_origRender(unit, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr && ioData && frames) {
        double sum = 0; UInt64 count = 0;
        UInt32 nb = ioData->mNumberBuffers;
        if (nb > 8) nb = 8;
        for (UInt32 i = 0; i < nb; i++) {
            AudioBuffer *b = &ioData->mBuffers[i];
            if (!b->mData || b->mDataByteSize < 4) continue;
            float *f = (float *)b->mData;
            UInt32 n = b->mDataByteSize / 4;
            if (n > 4096) n = 4096;
            for (UInt32 j = 0; j < n; j++) sum += fabsf(f[j]);
            count += n;
        }
        if (count) {
            float rms = (float)(sum / (double)count);
            if (!isfinite(rms)) rms = 0;
            atomic_store(&g_renderRmsBits, CCFloatBits(rms));
        }
        atomic_store(&g_renderFrames, frames);
        atomic_fetch_add(&g_renderCalls, 1);
    }
    return st;
}

// ---------- 后台汇报 ----------
static void CCReport(void) {
    int ctxCount = atomic_load(&g_ctxCount);
    for (int i = 0; i < ctxCount; i++) {
        CCWrapCtx *c = g_ctx[i];
        if (!c) continue;
        uint64_t calls = atomic_load(&c->calls);
        static uint64_t last[16];
        if (calls == 0 || calls == last[i]) continue;
        last[i] = calls;
        CCAppLog(@"renderCB u%lx b%u f%u rms%.5f n%llu",
                 (unsigned long)((uintptr_t)c->unit & 0xffff), c->bus,
                 atomic_load(&c->frames), CCBitsFloat(atomic_load(&c->rmsBits)),
                 (unsigned long long)calls);
    }

    static CFAbsoluteTime lastBeat;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastBeat >= 5.0) {
        lastBeat = now;
        CCAppLog(@"alive %@ ctx%d rt%llu setprop%p msh%p",
                 CCProcName(), ctxCount,
                 (unsigned long long)atomic_load(&g_renderCalls),
                 (void *)g_origSetProp, (void *)g_MSHook);
    }
}

static dispatch_queue_t g_reportQ;
static dispatch_source_t g_reportTimer;

// WhatsApp 的 App 包里自带了一个 libsubstrate.dylib（可能是某个插件塞进去的），
// 它的 MSHookFunction 是个空壳：不报错，但 old 返回 0，钩子根本不生效。
// 所以 RTLD_DEFAULT 找到的符号必须校验来源：只要路径在 .app/ 里就丢弃。
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

    // 顺便把 /var/jb/usr/lib 里相关的库名打出来，方便确认 ElleKit 的真实路径
    NSArray *ls = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/var/jb/usr/lib" error:nil];
    NSMutableArray *cands = [NSMutableArray array];
    for (NSString *n in ls) {
        NSString *l = n.lowercaseString;
        if ([l containsString:@"ellekit"] || [l containsString:@"substrate"] ||
            [l containsString:@"hooker"]) {
            [cands addObject:n];
        }
    }
    if (cands.count) CCAppLog(@"libs: %@", [cands componentsJoinedByString:@","]);

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
                } else {
                    CCAppLog(@"AudioUnitSetProperty not found");
                }

                void *render = dlsym(RTLD_DEFAULT, "AudioUnitRender");
                if (render) {
                    g_MSHook(render, (void *)CCHookedRender, (void **)&g_origRender);
                    CCAppLog(@"render hook sym=%p old=%p %@",
                             render, g_origRender,
                             g_origRender ? @"OK" : @"FAILED(old=0)");
                } else {
                    CCAppLog(@"AudioUnitRender not found");
                }
            }
        });
    }
}
