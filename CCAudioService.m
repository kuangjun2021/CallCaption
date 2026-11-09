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
#import <sys/stat.h>
#import <stdio.h>
#import <unistd.h>
#import <spawn.h>
#import <signal.h>
#import <sys/wait.h>
#import <fcntl.h>
#include <stdlib.h>

static void CCLocalTeeWriteFloat(const float *src, UInt32 n);

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
// v0.17.1：守护进程只做“音频桥”——麦克风 Tap + 16k WAV 写入 + TTS 文件复制。
// 识别/翻译/TTS 合成全部在 SpringBoard（唯一可用 SFSpeech 上下文）。
// 守护进程里那套 SFSpeech 从来没被喂过音频，只会触发看门狗反复重启 Tap，
// 把 local16k.wav 切成一段段空洞——这就是“我方漏句”的直接原因。
static BOOL g_bridgeOnly = YES;
static CFAbsoluteTime g_localStartAfter;   // arm 后延迟 1 秒再挂麦克风 Tap，避开通话建立
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

static NSString *g_waDocsDir;   // WhatsApp 的 Documents（App 探针 WAV / 上行 TTS 都在这里）
// 通话开始瞬间给所有探针 WAV 拍快照（路径→字节数）。
// 之后每个文件从快照位置开始读：跳过上一通，保留本通全部音频（哪怕选文件晚了）。
static NSMutableDictionary<NSString *, NSNumber *> *g_armFileSizes;

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

static BOOL CCWriteWav48kAtPath(NSString *path, NSData *pcm) {
    if (!path.length || !pcm.length) return NO;
    FILE *fp = fopen(path.fileSystemRepresentation, "wb");
    if (!fp) return NO;
    uint32_t riff = 36 + (uint32_t)pcm.length;
    uint32_t dsz = (uint32_t)pcm.length;
    uint32_t rate = 48000, byteRate = 96000;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    uint32_t sz16 = 16;
    fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp);
    fwrite("WAVEfmt ", 1, 8, fp); fwrite(&sz16, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp); fwrite(&ch, 2, 1, fp);
    fwrite(&rate, 4, 1, fp); fwrite(&byteRate, 4, 1, fp);
    fwrite(&align, 2, 1, fp); fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp); fwrite(&dsz, 4, 1, fp);
    fwrite(pcm.bytes, 1, pcm.length, fp);
    fclose(fp);
    chmod(path.fileSystemRepresentation, 0666);
    return YES;
}

static void CCWriteUplinkWav(NSData *pcm) {
    if (!pcm.length || !g_waDocsDir) return;
    NSString *path = [g_waDocsDir stringByAppendingPathComponent:@"cc_tts.wav"];
    if (!CCWriteWav48kAtPath(path, pcm)) {
        CCLogf(@"uplink tts open failed");
        return;
    }
    CCLogf(@"uplink tts written %lu bytes", (unsigned long)pcm.length);
}

static NSString *CCFindWhatsAppDocs(void) {
    if (g_waDocsDir) return g_waDocsDir;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *base = @"/var/mobile/Containers/Data/Application";
    for (NSString *a in [fm contentsOfDirectoryAtPath:base error:nil]) {
        NSString *dir = [base stringByAppendingPathComponent:a];
        NSString *meta = [dir stringByAppendingPathComponent:
                          @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([md[@"MCMMetadataIdentifier"] isEqualToString:@"net.whatsapp.WhatsApp"]) {
            NSString *docs = [dir stringByAppendingPathComponent:@"Documents"];
            if ([fm fileExistsAtPath:docs]) { g_waDocsDir = docs; return docs; }
        }
    }
    return nil;
}

// v0.18：英文 TTS 也串行写，防止同一秒两个翻译结果互相覆盖 cc_tts.wav。
static BOOL CCGenerateUplinkTTSNow(NSString *text, void (^completion)(void));
static NSMutableArray *g_enTTSQ;
static BOOL g_enTTSBusy;

static void CCGenerateUplinkTTSStartNext(void) {
    if (!g_enTTSQ.count) { g_enTTSBusy = NO; return; }
    NSString *text = g_enTTSQ.firstObject;
    [g_enTTSQ removeObjectAtIndex:0];
    // AVSpeechSynthesizer 放到主线程/主 runloop 上跑；守护进程主线程一直在跑 NSRunLoop。
    dispatch_async(dispatch_get_main_queue(), ^{
        CCGenerateUplinkTTSNow(text, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           g_stateQ, ^{ CCGenerateUplinkTTSStartNext(); });
        });
    });
}

static void CCGenerateUplinkTTSQueued(NSString *text) {
    if (!text.length) return;
    if (!g_enTTSQ) g_enTTSQ = [NSMutableArray array];
    [g_enTTSQ addObject:text];
    if (g_enTTSBusy) return;
    g_enTTSBusy = YES;
    CCGenerateUplinkTTSStartNext();
}

static void CCGenerateUplinkTTSClear(void) {
    [g_enTTSQ removeAllObjects];
}

// LCT 的上行注入：用 writeUtterance:toBufferCallback: 把英文 TTS 合成成 PCM，
// 转成 48k mono s16 写到 WhatsApp Documents/cc_tts.wav，
// App 探针会把它混进麦克风上行 buffer（对方能听到英文）。
static BOOL CCGenerateUplinkTTSNow(NSString *text, void (^completion)(void)) {
    if (text.length == 0) {
        if (completion) dispatch_async(g_stateQ, completion);
        return NO;
    }
    NSString *docs = CCFindWhatsAppDocs();
    if (!docs) {                          // 没有 App 探针文件目录，退回外放
        if (completion) dispatch_async(g_stateQ, completion);
        return NO;
    }
    AVSpeechSynthesizer *synth = [[AVSpeechSynthesizer alloc] init];
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
    NSString *vid = CCPrefStr(CC_K_LOCAL_VOICE, @"");
    AVSpeechSynthesisVoice *v = vid.length ? [AVSpeechSynthesisVoice voiceWithIdentifier:vid] : nil;
    u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    NSMutableData *out = [NSMutableData data];
    __block double phase = 0.0;
    __block BOOL finished = NO;
    __block BOOL cbDone = NO;
    void (^finish)(void) = ^{
        if (cbDone) return;
        cbDone = YES;
        if (completion) dispatch_async(g_stateQ, completion);
    };
    __block AVSpeechSynthesizer *keep = synth;
    [synth writeUtterance:u toBufferCallback:^(AVAudioBuffer *buffer) {
        @autoreleasepool {
            if (![buffer isKindOfClass:[AVAudioPCMBuffer class]]) return;
            AVAudioPCMBuffer *b = (AVAudioPCMBuffer *)buffer;
            AVAudioFrameCount n = b.frameLength;
            if (n == 0) {
                if (!finished) {
                    finished = YES;
                    CCWriteUplinkWav(out);
                    keep = nil;
                    finish();
                }
                return;
            }
            float *src = b.floatChannelData ? b.floatChannelData[0] : NULL;
            if (!src) return;
            double sr = b.format.sampleRate > 0 ? b.format.sampleRate : 22050.0;
            double step = sr / 48000.0;
            double pos = phase;
            int16_t buf[2048];
            UInt32 cnt = 0;
            while (pos < (double)n) {
                int i = (int)pos;
                float a = src[i];
                float c = src[i + 1 < n ? i + 1 : i];
                float fr = (float)(pos - (double)i);
                float val = a + (c - a) * fr;
                int iv = (int)lrintf(val * 32767.0f);
                if (iv > 32767) iv = 32767;
                if (iv < -32768) iv = -32768;
                buf[cnt++] = (int16_t)iv;
                if (cnt == 2048) { [out appendBytes:buf length:cnt * 2]; cnt = 0; }
                pos += step;
            }
            if (cnt) [out appendBytes:buf length:cnt * 2];
            phase = pos - (double)n;
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!finished) {
            finished = YES;
            CCWriteUplinkWav(out);
            keep = nil;
            finish();
        }
    });
    CCLogf(@"uplink tts start: %@", text);
    return YES;
}

// 兼容旧调用：没有队列的即时合成（只在兜底外放时用）
static BOOL CCGenerateUplinkTTS(NSString *text) {
    return CCGenerateUplinkTTSNow(text, nil);
}

// ================= v0.18 守护进程内“我方”中文识别 =================
// 只读 local16k.wav（守护进程自己连续写的 16k mono s16），绝不碰麦克风 Tap。
// 与 SpringBoard 的对方识别是两个进程、两条 SFSpeech 连接，不会再互杀。
static NSString *CCASRTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSUInteger CCASRUnits(NSString *s) {
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) n++;
    }
    return n;
}

static BOOL CCASREndsSentence(NSString *s) {
    if (!s.length) return NO;
    unichar c = [s characterAtIndex:s.length - 1];
    return (c == '.' || c == '?' || c == '!' ||
            c == 0x3002 || c == 0xFF1F || c == 0xFF01);   // 。？！
}

