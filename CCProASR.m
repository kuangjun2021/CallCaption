// CCProASR.m — CallCaption Pro CPU ASR helper (v1.0.0-pro1)
//
// 独立 arm64 进程，链接 sherpa-onnx iOS static xcframework。
// 读 local16k.wav（Pro 目录），16k mono s16 -> 480ms 流式中英模型，
// 输出 LI|/LQ| 到 Pro spool（live），或写 asr_test.txt（offline）。
//
// 不使用 corespeechd / SFSpeech / 麦克风权限；不会被本地 TTS 饿死。
#import "CCCommon.h"
#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/time.h>

#include "sherpa-onnx/c-api/c-api.h"

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) { (void)sig; g_stop = 1; }

static void Log(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDate date], msg];
        NSString *p = [CC_DIR stringByAppendingPathComponent:@"asr.log"];
        FILE *fp = fopen(p.fileSystemRepresentation, "a");
        if (fp) {
            // line.length 是 UTF-16 单元数，中文的 UTF-8 字节数更大；
            // 用它当 fwrite 长度会把多字节字符截断，日志变成乱码。
            NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (d.length) fwrite(d.bytes, 1, d.length, fp);
            fflush(fp);
            fclose(fp);
        }
        fprintf(stderr, "%s", line.UTF8String);
    }
}

static void AppendSpool(NSString *line) {
    if (!line.length) return;
    NSData *d = [[line stringByAppendingString:@"\n"]
                 dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open(CC_SPOOL_PATH.fileSystemRepresentation,
                  O_WRONLY | O_APPEND | O_CREAT, 0666);
    if (fd < 0) return;
    ssize_t off = 0;
    const uint8_t *p = d.bytes;
    while (off < (ssize_t)d.length) {
        ssize_t n = write(fd, p + off, d.length - off);
        if (n <= 0) break;
        off += n;
    }
    close(fd);
    // helper 不是 daemon，写 spool 不会经过 CCTransportSendLine，
    // 必须自己发 Darwin 通知，SpringBoard 才会立刻 drain。
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)[CC_NOTIF_PREFIX stringByAppendingString:@"line"],
        NULL, NULL, true);
}

static BOOL FindDataChunk(NSData *d, NSUInteger *off, NSUInteger *len) {
    if (d.length < 44) return NO;
    const uint8_t *p = d.bytes;
    if (memcmp(p, "RIFF", 4) || memcmp(p + 8, "WAVE", 4)) return NO;
    NSUInteger o = 12;
    while (o + 8 <= d.length) {
        uint32_t sz = (uint32_t)p[o + 4] | ((uint32_t)p[o + 5] << 8) |
                      ((uint32_t)p[o + 6] << 16) | ((uint32_t)p[o + 7] << 24);
        if (!memcmp(p + o, "data", 4)) {
            *off = o + 8;
            *len = MIN((NSUInteger)sz, d.length - *off);
            return *len >= 2;
        }
        o += 8 + sz + (sz & 1);
    }
    return NO;
}

static NSData *ReadWavData(NSString *path, NSUInteger *outOff, NSUInteger *outLen) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    NSUInteger off = 0, len = 0;
    if (!FindDataChunk(d, &off, &len)) return nil;
    // fmt 检查：16k / mono / 16bit
    const uint8_t *p = d.bytes;
    NSUInteger o = 12;
    while (o + 8 <= d.length) {
        uint32_t sz = (uint32_t)p[o + 4] | ((uint32_t)p[o + 5] << 8) |
                      ((uint32_t)p[o + 6] << 16) | ((uint32_t)p[o + 7] << 24);
        if (!memcmp(p + o, "fmt ", 4) && sz >= 16 && o + 24 <= d.length) {
            uint16_t ch = (uint16_t)(p[o + 10] | (p[o + 11] << 8));
            uint32_t rate = (uint32_t)p[o + 12] | ((uint32_t)p[o + 13] << 8) |
                            ((uint32_t)p[o + 14] << 16) | ((uint32_t)p[o + 15] << 24);
            uint16_t bits = (uint16_t)(p[o + 22] | (p[o + 23] << 8));
            if (ch != 1 || rate != 16000 || bits != 16) return nil;
            break;
        }
        o += 8 + sz + (sz & 1);
    }
    *outOff = off;
    *outLen = len;
    return d;
}

static NSString *Join(NSString *dir, NSString *name) {
    return [dir stringByAppendingPathComponent:name];
}

// ---------- Pro2：一个 Recognizer + 两条 OnlineStream ----------

