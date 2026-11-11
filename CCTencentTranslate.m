// CCTencentTranslate.m — v0.19.1 方案 D+
// 两条腾讯实时语音翻译 WebSocket（守护进程内）：
//   remote: source=en, target=zh, trans_model=hunyuan-translation, enable_tts=0
//           -> I| 原文 / RP| 或 R| 译文（R| 触发 SpringBoard 0.19.0 中文 TTS 队列）
//   local : source=zh/zh_en, target=en, trans_model=lite, enable_tts=1
//           -> LI| 原文 / LRP|/LR| 译文 + 英文 TTS PCM
// PCM 16k -> 48k（3x 线性插值，内存完成）-> WhatsApp Documents/uplink_stream.pcm
#import "CCTencentTranslate.h"
#import "CCCommon.h"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

// ---------- 16k s16 单生产者/单消费者环形缓冲 ----------
typedef struct {
    int16_t *buf;
    uint32_t cap;              // samples
    _Atomic(uint32_t) head;
    _Atomic(uint32_t) tail;
} CCTCRing;

static CCTCRing g_remoteRing;
static CCTCRing g_localRing;
static _Atomic(int) g_tcActive;
static _Atomic(int) g_tcLocalOn;   // 混合模式下 local 走 SFSpeech，不再推 local ring
static NSMutableArray *g_sessions;
static dispatch_queue_t g_tcTransportQ;
static dispatch_queue_t g_tcStartQ;

static void CCRingInit(CCTCRing *r, uint32_t cap) {
    if (r->buf) return;
    r->buf = calloc(cap, sizeof(int16_t));
    r->cap = r->buf ? cap : 0;
    atomic_store(&r->head, 0);
    atomic_store(&r->tail, 0);
}

static void CCRingClear(CCTCRing *r) {
    if (!r->buf) return;
    uint32_t h = atomic_load(&r->head);
    atomic_store(&r->tail, h);
}

static void CCRingPush(CCTCRing *r, const int16_t *s, NSUInteger n) {
    if (!r->buf || !s || !n || !r->cap) return;
    uint32_t head = atomic_load(&r->head);
    uint32_t tail = atomic_load(&r->tail);
    uint32_t used = head - tail;
    uint32_t space = r->cap - used;
    if (n > space) n = space;          // 满了只为音频流丢新样本，WAV 不受影响
    if (!n) return;
    for (NSUInteger i = 0; i < n; i++) r->buf[(head + (uint32_t)i) % r->cap] = s[i];
    atomic_store(&r->head, head + (uint32_t)n);
}

static uint32_t CCRingUsed(CCTCRing *r) {
    if (!r->buf) return 0;
    return atomic_load(&r->head) - atomic_load(&r->tail);
}

static NSUInteger CCRingRead(CCTCRing *r, int16_t *dst, NSUInteger max) {
    if (!r->buf || !dst || !max || !r->cap) return 0;
    uint32_t head = atomic_load(&r->head);
    uint32_t tail = atomic_load(&r->tail);
    uint32_t avail = head - tail;
    if (!avail) return 0;
    NSUInteger n = MIN((uint32_t)max, avail);
    for (NSUInteger i = 0; i < n; i++) dst[i] = r->buf[(tail + (uint32_t)i) % r->cap];
    atomic_store(&r->tail, tail + (uint32_t)n);
    return n;
}

// ---------- 字符串/签名 ----------
static NSString *CCPct(NSString *s) {
    static NSCharacterSet *ok;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = [NSCharacterSet characterSetWithCharactersInString:
              @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:ok] ?: @"";
}

static NSString *CCSignQuery(NSDictionary<NSString *, NSString *> *params,
                             NSString *appid, NSString *secretKey,
                             NSString *pathTemplate) {
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *k in keys)
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", CCPct(k), CCPct(params[k])]];
    NSString *query = [pairs componentsJoinedByString:@"&"];
    NSString *hostPath = [NSString stringWithFormat:pathTemplate, appid];
    NSString *src = [NSString stringWithFormat:@"%@?%@", hostPath, query];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA1,
           secretKey.UTF8String, secretKey.length,
           src.UTF8String, src.length,
           digest);
    NSData *d = [NSData dataWithBytes:digest length:sizeof(digest)];
    NSString *sig = [d base64EncodedStringWithOptions:0];
    return [NSString stringWithFormat:@"wss://%@?%@&signature=%@",
            hostPath, query, CCPct(sig)];
}

