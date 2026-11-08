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

// LCT 的上行注入：用 writeUtterance:toBufferCallback: 把英文 TTS 合成成 PCM，
// 转成 48k mono s16 写到 WhatsApp Documents/cc_tts.wav，
// App 探针会把它混进麦克风上行 buffer（对方能听到英文）。
static BOOL CCGenerateUplinkTTS(NSString *text) {
    if (text.length == 0) return NO;
    NSString *docs = CCFindWhatsAppDocs();
    if (!docs) return NO;                 // 没有 App 探针文件目录，退回外放
    AVSpeechSynthesizer *synth = [[AVSpeechSynthesizer alloc] init];
    AVSpeechUtterance *u = [[AVSpeechUtterance alloc] initWithString:text];
    NSString *vid = CCPrefStr(CC_K_LOCAL_VOICE, @"");
    AVSpeechSynthesisVoice *v = vid.length ? [AVSpeechSynthesisVoice voiceWithIdentifier:vid] : nil;
    u.voice = v ?: [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    NSMutableData *out = [NSMutableData data];
    __block double phase = 0.0;
    __block BOOL finished = NO;
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
        }
    });
    CCLogf(@"uplink tts start: %@", text);
    return YES;
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
                        if (ch->chunkBuf && ch->chunkIsFloat) {
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
    double largestT = 0, newestT = 0;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    for (NSString *d in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:d error:nil]) {
            if (![f hasPrefix:@"cc_remote_"] || ![f hasSuffix:@".wav"]) continue;
            NSString *p = [d stringByAppendingPathComponent:f];
            NSDictionary *at = [fm attributesOfItemAtPath:p error:nil];
            double t = [at[NSFileModificationDate] timeIntervalSince1970];
            unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
            if (t > newestT) { newestT = t; newest = p; }
            if (preferred && [p isEqualToString:preferred]) preferredSize = sz;
            if (now - t < 20.0 && sz > largestSize) { largestSize = sz; largest = p; largestT = t; }
        }
    }
    // 通话中真正的人声文件会持续增长，是最大的那个；铃声/提示音文件短且会停止增长。
    // 迟滞：当前文件还占最大文件 70% 以上就不切换。
    NSString *pick = nil;
    if (preferred && preferredSize > 0 && preferredSize * 10 >= largestSize * 7)
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
            fileOffset = 44;         // 跳过 WAV 头
            CCLogf(@"%@: file source %@", self.tag, [path lastPathComponent]);
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
        if (ch.expectCJK) { if (!CCGenerateUplinkTTS(out)) CCSpeakEnglish(out); }
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
        // 文件模式：每次 tick 把 WhatsApp 探针新写出的 PCM 喂给识别器
        if (g_remote.fileMode) [g_remote pumpFileAudio];
        // 分块识别：两个通道攒够 4 秒就送 SFSpeechURLRecognitionRequest
        if (g_remote->capturing && atomic_load(&g_remote->chunkReady))
            [g_remote flushChunk];

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

        // 识别健康看门狗：有真实声音、但 6 秒没有任何识别结果 → 重启识别
        for (CCChannel *ch in chans) {
            if (!ch->capturing || ch->ttsPaused) continue;
            if (ch->fileMode) continue;   // 文件分块识别自带重试，不走流式重启
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

        // 把两个“原音音量”设置写给 App 探针（App 沙盒读不到 /var/mobile 的 prefs）
        {
            static NSString *lastCfg = nil;
            NSString *docs = CCFindWhatsAppDocs();
            if (docs) {
                int rv = [CCPrefStr(@"RemoteOriginalVolume", @"30") intValue];
                int lv = [CCPrefStr(@"LocalOriginalVolume", @"30") intValue];
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

        // SpringBoard 合成好的英文 TTS（CC_DIR/cc_tts.wav）复制到 WhatsApp Documents，
        // App 探针会把它混进上行。
        {
            static NSTimeInterval lastTts = 0;
            NSString *src = [CC_DIR stringByAppendingPathComponent:@"cc_tts.wav"];
            NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:src error:nil];
            NSTimeInterval mt = [at[NSFileModificationDate] timeIntervalSince1970];
            if (at && mt > lastTts) {
                lastTts = mt;
                NSString *docs = CCFindWhatsAppDocs();
                if (docs) {
                    for (NSString *name in @[@"cc_tts.wav", @"cc_tts_zh.wav"]) {
                        NSString *s2 = [CC_DIR stringByAppendingPathComponent:name];
                        if (![[NSFileManager defaultManager] fileExistsAtPath:s2]) continue;
                        NSString *dst = [docs stringByAppendingPathComponent:name];
                        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
                        BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:s2 toPath:dst error:nil];
                        if (ok) chmod(dst.fileSystemRepresentation, 0666);
                        CCLogf(@"tts copied %@ ok=%d", name, ok);
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
        CCLogLine(@"audioservice started (v0.14.0-alpha28)");
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
                   CCPrefBool(CC_K_LOCAL_ENABLED, NO));
        }

        g_stateQ = dispatch_queue_create("net.user.callcaption.audio", DISPATCH_QUEUE_SERIAL);

        // 自检素材：把最近一通 WhatsApp 通话里“有声音的那段”复制到
        // /var/mobile/Library/CallCaption/selftest.wav，供 SpringBoard 里的
        // SFSpeech 自检使用（不需要用户再打电话）。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       g_stateQ, ^{
            @try {
                NSString *dst = [CC_DIR stringByAppendingPathComponent:@"selftest.wav"];
                NSString *src = CCLargestRemoteWav();
                if (!src) { CCLogf(@"selftest: no source wav"); return; }
                NSData *d = [NSData dataWithContentsOfFile:src];
                if (d.length < 44 + 48000 * 2) {
                    CCLogf(@"selftest: source too small %lu", (unsigned long)d.length);
                    return;
                }
                NSUInteger n = MIN(d.length - 44, (NSUInteger)48000 * 2 * 10);
                NSData *pcm = [d subdataWithRange:NSMakeRange(44, n)];
                if (CCWriteWav48kAtPath(dst, pcm))
                    CCLogf(@"selftest: wrote %lu bytes from %@",
                           (unsigned long)n, [src lastPathComponent]);
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

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, &CCDaemonNotifCB, NULL, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                                         0, 0, g_stateQ);
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                                  (uint64_t)500 * NSEC_PER_MSEC,
                                  (uint64_t)200 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{ CheckArm(); });
        dispatch_resume(timer);

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
