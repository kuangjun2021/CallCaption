// CCAudioHook.m — LCT 同款音频验证（alpha6）
// 注入 mediaserverd / audiomxd，两条抓音路径：
//   1) AudioUnitRender / AudioUnitProcess 直钩（只覆盖主动调用，实测很稀疏）
//   2) AudioUnitSetProperty 钩子：包住通话引擎设置给 AudioUnit 的 render callback，
//      这是实时通话音频真正流经的地方（alpha4 的 /tmp 日志证明钩子本身能注入成功）。
//
// 渲染线程里只做纯 C 的 RMS 统计；日志走后台 1 秒定时器。
//
// 日志通道：mediaserverd 沙盒写不了 /var/mobile/...，但 /tmp 可以写！
// alpha4 的 /tmp/ccaudiohook.log 证明了注入和文件日志都正常，
// 只有 Darwin 通知会被沙盒挡掉，所以这里以 /tmp 文件为主。
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>
#import <math.h>
#import <stdio.h>
#import <unistd.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach/mach_time.h>

typedef void (*CCMSHookFunction)(void *symbol, void *hook, void **old);
static CCMSHookFunction g_MSHook = NULL;
static os_log_t g_oslog = NULL;

#define CC_HOOK_LOG @"/var/mobile/Library/CallCaption/probe.log"
#define CC_HOOK_TMP @"/tmp/ccaudiohook.log"
#define CC_HOOK_OFF @"/var/mobile/Library/CallCaption/audiohook.off"

typedef OSStatus (*AURenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                               const AudioTimeStamp *, UInt32, UInt32,
                               AudioBufferList *);
typedef OSStatus (*AUProcessFn)(AudioUnit, AudioUnitRenderActionFlags *,
                                const AudioTimeStamp *, UInt32,
                                AudioBufferList *);
typedef OSStatus (*SetPropFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                              AudioUnitElement, const void *, UInt32);

static AURenderFn g_origRender = NULL;
static AUProcessFn g_origProcess = NULL;
static SetPropFn g_origSetProp = NULL;

#pragma mark - 日志（只在后台线程调用）

static void CCHookLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        if (!g_oslog) g_oslog = os_log_create("net.user.callcaption", "audiohook");
        os_log_with_type(g_oslog, OS_LOG_TYPE_DEFAULT, "%{public}s", msg.UTF8String);

        // Darwin 通知 → SpringBoard 落盘。通知名压到 90 字符以内。
        NSString *shortMsg = msg.length > 90 ? [msg substringToIndex:90] : msg;
        NSString *name = [NSString stringWithFormat:@"%@log hook: %@", CC_NOTIF_PREFIX, shortMsg];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name,
                                             NULL, NULL, true);

        NSString *line = [NSString stringWithFormat:@"[%@] hook: %@\n", [NSDate date], msg];
        for (NSString *p in @[CC_HOOK_TMP, CC_HOOK_LOG]) {
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

#pragma mark - 渲染线程：只做纯 C 统计

#define CC_MAX_SLOTS 16

typedef struct {
    _Atomic(uintptr_t) unit;
    _Atomic(uint32_t) bus;
    _Atomic(uint32_t) frames;
    _Atomic(uint64_t) calls;       // 渲染次数
    _Atomic(uint64_t) lastTick;
    _Atomic(uint32_t) rmsBits;     // float 的位模式
    _Atomic(uint32_t) isProcess;
} CCSlot;

static CCSlot g_slots[CC_MAX_SLOTS];
static uint64_t g_lastCalls[CC_MAX_SLOTS];
static _Atomic(int) g_mshookFound;
static _Atomic(int) g_rtInstalled;
static _Atomic(int) g_rpInstalled;
static _Atomic(int) g_hookTried;

static inline uint32_t CCFloatBits(float f) {
    union { float f; uint32_t u; } v;
    v.f = f;
    return v.u;
}
static inline float CCBitsFloat(uint32_t u) {
    union { float f; uint32_t u; } v;
    v.u = u;
    return v.f;
}

// 渲染线程安全：只在空槽上用 CAS 占位，不分配内存、不调用音频单元 API。
static CCSlot *CCSlotFor(uintptr_t unit, uint32_t bus) {
    for (int i = 0; i < CC_MAX_SLOTS; i++) {
        if (atomic_load_explicit(&g_slots[i].unit, memory_order_relaxed) == unit &&
            atomic_load_explicit(&g_slots[i].bus, memory_order_relaxed) == bus) {
            return &g_slots[i];
        }
    }
    for (int i = 0; i < CC_MAX_SLOTS; i++) {
        uintptr_t expected = 0;
        if (atomic_compare_exchange_strong(&g_slots[i].unit, &expected, unit)) {
            atomic_store(&g_slots[i].bus, bus);
            return &g_slots[i];
        }
        if (expected == unit) {
            atomic_store(&g_slots[i].bus, bus);
            return &g_slots[i];
        }
    }
    return NULL;
}

static void CCRecord(AudioUnit unit, UInt32 bus, UInt32 frames,
                     AudioBufferList *abl, BOOL isProcess) {
    if (!unit || !abl || frames == 0) return;
    CCSlot *s = CCSlotFor((uintptr_t)unit, bus);
    if (!s) return;
    atomic_store_explicit(&s->isProcess, isProcess ? 1 : 0, memory_order_relaxed);

    double sum = 0;
    UInt64 count = 0;
    UInt32 nb = abl->mNumberBuffers;
    if (nb > 8) nb = 8;
    for (UInt32 i = 0; i < nb; i++) {
        AudioBuffer *b = &abl->mBuffers[i];
        if (!b->mData || b->mDataByteSize < 4) continue;
        float *f = (float *)b->mData;
        UInt32 n = b->mDataByteSize / 4;
        if (n > 4096) n = 4096;          // 实时线程里限定工作量
        for (UInt32 j = 0; j < n; j++) sum += fabsf(f[j]);
        count += n;
    }
    if (count) {
        float rms = (float)(sum / (double)count);
        if (!isfinite(rms)) rms = 0;
        atomic_store_explicit(&s->rmsBits, CCFloatBits(rms), memory_order_relaxed);
    }
    atomic_store_explicit(&s->frames, frames, memory_order_relaxed);
    atomic_store_explicit(&s->lastTick, mach_absolute_time(), memory_order_relaxed);
    atomic_fetch_add_explicit(&s->calls, 1, memory_order_relaxed);
}

static OSStatus CCHookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *ioData) {
    OSStatus st = g_origRender ? g_origRender(unit, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr && ioData && frames) CCRecord(unit, bus, frames, ioData, NO);
    return st;
}