static void CCASendLine(NSString *line) {
    if (!line.length) return;
    if (!g_tcTransportQ) {
        g_tcTransportQ = dispatch_queue_create("callcaption.tc.transport",
                                               DISPATCH_QUEUE_SERIAL);
    }
    dispatch_async(g_tcTransportQ, ^{
        @try { CCTransportSendLine(line); } @catch (NSException *e) { }
    });
}

static void CCASendState(NSString *text) {
    CCASendLine([@"S|" stringByAppendingString:text]);
}

// v0.19.2：断句参数从设置读取并夹到腾讯允许的范围。
static NSString *CCVadSilence(void) {
    NSInteger v = [CCPrefStr(CC_K_TC_VAD_SILENCE, @"600") integerValue];
    if (v < 500) v = 500;
    if (v > 2000) v = 2000;
    return [NSString stringWithFormat:@"%ld", (long)v];
}

static NSString *CCMaxSpeak(void) {
    NSInteger v = [CCPrefStr(CC_K_TC_MAX_SPEAK, @"6000") integerValue];
    if (v < 5000) v = 5000;
    if (v > 90000) v = 90000;
    return [NSString stringWithFormat:@"%ld", (long)v];
}

static void CCTencentResetUplinkMarker(void) {
    @try {
        NSString *docs = CCFindWhatsAppDocs();
        if (!docs.length) return;
        NSString *p = [docs stringByAppendingPathComponent:@"uplink_reset"];
        [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod(p.fileSystemRepresentation, 0666);
    } @catch (NSException *e) { }
}

// ---------- 单个方向 ----------
@interface CCTencentSession : NSObject {
@public
    BOOL isLocal;
    NSString *tag;
    NSString *appid, *secretid, *secretkey;
    NSString *source, *target, *model, *voiceType;
    NSString *volume, *speed;
    NSURLSession *sess;
    NSURLSessionWebSocketTask *task;
    dispatch_queue_t q;
    dispatch_source_t timer;
    BOOL running;
    BOOL ending;
    BOOL connected;
    BOOL tencentTTS;                 // v0.19.2：我方英文播报是否用腾讯 TTS
    BOOL liteRetried;                // v0.19.5：lite 6001 先原样重试一次
    BOOL asrMode;                    // v0.20.0 B1：腾讯实时 ASR（不翻译）
    int sampleRate;                  // v0.19.7：16000 / 8000
    NSUInteger gen;
    int failures;
    CFAbsoluteTime lastPartialAt;
    CFAbsoluteTime lastBacklogLog;
    CFAbsoluteTime lrAt;             // v0.19.2：LR| 时刻，量首包 TTS 延迟
    CFAbsoluteTime lastTextAt;       // v0.19.6：最近一次文本结果
    int sentReal;                    // v0.19.6：连续发送的真实音频包数（5/s）
    _Atomic(int) inFlight;           // v0.19.6：未完成的 WS 发送数
    double nextRetryDelay;           // v0.19.3：6001 时快速重连
    NSString *lastPartialSrc;
    NSString *lastPartialTgt;
    NSString *lastASRFinal;          // v0.20.0 B1：同一句 final 只发一次
    NSInteger lastASRIndex;          // v0.20.0 B1：ASR 句序号
    NSMutableData *audioPending;
    FILE *uplinkFp;
    NSString *uplinkPath;
}
- (instancetype)initWithLocal:(BOOL)local
                        appid:(NSString *)pAppid
                     secretid:(NSString *)pSecretid
                     secretkey:(NSString *)pSecretkey
                       model:(NSString *)pModel
                   voiceType:(NSString *)pVoiceType
                      volume:(NSString *)pVolume
                       speed:(NSString *)pSpeed
                  tencentTTS:(BOOL)pTencentTTS
                     asrMode:(BOOL)pAsrMode;
- (void)start;
- (void)stop;
- (void)handleASRResult:(NSDictionary *)res;
@end

@implementation CCTencentSession

- (instancetype)initWithLocal:(BOOL)local
                        appid:(NSString *)pAppid
                     secretid:(NSString *)pSecretid
                     secretkey:(NSString *)pSecretkey
                       model:(NSString *)pModel
                   voiceType:(NSString *)pVoiceType
                      volume:(NSString *)pVolume
                       speed:(NSString *)pSpeed
                  tencentTTS:(BOOL)pTencentTTS
                     asrMode:(BOOL)pAsrMode {
    if ((self = [super init])) {
        isLocal = local;
        tencentTTS = local && pTencentTTS;
        asrMode = pAsrMode;
        sampleRate = 16000;   // B1 ASR 只支持 16k
        tag = local ? @"local" : @"remote";
        lastASRIndex = -1;
        self->appid = [pAppid copy];
        self->secretid = [pSecretid copy];
        self->secretkey = [pSecretkey copy];
        self->model = [pModel copy];
        self->voiceType = [pVoiceType copy];
        self->volume = [pVolume copy];
        self->speed = [pSpeed copy];
        self->source = local ? [CCPrefStr(CC_K_TC_LOCAL_SOURCE, @"zh") copy] : @"en";
        self->target = local ? @"en" : @"zh";
        q = dispatch_queue_create(local ? "callcaption.tc.local"
                                        : "callcaption.tc.remote",
                                  DISPATCH_QUEUE_SERIAL);
        audioPending = [NSMutableData data];
    }
    return self;
}

- (NSString *)urlString {
    NSString *ts = [NSString stringWithFormat:@"%lld",
                    (long long)[[NSDate date] timeIntervalSince1970]];
    NSString *exp = [NSString stringWithFormat:@"%lld",
                     (long long)[[NSDate date] timeIntervalSince1970] + 3600];
    NSString *nonce = [NSString stringWithFormat:@"%u",
                       1 + arc4random_uniform(999999999)];
    NSString *vid = [[NSUUID UUID].UUIDString lowercaseString];
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"secretid"] = secretid ?: @"";
    p[@"timestamp"] = ts;
    p[@"expired"] = exp;
    p[@"nonce"] = nonce;
    p[@"voice_id"] = vid;
    p[@"voice_format"] = @"1";
    if (asrMode) {
        // v0.20.0 B1：腾讯实时 ASR（只识别，不翻译）
        p[@"engine_model_type"] = model;   // 16k_en / 16k_zh
        p[@"needvad"] = @"1";
        p[@"vad_silence_time"] = CCVadSilence();
        p[@"max_speak_time"] = CCMaxSpeak();
        p[@"filter_punc"] = @"0";
        p[@"convert_num_mode"] = @"1";
        CCLogf(@"tencent asr %@ connect engine=%@ source=%@ target=%@ vad=%@ maxsp=%@",
               tag, model, source, target,
               p[@"vad_silence_time"], p[@"max_speak_time"]);
        return CCSignQuery(p, appid, secretkey,
                           @"asr.cloud.tencent.com/asr/v2/%@");
    }
    p[@"source"] = source;
    p[@"target"] = target;
    p[@"trans_model"] = model;
    p[@"enable_tts"] = tencentTTS ? @"1" : @"0";
    p[@"codec"] = @"pcm";
    p[@"sample_rate"] = sampleRate == 8000 ? @"8000" : @"16000";
    p[@"vad_silence_time"] = CCVadSilence();
    p[@"max_speak_time"] = CCMaxSpeak();
    p[@"filter_punc"] = @"0";
    p[@"convert_num_mode"] = @"1";
    if (tencentTTS) {
        if (voiceType.length) p[@"voice_type"] = voiceType;
        if (volume.length) p[@"volume"] = volume;
        if (speed.length) p[@"speed"] = speed;
    }
    CCLogf(@"tencent %@ connect model=%@ source=%@ target=%@ tts=%@ voice=%@ vad=%@ maxsp=%@ rate=%d",
           tag, model, source, target, tencentTTS ? @"tencent" : @"off",
           tencentTTS ? (voiceType ?: @"?") : @"-",
           p[@"vad_silence_time"], p[@"max_speak_time"], sampleRate);
    return CCSignQuery(p, appid, secretkey,
                       @"asr.cloud.tencent.com/asr/speech_translate/%@");
}