@interface CCASRStream : NSObject
@property (nonatomic, assign) const SherpaOnnxOnlineStream *stream;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) BOOL isLocal;
@property (nonatomic, assign) FILE *fp;
@property (nonatomic, assign) long offset;
@property (nonatomic, copy) NSString *lastText;
@property (nonatomic, assign) CFAbsoluteTime lastPartialAt;
@property (nonatomic, assign) CFAbsoluteTime firstAt;
@property (nonatomic, assign) unsigned long finals;
@property (nonatomic, assign) unsigned long samples;
@end

@implementation CCASRStream
- (instancetype)initWithRecognizer:(const SherpaOnnxOnlineRecognizer *)rec
                              path:(NSString *)path
                           isLocal:(BOOL)isLocal {
    if ((self = [super init])) {
        _stream = SherpaOnnxCreateOnlineStream(rec);
        if (!_stream) return nil;
        _path = [path copy];
        _isLocal = isLocal;
        _offset = 44;
        _lastText = @"";
    }
    return self;
}
- (void)dealloc {
    if (_fp) fclose(_fp);
    if (_stream) SherpaOnnxDestroyOnlineStream(_stream);
}
- (NSString *)tag { return _isLocal ? @"L" : @"R"; }
- (void)resetForNextCall:(const SherpaOnnxOnlineRecognizer *)rec {
    if (_fp) { fclose(_fp); _fp = NULL; }
    _offset = 44;
    _lastText = @"";
    _lastPartialAt = 0;
    _firstAt = 0;
    _finals = 0;
    _samples = 0;
    if (_stream) SherpaOnnxOnlineStreamReset(rec, _stream);
}
- (BOOL)ensureOpen {
    if (_fp) return YES;
    if (![[NSFileManager defaultManager] fileExistsAtPath:_path]) return NO;
    _fp = fopen(_path.fileSystemRepresentation, "rb");
    if (!_fp) {
        Log(@"%@ open live wav failed %@", self.tag, _path.lastPathComponent);
        return NO;
    }
    _offset = 44;
    Log(@"%@ stream open %@", self.tag, _path.lastPathComponent);
    return YES;
}
- (void)handleResult:(NSString *)text
        recognizer:(const SherpaOnnxOnlineRecognizer *)rec
                now:(CFAbsoluteTime)now
                 t0:(CFAbsoluteTime)t0 {
    if (text.length && !_firstAt) {
        _firstAt = now;
        Log(@"%@ first +%.2fs: %@", self.tag, now - t0, text);
    }
    if (text.length && ![text isEqualToString:_lastText] &&
        now - _lastPartialAt > 0.3) {
        _lastPartialAt = now;
        _lastText = text;
        AppendSpool([(_isLocal ? @"LI|" : @"I|") stringByAppendingString:text]);
        Log(@"%@ partial +%.2fs: %@", self.tag, now - t0, text);
    }
    BOOL endpoint = SherpaOnnxOnlineStreamIsEndpoint(rec, _stream) ? YES : NO;
    if (endpoint) {
        if (text.length) {
            _finals++;
            AppendSpool([(_isLocal ? @"LI|" : @"I|") stringByAppendingString:text]);
            AppendSpool([(_isLocal ? @"LQ|" : @"RQ|") stringByAppendingString:text]);
            Log(@"%@ final +%.2fs: %@", self.tag, now - t0, text);
        }
        SherpaOnnxOnlineStreamReset(rec, _stream);
        _lastText = @"";
        _lastPartialAt = 0;
    }
}
- (BOOL)feedRecognizer:(const SherpaOnnxOnlineRecognizer *)rec
                    t0:(CFAbsoluteTime)t0 {
    if (![self ensureOpen]) return NO;
    fseek(_fp, 0, SEEK_END);
    long size = ftell(_fp);
    if (size < _offset) {
        // 文件被重建：从新文件头开始
        _offset = 44;
    }
    if (size <= _offset) return NO;
    fseek(_fp, _offset, SEEK_SET);
    size_t want = MIN((size_t)6400, (size_t)(size - _offset));
    want &= ~(size_t)1;
    if (!want) return NO;

    int16_t pcm[3200];
    float flt[3200];
    size_t got = fread(pcm, 1, want, _fp);
    if (!got) return NO;
    _offset += (long)got;
    int n = (int)(got / 2);
    _samples += (unsigned long)n;
    for (int i = 0; i < n; i++) flt[i] = (float)pcm[i] / 32768.0f;

    SherpaOnnxOnlineStreamAcceptWaveform(_stream, 16000, flt, n);
    while (SherpaOnnxIsOnlineStreamReady(rec, _stream)) {
        SherpaOnnxDecodeOnlineStream(rec, _stream);
    }
    const SherpaOnnxOnlineRecognizerResult *r =
        SherpaOnnxGetOnlineStreamResult(rec, _stream);
    NSString *text = r && r->text ? @(r->text) : @"";
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    [self handleResult:text recognizer:rec now:now t0:t0];
    if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
    return YES;
}
@end