static OSStatus CCHookedProcess(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *ts, UInt32 frames,
                                AudioBufferList *ioData) {
    OSStatus st = g_origProcess ? g_origProcess(unit, flags, ts, frames, ioData) : -1;
    if (st == noErr && ioData && frames) CCRecord(unit, 0, frames, ioData, YES);
    return st;
}

#pragma mark - 通话引擎的 render callback（对方语音真正流经的地方）

typedef struct {
    AURenderCallback proc;
    void *refcon;
    AudioUnit unit;
    UInt32 bus;
    _Atomic(uint64_t) calls;
    _Atomic(uint32_t) frames;
    _Atomic(uint32_t) rmsBits;
} CCCB;

static CCCB *g_cbs[16];
static _Atomic(int) g_cbCount;
static uint64_t g_lastCbCalls[16];

static void CCRecordCB(CCCB *c, AudioBufferList *ioData, UInt32 frames) {
    if (!c || !ioData || frames == 0) return;
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
        atomic_store_explicit(&c->rmsBits, CCFloatBits(rms), memory_order_relaxed);
    }
    atomic_store_explicit(&c->frames, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->calls, 1, memory_order_relaxed);
}

static OSStatus CCHookedRenderCB(void *refCon, AudioUnitRenderActionFlags *flags,
                                 const AudioTimeStamp *ts, UInt32 bus,
                                 UInt32 frames, AudioBufferList *ioData) {
    CCCB *c = (CCCB *)refCon;
    OSStatus st = (c && c->proc)
        ? c->proc(c->refcon, flags, ts, bus, frames, ioData) : -1;
    if (st == noErr) CCRecordCB(c, ioData, frames);
    return st;
}

// 只记录每个 unit/property 一次，避免刷屏
static void CCNoteProperty(AudioUnit unit, AudioUnitPropertyID prop,
                           AudioUnitScope scope, AudioUnitElement elem, UInt32 size) {
    static uint32_t seen[64][4];
    static int seenCount;
    uint32_t u = (uint32_t)((uintptr_t)unit & 0xffff);
    for (int i = 0; i < seenCount; i++) {
        if (seen[i][0] == u && seen[i][1] == prop &&
            seen[i][2] == scope && seen[i][3] == elem) return;
    }
    // v0.19.2：表满后不再记录、也不再打日志。以前表满后每个新 unit 都会
    // 重新刷一行，挂断时路由切换能刷出上千行，把 1MB 日志顶掉。
    if (seenCount >= 64) return;
    seen[seenCount][0] = u; seen[seenCount][1] = prop;
    seen[seenCount][2] = scope; seen[seenCount][3] = elem;
    seenCount++;
    CCHookLog(@"setprop u%x p%u s%u e%u sz%u", u, prop, scope, elem, size);
}

