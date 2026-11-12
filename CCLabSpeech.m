// CCLabSpeech.m — v0.20.8-lab
// 只做离线实验：16k mono s16 WAV -> 实时 200ms/包 -> SFSpeech on-device。
// 不翻译、不 TTS、不碰腾讯/DeepL/Google，也不改通话路径。
#import "CCLabSpeech.h"
#import "CCCommon.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <string.h>

static AVAudioFormat *CCLabFormat(void) {
    static AVAudioFormat *f;
    if (!f) f = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                sampleRate:16000
                                                  channels:1
                                               interleaved:NO];
    return f;
}

@implementation CCLabSpeech {
    NSString *_tag, *_locale, *_path;
    double _duration;
    SFSpeechRecognizer *_recog;
    SFSpeechRecognitionTask *_task;
    SFSpeechAudioBufferRecognitionRequest *_req;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    NSData *_pcm;
    NSUInteger _offset;
    CFAbsoluteTime _startAt;
    CFAbsoluteTime _firstPartialAt;
    CFAbsoluteTime _lastPartialLog;
    CFAbsoluteTime _lastThermalLog;
    NSUInteger _finals, _partials, _loops, _sessions;
    NSInteger _lastErr;
    BOOL _running, _ending, _restarting;
}

- (instancetype)initWithTag:(NSString *)tag
                     locale:(NSString *)locale
                       path:(NSString *)path
                   duration:(double)duration {
    if ((self = [super init])) {
        _tag = [tag copy];
        _locale = [locale copy];
        _path = [path copy];
        _duration = duration > 10.0 ? duration : 150.0;
        _q = dispatch_queue_create("callcaption.lab.speech", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRunning { return _running; }

- (BOOL)loadWav {
    NSData *d = [NSData dataWithContentsOfFile:_path];
    if (d.length < 44) return NO;
    const uint8_t *p = (const uint8_t *)d.bytes;
    if (memcmp(p, "RIFF", 4) || memcmp(p + 8, "WAVE", 4)) return NO;

    NSUInteger off = 12, dataOff = 0, dataLen = 0;
    uint16_t ch = 0, bits = 0;
    uint32_t rate = 0;
    while (off + 8 <= d.length) {
        uint32_t sz = (uint32_t)p[off + 4] | ((uint32_t)p[off + 5] << 8) |
                      ((uint32_t)p[off + 6] << 16) | ((uint32_t)p[off + 7] << 24);
        if (!memcmp(p + off, "fmt ", 4) && sz >= 16 && off + 8 + 16 <= d.length) {
            ch = (uint16_t)(p[off + 10] | (p[off + 11] << 8));
            rate = (uint32_t)p[off + 12] | ((uint32_t)p[off + 13] << 8) |
                   ((uint32_t)p[off + 14] << 16) | ((uint32_t)p[off + 15] << 24);
            bits = (uint16_t)(p[off + 22] | (p[off + 23] << 8));
        }
        if (!memcmp(p + off, "data", 4)) {
            dataOff = off + 8;
            dataLen = MIN((NSUInteger)sz, d.length - dataOff);
            break;
        }
        off += 8 + sz + (sz & 1);
    }
    if (!dataOff || dataLen < 6400) return NO;
    if (ch != 1 || rate != 16000 || bits != 16) {
        CCLogf(@"LAB %@ bad wav ch=%u rate=%u bits=%u", _tag, ch, rate, bits);
        return NO;
    }
    _pcm = [d subdataWithRange:NSMakeRange(dataOff, dataLen & ~(NSUInteger)1)];
    return _pcm.length >= 6400;
}

- (void)start {
    if (_running) return;
    if (![self loadWav]) {
        CCLogf(@"LAB %@ no wav %@", _tag, _path.lastPathComponent);
        return;
    }
    _recog = [[SFSpeechRecognizer alloc] initWithLocale:
              [NSLocale localeWithLocaleIdentifier:_locale]];
    if (!_recog || !_recog.isAvailable) {
        CCLogf(@"LAB %@ recognizer unavailable locale=%@", _tag, _locale);
        return;
    }
    SFSpeechRecognizerAuthorizationStatus auth = [SFSpeechRecognizer authorizationStatus];
    BOOL od = _recog.supportsOnDeviceRecognition;
    CCLogf(@"LAB %@ start locale=%@ auth=%ld avail=%d supportOD=%d samples=%lu path=%@",
           _tag, _locale, (long)auth, _recog.isAvailable, od,
           (unsigned long)(_pcm.length / 2), _path.lastPathComponent);
    if (auth != SFSpeechRecognizerAuthorizationStatusAuthorized || !od) {
        CCLogf(@"LAB %@ abort auth=%ld supportOD=%d", _tag, (long)auth, od);
        return;
    }
    _running = YES;
    _startAt = CFAbsoluteTimeGetCurrent();
    _lastThermalLog = _startAt;
    dispatch_async(_q, ^{ [self startTask]; });
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    __weak CCLabSpeech *weakSelf = self;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              200 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)startTask {
    if (!_running || _ending || _task) return;
    SFSpeechAudioBufferRecognitionRequest *r =
        [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    r.shouldReportPartialResults = YES;
    if (@available(iOS 13.0, *)) {
        r.taskHint = SFSpeechRecognitionTaskHintDictation;
        r.requiresOnDeviceRecognition = YES;
    }
    if (@available(iOS 16.0, *)) r.addsPunctuation = YES;
    _req = r;
    _sessions++;
    __weak CCLabSpeech *weakSelf = self;
    __block SFSpeechRecognitionTask *t = nil;
    t = [_recog recognitionTaskWithRequest:r
        resultHandler:^(SFSpeechRecognitionResult *res, NSError *err) {
            dispatch_async(self->_q, ^{
                CCLabSpeech *s = weakSelf;
                if (!s || s->_task != t) return;
                CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                if (res) {
                    NSString *text = res.bestTranscription.formattedString ?: @"";
                    if (text.length && s->_firstPartialAt <= 0) {
                        s->_firstPartialAt = now;
                        s->_lastPartialLog = now;
                        CCLogf(@"LAB %@ first partial +%.2fs: %@",
                               s->_tag, now - s->_startAt, text);
                    } else if (!res.isFinal && now - s->_lastPartialLog >= 2.0) {
                        s->_lastPartialLog = now;
                        s->_partials++;
                        CCLogf(@"LAB %@ partial +%.1fs: %@",
                               s->_tag, now - s->_startAt, text);
                    }
                    if (res.isFinal) {
                        s->_finals++;
                        CCLogf(@"LAB %@ final +%.1fs session=%lu chars=%lu: %@",
                               s->_tag, now - s->_startAt,
                               (unsigned long)s->_sessions,
                               (unsigned long)text.length, text);
                        s->_task = nil;
                        s->_req = nil;
                        s->_restarting = YES;
                        if (s->_running && !s->_ending) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(0.3 * NSEC_PER_SEC)), s->_q, ^{
                                CCLabSpeech *s2 = weakSelf;
                                if (!s2 || !s2->_running || s2->_ending) return;
                                s2->_restarting = NO;
                                [s2 startTask];
                            });
                        }
                    }
                }
                if (err) {
                    s->_lastErr = err.code;
                    CCLogf(@"LAB %@ err %ld %@", s->_tag,
                           (long)err.code, err.localizedDescription ?: @"");
                    s->_task = nil;
                    s->_req = nil;
                    [s finish];
                }
            });
        }];
    _task = t;
    if (!_task) {
        CCLogf(@"LAB %@ task create failed", _tag);
        _req = nil;
    }
}

- (void)tick {
    if (!_running || _ending) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _startAt >= _duration) {
        [self finish];
        return;
    }
    if (now - _lastThermalLog >= 30.0) {
        _lastThermalLog = now;
        NSProcessInfo *pi = [NSProcessInfo processInfo];
        CCLogf(@"LAB %@ thermal=%ld lowpower=%d elapsed=%.0fs",
               _tag, (long)pi.thermalState, pi.isLowPowerModeEnabled ? 1 : 0,
               now - _startAt);
    }
    if (!_req || _restarting || !_pcm.length) return;
    if (_offset >= _pcm.length) {
        _offset = 0;
        _loops++;
        CCLogf(@"LAB %@ loop %lu", _tag, (unsigned long)_loops);
    }
    NSUInteger remain = _pcm.length - _offset;
    NSUInteger nBytes = MIN((NSUInteger)6400, remain) & ~(NSUInteger)1;
    if (nBytes < 2) return;
    const int16_t *s = (const int16_t *)((const uint8_t *)_pcm.bytes + _offset);
    NSUInteger n = nBytes / 2;
    AVAudioPCMBuffer *buf =
        [[AVAudioPCMBuffer alloc] initWithPCMFormat:CCLabFormat()
                                     frameCapacity:(AVAudioFrameCount)n];
    if (!buf) return;
    buf.frameLength = (AVAudioFrameCount)n;
    float *dst = buf.floatChannelData[0];
    for (NSUInteger i = 0; i < n; i++) {
        float v = (float)s[i] / 32768.0f;
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        dst[i] = v;
    }
    [_req appendAudioPCMBuffer:buf];
    _offset += nBytes;
}

