// CCAudioHook.m — LCT 同款音频验证（阶段 1）
// 注入 mediaserverd / audiomxd，只观察 AudioUnitRender / AudioUnitProcess 的音频，
// 打印格式与 RMS，不修改音频、不接 UI。用于验证“远端/本地声音到底有没有经过系统音频单元”。
//
// 日志通道：mediaserverd 是沙盒进程，不能直接写 /var/mobile/...，
// 所以主通道是 Darwin 通知 "net.user.callcaption.log hook: ..."，
// 由 SpringBoard 侧的 Tweak.x 收到后写进 probe.log；os_log/文件只是兜底。
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

typedef void (*CCMSHookFunction)(void *symbol, void *hook, void **old);
static CCMSHookFunction g_MSHook = NULL;
static os_log_t g_oslog = NULL;

#define CC_HOOK_LOG @"/var/mobile/Library/CallCaption/probe.log"

typedef OSStatus (*AURenderFn)(AudioUnit, AudioUnitRenderActionFlags *,
                               const AudioTimeStamp *, UInt32, UInt32,
                               AudioBufferList *);
typedef OSStatus (*AUProcessFn)(AudioUnit, AudioUnitRenderActionFlags *,
                                const AudioTimeStamp *, UInt32,
                                AudioBufferList *);

static AURenderFn g_origRender = NULL;
static AUProcessFn g_origProcess = NULL;

static void CCHookLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        // 统一日志（Console/log show 可见）
        if (!g_oslog) g_oslog = os_log_create("net.user.callcaption", "audiohook");
        os_log_with_type(g_oslog, OS_LOG_TYPE_DEFAULT, "%{public}s", msg.UTF8String);

        // 主通道：Darwin 通知 → SpringBoard 落盘（沙盒进程无文件权限）
        NSString *name = [NSString stringWithFormat:@"net.user.callcaption.log hook: %@", msg];
        if (name.length > 400) name = [name substringToIndex:400];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)name,
                                             NULL, NULL, true);

        // 兜底：万一进程有权限就直接写文件
        NSString *line = [NSString stringWithFormat:@"[%@] hook: %@\n",
                          [NSDate date], msg];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:@"/var/mobile/Library/CallCaption"
      withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil];
        const char *paths[] = {
            CC_HOOK_LOG.UTF8String,
            "/tmp/ccaudiohook.log",
            NULL
        };
        for (int i = 0; paths[i]; i++) {
            FILE *fp = fopen(paths[i], "a");
            if (!fp) continue;
            fputs(line.UTF8String, fp);
            fclose(fp);
            chmod(paths[i], 0666);
        }
    }
}

static NSString *CCProcName(void) {
    return [[NSProcessInfo processInfo] processName] ?: @"?";
}

static NSString *CCFourCC(UInt32 v) {
    char c[5] = { (char)((v >> 24) & 0xff), (char)((v >> 16) & 0xff),
                  (char)((v >> 8) & 0xff), (char)(v & 0xff), 0 };
    for (int i = 0; i < 4; i++) if (c[i] < 32 || c[i] > 126) c[i] = '?';
    return [NSString stringWithUTF8String:c];
}

// 每个 unit/bus 每秒最多一条，避免刷屏
typedef struct {
    AudioUnit unit;
    UInt32 bus;
    CFAbsoluteTime last;
} CCSlot;
static CCSlot g_slots[32];

static BOOL CCShouldLog(AudioUnit unit, UInt32 bus) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    for (int i = 0; i < 32; i++) {
        if (g_slots[i].unit == unit && g_slots[i].bus == bus) {
            if (now - g_slots[i].last < 1.0) return NO;
            g_slots[i].last = now;
            return YES;
        }
    }
    for (int i = 0; i < 32; i++) {
        if (g_slots[i].unit == NULL) {
            g_slots[i].unit = unit;
            g_slots[i].bus = bus;
            g_slots[i].last = now;
            return YES;
        }
    }
    return NO;
}