// 字符级 LCS 差集：ASR 改写句首/插入字时，只交付最后一个已对齐字符之后的新内容，
// 不会整句重发，也不会把已经说过的半句再播一遍。
static NSString *CCASRTail(NSString *full, NSString *delivered) {
    if (!full.length) return @"";
    if (!delivered.length) return full;
    if ([full hasPrefix:delivered])
        return CCASRTrim([full substringFromIndex:delivered.length]);
    NSUInteger dc = delivered.length, fc = full.length;
    if (!dc || !fc) return @"";
    unichar *d = malloc(dc * sizeof(unichar));
    unichar *f = malloc(fc * sizeof(unichar));
    if (!d || !f) { free(d); free(f); return @""; }
    [delivered getCharacters:d range:NSMakeRange(0, dc)];
    [full getCharacters:f range:NSMakeRange(0, fc)];
    NSUInteger *dp = calloc((dc + 1) * (fc + 1), sizeof(NSUInteger));
    if (!dp) { free(d); free(f); return @""; }
    for (NSUInteger i = 1; i <= dc; i++) {
        for (NSUInteger j = 1; j <= fc; j++) {
            if (d[i - 1] == f[j - 1])
                dp[i * (fc + 1) + j] = dp[(i - 1) * (fc + 1) + (j - 1)] + 1;
            else {
                NSUInteger a = dp[(i - 1) * (fc + 1) + j];
                NSUInteger b = dp[i * (fc + 1) + (j - 1)];
                dp[i * (fc + 1) + j] = a > b ? a : b;
            }
        }
    }
    NSUInteger i = dc, j = fc;
    NSInteger lastFull = -1;
    while (i > 0 && j > 0) {
        if (d[i - 1] == f[j - 1]) {
            if (lastFull < 0) lastFull = (NSInteger)(j - 1);
            i--; j--;
        } else if (dp[(i - 1) * (fc + 1) + j] >= dp[i * (fc + 1) + (j - 1)]) {
            i--;
        } else {
            j--;
        }
    }
    free(dp); free(d); free(f);
    if (lastFull < 0) return @"";
    NSUInteger start = (NSUInteger)lastFull + 1;
    if (start >= fc) return @"";
    return CCASRTrim([full substringFromIndex:start]);
}

@interface CCLocalASR : NSObject {
@public
    SFSpeechRecognizer *recog;
    SFSpeechAudioBufferRecognitionRequest *req;
    SFSpeechRecognitionTask *task;
    NSString *text;
    NSString *delivered;
    NSString *lastPartial;
    unsigned long long offset;
    CFAbsoluteTime sessionStart;
    CFAbsoluteTime lastTextAt;
    CFAbsoluteTime lastVoiceAt;
    CFAbsoluteTime lastDeliverAt;
    CFAbsoluteTime lastPartialAt;
    CFAbsoluteTime nextRetryAt;
    CFAbsoluteTime nextDeliverAt;
    CFAbsoluteTime rotateAt;
    CFAbsoluteTime suspendedUntil;
    BOOL running;
    BOOL starting;
    BOOL rotating;
    BOOL useCloud;
    int failures;
    int consecutiveFailures;
    int fastFailures;              // 短命会话（start 后 3 秒内被 1110/1101 杀掉）的次数
    NSUInteger callGen;
    NSUInteger deliverGen;         // 只接受最新一次交付的翻译结果，防止慢请求乱序重复播报
}
- (void)start;
- (void)stop;
- (void)tick;
- (void)startTask;
- (void)handleResult:(SFSpeechRecognitionResult *)res;
- (void)handleError:(NSError *)err;
- (void)scheduleRetry:(double)delay;
- (void)feed;
- (BOOL)hasRecentVoice;
- (void)deliverNow;
- (void)checkEndpoint:(CFAbsoluteTime)now;
- (void)maybeRotate:(CFAbsoluteTime)now;
@end

@implementation CCLocalASR

- (void)start {
    if (running) return;
    if (!CCPrefBool(CC_K_LOCAL_ENABLED, YES)) return;
    running = YES;
    failures = 0;
    consecutiveFailures = 0;
    fastFailures = 0;
    useCloud = NO;
    suspendedUntil = 0;
    nextRetryAt = 0;
    nextDeliverAt = 0;
    offset = 44;
    callGen++;
    text = @"";
    delivered = @"";
    lastPartial = nil;
    // 不在这里直接起 task：等 tick 探测到有人声再起，避免整通电话空跑/抢会话。
}

- (void)startTask {
    if (!running || req || starting) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < suspendedUntil) return;
    NSString *loc = CCPrefStr(CC_K_LOCAL_LOCALE, @"zh-CN");
    if (recog && ![[recog.locale localeIdentifier] isEqualToString:loc]) recog = nil;
    if (!recog) {
        recog = [[SFSpeechRecognizer alloc] initWithLocale:
                 [NSLocale localeWithLocaleIdentifier:loc]];
    }
    if (!recog || !recog.isAvailable) {
        CCLogf(@"local asr: recognizer unavailable (%@), retry", loc);
        nextRetryAt = now + 2.0;
        return;
    }
    if (!recog.supportsOnDeviceRecognition) useCloud = YES;
    SFSpeechAudioBufferRecognitionRequest *r =
        [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    r.shouldReportPartialResults = YES;
    if (@available(iOS 13.0, *)) {
        r.taskHint = SFSpeechRecognitionTaskHintDictation;
        if (recog.supportsOnDeviceRecognition)
            r.requiresOnDeviceRecognition = !useCloud;
    }
    if (@available(iOS 16.0, *)) r.addsPunctuation = YES;
    req = r;
    starting = YES;
    sessionStart = now;
    text = @"";
    delivered = @"";
    lastPartial = nil;
    lastTextAt = now;
    lastVoiceAt = now;
    lastDeliverAt = now;
    lastPartialAt = 0;
    nextDeliverAt = 0;
    CCLogf(@"local asr start onDevice=%d locale=%@ auth=%ld avail=%d supportOD=%d",
           !useCloud, loc, (long)[SFSpeechRecognizer authorizationStatus],
           recog.isAvailable, recog.supportsOnDeviceRecognition);

    __weak CCLocalASR *weakSelf = self;
    __block SFSpeechRecognitionTask *t = nil;
    t = [recog recognitionTaskWithRequest:r
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
            dispatch_async(g_stateQ, ^{
                CCLocalASR *s = weakSelf;
                if (!s || s->task != t) return;
                s->starting = NO;
                if (res) {
                    [s handleResult:res];
                    if (res.isFinal) return;   // final 已处理并重启新 task，忽略同一回调里的 trailing error
                }
                if (err) [s handleError:err];
            });
        }];
    task = t;
    if (!task) {
        req = nil;
        starting = NO;
        CCLogf(@"local asr: task create failed");
        nextRetryAt = now + 1.0;
    }
}