static NSString *CCFourCC(UInt32 v) {
    char c[5] = { (char)((v >> 24) & 0xff), (char)((v >> 16) & 0xff),
                  (char)((v >> 8) & 0xff), (char)(v & 0xff), 0 };
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) c[i] = '?';
    return [NSString stringWithUTF8String:c];
}

// 记录每个 unit/scope/element 的音频格式 + 组件类型，用来区分对方/我方音频单元
static void CCNoteFormat(AudioUnit unit, AudioUnitScope scope, AudioUnitElement elem,
                         const AudioStreamBasicDescription *a) {
    static uint32_t seen[64][3];
    static int seenCount;
    uint32_t u = (uint32_t)((uintptr_t)unit & 0xffff);
    for (int i = 0; i < seenCount; i++) {
        if (seen[i][0] == u && seen[i][1] == scope && seen[i][2] == elem) return;
    }
    if (seenCount >= 64) return;   // v0.19.2：表满即静默，避免挂断时刷屏
    seen[seenCount][0] = u; seen[seenCount][1] = scope; seen[seenCount][2] = elem;
    seenCount++;

    UInt32 sub = 0, man = 0;
    @try {
        AudioComponent comp = AudioComponentInstanceGetComponent(unit);
        AudioComponentDescription desc;
        memset(&desc, 0, sizeof(desc));
        if (comp) AudioComponentGetDescription(comp, &desc);
        sub = desc.componentSubType;
        man = desc.componentManufacturer;
    } @catch (NSException *e) { }

    CCHookLog(@"fmt u%x s%u e%u rate%.0f ch%u bpf%u bits%u fl0x%x sub%@ man%@",
              u, scope, elem, a->mSampleRate, a->mChannelsPerFrame,
              a->mBytesPerFrame, a->mBitsPerChannel, a->mFormatFlags,
              CCFourCC(sub), CCFourCC(man));
}

static OSStatus CCHookedSetProp(AudioUnit unit, AudioUnitPropertyID prop,
                                AudioUnitScope scope, AudioUnitElement elem,
                                const void *inData, UInt32 inDataSize) {
    if (prop == kAudioUnitProperty_SetRenderCallback &&
        inData && inDataSize >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *orig = (const AURenderCallbackStruct *)inData;
        int idx = atomic_load(&g_cbCount);
        if (orig->inputProc && idx < 16) {
            CCCB *c = calloc(1, sizeof(CCCB));
            if (c) {
                c->proc = orig->inputProc;
                c->refcon = orig->inputProcRefCon;
                c->unit = unit;
                c->bus = elem;
                g_cbs[idx] = c;
                atomic_store(&g_cbCount, idx + 1);

                AURenderCallbackStruct wrap = *orig;
                wrap.inputProc = CCHookedRenderCB;
                wrap.inputProcRefCon = c;
                OSStatus st = g_origSetProp(unit, prop, scope, elem, &wrap, sizeof(wrap));
                CCHookLog(@"setRenderCB u%lx b%u proc%p ok%d",
                          (unsigned long)((uintptr_t)unit & 0xffff), elem,
                          orig->inputProc, st == noErr);
                return st;
            }
        }
    }
    if (prop == kAudioOutputUnitProperty_SetInputCallback) {
        CCNoteProperty(unit, prop, scope, elem, inDataSize);
    } else if (prop == kAudioUnitProperty_StreamFormat) {
        if (inData && inDataSize >= sizeof(AudioStreamBasicDescription))
            CCNoteFormat(unit, scope, elem, (const AudioStreamBasicDescription *)inData);
    } else if (prop == kAudioOutputUnitProperty_EnableIO ||
               prop == kAudioUnitProperty_MaximumFramesPerSlice) {
        CCNoteProperty(unit, prop, scope, elem, inDataSize);
    }
    return g_origSetProp(unit, prop, scope, elem, inData, inDataSize);
}

#pragma mark - 后台线程：每秒汇报一次

