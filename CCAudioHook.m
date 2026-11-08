// CCAudioHook.m — LCT 同款音频验证（阶段 1，alpha3 安全版）
// 注入 mediaserverd / audiomxd，观察 AudioUnitRender / AudioUnitProcess。
//
// alpha2 教训：渲染线程里绝不能调 AudioUnitGetProperty / ObjC / 文件 / 通知，
// 会和音频单元锁自死锁，把 mediaserverd 卡死（通话拨不出去、看门狗 0x8BADF00D）。
// 现在渲染线程只做纯 C 的 RMS 统计 + 原子写；格式查询、字符串、日志全部挪到
// 后台 1 秒定时器里做。
//
// 日志通道：mediaserverd 是沙盒进程，写不了 /var/mobile/...，
// 主通道是 Darwin 通知 "net.user.callcaption.log hook: ..."，
// 由 SpringBoard 侧 Tweak.x 收到后写进 probe.log；os_log/文件只是兜底。
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
#define CC_HOOK_OFF @"/var/mobile/Library/CallCaption/audiohook.off"

typedef OSStatus (*AURenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                               const AudioTimeStamp *, UInt32, UInt32,
                               AudioBufferList *);
typedef OSStatus (*AUProcessFn)(AudioUnit, AudioUnitRenderActionFlags *,
                                const AudioTimeStamp *, UInt32,
                                AudioBufferList *);

static AURenderFn g_origRender = NULL;
static AUProcessFn g_origProcess = NULL;

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
        NSString *name = [NSString stringWithFormat:@"net.user.callcaption.log hook: %@", shortMsg];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name,
                                             NULL, NULL, true);

        NSString *line = [NSString stringWithFormat:@"[%@] hook: %@\n", [NSDate date], msg];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        [paths addObject:CC_HOOK_LOG];
        [paths addObject:@"/tmp/ccaudiohook.log"];
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length) [paths addObject:[tmp stringByAppendingPathComponent:@"ccaudiohook.log"]];
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

#pragma mark - 后台线程：每秒汇报一次

static void CCReport(void) {
    for (int i = 0; i < CC_MAX_SLOTS; i++) {
        CCSlot *s = &g_slots[i];
        uintptr_t unit = atomic_load(&s->unit);
        if (!unit) continue;
        uint64_t calls = atomic_load(&s->calls);
        if (calls == 0 || calls == g_lastCalls[i]) continue;
        g_lastCalls[i] = calls;

        // 不在这里碰 AudioComponent/unit 指针：音频单元可能已被销毁，
        // 后台线程解引用会崩 mediaserverd。只读我们自己的原子字段。
        float rms = CCBitsFloat(atomic_load(&s->rmsBits));
        CCHookLog(@"%@ u%lx b%u f%u rms%.5f n%llu",
                  atomic_load(&s->isProcess) ? @"process" : @"render",
                  (unsigned long)unit, atomic_load(&s->bus), atomic_load(&s->frames),
                  rms, (unsigned long long)calls);
    }
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

        void *renderSym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (renderSym && CCSymbolInAudioToolbox(renderSym)) {
            g_MSHook(renderSym, (void *)CCHookedRender, (void **)&g_origRender);
            CCHookLog(@"installed AudioUnitRender sym=%p old=%p", renderSym, g_origRender);
        } else {
            CCHookLog(@"AudioUnitRender skipped sym=%p (not AudioToolbox)", renderSym);
        }

        void *processSym = dlsym(RTLD_DEFAULT, "AudioUnitProcess");
        if (processSym && CCSymbolInAudioToolbox(processSym)) {
            g_MSHook(processSym, (void *)CCHookedProcess, (void **)&g_origProcess);
            CCHookLog(@"installed AudioUnitProcess sym=%p old=%p", processSym, g_origProcess);
        } else {
            CCHookLog(@"AudioUnitProcess skipped sym=%p (not AudioToolbox)", processSym);
        }
    }
}

__attribute__((constructor))
static void CCAudioHookBoot(void) {
    @autoreleasepool {
        NSString *proc = CCProcName();
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