- (void)finish {
    if (_ending) return;
    _ending = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    if (_req) [_req endAudio];
    __weak CCLabSpeech *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   _q, ^{
        CCLabSpeech *s = weakSelf;
        if (!s) return;
        CCLogf(@"LAB %@ done sessions=%lu finals=%lu partials=%lu first=%.2fs err=%ld loops=%lu",
               s->_tag, (unsigned long)s->_sessions, (unsigned long)s->_finals,
               (unsigned long)s->_partials,
               s->_firstPartialAt > 0 ? s->_firstPartialAt - s->_startAt : -1.0,
               (long)s->_lastErr, (unsigned long)s->_loops);
        [s->_task cancel];
        s->_task = nil;
        s->_req = nil;
        s->_running = NO;
    });
}

- (void)stop {
    if (!_running && !_task) return;
    _running = NO;
    _ending = YES;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    if (_req) [_req endAudio];
    [_task cancel];
    _task = nil;
    _req = nil;
}

@end

void CCLabSpeechStartFromMode(BOOL localSide) {
    @try {
        CCPrefsReload();
        NSString *mode = CCPrefStr(CC_K_LAB_MODE, @"");
        if (!mode.length) {
            CCLogf(@"LAB %@ no mode", localSide ? @"local" : @"remote");
            return;
        }
        BOOL run = [mode isEqualToString:@"dual"] ||
                   (localSide ? [mode isEqualToString:@"local"]
                              : [mode isEqualToString:@"remote"]);
        if (!run) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:CC_ARM_PATH] ||
            [fm fileExistsAtPath:CC_PREPARE_PATH]) {
            CCLogf(@"LAB %@ armed/prepared, abort",
                   localSide ? @"local" : @"remote");
            return;
        }
        static CCLabSpeech *g_lab;
        if (g_lab && [g_lab isRunning]) {
            CCLogf(@"LAB %@ already running", localSide ? @"local" : @"remote");
            return;
        }
        NSString *path = [CC_DIR stringByAppendingPathComponent:
                          localSide ? @"local16k.wav" : @"remote16k.wav"];
        if (![fm fileExistsAtPath:path]) {
            CCLogf(@"LAB %@ missing %@ (run before next call)",
                   localSide ? @"local" : @"remote", path.lastPathComponent);
            return;
        }
        g_lab = [[CCLabSpeech alloc] initWithTag:(localSide ? @"local" : @"remote")
                                          locale:(localSide ? @"zh-CN" : @"en-US")
                                            path:path
                                        duration:150.0];
        [g_lab start];
    } @catch (NSException *e) {
        CCLogf(@"LAB start exc %@", e.reason ?: @"?");
    }
}