- (void)handleResult:(SFSpeechRecognitionResult *)res {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (![[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH]) return;
    NSString *t = CCASRTrim(res.bestTranscription.formattedString);
    if (t.length) {
        failures = 0;
        consecutiveFailures = 0;
        if (now - sessionStart > 3.0) fastFailures = 0;   // 存活超过 3 秒才算健康会话
        if (![t isEqualToString:(text ?: @"")]) {
            if (!text.length)
                CCLogf(@"local asr first partial after %.2fs onDevice=%d",
                       now - sessionStart, !useCloud);
            text = t;
            lastTextAt = now;               // 只有文本真的变了才算“还在说话”
            NSString *tail = CCASRTail(text, delivered);
            if (tail.length && now - lastPartialAt > 0.30 &&
                ![tail isEqualToString:(lastPartial ?: @"")]) {
                lastPartial = tail;
                lastPartialAt = now;
                CCTransportSendLine([@"LI|" stringByAppendingString:tail]);
            }
        }
    }
    if (res.isFinal) {
        CCLogf(@"local asr final %lu chars", (unsigned long)t.length);
        [self deliverNow];
        task = nil;
        req = nil;
        rotating = NO;
        starting = NO;
        nextRetryAt = now + 0.2;   // 交给 tick 的人声探测再起下一条，避免空跑
    }
}

- (void)handleError:(NSError *)err {
    NSInteger code = err.code;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    CCLogf(@"local asr err %ld %@ onDevice=%d",
           (long)code, err.localizedDescription ?: @"", !useCloud);
    if (!running) return;
    BOOL unexpectedCancel = ((code == 301 || code == 216) && !rotating);
    if (code != 301 && code != 216) {
        failures++;
        consecutiveFailures++;
    }
    if (code == 1110 || code == 1101 || unexpectedCancel) {
        // 如果全局只允许一条 SFSpeech，我方 task 一启动就会被对方杀掉。
        // 用“短命会话”计数识别这种冲突：start 后 3 秒内就被 1110/1101/301 杀掉，
        // 连续 3 次就暂停 20 秒，先保对方通道；到点自动再试，不永久放弃。
        if (now - sessionStart < 3.0) fastFailures++;
        else fastFailures = 0;
        if (fastFailures >= 3) {
            suspendedUntil = now + 20.0;
            fastFailures = 0;
            CCLogf(@"local asr suspend 20s (possible global SFSpeech conflict)");
            CCTransportSendLine(@"S|● 我方识别暂不可用，20 秒后自动重试");
        }
    }
    if (code != 301 && code != 216 && !useCloud && failures >= 2) {
        useCloud = YES;
        CCLogf(@"local asr fallback to cloud");
    }
    // 301/216 也可能带着已经识别出的半句；先交付，再重启，不能默默吞掉。
    [self deliverNow];
    task = nil;
    req = nil;
    starting = NO;
    rotating = NO;
    if (running) nextRetryAt = now + (useCloud ? 1.5 : 0.6);
}

- (void)scheduleRetry:(double)delay {
    nextRetryAt = CFAbsoluteTimeGetCurrent() + delay;
}

// 只探测文件尾部有没有人声，不推进 offset、不丢音频。
// 我方没说话时不起 SFSpeech task：既省云端/本地资源，也避免和对方通道抢会话。
- (BOOL)hasRecentVoice {
    NSString *p = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!at) return NO;
    unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
    if (size <= 44) return NO;
    // 第一次起识别（offset 还没动）扫最近 3 秒，避免通话刚接通时一句短话落在探测窗之外；
    // 之后只需 0.5 秒，短促的“嗯/好”也能抓到。
    NSUInteger want = (offset <= 44) ? 96000 : 16000;
    if (size - 44 < (unsigned long long)want)
        want = (NSUInteger)(size - 44) & ~(NSUInteger)1;
    if (!want) return NO;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
    if (!fh) return NO;
    NSData *d = nil;
    @try {
        [fh seekToFileOffset:size - want];
        d = [fh readDataOfLength:want];
    } @catch (NSException *e) { d = nil; }
    [fh closeFile];
    if (d.length < 2) return NO;
    const int16_t *s = (const int16_t *)d.bytes;
    NSUInteger n = d.length / 2;
    double sum = 0;
    for (NSUInteger i = 0; i < n; i++) sum += fabs((double)s[i]);
    // 起识别门槛略高于静音判断，避免环境底噪一直把 task 拉起来。
    return n && (sum / (double)n / 32768.0) > 0.008;
}

- (void)feed {
    NSString *p = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
    NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
    if (!at) return;
    unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
    if (size <= 44) return;
    if (offset < 44) offset = 44;
    if (size < offset) {
        // 文件被 arm 重建：从新文件头开始，旧文本作废
        offset = 44;
        text = @"";
        delivered = @"";
        lastPartial = nil;
    }
    if (size <= offset) return;
    unsigned long long avail = size - offset;
    if (avail > 32000ULL * 2) avail = 32000ULL * 2;   // 每拍最多 2 秒，积压会追上
    avail &= ~1ULL;
    if (!avail) return;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
    if (!fh) return;
    NSData *d = nil;
    @try {
        [fh seekToFileOffset:offset];
        d = [fh readDataOfLength:(NSUInteger)avail];
    } @catch (NSException *e) { d = nil; }
    [fh closeFile];
    if (d.length < 2) return;
    NSUInteger n = d.length / 2;
    static AVAudioFormat *fmt;
    if (!fmt) fmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                     sampleRate:16000
                                                       channels:1
                                                    interleaved:NO];
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt
                                                         frameCapacity:(AVAudioFrameCount)n];
    if (!buf) return;
    buf.frameLength = (AVAudioFrameCount)n;
    const int16_t *s = (const int16_t *)d.bytes;
    float *dst = buf.floatChannelData[0];
    double sum = 0;
    for (NSUInteger i = 0; i < n; i++) {
        dst[i] = (float)s[i] / 32768.0f;
        sum += fabs((double)s[i]);
    }
    if (n && (sum / (double)n / 32768.0) > 0.006)
        lastVoiceAt = CFAbsoluteTimeGetCurrent();
    @try { [req appendAudioPCMBuffer:buf]; }
    @catch (NSException *e) { return; }
    offset += (unsigned long long)n * 2;
}

- (void)deliverNow {
    if (!text.length) return;
    // 挂断后 arm 文件会被删除；不再往字幕/TTS 送任何迟到的句子。
    if (![[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH]) return;
    NSString *full = text;
    NSString *tail = CCASRTail(full, delivered);
    if (!tail.length) return;
    NSString *prev = delivered;
    delivered = full;
    lastDeliverAt = CFAbsoluteTimeGetCurrent();
    CCLogf(@"local asr deliver (silence %.2fs): %@",
           lastDeliverAt - lastTextAt, tail);
    CCTransportSendLine([@"LI|" stringByAppendingString:tail]);
    NSUInteger cg = callGen;
    NSUInteger dg = ++deliverGen;
    __weak CCLocalASR *weakSelf = self;
    CCTranslateEx(tail, @"zh", @"en", ^(NSString *out, NSString *engine) {
        dispatch_async(g_stateQ, ^{
            CCLocalASR *s = weakSelf;
            if (!s) return;
            if (!s->running || cg != s->callGen || dg != s->deliverGen) return;
            if (![[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH]) return;
            if (!out.length) {
                if ([s->delivered isEqualToString:full]) s->delivered = prev;
                s->nextDeliverAt = CFAbsoluteTimeGetCurrent() + 2.0;
                CCLogf(@"local asr trans FAILED");
                return;
            }
            if (engine.length)
                CCTransportSendLine([@"LE|" stringByAppendingString:engine]);
            CCTransportSendLine([@"LR|" stringByAppendingString:out]);
            if (CCPrefBool(CC_K_TTS_ENABLED, YES))
                CCGenerateUplinkTTSQueued(out);
        });
    });
}

- (void)checkEndpoint:(CFAbsoluteTime)now {
    if (now < nextDeliverAt) return;
    NSString *tail = CCASRTail(text, delivered);
    if (!tail.length) return;
    double silence = now - lastVoiceAt;   // 音频静音，不是“ASR 没回调”
    double stable = now - lastTextAt;     // 文本最后一次变化
    NSUInteger units = CCASRUnits(tail);
    BOOL ended = NO;
    if (CCASREndsSentence(tail) && stable >= 0.30) ended = YES;
    else if (silence >= 0.80 && units >= 4) ended = YES;
    else if (silence >= 1.80) ended = YES;
    else if (lastDeliverAt > 0 && now - lastDeliverAt >= 15.0 && units >= 4) ended = YES;
    if (ended) [self deliverNow];
}

- (void)maybeRotate:(CFAbsoluteTime)now {
    if (!req || rotating) return;
    double age = now - sessionStart;
    if (age <= 55.0) return;
    double stable = now - lastTextAt;
    if (stable > 0.8 || age > 58.0) {
        CCLogf(@"local asr rotate at %.0fs", age);
        [self deliverNow];
        rotateAt = now;
        rotating = YES;
        [req endAudio];
    }
}

- (void)tick {
    if (!running) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now < suspendedUntil) return;
    if (!req && now >= nextRetryAt) {
        // 先确认麦克风里有人声再起识别；音频一直在 local16k.wav 里，offset 没动。
        if ([self hasRecentVoice]) {
            // 每次起 task 最多回看 3 秒：句首一定在最近 0.5 秒探测窗内；如果 backlog
            // 更长（长时间静音 / task 暂停），只处理最近 3 秒，避免喂几分钟静音。
            NSString *p = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
            NSDictionary *at = [[NSFileManager defaultManager]
                                attributesOfItemAtPath:p error:nil];
            unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
            if (size > offset + 96000) offset = size - 96000;
            [self startTask];
        } else {
            nextRetryAt = now + 0.2;
        }
    }
    if (rotating) {
        // endAudio 后正常会来 final/error；2.5 秒还没来就自己收尾，别把 SFSpeech 会话挂死。
        if (req && now - rotateAt > 2.5) {
            CCLogf(@"local asr rotate timeout");
            task = nil;
            req = nil;
            rotating = NO;
            starting = NO;
            nextRetryAt = now + 0.2;
        }
        return;
    }
    if (!req) return;
    [self feed];
    [self checkEndpoint:now];
    [self maybeRotate:now];
    // 我方说完并安静 2.5 秒后主动收掉本地 task，把 SFSpeech 会话让回给“对方”通道。
    // 下一句人声到来时 tick 会重新起 task，音频一直在文件里，不会漏。
    if (req && !rotating && !useCloud &&
        now - lastVoiceAt > 2.5 && now - lastDeliverAt > 2.0) {
        CCLogf(@"local asr idle end");
        rotateAt = now;
        rotating = YES;
        [req endAudio];
    }
}

- (void)stop {
    if (!running && !task && !req) return;
    running = NO;
    callGen++;
    task = nil;
    if (req) { [req endAudio]; req = nil; }
    text = @"";
    delivered = @"";
    lastPartial = nil;
    offset = 0;
    starting = NO;
    rotating = NO;
    suspendedUntil = 0;
    nextRetryAt = 0;
    nextDeliverAt = 0;
    fastFailures = 0;
    CCLogf(@"local asr stopped");
}

@end

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
    BOOL fileMode;                   // YES: 不用 ATAudioTap，读 App 探针写出的 WAV
    NSString *filePath;              // 当前读取的 WAV
    unsigned long long fileOffset;   // 已读到的字节偏移
    CFAbsoluteTime lastFileAt;       // 最近一次从文件读到新数据的时间
    NSMutableData *chunkBuf;         // 16k s16 累积的识别块
    double chunkEnergy;              // 块内能量累计
    uint64_t chunkSamples;
    BOOL urlTaskRunning;             // 当前有 SFSpeechURLRecognitionRequest 在跑
    NSString *lastChunkText;         // 上一块的识别文本（用于重叠去重）
    NSUInteger chunkSeq;
    BOOL urlUseOnDevice;
    BOOL chunkIsFloat;
    double chunkRate;
    _Atomic(int) chunkReady;
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
@property (nonatomic, assign) BOOL fileMode;        // YES: 读 App 探针 WAV 而不是 ATAudioTap
- (void)configure;
- (BOOL)start;
- (void)stop;
- (void)pumpFileAudio;
- (void)flushChunk;
- (void)deliverChunkText:(NSString *)txt;
- (void)pauseRecog;
- (void)recogStart;
- (void)recogRestart:(double)delay;
- (void)handleResult:(SFSpeechRecognitionResult *)result error:(NSError *)error;
- (void)deliverFinal:(NSString *)text;
- (void)translateProvisional:(NSString *)text;
@end

static CCChannel *g_remote;
static CCChannel *g_local;
static CCLocalASR *g_localASR;

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
            if (monoFmt && srcFmt && buf->mAudioData && buf->mAudioDataByteSize > 0) {
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
                        if (ch.expectCJK)
                            CCLocalTeeWriteFloat(dst, nf);
                        if (!g_bridgeOnly && ch->chunkBuf && ch->chunkIsFloat) {
                            @synchronized(ch) {
                                [ch->chunkBuf appendBytes:dst length:nf * sizeof(float)];
                                ch->chunkEnergy += (double)rms * (double)nf;
                                ch->chunkSamples += nf;
                                if (ch->chunkRate > 0 &&
                                    (double)ch->chunkSamples / ch->chunkRate >= 4.0) {
                                    atomic_store(&ch->chunkReady, 1);
                                }
                            }
                        }
                        (void)r;
                        (void)pcm;
                        __atomic_add_fetch(&ch->frames, nf, __ATOMIC_RELAXED);
                    }
                }
            }
        } @catch (NSException *e) { }
        if (ch->capturing && ch->queue) AudioQueueEnqueueBuffer(ch->queue, buf, 0, NULL);
    }
}