static double ASRGoStamp(void) {
    NSString *s = [NSString stringWithContentsOfFile:CC_ASR_GO_PATH
                                            encoding:NSUTF8StringEncoding error:nil];
    return s.length ? s.doubleValue : 0.0;
}
static BOOL ASRParentAlive(void) {
    // daemon 被 launchd 重启后，helper 会被 reparent 到 launchd(PID 1)。
    return getppid() != 1;
}

static int RunLive(const SherpaOnnxOnlineRecognizer *rec,
                   BOOL localOn, BOOL remoteOn,
                   NSString *localWav, NSString *remoteWav,
                   BOOL waitArm, BOOL resident,
                   CFAbsoluteTime t0) {
    NSMutableArray<CCASRStream *> *streams = [NSMutableArray array];
    if (localOn) {
        CCASRStream *s = [[CCASRStream alloc] initWithRecognizer:rec
                                                            path:localWav
                                                         isLocal:YES];
        if (!s) { Log(@"create local stream failed"); return 4; }
        [streams addObject:s];
    }
    if (remoteOn) {
        CCASRStream *s = [[CCASRStream alloc] initWithRecognizer:rec
                                                            path:remoteWav
                                                         isLocal:NO];
        if (!s) { Log(@"create remote stream failed"); return 4; }
        [streams addObject:s];
    }
    if (!streams.count) {
        Log(@"no live stream enabled");
        return 7;
    }
    Log(@"live streams local=%d remote=%d waitArm=%d resident=%d",
        localOn, remoteOn, waitArm, resident);

    double go0 = ASRGoStamp();
    while (!g_stop) {
        if (waitArm) {
            Log(@"%@ waiting for arm", resident ? @"resident" : @"ring");
            while (!g_stop) {
                if (!ASRParentAlive()) {
                    Log(@"parent gone while waiting");
                    return 0;
                }
                if (access(CC_ARM_PATH.fileSystemRepresentation, F_OK) == 0) break;
                if (!resident &&
                    access(CC_PREPARE_PATH.fileSystemRepresentation, F_OK) != 0) {
                    Log(@"prepare gone before arm, exit");
                    return 0;
                }
                usleep(100000);
            }
            if (g_stop) break;
            // daemon 在清空 WAV 后才更新 asr_go；先等到它变化再开文件，
            // 防止预加载 helper 把上一通的旧 WAV 再识别一遍。
            CFAbsoluteTime waitStart = CFAbsoluteTimeGetCurrent();
            while (!g_stop && ASRGoStamp() <= go0 &&
                   CFAbsoluteTimeGetCurrent() - waitStart < 5.0) {
                usleep(50000);
            }
            go0 = ASRGoStamp();
            Log(@"arm seen, starting streams");
        }

        while (!g_stop) {
            if (!ASRParentAlive()) {
                Log(@"parent gone, exit");
                break;
            }
            if (access(CC_ARM_PATH.fileSystemRepresentation, F_OK) != 0) {
                Log(@"armed file gone");
                break;
            }
            BOOL did = NO;
            for (CCASRStream *s in streams) {
                @autoreleasepool {
                    if ([s feedRecognizer:rec t0:t0]) did = YES;
                }
            }
            if (!did) usleep(100000);
        }

        for (CCASRStream *s in streams) {
            Log(@"%@ done samples=%lu finals=%lu", s.tag,
                s.samples, s.finals);
        }
        if (!resident || g_stop) break;

        // 常驻模式：清掉本通状态，等下一通 arm。
        for (CCASRStream *s in streams) [s resetForNextCall:rec];
        Log(@"resident: call ended, waiting next arm");
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
        [[NSFileManager defaultManager] createDirectoryAtPath:CC_DIR
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

        NSString *mode = @"offline";
        NSString *wav = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
        NSString *localWav = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
        NSString *remoteWav = [CC_DIR stringByAppendingPathComponent:@"remote16k.wav"];
        NSString *modelDir = [CC_DIR stringByAppendingPathComponent:@"models/x-asr-480ms"];
        NSString *hotwordsPath = [CC_DIR stringByAppendingPathComponent:@"asr_hotwords.txt"];
        double maxSec = 0;
        BOOL fast = NO;
        BOOL localOn = YES;
        BOOL remoteOn = NO;
        BOOL waitArm = NO;
        BOOL resident = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = @(argv[++i]);
            else if (!strcmp(argv[i], "--wav") && i + 1 < argc) wav = @(argv[++i]);
            else if (!strcmp(argv[i], "--local-wav") && i + 1 < argc) localWav = @(argv[++i]);
            else if (!strcmp(argv[i], "--remote-wav") && i + 1 < argc) remoteWav = @(argv[++i]);
            else if (!strcmp(argv[i], "--hotwords") && i + 1 < argc) hotwordsPath = @(argv[++i]);
            else if (!strcmp(argv[i], "--local") && i + 1 < argc) localOn = atoi(argv[++i]) != 0;
            else if (!strcmp(argv[i], "--remote") && i + 1 < argc) remoteOn = atoi(argv[++i]) != 0;
            else if (!strcmp(argv[i], "--model-dir") && i + 1 < argc) modelDir = @(argv[++i]);
            else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) maxSec = atof(argv[++i]);
            else if (!strcmp(argv[i], "--fast")) fast = YES;
            else if (!strcmp(argv[i], "--wait-arm")) waitArm = YES;
            else if (!strcmp(argv[i], "--resident")) { resident = YES; waitArm = YES; }
        }
        BOOL live = [mode isEqualToString:@"live"];
        NSString *encoder = Join(modelDir, @"encoder.int8.onnx");
        NSString *decoder = Join(modelDir, @"decoder.onnx");
        NSString *joiner = Join(modelDir, @"joiner.int8.onnx");
        NSString *tokens = Join(modelDir, @"tokens.txt");
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *p in @[encoder, decoder, joiner, tokens]) {
            if (![fm fileExistsAtPath:p]) {
                Log(@"missing model file %@", p);
                return 2;
            }
        }
        if (live) {
            Log(@"start mode=live local=%d remote=%d localWav=%@ remoteWav=%@ model=%@ threads=2",
                localOn, remoteOn, localWav.lastPathComponent,
                remoteWav.lastPathComponent, modelDir.lastPathComponent);
        } else {
            Log(@"start mode=offline wav=%@ model=%@ threads=2",
                wav.lastPathComponent, modelDir.lastPathComponent);
        }

        SherpaOnnxOnlineRecognizerConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        cfg.feat_config.sample_rate = 16000;
        cfg.feat_config.feature_dim = 80;
        cfg.model_config.transducer.encoder = encoder.UTF8String;
        cfg.model_config.transducer.decoder = decoder.UTF8String;
        cfg.model_config.transducer.joiner = joiner.UTF8String;
        cfg.model_config.tokens = tokens.UTF8String;
        cfg.model_config.num_threads = 2;
        cfg.model_config.provider = "cpu";
        // 官方模型 encoder 元数据就是 zipformer2；显式指定可避免 sherpa
        // 为探测模型类型而把 169MB 模型加载两遍（首包延迟翻倍）。
        cfg.model_config.model_type = "zipformer2";
        // 热词只在 modified_beam_search 下生效；这个模型用 SentencePiece BPE，
        // bpe.vocab 由 bpe.model 导出（空格分隔），modeling_unit 必须是 bpe。
        NSDictionary *hwAttrs = [fm attributesOfItemAtPath:hotwordsPath error:nil];
        BOOL hasHotwords = [hwAttrs[NSFileSize] unsignedLongLongValue] > 0;
        NSString *bpeVocab = Join(modelDir, @"bpe.vocab");
        BOOL hotwordsOK = hasHotwords && [fm fileExistsAtPath:bpeVocab];
        if (hotwordsOK) {
            cfg.decoding_method = "modified_beam_search";
            cfg.max_active_paths = 4;
            cfg.hotwords_file = hotwordsPath.UTF8String;
            cfg.hotwords_score = 1.5f;
            cfg.model_config.modeling_unit = "bpe";
            cfg.model_config.bpe_vocab = bpeVocab.UTF8String;
        } else {
            cfg.decoding_method = "greedy_search";
            cfg.max_active_paths = 4;
        }
        cfg.enable_endpoint = 1;
        cfg.rule1_min_trailing_silence = 1.2f;
        cfg.rule2_min_trailing_silence = 0.8f;
        cfg.rule3_min_utterance_length = 10.0f;

        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        const SherpaOnnxOnlineRecognizer *rec = SherpaOnnxCreateOnlineRecognizer(&cfg);
        if (!rec) {
            Log(@"create recognizer failed");
            return 3;
        }
        NSString *decodeName = cfg.decoding_method
            ? [NSString stringWithUTF8String:cfg.decoding_method] : @"?";
        Log(@"model loaded in %.2fs (hotwords=%d decode=%@)",
            CFAbsoluteTimeGetCurrent() - t0, hotwordsOK, decodeName);

        if (live) {
            int rc = RunLive(rec, localOn, remoteOn, localWav, remoteWav,
                             waitArm, resident, t0);
            SherpaOnnxDestroyOnlineRecognizer(rec);
            Log(@"exit rc=%d", rc);
            return rc;
        }

        const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(rec);
        if (!stream) {
            Log(@"create stream failed");
            SherpaOnnxDestroyOnlineRecognizer(rec);
            return 4;
        }

        NSString *outPath = nil;
        FILE *outFp = NULL;
        if (!live) {
            outPath = [CC_DIR stringByAppendingPathComponent:@"asr_test.txt"];
            outFp = fopen(outPath.fileSystemRepresentation, "w");
            if (outFp) {
                fprintf(outFp, "mode=offline wav=%s model=%s\n",
                        wav.lastPathComponent.UTF8String,
                        modelDir.lastPathComponent.UTF8String);
                fflush(outFp);
            }
        }

        const int kChunk = 3200;              // 200ms @16k
        const int kChunkBytes = kChunk * 2;
        int16_t pcm[kChunk];
        float flt[kChunk];
        NSUInteger feedOffset = 44;
        NSData *wavData = nil;
        NSUInteger dataOff = 0, dataLen = 0;
        if (!live) {
            wavData = ReadWavData(wav, &dataOff, &dataLen);
            if (!wavData) {
                Log(@"bad wav %@", wav);
                if (outFp) fclose(outFp);
                SherpaOnnxDestroyOnlineStream(stream);
                SherpaOnnxDestroyOnlineRecognizer(rec);
                return 5;
            }
            feedOffset = dataOff;
            if (maxSec > 0) {
                NSUInteger maxBytes = (NSUInteger)(maxSec * 32000.0);
                if (dataLen > maxBytes) dataLen = maxBytes;
            }
            Log(@"wav data=%lu bytes (%.1fs)", (unsigned long)dataLen,
                (double)dataLen / 32000.0);
        }

        NSString *lastText = @"";
        CFAbsoluteTime lastPartialAt = 0;
        CFAbsoluteTime firstAt = 0;
        NSUInteger finals = 0;
        NSUInteger audioSamples = 0;
        FILE *liveFp = NULL;
        if (live) {
            // 等文件出现
            for (int i = 0; i < 50 && !g_stop; i++) {
                if ([fm fileExistsAtPath:wav]) break;
                usleep(100000);
            }
            liveFp = fopen(wav.fileSystemRepresentation, "rb");
            if (!liveFp) {
                Log(@"open live wav failed %@", wav);
                SherpaOnnxDestroyOnlineStream(stream);
                SherpaOnnxDestroyOnlineRecognizer(rec);
                return 6;
            }
            feedOffset = 44;
        }

        while (!g_stop) {
            if (live && access(CC_ARM_PATH.fileSystemRepresentation, F_OK) != 0) {
                Log(@"armed file gone, exit");
                break;
            }
            int16_t *dst = pcm;
            int n = 0;
            if (live) {
                fseek(liveFp, 0, SEEK_END);
                long size = ftell(liveFp);
                if (size < (long)feedOffset) {
                    // 文件被重建：从新文件头开始
                    feedOffset = 44;
                }
                if (size <= (long)feedOffset) {
                    usleep(100000);
                    continue;
                }
                fseek(liveFp, (long)feedOffset, SEEK_SET);
                size_t want = MIN((size_t)kChunkBytes, (size_t)(size - (long)feedOffset));
                want &= ~(size_t)1;
                if (!want) {
                    usleep(100000);
                    continue;
                }
                size_t got = fread(dst, 1, want, liveFp);
                if (!got) {
                    usleep(100000);
                    continue;
                }
                feedOffset += got;
                n = (int)(got / 2);
            } else {
                NSUInteger remain = dataLen - (feedOffset - dataOff);
                if (!remain) break;
                NSUInteger want = MIN((NSUInteger)kChunkBytes, remain);
                want &= ~(NSUInteger)1;
                const uint8_t *p = (const uint8_t *)wavData.bytes + feedOffset;
                memcpy(dst, p, want);
                feedOffset += want;
                n = (int)(want / 2);
            }
            for (int i = 0; i < n; i++) flt[i] = (float)dst[i] / 32768.0f;
            SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, flt, n);
            audioSamples += n;
            while (SherpaOnnxIsOnlineStreamReady(rec, stream)) {
                SherpaOnnxDecodeOnlineStream(rec, stream);
            }
            const SherpaOnnxOnlineRecognizerResult *r =
                SherpaOnnxGetOnlineStreamResult(rec, stream);
            NSString *text = r && r->text ? @(r->text) : @"";
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (text.length && !firstAt) {
                firstAt = now;
                Log(@"first +%.2fs: %@", now - t0, text);
                if (outFp) {
                    fprintf(outFp, "[first] +%.2fs: %s\n", now - t0, text.UTF8String);
                    fflush(outFp);
                }
            }
            if (text.length && ![text isEqualToString:lastText] &&
                now - lastPartialAt > 0.3) {
                lastPartialAt = now;
                lastText = text;
                if (live) AppendSpool([@"LI|" stringByAppendingString:text]);
                if (outFp) {
                    fprintf(outFp, "[partial] +%.2fs: %s\n", now - t0, text.UTF8String);
                    fflush(outFp);
                }
            }
            BOOL endpoint = SherpaOnnxOnlineStreamIsEndpoint(rec, stream) ? YES : NO;
            if (endpoint) {
                if (text.length) {
                    finals++;
                    Log(@"final +%.2fs: %@", now - t0, text);
                    if (live) {
                        AppendSpool([@"LI|" stringByAppendingString:text]);
                        AppendSpool([@"LQ|" stringByAppendingString:text]);
                    }
                    if (outFp) {
                        fprintf(outFp, "[final] +%.2fs: %s\n", now - t0, text.UTF8String);
                        fflush(outFp);
                    }
                }
                SherpaOnnxOnlineStreamReset(rec, stream);
                lastText = @"";
                lastPartialAt = 0;
            }
            if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
            if (!live && !fast) {
                // 实时节奏：下一个 200ms
                double target = t0 + (double)audioSamples / 16000.0;
                double delay = target - CFAbsoluteTimeGetCurrent();
                if (delay > 0) usleep((useconds_t)(delay * 1000000.0));
            }
            if (!live && !fast) {
                // 每 5 秒打一行进度
                static CFAbsoluteTime lastLog;
                if (now - lastLog > 5.0) {
                    lastLog = now;
                    Log(@"progress %.1fs/%lu samples", (double)audioSamples / 16000.0,
                        (unsigned long)audioSamples);
                }
            }
        }

        if (!live) {
            SherpaOnnxOnlineStreamInputFinished(stream);
            while (SherpaOnnxIsOnlineStreamReady(rec, stream)) {
                SherpaOnnxDecodeOnlineStream(rec, stream);
            }
            const SherpaOnnxOnlineRecognizerResult *r =
                SherpaOnnxGetOnlineStreamResult(rec, stream);
            NSString *text = r && r->text ? @(r->text) : @"";
            if (text.length) {
                finals++;
                Log(@"final-end: %@", text);
                if (outFp) {
                    fprintf(outFp, "[final-end] %s\n", text.UTF8String);
                    fflush(outFp);
                }
            }
            if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
        }

        double wall = CFAbsoluteTimeGetCurrent() - t0;
        double audio = (double)audioSamples / 16000.0;
        Log(@"done wall=%.2fs audio=%.1fs rtf=%.3f first=%.2fs finals=%lu",
            wall, audio, wall / MAX(audio, 0.001),
            firstAt > 0 ? firstAt - t0 : -1.0, (unsigned long)finals);
        if (outFp) {
            fprintf(outFp, "[done] wall=%.2fs audio=%.1fs rtf=%.3f first=%.2fs finals=%lu\n",
                    wall, audio, wall / MAX(audio, 0.001),
                    firstAt > 0 ? firstAt - t0 : -1.0, (unsigned long)finals);
            fclose(outFp);
        }
        if (liveFp) fclose(liveFp);
        SherpaOnnxDestroyOnlineStream(stream);
        SherpaOnnxDestroyOnlineRecognizer(rec);
        Log(@"exit");
        return 0;
    }
}