- (void)start {
    if (task || ending) return;
    running = YES;
    connected = NO;
    failures = 0;
    gen++;
    NSUInteger g = gen;
    if (!appid.length || !secretid.length || !secretkey.length) {
        CCLogf(@"tencent %@ missing key", tag);
        CCASendState(isLocal ? @"● 腾讯我方缺少 AppID/Key"
                             : @"● 腾讯对方缺少 AppID/Key");
        running = NO;
        return;
    }
    NSString *u = [self urlString];
    NSURL *url = [NSURL URLWithString:u];
    if (!url) {
        CCLogf(@"tencent %@ bad url", tag);
        [self scheduleRetry:3.0];
        return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15.0;
    cfg.timeoutIntervalForResource = 3600.0;
    sess = [NSURLSession sessionWithConfiguration:cfg];
    task = [sess webSocketTaskWithURL:url];
    [task resume];
    CCLogf(@"tencent %@ opened", tag);
    [self receiveNext];
    __weak CCTencentSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   q, ^{
        CCTencentSession *s = weakSelf;
        if (!s || s->gen != g || s->ending) return;
        if (!s->connected) {
            CCLogf(@"tencent %@ handshake timeout", s->tag);
            [s fail:@"handshake timeout"];
        }
    });
}

- (void)receiveNext {
    if (!running || ending || !task) return;
    NSURLSessionWebSocketTask *t = task;
    __weak CCTencentSession *weakSelf = self;
    [t receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        dispatch_async(self->q, ^{
            CCTencentSession *s = weakSelf;
            if (!s || s->ending || s->task != t) return;
            if (err) { [s fail:err.localizedDescription ?: @"recv error"]; return; }
            [s handleMessage:msg];
            if (s->task == t && !s->ending) [s receiveNext];
        });
    }];
}