@implementation CCChannel
@synthesize fileMode = fileMode;   // 复用已有 ivar，避免 _fileMode 与 fileMode 两份状态

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

    // 文件模式：音频来自 WhatsApp 探针写出的 /Documents/cc_remote_*.wav，
    // 不需要 ATAudioTap，也不需要 AudioQueue。
    if (self.fileMode) {
        capturing = YES;
        [self configure];
        mono = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                sampleRate:16000.0 channels:1 interleaved:NO];
        chunkBuf = [NSMutableData data];
        chunkEnergy = 0;
        chunkSamples = 0;
        lastChunkText = nil;
        urlTaskRunning = NO;
        urlUseOnDevice = YES;
        chunkRate = 16000.0;
        chunkIsFloat = NO;
        atomic_store(&chunkReady, 0);
        CCLogf(@"%@: file capture started (wav chunked, locale=%@)", self.tag, self.locale);
        return YES;
    }

    if (!g_bridgeOnly) {
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
    chunkRate = 44100.0;
    chunkIsFloat = YES;
    chunkBuf = [NSMutableData data];
    chunkEnergy = 0;
    chunkSamples = 0;
    lastChunkText = nil;
    urlTaskRunning = NO;
    urlUseOnDevice = YES;
    atomic_store(&chunkReady, 0);

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
    filePath = nil;
    fileOffset = 0;
    lastFileAt = 0;
    chunkBuf = nil;
    chunkEnergy = 0;
    chunkSamples = 0;
    lastChunkText = nil;
    urlTaskRunning = NO;
    atomic_store(&chunkReady, 0);
    if (self.fileMode) CCRemoteTeeClose();
    else CCLocalTeeClose();
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

// 读取 WhatsApp 探针写出的 cc_remote_*.wav（48k mono s16）。
// 通话时会有多个单元各写一个文件，只有真正有声音的那个是对方语音，
// 所以按“文件尾部 1 秒的能量”挑，而不是按修改时间。

static double CCFileTailEnergy(NSString *path, double *mtimeOut) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *at = [fm attributesOfItemAtPath:path error:nil];
    if (mtimeOut) *mtimeOut = [at[NSFileModificationDate] timeIntervalSince1970];
    unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
    if (size <= 44 + 4) return 0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return 0;
    unsigned long long want = 48000 * 2;   // 1 秒
    unsigned long long off = (size > 44 + want) ? size - want : 44;
    [fh seekToFileOffset:off];
    NSData *d = [fh readDataToEndOfFile];
    [fh closeFile];
    const int16_t *s = (const int16_t *)d.bytes;
    NSUInteger n = d.length / 2;
    if (!n) return 0;
    double sum = 0;
    for (NSUInteger i = 0; i < n; i++) sum += fabs((double)s[i]);
    return sum / (double)n / 32768.0;
}

static NSString *CCFindRemoteWav(NSString *preferred, double *mtimeOut) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    if (g_waDocsDir) [dirs addObject:g_waDocsDir];
    if (dirs.count == 0) {
        NSString *base = @"/var/mobile/Containers/Data/Application";
        for (NSString *a in [fm contentsOfDirectoryAtPath:base error:nil]) {
            NSString *docs = [[base stringByAppendingPathComponent:a]
                              stringByAppendingPathComponent:@"Documents"];
            if (docs) [dirs addObject:docs];
        }
    }
    NSString *largest = nil, *newest = nil;
    unsigned long long largestSize = 0, preferredSize = 0;
    double largestT = 0, newestT = 0, preferredT = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSString *d in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:d error:nil]) {
            if (![f hasPrefix:@"cc_remote_"] || ![f hasSuffix:@".wav"]) continue;
            NSString *p = [d stringByAppendingPathComponent:f];
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            double t = [at[NSFileModificationDate] timeIntervalSince1970];
            unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
            if (t > newestT) { newestT = t; newest = p; }
            if (preferred && [p isEqualToString:preferred]) {
                preferredSize = sz;
                preferredT = t;
            }
            if (now - t < 20.0 && sz > largestSize) { largestSize = sz; largest = p; largestT = t; }
        }
    }
    // 通话中真正的人声文件会持续增长，是最大的那个；铃声/提示音文件短且会停止增长。
    // 迟滞：当前文件还占最大文件 70% 以上就不切换。
    NSString *pick = nil;
    // 只有“还在被写”的 preferred 才保留；上一通的旧大文件不能靠体积赖着不走，
    // 否则新通话的新文件永远选不上（日志里 frames 不再增长、整通无音频）。
    BOOL preferredFresh = preferred && preferredSize > 0 && preferredT > 0 &&
                          (now - preferredT < 5.0);
    if (preferredFresh && preferredSize * 10 >= largestSize * 7)
        pick = preferred;
    else
        pick = largest ?: newest;
    if (pick) g_waDocsDir = [pick stringByDeletingLastPathComponent];
    if (mtimeOut) *mtimeOut = largestT;
    return pick;
}

static NSString *CCLargestRemoteWav(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    if (g_waDocsDir) [dirs addObject:g_waDocsDir];
    if (dirs.count == 0) {
        NSString *base = @"/var/mobile/Containers/Data/Application";
        for (NSString *a in [fm contentsOfDirectoryAtPath:base error:nil]) {
            NSString *docs = [[base stringByAppendingPathComponent:a]
                              stringByAppendingPathComponent:@"Documents"];
            if (docs) [dirs addObject:docs];
        }
    }
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSString *d in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:d error:nil]) {
            if (![f hasPrefix:@"cc_remote_"] || ![f hasSuffix:@".wav"]) continue;
            NSString *p = [d stringByAppendingPathComponent:f];
            unsigned long long sz = [[fm attributesOfItemAtPath:p error:nil][NSFileSize] unsignedLongLongValue];
            if (sz > bestSize) { bestSize = sz; best = p; }
        }
    }
    if (best) g_waDocsDir = [best stringByDeletingLastPathComponent];
    return best;
}

