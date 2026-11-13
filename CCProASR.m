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
            fwrite(line.UTF8String, 1, line.length, fp);
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

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGTERM, on_signal);
        signal(SIGINT, on_signal);
        [[NSFileManager defaultManager] createDirectoryAtPath:CC_DIR
                                  withIntermediateDirectories:YES
                                                   attributes:nil error:nil];

        NSString *mode = @"offline";
        NSString *wav = [CC_DIR stringByAppendingPathComponent:@"local16k.wav"];
        NSString *modelDir = [CC_DIR stringByAppendingPathComponent:@"models/x-asr-480ms"];
        double maxSec = 0;
        BOOL fast = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--mode") && i + 1 < argc) mode = @(argv[++i]);
            else if (!strcmp(argv[i], "--wav") && i + 1 < argc) wav = @(argv[++i]);
            else if (!strcmp(argv[i], "--model-dir") && i + 1 < argc) modelDir = @(argv[++i]);
            else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) maxSec = atof(argv[++i]);
            else if (!strcmp(argv[i], "--fast")) fast = YES;
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
        Log(@"start mode=%@ wav=%@ model=%@ threads=2", mode, wav.lastPathComponent,
            modelDir.lastPathComponent);

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
        cfg.decoding_method = "greedy_search";
        cfg.max_active_paths = 4;
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
        const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(rec);
        if (!stream) {
            Log(@"create stream failed");
            SherpaOnnxDestroyOnlineRecognizer(rec);
            return 4;
        }
        Log(@"model loaded in %.2fs", CFAbsoluteTimeGetCurrent() - t0);

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