- (void)handleMessage:(NSURLSessionWebSocketMessage *)msg {
    if (!msg) return;
    if (msg.type == NSURLSessionWebSocketMessageTypeData) {
        if (isLocal && msg.data.length) [self handleAudio:msg.data];
        return;
    }
    NSString *str = msg.string;
    if (!str.length) return;
    NSData *d = [str dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return;

    NSInteger code = [obj[@"code"] integerValue];
    NSInteger final = [obj[@"final"] integerValue];

    if (!connected) {
        if (code == 0) {
            connected = YES;
            failures = 0;
            // v0.19.2：握手期间 ring 会积压 0.5~1.5 秒音频，而腾讯要求严格
            // 1:1 发送、不能加速追回；这里直接清空，从“现在”开始，避免整通
            // 电话都带着固定延迟。开头不到 1 秒的音频会被丢掉。
            CCRingClear(isLocal ? &g_localRing : &g_remoteRing);
            lastPartialSrc = nil;
            lastPartialTgt = nil;
            lrAt = 0;
            lastTextAt = CFAbsoluteTimeGetCurrent();
            sentReal = 0;
            atomic_store(&inFlight, 0);
            CCLogf(@"tencent %@ open code=0 (ring cleared)", tag);
            CCASendState(isLocal ? @"● 腾讯我方已连接" : @"● 腾讯对方已连接");
            [self startTimer];
        } else {
            NSString *m = obj[@"message"] ?: @"";
            CCLogf(@"tencent %@ handshake fail code=%ld %@", tag, (long)code, m);
            // v0.19.3：我方 lite 模型偶尔首连返回 6001“not support this
            // trans model”，同一参数重连又成功（0.19.1/0.19.2 实测均出现）。
            // 直接回退标准版并 0.3 秒快速重连，避免开头 3~5 秒空白。
            if (isLocal && code == 6001 &&
                [model isEqualToString:@"hunyuan-translation-lite"]) {
                // v0.19.5：0.19.2 实测 lite 重连一次就能成功；0.19.3 直接
                // 切 standard 可能把 zh→en 的流式效果拖坏。先原样重试 lite，
                // 第二次还 6001 才回退 standard。
                if (!liteRetried) {
                    liteRetried = YES;
                    nextRetryDelay = 0.3;
                    CCLogf(@"tencent local lite 6001, retry lite");
                } else {
                    model = @"hunyuan-translation";
                    nextRetryDelay = 0.3;
                    CCLogf(@"tencent local lite 6001 again, fallback standard");
                }
            }
            CCASendState([NSString stringWithFormat:@"● 腾讯%@连接失败(%ld)",
                          isLocal ? @"我方" : @"对方", (long)code]);
            [self fail:[NSString stringWithFormat:@"code %ld", (long)code]];
        }
        return;
    }

    if (code != 0) {
        NSString *m = obj[@"message"] ?: @"";
        CCLogf(@"tencent %@ err code=%ld %@", tag, (long)code, m);
        if (asrMode || final == 1)
            [self fail:[NSString stringWithFormat:@"code %ld", (long)code]];
        return;
    }

    NSDictionary *res = obj[@"result"];
    if (asrMode) {
        if ([res isKindOfClass:[NSDictionary class]]) [self handleASRResult:res];
        if (final == 1 && !ending) [self fail:@"stream final"];
        return;
    }
    if ([res isKindOfClass:[NSDictionary class]]) [self handleResult:res];

    if (final == 1 && (!isLocal || !tencentTTS)) {
        // 没有腾讯 TTS 时，final=1 表示整条流结束；通话中则重连。
        if (!ending) [self fail:@"stream final"];
    } else if (final == 2 && isLocal && tencentTTS) {
        if (!ending) [self fail:@"stream final2"];
    }
}

- (void)handleASRResult:(NSDictionary *)res {
    if (ending || !atomic_load(&g_tcActive)) return;
    NSInteger slice = [res[@"slice_type"] integerValue];
    NSString *text = [res[@"voice_text_str"] isKindOfClass:[NSString class]]
                     ? res[@"voice_text_str"] : @"";
    text = [text stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) {
        // 少数情况下 final 帧不带 text，用上一帧的原文兜底
        if (slice == 2 && lastPartialSrc.length) text = lastPartialSrc;
        else return;
    }

    NSInteger idx = [res[@"index"] integerValue];
    if (idx != lastASRIndex) {
        lastASRIndex = idx;
        lastASRFinal = nil;
    }

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    lastTextAt = now;
    sentReal = 0;

    if (slice == 2) {
        // 稳态最终句：只翻这一次，避免“碎片翻译 + 再总结”。
        if (lastASRFinal && [text isEqualToString:lastASRFinal]) return;
        lastASRFinal = [text copy];
        lastPartialSrc = nil;
        lastPartialTgt = nil;
        CCLogf(@"tencent asr %@ final: %@", tag,
               text.length > 60 ? [text substringToIndex:60] : text);
        CCASendLine([(isLocal ? @"LI|" : @"I|") stringByAppendingString:text]);
        // 最终翻译请求交给 SpringBoard：来电 Google、去电 DeepL
        CCASendLine([(isLocal ? @"LQ|" : @"RQ|") stringByAppendingString:text]);
        return;
    }

    // 非稳态只更新识别原文，不做翻译、不出 TTS。
    if (now - lastPartialAt < 0.15) return;
    lastPartialAt = now;
    if (lastPartialSrc && [text isEqualToString:lastPartialSrc]) return;
    lastPartialSrc = [text copy];
    lastPartialTgt = nil;
    CCASendLine([(isLocal ? @"LI|" : @"I|") stringByAppendingString:text]);
}

- (void)handleResult:(NSDictionary *)res {
    // v0.19.8：通话已结束/已 disarm，迟到的 WS 结果直接丢弃，
    // 不再写 spool，避免下一通接通时蹦出上一轮字幕。
    if (ending || !atomic_load(&g_tcActive)) return;
    NSString *src = [res[@"source_text"] isKindOfClass:[NSString class]]
                    ? res[@"source_text"] : @"";
    NSString *tgt = [res[@"target_text"] isKindOfClass:[NSString class]]
                    ? res[@"target_text"] : @"";
    src = [src stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    tgt = [tgt stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!src.length && !tgt.length) return;
    BOOL end = [res[@"sentence_end"] boolValue];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // v0.19.6：只要腾讯回了文本，就说明服务端没积压，重置延迟看门狗。
    lastTextAt = now;
    sentReal = 0;
    // v0.19.2：partial 节流 0.25→0.15 秒，并跳过连续完全相同的文本。
    // 腾讯会把同一 partial 每 200ms 重发一次，不去重会看到字幕“卡住”。
    if (!end && now - lastPartialAt < 0.15) return;
    if (!end) lastPartialAt = now;
    if (!end && lastPartialSrc && [src isEqualToString:lastPartialSrc] &&
        [tgt isEqualToString:lastPartialTgt]) return;
    if (end) {
        lastPartialSrc = nil;
        lastPartialTgt = nil;
    } else {
        lastPartialSrc = [src copy];
        lastPartialTgt = [tgt copy];
    }

    if (!isLocal) {
        if (src.length) CCASendLine([@"I|" stringByAppendingString:src]);
        if (!tgt.length) return;
        if (!end) {
            CCASendLine([@"RP|" stringByAppendingString:tgt]);
            return;
        }
        // 语气词/极短句只上字幕，不触发 TTS
        NSString *low = [[src lowercaseString] stringByTrimmingCharactersInSet:
                         [NSCharacterSet punctuationCharacterSet]];
        NSSet *fillers = [NSSet setWithObjects:
                          @"hmm", @"um", @"uh", @"er", @"ah", @"oh", @"huh", @"mm", nil];
        BOOL filler = (low.length <= 2) || [fillers containsObject:low] || (tgt.length <= 1);
        CCASendLine([(filler ? @"RP|" : @"R|") stringByAppendingString:tgt]);
    } else {
        if (src.length) CCASendLine([@"LI|" stringByAppendingString:src]);
        if (!tgt.length) return;
        if (end) {
            lrAt = now;   // v0.19.2：量 LR| 之后多久收到首包英文 TTS
            CCASendLine([@"LR|" stringByAppendingString:tgt]);
            CCASendLine(@"LE|tencent");
        } else {
            CCASendLine([@"LRP|" stringByAppendingString:tgt]);
        }
    }
}

- (void)startTimer {
    if (timer) return;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    if (!timer) return;
    __weak CCTencentSession *weakSelf = self;
    // v0.19.7：两条 WS 错开 100ms 发送，避免每 200ms 同时灌两包，
    // 双开时上行突发减半。
    uint64_t first = isLocal ? 100 * NSEC_PER_MSEC : 0;
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, first),
                              200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        CCTencentSession *s = weakSelf;
        if (!s) return;
        [s sendTick];
    });
    dispatch_resume(timer);
}