static void CCSnapshotProbeFileSizes(void) {
    @try {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *base = @"/var/mobile/Containers/Data/Application";
        for (NSString *a in [fm contentsOfDirectoryAtPath:base error:nil]) {
            NSString *docs = [[base stringByAppendingPathComponent:a]
                              stringByAppendingPathComponent:@"Documents"];
            for (NSString *f in [fm contentsOfDirectoryAtPath:docs error:nil]) {
                if (![f hasPrefix:@"cc_remote_"] || ![f hasSuffix:@".wav"]) continue;
                NSString *pth = [docs stringByAppendingPathComponent:f];
                NSDictionary *at = [fm attributesOfItemAtPath:pth error:nil];
                if (!at) continue;
                m[pth] = at[NSFileSize] ?: @0;
            }
        }
        g_armFileSizes = m;
        CCLogf(@"arm: probe snapshot %lu files", (unsigned long)m.count);
    } @catch (NSException *e) { }
}

static NSString *CCMergeOverlap(NSString *prev, NSString *next) {
    NSArray *a = [prev componentsSeparatedByString:@" "];
    NSArray *b = [next componentsSeparatedByString:@" "];
    NSInteger maxK = MIN((NSInteger)a.count, (NSInteger)b.count);
    for (NSInteger k = maxK; k > 0; k--) {
        BOOL ok = YES;
        for (NSInteger i = 0; i < k; i++) {
            NSString *x = [a[a.count - k + i] lowercaseString];
            NSString *y = [b[i] lowercaseString];
            if (![x isEqualToString:y]) { ok = NO; break; }
        }
        if (ok) {
            return [[b subarrayWithRange:NSMakeRange(k, b.count - k)]
                    componentsJoinedByString:@" "];
        }
    }
    return next;
}

// SpringBoard 侧识别的音频桥：把远程 16k mono s16 连续写成 CC_DIR/remote16k.wav
static FILE *g_remoteTee;
static uint64_t g_remoteTeeBytes;
static void CCRemoteTeeOpen(void) {
    if (g_remoteTee) return;
    NSString *p = [CC_DIR stringByAppendingPathComponent:@"remote16k.wav"];
    g_remoteTee = fopen(p.fileSystemRepresentation, "wb");
    if (!g_remoteTee) return;
    uint32_t riff = 36, dsz = 0, rate = 16000, byteRate = 32000, sz16 = 16;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, g_remoteTee); fwrite(&riff, 4, 1, g_remoteTee);
    fwrite("WAVEfmt ", 1, 8, g_remoteTee); fwrite(&sz16, 4, 1, g_remoteTee);
    fwrite(&fmt, 2, 1, g_remoteTee); fwrite(&ch, 2, 1, g_remoteTee);
    fwrite(&rate, 4, 1, g_remoteTee); fwrite(&byteRate, 4, 1, g_remoteTee);
    fwrite(&align, 2, 1, g_remoteTee); fwrite(&bits, 2, 1, g_remoteTee);
    fwrite("data", 1, 4, g_remoteTee); fwrite(&dsz, 4, 1, g_remoteTee);
    g_remoteTeeBytes = 0;
    fflush(g_remoteTee);
    chmod(p.fileSystemRepresentation, 0666);
}
static void CCRemoteTeeWrite(const int16_t *s, UInt32 n) {
    if (!n) return;
    if (!g_remoteTee) CCRemoteTeeOpen();
    if (!g_remoteTee) return;
    fwrite(s, 2, n, g_remoteTee);
    g_remoteTeeBytes += (uint64_t)n * 2;
    uint32_t riff = (uint32_t)(36 + g_remoteTeeBytes);
    uint32_t dsz = (uint32_t)g_remoteTeeBytes;
    fseek(g_remoteTee, 4, SEEK_SET); fwrite(&riff, 4, 1, g_remoteTee);
    fseek(g_remoteTee, 40, SEEK_SET); fwrite(&dsz, 4, 1, g_remoteTee);
    fseek(g_remoteTee, 0, SEEK_END);
    fflush(g_remoteTee);
}
static void CCRemoteTeeClose(void) {
    if (g_remoteTee) { fclose(g_remoteTee); g_remoteTee = NULL; }
    g_remoteTeeBytes = 0;
}

// 本地麦克风：44.1k float -> 16k s16 连续写入 CC_DIR/local16k.wav 供 SpringBoard 识别
static FILE *g_localTee;
static double g_localTeePhase;
static uint64_t g_localTeeBytes;
static void CCLocalTeeOpen(void) {
    if (g_localTee) return;
    NSString *p = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
    g_localTee = fopen(p.fileSystemRepresentation, "wb");
    if (!g_localTee) return;
    uint32_t riff = 36, dsz = 0, rate = 16000, byteRate = 32000, sz16 = 16;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16;
    fwrite("RIFF", 1, 4, g_localTee); fwrite(&riff, 4, 1, g_localTee);
    fwrite("WAVEfmt ", 1, 8, g_localTee); fwrite(&sz16, 4, 1, g_localTee);
    fwrite(&fmt, 2, 1, g_localTee); fwrite(&ch, 2, 1, g_localTee);
    fwrite(&rate, 4, 1, g_localTee); fwrite(&byteRate, 4, 1, g_localTee);
    fwrite(&align, 2, 1, g_localTee); fwrite(&bits, 2, 1, g_localTee);
    fwrite("data", 1, 4, g_localTee); fwrite(&dsz, 4, 1, g_localTee);
    g_localTeeBytes = 0; g_localTeePhase = 0;
    fflush(g_localTee);
    chmod(p.fileSystemRepresentation, 0666);
}
static void CCLocalTeeWriteFloat(const float *src, UInt32 n) {
    if (!n || !src) return;
    if (!g_localTee) CCLocalTeeOpen();
    if (!g_localTee) return;
    double step = 44100.0 / 16000.0;
    double pos = g_localTeePhase;
    int16_t buf[1024];
    UInt32 cnt = 0;
    while (pos < (double)n) {
        UInt32 i = (UInt32)pos;
        float a = src[i];
        float c = src[i + 1 < n ? i + 1 : i];
        float v = a + (c - a) * (float)(pos - (double)i);
        int iv = (int)lrintf(v * 32767.0f);
        if (iv > 32767) iv = 32767;
        if (iv < -32768) iv = -32768;
        buf[cnt++] = (int16_t)iv;
        if (cnt == 1024) {
            fwrite(buf, 2, cnt, g_localTee);
            g_localTeeBytes += (uint64_t)cnt * 2;
            cnt = 0;
        }
        pos += step;
    }
    if (cnt) {
        fwrite(buf, 2, cnt, g_localTee);
        g_localTeeBytes += (uint64_t)cnt * 2;
    }
    g_localTeePhase = pos - (double)n;
    uint32_t riff = (uint32_t)(36 + g_localTeeBytes);
    uint32_t dsz = (uint32_t)g_localTeeBytes;
    fseek(g_localTee, 4, SEEK_SET); fwrite(&riff, 4, 1, g_localTee);
    fseek(g_localTee, 40, SEEK_SET); fwrite(&dsz, 4, 1, g_localTee);
    fseek(g_localTee, 0, SEEK_END);
    fflush(g_localTee);
}
static void CCLocalTeeClose(void) {
    if (g_localTee) { fclose(g_localTee); g_localTee = NULL; }
    g_localTeeBytes = 0; g_localTeePhase = 0;
}

static void CCWriteChunkWav(NSString *path, NSData *pcm) {
    FILE *fp = fopen(path.fileSystemRepresentation, "wb");
    if (!fp) return;
    uint32_t riff = 36 + (uint32_t)pcm.length;
    uint32_t dsz = (uint32_t)pcm.length;
    uint32_t rate = 16000, byteRate = 32000;
    uint16_t fmt = 1, ch = 1, align = 2, bits = 16, zero = 0;
    uint32_t sz16 = 16;
    fwrite("RIFF", 1, 4, fp); fwrite(&riff, 4, 1, fp);
    fwrite("WAVEfmt ", 1, 8, fp); fwrite(&sz16, 4, 1, fp);
    fwrite(&fmt, 2, 1, fp); fwrite(&ch, 2, 1, fp);
    fwrite(&rate, 4, 1, fp); fwrite(&byteRate, 4, 1, fp);
    fwrite(&align, 2, 1, fp); fwrite(&bits, 2, 1, fp);
    fwrite("data", 1, 4, fp); fwrite(&dsz, 4, 1, fp);
    fwrite(pcm.bytes, 1, pcm.length, fp);
    fclose(fp);
    (void)zero;
}