static void CCReport(void) {
    static CFAbsoluteTime lastBeat;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastBeat < 30.0) return;
    lastBeat = now;
    int units = 0;
    uint64_t calls = 0;
    for (int i = 0; i < CC_MAX_SLOTS; i++) {
        if (!atomic_load(&g_slots[i].unit)) continue;
        units++;
        calls += atomic_load(&g_slots[i].calls);
    }
    CCHookLog(@"alive %@ tried%d msh%d rt%d rp%d sp%d units%d calls%llu",
              CCProcName(), atomic_load(&g_hookTried), atomic_load(&g_mshookFound),
              atomic_load(&g_rtInstalled), atomic_load(&g_rpInstalled),
              g_origSetProp ? 1 : 0, units, (unsigned long long)calls);
}

static dispatch_queue_t g_reportQ;
static dispatch_source_t g_reportTimer;

static void CCStartReporter(void) {
    g_reportQ = dispatch_queue_create("cc.audiohook.report", DISPATCH_QUEUE_SERIAL);
    g_reportTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_reportQ);
    dispatch_source_set_timer(g_reportTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(g_reportTimer, ^{ @autoreleasepool { CCReport(); } });
    dispatch_resume(g_reportTimer);
}

#pragma mark - 安装

static BOOL CCSymbolInAudioToolbox(void *sym) {
    Dl_info info;
    memset(&info, 0, sizeof(info));
    if (!dladdr(sym, &info) || !info.dli_fname) return NO;
    return strstr(info.dli_fname, "AudioToolbox") != NULL;
}

static void CCInstallHooks(void) {
    @autoreleasepool {
        NSString *proc = CCProcName();
        if (!([proc isEqualToString:@"mediaserverd"] ||
              [proc isEqualToString:@"audiomxd"])) {
            return;
        }
        atomic_store(&g_hookTried, 1);
        if ([[NSFileManager defaultManager] fileExistsAtPath:CC_HOOK_OFF]) {
            CCHookLog(@"hook disabled by audiohook.off");
            return;
        }

        g_MSHook = (CCMSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!g_MSHook) {
            void *h = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (!h) h = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
            if (!h) h = dlopen("libsubstrate.dylib", RTLD_NOW);
            if (h) g_MSHook = (CCMSHookFunction)dlsym(h, "MSHookFunction");
            CCHookLog(@"MSHookFunction dlsym=%p dlopen=%p", g_MSHook, h);
        }
        if (!g_MSHook) {
            CCHookLog(@"MSHookFunction not found, hook aborted");
            return;
        }
        atomic_store(&g_mshookFound, 1);

        void *renderSym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (renderSym && CCSymbolInAudioToolbox(renderSym)) {
            g_MSHook(renderSym, (void *)CCHookedRender, (void **)&g_origRender);
            atomic_store(&g_rtInstalled, g_origRender ? 1 : 0);
            CCHookLog(@"installed AudioUnitRender sym=%p old=%p", renderSym, g_origRender);
        } else {
            CCHookLog(@"AudioUnitRender skipped sym=%p (not AudioToolbox)", renderSym);
        }

        void *processSym = dlsym(RTLD_DEFAULT, "AudioUnitProcess");
        if (processSym && CCSymbolInAudioToolbox(processSym)) {
            g_MSHook(processSym, (void *)CCHookedProcess, (void **)&g_origProcess);
            atomic_store(&g_rpInstalled, g_origProcess ? 1 : 0);
            CCHookLog(@"installed AudioUnitProcess sym=%p old=%p", processSym, g_origProcess);
        } else {
            CCHookLog(@"AudioUnitProcess skipped sym=%p (not AudioToolbox)", processSym);
        }

        void *setPropSym = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
        if (setPropSym && CCSymbolInAudioToolbox(setPropSym)) {
            g_MSHook(setPropSym, (void *)CCHookedSetProp, (void **)&g_origSetProp);
            CCHookLog(@"installed AudioUnitSetProperty sym=%p old=%p", setPropSym, g_origSetProp);
        } else {
            CCHookLog(@"AudioUnitSetProperty skipped sym=%p (not AudioToolbox)", setPropSym);
        }
    }
}

__attribute__((constructor))
static void CCAudioHookBoot(void) {
    @autoreleasepool {
        NSString *proc = CCProcName();
        // SpringBoard 也注入：它只写这一行证明 dylib/日志通道正常，不装任何钩子。
        CCHookLog(@"dylib loaded proc=%@ pid=%d", proc, getpid());
        if (!([proc isEqualToString:@"mediaserverd"] ||
              [proc isEqualToString:@"audiomxd"])) {
            return;
        }
        CCStartReporter();
        // 等进程/音频栈稳定后再装钩子，避免启动阶段碰到半初始化的音频单元
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CCInstallHooks();
        });
    }
}