- (void)sendTick {
    if (!connected || ending || !task) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastBacklogLog >= 5.0) {
        lastBacklogLog = now;
        CCLogf(@"tencent %@ backlog=%ums inflight=%d sentReal=%d noText=%.1fs",
               tag, (unsigned)(CCRingUsed(isLocal ? &g_localRing : &g_remoteRing) / 16),
               atomic_load(&inFlight), sentReal,
               lastTextAt > 0 ? now - lastTextAt : 0);
    }
    // v0.20.0 B1：ASR 只允许一个发送在途，避免服务端慢时把几十秒音频
    // 排进 socket，恢复时突发触发 4000/6000。慢的时候 ring 会积压。
    if (asrMode && atomic_load(&inFlight) > 0) return;
    // v0.19.8：看门狗改成“只记录、不重连”，并且只统计真正的语音包。
    // 0.19.6/0.19.7 的 12 秒重连会把上一通/本条流的内容直接丢掉；
    // 用户明确要求“不能漏掉通话内容”，所以这里不再自动 reconnect。
    // 队列/服务端慢只写日志，由人决定是否挂断或改设置。
    int16_t buf[3200];
    NSUInteger got = CCRingRead(isLocal ? &g_localRing : &g_remoteRing, buf, 3200);
    if (got < 3200) memset(buf + got, 0, (3200 - got) * sizeof(int16_t));
    double absSum = 0;
    for (NSUInteger i = 0; i < 3200; i++) {
        int16_t v = buf[i];
        absSum += (double)(v < 0 ? -v : v);
    }
    double pktRms = absSum / 3200.0 / 32768.0;
    // 只有明显高于底噪的包才算“真实语音”；静音/底噪把计数清零。
    // 这样不会再出现“安静 12 秒也被看成 12 秒语音”的误判。
    if (got > 0 && pktRms > 0.004) sentReal++; else sentReal = 0;
    NSData *d = nil;
    if (sampleRate == 8000) {
        // v0.19.7：ring 仍是 16k；发 8k 时每 200ms 取 3200 个 16k 样本，
        // 两两平均成 1600 个 8k 样本（3200 字节），双开时总带宽减半。
        int16_t out[1600];
        for (NSUInteger i = 0; i < 1600; i++)
            out[i] = (int16_t)(((int)buf[2 * i] + (int)buf[2 * i + 1]) / 2);
        d = [NSData dataWithBytes:out length:sizeof(out)];
    } else {
        d = [NSData dataWithBytes:buf length:sizeof(buf)];
    }
    NSURLSessionWebSocketTask *t = task;
    NSURLSessionWebSocketMessage *m =
        [[NSURLSessionWebSocketMessage alloc] initWithData:d];
    CFAbsoluteTime sendAt = CFAbsoluteTimeGetCurrent();
    atomic_fetch_add(&inFlight, 1);
    __weak CCTencentSession *weakSelf = self;
    [t sendMessage:m completionHandler:^(NSError *e) {
        atomic_fetch_sub(&self->inFlight, 1);
        double lag = CFAbsoluteTimeGetCurrent() - sendAt;
        __weak CCTencentSession *ws = weakSelf;
        dispatch_async(self->q, ^{
            CCTencentSession *s = ws;
            if (!s || s->ending || s->task != t) return;
            if (lag > 2.0)
                CCLogf(@"tencent %@ send lag %.1fs inflight=%d", s->tag, lag,
                       atomic_load(&s->inFlight));
            if (e) [s fail:e.localizedDescription ?: @"send error"];
        });
    }];
}