- (void)pumpFileAudio {
    @try {
        if (!self.fileMode || !capturing) return;
        double mt = 0;
        NSString *path = CCFindRemoteWav(filePath, &mt);
        if (!path) {
            if (lastFileAt > 0 && CFAbsoluteTimeGetCurrent() - lastFileAt > 10.0)
                g_waDocsDir = nil;   // 文件没了，下次重新找
            return;
        }
        if (!filePath || ![filePath isEqualToString:path]) {
            filePath = path;
            NSDictionary *fat = [[NSFileManager defaultManager]
                                 attributesOfItemAtPath:path error:nil];
            unsigned long long fsz = [fat[NSFileSize] unsignedLongLongValue];
            NSNumber *armNum = g_armFileSizes[path];
            unsigned long long armSize = armNum ? armNum.unsignedLongLongValue : 0;
            // 用“arm 瞬间的文件大小”当分界线：
            //   - 文件被截断/新建（size < 快照）→ 从头读，一个字不丢；
            //   - 文件是旧内容累积（size >= 快照）→ 从快照位置读：
            //     跳过上一通，但本通从 arm 之后写进来的音频全部保留（哪怕选文件晚了）。
            //   - 没有快照（arm 之后新建的文件）→ 从头读。
            if (armNum && fsz < armSize) {
                fileOffset = 44;
            } else if (armNum && armSize > 44) {
                fileOffset = armSize;
                CCLogf(@"%@: start at arm offset %.1fs (skip previous call)",
                       self.tag, (double)(armSize - 44) / 96000.0);
            } else {
                fileOffset = 44;
            }
            CCLogf(@"%@: file source %@ (size %.1fs)",
                   self.tag, [path lastPathComponent], (double)(fsz - 44) / 96000.0);
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) return;
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
        if (size < fileOffset) fileOffset = 44;   // 同名文件被新通话覆盖，从头读
        if (size <= fileOffset) { [fh closeFile]; return; }
        [fh seekToFileOffset:fileOffset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        NSUInteger n = d.length & ~(NSUInteger)1;
        if (n < 6) return;
        fileOffset += n;
        lastFileAt = CFAbsoluteTimeGetCurrent();

        // 48k -> 16k：每 3 个样本取平均（简单低通）
        const int16_t *s = (const int16_t *)d.bytes;
        NSUInteger inSamples = n / 2;
        UInt32 outFrames = (UInt32)(inSamples / 3);
        if (outFrames == 0) return;
        if (!chunkBuf) chunkBuf = [NSMutableData data];
        double sum = 0;
        int16_t tmp[2048];
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:mono
                                                             frameCapacity:outFrames];
        if (!pcm) return;
        pcm.frameLength = outFrames;
        float *dst = pcm.floatChannelData[0];
        UInt32 produced = 0;
        while (produced < outFrames) {
            UInt32 batch = MIN((UInt32)2048, outFrames - produced);
            for (UInt32 i = 0; i < batch; i++) {
                UInt32 idx = produced + i;
                int32_t v = ((int32_t)s[idx * 3] + s[idx * 3 + 1] + s[idx * 3 + 2]) / 3;
                if (v > 32767) v = 32767;
                if (v < -32768) v = -32768;
                tmp[i] = (int16_t)v;
                dst[idx] = (float)v / 32768.0f;
                sum += fabs((double)v) / 32768.0;
            }
            CCRemoteTeeWrite(tmp, batch);
            produced += batch;
        }
        float rms = (float)(sum / (double)outFrames);
        lastRMS = rms;
        if (rms > 0.008f) lastLoudAt = CFAbsoluteTimeGetCurrent();
        __atomic_add_fetch(&frames, outFrames, __ATOMIC_RELAXED);
        __atomic_add_fetch(&audioBytes, (uint64_t)outFrames * 2, __ATOMIC_RELAXED);
    } @catch (NSException *e) { }
}

- (NSData *)chunkTo16kS16 {
    if (!chunkIsFloat && chunkRate == 16000.0) return [chunkBuf copy];
    NSMutableData *out = [NSMutableData data];
    int16_t buf[2048];
    UInt32 cnt = 0;
    if (chunkIsFloat) {
        const float *src = (const float *)chunkBuf.bytes;
        NSUInteger n = chunkBuf.length / 4;
        if (!n) return out;
        double step = chunkRate / 16000.0;
        double pos = 0;
        while (pos < (double)n) {
            NSUInteger i = (NSUInteger)pos;
            float a = src[i];
            float c = src[i + 1 < n ? i + 1 : i];
            float v = a + (c - a) * (float)(pos - (double)i);
            int iv = (int)lrintf(v * 32767.0f);
            if (iv > 32767) iv = 32767;
            if (iv < -32768) iv = -32768;
            buf[cnt++] = (int16_t)iv;
            if (cnt == 2048) { [out appendBytes:buf length:cnt * 2]; cnt = 0; }
            pos += step;
        }
    } else {
        const int16_t *src = (const int16_t *)chunkBuf.bytes;
        NSUInteger n = chunkBuf.length / 2;
        for (NSUInteger i = 0; i + 2 < n; i += 3) {
            int v = ((int)src[i] + src[i + 1] + src[i + 2]) / 3;
            buf[cnt++] = (int16_t)v;
            if (cnt == 2048) { [out appendBytes:buf length:cnt * 2]; cnt = 0; }
        }
    }
    if (cnt) [out appendBytes:buf length:cnt * 2];
    return out;
}

- (void)flushChunk {
    @try {
        if (!capturing || urlTaskRunning) return;
        NSData *pcm = nil;
        double avg = 0;
        @synchronized(self) {
            if (!chunkBuf || chunkSamples == 0) return;
            double dur = chunkRate > 0 ? (double)chunkSamples / chunkRate : 0;
            if (dur < 3.0) return;
            avg = chunkEnergy / (double)chunkSamples;
            pcm = [self chunkTo16kS16];
            NSUInteger keepSamples = (NSUInteger)chunkRate;   // 保留 1 秒重叠
            if (chunkSamples > keepSamples) {
                NSUInteger bps = chunkIsFloat ? 4 : 2;
                NSUInteger keepBytes = keepSamples * bps;
                if (keepBytes < chunkBuf.length) {
                    NSData *tail = [chunkBuf subdataWithRange:
                                    NSMakeRange(chunkBuf.length - keepBytes, keepBytes)];
                    chunkBuf = [tail mutableCopy];
                }
                chunkEnergy = avg * (double)keepSamples;
                chunkSamples = keepSamples;
            } else {
                chunkBuf = [NSMutableData data];
                chunkEnergy = 0;
                chunkSamples = 0;
            }
            atomic_store(&chunkReady, 0);
        }
        if (avg < 0.003 || pcm.length < 3200) {
            CCLogf(@"%@: chunk skip (rms %.4f len %lu)", self.tag, avg, (unsigned long)pcm.length);
            return;
        }
        if (!recog) {
            recog = [[SFSpeechRecognizer alloc] initWithLocale:
                     [NSLocale localeWithLocaleIdentifier:self.locale ?: @"en-US"]];
        }
        if (!recog || !recog.isAvailable) {
            CCLogf(@"%@: url recog not available", self.tag);
            return;
        }
        NSUInteger seq = ++chunkSeq;
        NSString *path = [NSString stringWithFormat:@"/tmp/cc_chunk_%lu.wav", (unsigned long)seq];
        CCWriteChunkWav(path, pcm);
        SFSpeechURLRecognitionRequest *ur =
            [[SFSpeechURLRecognitionRequest alloc] initWithURL:[NSURL fileURLWithPath:path]];
        ur.shouldReportPartialResults = NO;
        if (@available(iOS 13.0, *)) {
            ur.taskHint = SFSpeechRecognitionTaskHintDictation;
            if (urlUseOnDevice && recog.supportsOnDeviceRecognition)
                ur.requiresOnDeviceRecognition = YES;
        }
        urlTaskRunning = YES;
        CCLogf(@"%@: url recog chunk %lu (%.1fs rms%.3f onDevice=%d)",
               self.tag, (unsigned long)seq, (double)pcm.length / 32000.0, avg, urlUseOnDevice);

        __weak CCChannel *weakSelf = self;
        [recog recognitionTaskWithRequest:ur
            resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
                CCChannel *ch = weakSelf;
                if (!ch) return;
                if (result.isFinal) {
                    NSString *txt = CCTrim(result.bestTranscription.formattedString);
                    if (txt.length) [ch deliverChunkText:txt];
                }
                if (error) {
                    CCLogf(@"%@: url recog err %ld %@", ch.tag, (long)error.code,
                           error.localizedDescription);
                    if (ch->urlUseOnDevice) ch->urlUseOnDevice = NO;   // 下一块走云端
                }
                ch->urlTaskRunning = NO;
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }];
    } @catch (NSException *e) { }
}

- (void)deliverChunkText:(NSString *)txt {
    @try {
        NSString *part = txt;
        if (lastChunkText.length) part = CCMergeOverlap(lastChunkText, txt);
        lastChunkText = txt;
        part = CCTrim(part);
        if (part.length == 0) return;
        [self deliverFinal:part];
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
    if (self.expectCJK && !CCPrefBool(CC_K_LOCAL_ENABLED, YES)) return;
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

    if (self.expectCJK && !CCPrefBool(CC_K_LOCAL_ENABLED, YES)) return;
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
        if (ch.expectCJK) { if (!CCGenerateUplinkTTS(out)) CCSpeakEnglish(out); }
    });
}