static void CCInspect(AudioUnit unit, UInt32 bus, UInt32 frames,
                      AudioBufferList *ioData, const char *source) {
    if (!unit || !ioData || frames == 0) return;
    if (!CCShouldLog(unit, bus)) return;

    AudioStreamBasicDescription asbd;
    memset(&asbd, 0, sizeof(asbd));
    UInt32 size = sizeof(asbd);
    OSStatus st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Output, bus, &asbd, &size);
    if (st != noErr || asbd.mSampleRate <= 0) {
        size = sizeof(asbd);
        st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input, bus, &asbd, &size);
    }

    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    AudioComponent comp = AudioComponentInstanceGetComponent(unit);
    if (comp) AudioComponentGetDescription(comp, &desc);

    BOOL isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) &&
                   asbd.mBitsPerChannel == 32;
    double sum = 0;
    UInt64 count = 0;
    if (isFloat) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
            AudioBuffer *b = &ioData->mBuffers[i];
            if (!b->mData || b->mDataByteSize == 0) continue;
            float *f = (float *)b->mData;
            UInt32 n = b->mDataByteSize / sizeof(float);
            for (UInt32 j = 0; j < n; j++) sum += fabsf(f[j]);
            count += n;
        }
    }
    double rms = count ? (sum / (double)count) : 0;

    CCHookLog(@"proc=%@ src=%s unit=%p bus=%u frames=%u rate=%.0f ch=%u float=%d rms=%.5f sub=%@ man=%@",
              CCProcName(), source, unit, bus, frames,
              asbd.mSampleRate, asbd.mChannelsPerFrame, isFloat, rms,
              CCFourCC(desc.componentSubType), CCFourCC(desc.componentManufacturer));
}

static OSStatus CCHookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *ioData) {
    OSStatus st = g_origRender ? g_origRender(unit, flags, ts, bus, frames, ioData) : -1;
    @try {
        if (st == noErr && ioData && frames)
            CCInspect(unit, bus, frames, ioData, "render");
    } @catch (NSException *e) { }
    return st;
}

static OSStatus CCHookedProcess(AudioUnit unit, AudioUnitRenderActionFlags *flags,
                                const AudioTimeStamp *ts, UInt32 frames,
                                AudioBufferList *ioData) {
    OSStatus st = g_origProcess ? g_origProcess(unit, flags, ts, frames, ioData) : -1;
    @try {
        if (st == noErr && ioData && frames)
            CCInspect(unit, 0, frames, ioData, "process");
    } @catch (NSException *e) { }
    return st;
}

__attribute__((constructor))
static void CCAudioHookBoot(void) {
    @autoreleasepool {
        NSString *proc = CCProcName();
        // 先报一声，确认 dylib 到底有没有被注入
        CCHookLog(@"dylib loaded proc=%@ pid=%d", proc, getpid());

        if (!([proc isEqualToString:@"mediaserverd"] ||
              [proc isEqualToString:@"audiomxd"])) {
            return;
        }

        g_MSHook = (CCMSHookFunction)dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!g_MSHook) {
            void *h = dlopen("/var/jb/usr/lib/libsubstrate.dylib", RTLD_NOW);
            if (!h) h = dlopen("/var/jb/usr/lib/libellekit.dylib", RTLD_NOW);
            if (!h) h = dlopen("libsubstrate.dylib", RTLD_NOW);
            if (h) g_MSHook = (CCMSHookFunction)dlsym(h, "MSHookFunction");
            CCHookLog(@"MSHookFunction dlsym=%p from dlopen=%p", g_MSHook, h);
        } else {
            CCHookLog(@"MSHookFunction dlsym=%p", g_MSHook);
        }
        if (!g_MSHook) {
            CCHookLog(@"MSHookFunction not found, hook aborted");
            return;
        }

        void *renderSym = dlsym(RTLD_DEFAULT, "AudioUnitRender");
        if (renderSym) {
            g_MSHook(renderSym, (void *)CCHookedRender, (void **)&g_origRender);
            CCHookLog(@"installed AudioUnitRender sym=%p old=%p", renderSym, g_origRender);
        } else {
            CCHookLog(@"AudioUnitRender symbol not found");
        }

        void *processSym = dlsym(RTLD_DEFAULT, "AudioUnitProcess");
        if (processSym) {
            g_MSHook(processSym, (void *)CCHookedProcess, (void **)&g_origProcess);
            CCHookLog(@"installed AudioUnitProcess sym=%p old=%p", processSym, g_origProcess);
        } else {
            CCHookLog(@"AudioUnitProcess symbol not found");
        }
    }
}