- (BOOL)ensureUplink {
    if (uplinkFp) return YES;
    NSString *docs = CCFindWhatsAppDocs();
    if (!docs.length) return NO;
    uplinkPath = [docs stringByAppendingPathComponent:@"uplink_stream.pcm"];
    uplinkFp = fopen(uplinkPath.fileSystemRepresentation, "wb");
    if (!uplinkFp) return NO;
    chmod(uplinkPath.fileSystemRepresentation, 0666);
    CCTencentResetUplinkMarker();
    CCLogf(@"tencent local uplink stream opened");
    return YES;
}

- (void)handleAudio:(NSData *)d {
    if (ending || !atomic_load(&g_tcActive)) return;
    if (!isLocal || !tencentTTS || !d.length) return;
    if (lrAt > 0) {
        CCLogf(@"tencent local LR->pcm %.2fs (%lu bytes)",
               CFAbsoluteTimeGetCurrent() - lrAt, (unsigned long)d.length);
        lrAt = 0;
    }
    [audioPending appendData:d];
    NSUInteger n = audioPending.length / 2;
    if (!n) return;
    if (![self ensureUplink]) return;

    const int16_t *s = (const int16_t *)audioPending.bytes;
    NSUInteger outN = n * 3;
    int16_t *out = malloc(outN * sizeof(int16_t));
    if (!out) return;
    for (NSUInteger i = 0; i < n; i++) {
        int a = s[i];
        int b = s[i + 1 < n ? i + 1 : i];
        out[i * 3 + 0] = (int16_t)a;
        out[i * 3 + 1] = (int16_t)((a * 2 + b) / 3);
        out[i * 3 + 2] = (int16_t)((a + b * 2) / 3);
    }
    fwrite(out, sizeof(int16_t), outN, uplinkFp);
    fflush(uplinkFp);
    free(out);

    NSUInteger even = audioPending.length & ~(NSUInteger)1;
    if (even >= audioPending.length) {
        [audioPending setLength:0];
    } else {
        NSData *tail = [audioPending subdataWithRange:
                        NSMakeRange(even, audioPending.length - even)];
        audioPending = [tail mutableCopy];
    }
}