@end

// ---------- armed 文件监视 ----------

// Stage A：Siri 本地识别跑在独立 helper 进程里，卡死/崩溃不拖垮音频守护进程
static pid_t g_siriPid = 0;
static CFAbsoluteTime g_siriLastSpawn = 0;
static pid_t CCReadSiriPidFile(void) {
    FILE *fp = fopen("/var/mobile/Library/CallCaption/sirihelper.pid", "r");
    if (!fp) return 0;
    int p = 0;
    if (fscanf(fp, "%d", &p) != 1) p = 0;
    fclose(fp);
    return p > 0 ? (pid_t)p : 0;
}
static void CCManageSiriHelper(BOOL armed) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (armed) {
        // 守护进程重启过：先清掉 pid 文件里遗留的旧 helper
        pid_t stale = CCReadSiriPidFile();
        if (stale > 0 && stale != g_siriPid) kill(stale, SIGKILL);
        if (g_siriPid > 0) {
            int st = 0;
            pid_t r = waitpid(g_siriPid, &st, WNOHANG);
            if (r == 0) return;            // 还活着（可能卡死，由 disarm 时 kill）
            g_siriPid = 0;                 // 已退出/崩溃，下面按节流重拉
        }
        if (now - g_siriLastSpawn < 8.0) return;
        g_siriLastSpawn = now;
        const char *path = "/var/jb/usr/local/bin/CallCaptionSiriHelper";
        if (access(path, X_OK) != 0) {
            CCLogf(@"sirihelper missing");
            return;
        }
        posix_spawn_file_actions_t acts;
        posix_spawn_file_actions_init(&acts);
        posix_spawn_file_actions_addopen(&acts, 1, "/dev/null", O_WRONLY, 0);
        posix_spawn_file_actions_addopen(&acts, 2, "/dev/null", O_WRONLY, 0);
        pid_t pid = 0;
        char *argv[] = { (char *)path, NULL };
        extern char **environ;
        int rc = posix_spawn(&pid, path, &acts, NULL, argv, environ);
        posix_spawn_file_actions_destroy(&acts);
        if (rc == 0) {
            g_siriPid = pid;
            CCLogf(@"sirihelper spawned pid=%d", pid);
        } else {
            CCLogf(@"sirihelper spawn failed %d", rc);
        }
    } else {
        pid_t stale = CCReadSiriPidFile();
        if (stale > 0) kill(stale, SIGKILL);
        unlink("/var/mobile/Library/CallCaption/sirihelper.pid");
        if (g_siriPid > 0) {
            kill(g_siriPid, SIGKILL);
            waitpid(g_siriPid, NULL, WNOHANG);
            CCLogf(@"sirihelper killed pid=%d", g_siriPid);
            g_siriPid = 0;
        }
    }
}

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
            // 新通话：先停我方 ASR，再重建桥文件；ASR 只读文件，不碰 Tap。
            [g_localASR stop];
            CCGenerateUplinkTTSClear();
            // 新通话：重置 Tap 探测，从 speaker(-2) 开始，最多试 -1 / -3。
            g_remote->tapProbeCount = 0;
            g_remote.tapPID = CC_TAP_PID_SPEAKER;
            // 清掉上一通的 16k 桥文件：关闭后删除，下次写入自动重建并截断。
            // 0.17.1 在这里 stop 通道并直接 fopen，结果守护进程每 6~7 秒重启一次
            // （日志里 44 次 audioservice started），整条链路等于没有运行。
            NSFileManager *fm2 = [NSFileManager defaultManager];
            // 清掉上一通可能残留的 TTS 文件，避免新通话一接通就冒出旧句子。
            NSString *waDocs = CCFindWhatsAppDocs();
            if (waDocs) {
                [fm2 removeItemAtPath:[waDocs stringByAppendingPathComponent:@"cc_tts.wav"]
                                error:nil];
                [fm2 removeItemAtPath:[waDocs stringByAppendingPathComponent:@"cc_tts_zh.wav"]
                                error:nil];
                NSString *reset = [waDocs stringByAppendingPathComponent:@"cc_tts_reset"];
                [@"" writeToFile:reset atomically:YES encoding:NSUTF8StringEncoding error:nil];
                chmod(reset.fileSystemRepresentation, 0666);
            }
            [fm2 removeItemAtPath:[CC_DIR stringByAppendingPathComponent:@"cc_tts.wav"]
                            error:nil];
            [fm2 removeItemAtPath:[CC_DIR stringByAppendingPathComponent:@"cc_tts_zh.wav"]
                            error:nil];
            CCRemoteTeeClose();
            [fm2 removeItemAtPath:[CC_DIR stringByAppendingPathComponent:@"remote16k.wav"]
                            error:nil];
            if (CCPrefBool(CC_K_LOCAL_ENABLED, YES)) {
                CCLocalTeeClose();
                [fm2 removeItemAtPath:[CC_DIR stringByAppendingPathComponent:@"local16k.wav"]
                                error:nil];
            }
            g_localStartAfter = CFAbsoluteTimeGetCurrent() + 1.0;
            CCSnapshotProbeFileSizes();
            CCLogf(@"arm: bridge wav cleared (local tap in 1.0s)");
        }
        lastArmed = armed;
        if (!armed) {
            [g_localASR stop];
            CCGenerateUplinkTTSClear();
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
        // 文件模式：每次 tick 把 WhatsApp 探针新写出的 PCM 喂给识别器
        if (g_remote.fileMode) [g_remote pumpFileAudio];
        // 分块识别只在非桥接模式启用（桥接模式由 SpringBoard 统一识别）
        if (!g_bridgeOnly && g_remote->capturing && atomic_load(&g_remote->chunkReady))
            [g_remote flushChunk];

        // 我方通道（双向模式）
        BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, YES);
        if (localOn) {
            NSString *oldLocalLocale = g_local.locale;
            [g_local configure];
            if (g_local->capturing && oldLocalLocale &&
                ![oldLocalLocale isEqualToString:g_local.locale]) {
                CCLogf(@"local: locale changed %@ -> %@, restart", oldLocalLocale, g_local.locale);
                [g_local stop];
            }
            if (!g_local->capturing && now - g_local->lastAttempt > 3.0 &&
                now >= g_localStartAfter) {
                g_local->lastAttempt = now;
                [g_local start];
            }
        } else if (g_local->capturing) {
            [g_local stop];
        }

        // v0.18：我方中文识别在守护进程里独立跑（第二进程、第二条 SFSpeech），
        // 只读 local16k.wav；Tap 继续连续写文件，识别失败不会影响抓音。
        if (localOn && now >= g_localStartAfter + 0.5) {
            if (!g_localASR) g_localASR = [CCLocalASR new];
            [g_localASR start];
        } else if (!localOn && g_localASR) {
            [g_localASR stop];
        }

        NSArray<CCChannel *> *chans = @[g_remote, g_local];
        if (!g_bridgeOnly) {
            // TTS 外放期间暂停两路识别，避免把播报回声当成人声
            BOOL speaking = (now < g_ttsUntil) || (now < g_muteUntil);
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
        }

        // 帧停滞看门狗：换通话/音频会话重建后 Tap 可能不再送音频，自动重挂
        for (CCChannel *ch in chans) {
            if (!ch->capturing) continue;
            if (ch->audioBytes != ch->lastAudioSeen) {
                ch->lastAudioSeen = ch->audioBytes;
                ch->lastFrameChangeAt = now;
                (void)0;
            } else if (now - ch->lastFrameChangeAt > 8.0) {
                if (ch->fileMode) {
                    // 文件模式没有 Tap 可重挂；文件 8 秒没长，多半是通话结束了
                    ch->lastFrameChangeAt = now;
                } else {
                    // 只重挂同一个 PID，不再乱换 -2/-1/-3：
                    // 换到 -3 会把麦克风声音当“对方”，还会把通道语言切成中文。
                    CCLogf(@"%@: audio stalled (frames=%llu), restarting tap pid=%d",
                           ch.tag, (unsigned long long)ch->frames, ch.tapPID);
                    [ch stop];
                    ch->lastAttempt = 0;
                    ch->lastFrameChangeAt = now;
                }
            }
        }

        // 识别健康看门狗只在非桥接模式启用；桥接模式没有识别结果，
        // 以前它每 5~10 秒就重启一次麦克风 Tap，直接把 local16k.wav 切出空洞。
        if (!g_bridgeOnly) {
            for (CCChannel *ch in chans) {
                if (!ch->capturing || ch->ttsPaused) continue;
                if (ch->fileMode) continue;
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
        }

        // 把两个“原音音量”设置写给 App 探针（App 沙盒读不到 /var/mobile 的 prefs）
        {
            static NSString *lastCfg = nil;
            NSString *docs = CCFindWhatsAppDocs();
            if (docs) {
                int rv = [CCPrefStr(@"RemoteOriginalVolume", @"45") intValue];
                int lv = [CCPrefStr(@"LocalOriginalVolume", @"30") intValue];
                if (rv == 30) rv = 45;   // 旧默认值迁移：中文播报时原音 30% 太轻，听不清对方后续
                if (rv < 0) rv = 0; if (rv > 100) rv = 100;
                if (lv < 0) lv = 0; if (lv > 100) lv = 100;
                NSString *cfg = [NSString stringWithFormat:@"remote=%.2f\nlocal=%.2f\n",
                                 rv / 100.0, lv / 100.0];
                if (![cfg isEqualToString:lastCfg]) {
                    NSString *p = [docs stringByAppendingPathComponent:@"cc_cfg.txt"];
                    [cfg writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    chmod(p.fileSystemRepresentation, 0666);
                    lastCfg = cfg;
                    CCLogf(@"app cfg remote=%d local=%d", rv, lv);
                }
            }
        }

        // SpringBoard 合成好的 TTS 复制到 WhatsApp Documents：
        //   cc_tts.wav    = 英文（我方说话 → 对方听），App 探针混进上行
        //   cc_tts_zh.wav = 中文（对方说话 → 我方听），App 探针混进下行
        // 两个文件必须各自独立监视：以前只看 cc_tts.wav，双向模式没开时中文 TTS
        // 永远不会被复制，用户就一直只听到英文原音。
        {
            static NSTimeInterval lastEn = 0, lastZh = 0;
            static BOOL primed = NO;
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *pEn = [CC_DIR stringByAppendingPathComponent:@"cc_tts.wav"];
            NSString *pZh = [CC_DIR stringByAppendingPathComponent:@"cc_tts_zh.wav"];
            NSDictionary *atEn = [fm attributesOfItemAtPath:pEn error:nil];
            NSDictionary *atZh = [fm attributesOfItemAtPath:pZh error:nil];
            NSTimeInterval mtEn = atEn ? [atEn[NSFileModificationDate] timeIntervalSince1970] : 0;
            NSTimeInterval mtZh = atZh ? [atZh[NSFileModificationDate] timeIntervalSince1970] : 0;
            if (!primed) {
                // 守护进程刚起：旧文件只记时间，不再复制，避免上一通的 TTS 被重播
                primed = YES;
                lastEn = mtEn;
                lastZh = mtZh;
            } else if ((mtEn > lastEn) || (mtZh > lastZh)) {
                NSString *docs = CCFindWhatsAppDocs();
                if (docs) {
                    if (mtEn > lastEn) {
                        lastEn = mtEn;
                        NSString *dst = [docs stringByAppendingPathComponent:@"cc_tts.wav"];
                        [fm removeItemAtPath:dst error:nil];
                        BOOL ok = [fm copyItemAtPath:pEn toPath:dst error:nil];
                        if (ok) chmod(dst.fileSystemRepresentation, 0666);
                        CCLogf(@"tts copied cc_tts.wav ok=%d", ok);
                    }
                    if (mtZh > lastZh) {
                        lastZh = mtZh;
                        NSString *dst = [docs stringByAppendingPathComponent:@"cc_tts_zh.wav"];
                        [fm removeItemAtPath:dst error:nil];
                        BOOL ok = [fm copyItemAtPath:pZh toPath:dst error:nil];
                        if (ok) chmod(dst.fileSystemRepresentation, 0666);
                        CCLogf(@"tts copied cc_tts_zh.wav ok=%d", ok);
                    }
                }
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
                   CCPrefBool(CC_K_LOCAL_ENABLED, YES));
        } else if ([suffix isEqualToString:@"arm"] || [suffix isEqualToString:@"disarm"]) {
            dispatch_async(g_stateQ, ^{ CheckArm(); });
        }
    } @catch (NSException *e) { }
}

// ---------- 入口 ----------

static void CCUncaughtException(NSException *e) {
    CCLogf(@"UNCAUGHT %@: %@", e.name, e.reason);
}
static void CCAtExit(void) {
    CCLogf(@"daemon exiting (atexit)");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CCProcessInit();
        NSSetUncaughtExceptionHandler(&CCUncaughtException);
        atexit(CCAtExit);
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:CC_DIR]) {
            [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0777} error:nil];
        }
        CCPrefsReload();
        CCLogLine(@"audioservice started (v0.17.1)");
        // LCT 的 livecallhelper 在识别前会配置 AVAudioSession（SoloAmbient/Default）；
        // 我们的守护进程以前没做这一步，补上。
        @try {
            AVAudioSession *sess = [AVAudioSession sharedInstance];
            [sess setCategory:AVAudioSessionCategorySoloAmbient
                         mode:AVAudioSessionModeDefault
                      options:0
                        error:nil];
            [sess setActive:YES error:nil];
            CCLogf(@"audio session: cat=%@ mode=%@", sess.category, sess.mode);
        } @catch (NSException *e) {
            CCLogf(@"audio session exc %@", e.reason);
        }
        {
            NSString *dk = CCPrefStr(CC_K_DEEPL_KEY, @"");
            CCLogf(@"prefs boot: engine=%@ deeplKeyLen=%lu remote=%d local=%d",
                   CCPrefStr(CC_K_ENGINE, @"auto"), (unsigned long)dk.length,
                   CCPrefBool(CC_K_REMOTE_ENABLED, YES),
                   CCPrefBool(CC_K_LOCAL_ENABLED, YES));
        }

        g_stateQ = dispatch_queue_create("net.user.callcaption.audio", DISPATCH_QUEUE_SERIAL);

        // 旧版这里有一个 +6 秒的“自检素材复制”：会把最大的 cc_remote_*.wav
        // 整个读进内存再截取 10 秒。长通话后文件可达几十 MB，守护进程会被
        // jetsam 杀掉 → 日志里出现每 6~7 秒一次 audioservice started 的崩溃循环。
        // 现在改成只读文件尾部一小段，且只在 selftest 开关存在时执行。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       g_stateQ, ^{
            @try {
                if (![[NSFileManager defaultManager] fileExistsAtPath:
                      [CC_DIR stringByAppendingPathComponent:@"run_selftest"]]) return;
                NSString *dst = [CC_DIR stringByAppendingPathComponent:@"selftest.wav"];
                NSString *src = CCLargestRemoteWav();
                if (!src) return;
                NSDictionary *at = [[NSFileManager defaultManager]
                                    attributesOfItemAtPath:src error:nil];
                unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
                if (size < 44 + 48000 * 2) return;
                unsigned long long want = MIN((unsigned long long)(48000 * 2 * 10),
                                              size - 44);
                NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:src];
                if (!fh) return;
                [fh seekToFileOffset:size - want];
                NSData *pcm = [fh readDataToEndOfFile];
                [fh closeFile];
                if (pcm.length && CCWriteWav48kAtPath(dst, pcm))
                    CCLogf(@"selftest tail %lu bytes from %@",
                           (unsigned long)pcm.length, [src lastPathComponent]);
            } @catch (NSException *e) {
                CCLogf(@"selftest copy exc %@", e.reason);
            }
        });

        g_remote = [[CCChannel alloc] init];
        g_remote.tapPID = CC_TAP_PID_SPEAKER;
        g_remote.tag = @"remote";
        g_remote.fileMode = YES;   // 对方语音来自 App 探针写出的 WAV
        [g_remote configure];

        g_local = [[CCChannel alloc] init];
        g_local.tapPID = CC_TAP_PID_MIC;
        g_local.tag = @"local";
        [g_local configure];

        g_localASR = [CCLocalASR new];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &CCDaemonNotifCB, NULL, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                         0, 0, g_stateQ);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                                  (uint64_t)500 * NSEC_PER_MSEC,
                                  (uint64_t)200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            static CFAbsoluteTime lastBeat;
            CFAbsoluteTime tn = CFAbsoluteTimeGetCurrent();
            if (tn - lastBeat >= 30.0) {
                lastBeat = tn;
                CCLogf(@"daemon alive armed=%d",
                       (int)[[NSFileManager defaultManager] fileExistsAtPath:CC_ARM_PATH]);
            }
            CheckArm();
        });
        dispatch_resume(timer);

        // 我方 ASR 的读文件/喂音频节拍：150ms 一次，比 500ms 主 tick 更跟手。
        dispatch_source_t asrTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                            0, 0, g_stateQ);
        dispatch_source_set_timer(asrTimer, DISPATCH_TIME_NOW,
                                  (uint64_t)150 * NSEC_PER_MSEC,
                                  (uint64_t)50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(asrTimer, ^{
            [g_localASR tick];
        });
        dispatch_resume(asrTimer);

        // 即使 run loop 没有任何 source，也绝不退出：
        // 退出会被 launchd 立即重启，形成 logs 里每 6~7 秒一次的重启循环。
        while (1) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
            }
        }
    }
    return 0;
}