- (void)scheduleRetry:(double)delay {
    NSUInteger g = gen;
    __weak CCTencentSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   q, ^{
        CCTencentSession *s = weakSelf;
        if (!s || !s->running || s->ending || s->gen != g) return;
        [s start];
    });
}

- (void)fail:(NSString *)why {
    if (ending) return;
    if (!running) return;
    failures++;
    CCLogf(@"tencent %@ failed: %@ (failures=%d)", tag, why ?: @"?", failures);
    [self closeSocket];
    if (!ending) {
        double delay = nextRetryDelay > 0
                     ? nextRetryDelay
                     : (failures <= 1 ? 1.0 : (failures == 2 ? 3.0 : 5.0));
        nextRetryDelay = 0;
        [self scheduleRetry:delay];
    }
}

- (void)closeSocket {
    if (timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
    connected = NO;
    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    task = nil;
    [sess invalidateAndCancel];
    sess = nil;
    CCRingClear(isLocal ? &g_localRing : &g_remoteRing);
}

- (void)stop {
    if (!running && !task) return;
    ending = YES;
    running = NO;
    gen++;
    CCLogf(@"tencent %@ stop", tag);
    if (task && connected) {
        NSURLSessionWebSocketMessage *m =
            [[NSURLSessionWebSocketMessage alloc] initWithString:@"{\"type\":\"end\"}"];
        [task sendMessage:m completionHandler:^(NSError *e) { }];
    }
    [self closeSocket];
    if (uplinkFp) {
        fclose(uplinkFp);
        uplinkFp = NULL;
    }
    if (isLocal) {
        lrAt = 0;
        // v0.19.2：挂断清掉整段上行 PCM，避免下次 reset 时 AppProbe 把旧文件
        // 重新装进 ring（0.19.1 实测一次 reload 869931 samples = 18.1 秒）。
        if (uplinkPath.length) {
            [[NSFileManager defaultManager] removeItemAtPath:uplinkPath error:nil];
            CCLogf(@"tencent local uplink pcm removed");
        }
        CCTencentResetUplinkMarker();
    }
}

@end

// ---------- 生命周期 ----------
void CCTencentStart(void) {
    if (atomic_load(&g_tcActive)) return;
    CCPrefsReload();
    if (!CCPrefBool(CC_K_TC_ENABLED, NO)) return;
    NSString *appid = CCPrefStr(CC_K_TC_APPID, @"");
    NSString *sid = CCPrefStr(CC_K_TC_SECRETID, @"");
    NSString *skey = CCPrefStr(CC_K_TC_SECRETKEY, @"");
    if (!appid.length || !sid.length || !skey.length) {
        CCLogf(@"tencent missing AppID/SecretId/SecretKey");
        CCASendState(@"● 腾讯翻译缺少 AppID/Secret/Key");
        return;
    }
    BOOL remoteOn = CCPrefBool(CC_K_REMOTE_ENABLED, YES);
    BOOL localOn = CCPrefBool(CC_K_LOCAL_ENABLED, YES);
    if (!remoteOn && !localOn) return;

    CCRingInit(&g_remoteRing, 16000 * 10);
    CCRingInit(&g_localRing, 16000 * 10);
    CCRingClear(&g_remoteRing);
    CCRingClear(&g_localRing);
    atomic_store(&g_tcLocalOn, localOn ? 1 : 0);
    atomic_store(&g_tcActive, 1);
    if (!g_sessions) g_sessions = [NSMutableArray array];

    // v0.20.0 B1：腾讯只做实时 ASR，翻译交给 SpringBoard（来电 Google / 去电 DeepL）。
    NSString *remoteModel = @"16k_en";
    NSString *localModel = @"16k_zh";

    if (remoteOn) {
        CCTencentSession *s = [[CCTencentSession alloc] initWithLocal:NO
            appid:appid secretid:sid secretkey:skey model:remoteModel
            voiceType:@"" volume:@"" speed:@"" tencentTTS:NO asrMode:YES];
        [g_sessions addObject:s];
        dispatch_async(s->q, ^{ [s start]; });
    }
    if (localOn) {
        CCTencentSession *s = [[CCTencentSession alloc] initWithLocal:YES
            appid:appid secretid:sid secretkey:skey model:localModel
            voiceType:@"" volume:@"" speed:@"" tencentTTS:NO asrMode:YES];
        [g_sessions addObject:s];
        dispatch_async(s->q, ^{ [s start]; });
    }
    CCLogf(@"tencent asr started remote=%d local=%d", remoteOn, localOn);
    CCASendState(@"● 腾讯 ASR 已启动");
}

void CCTencentStop(void) {
    if (!atomic_load(&g_tcActive)) return;
    atomic_store(&g_tcActive, 0);
    atomic_store(&g_tcLocalOn, 0);
    for (CCTencentSession *s in [g_sessions copy])
        dispatch_async(s->q, ^{ [s stop]; });
    [g_sessions removeAllObjects];
    CCRingClear(&g_remoteRing);
    CCRingClear(&g_localRing);
    CCLogf(@"tencent stopped");
    CCASendState(@"● 腾讯翻译已停止");
}

BOOL CCTencentIsActive(void) {
    return atomic_load(&g_tcActive) != 0;
}

void CCTencentPushRemote(const int16_t *samples, NSUInteger count) {
    if (!atomic_load(&g_tcActive)) return;
    CCRingPush(&g_remoteRing, samples, count);
}

void CCTencentPushLocal(const int16_t *samples, NSUInteger count) {
    if (!atomic_load(&g_tcActive) || !atomic_load(&g_tcLocalOn)) return;
    CCRingPush(&g_localRing, samples, count);
}
