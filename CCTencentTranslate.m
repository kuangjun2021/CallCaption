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
                             NSString *appid, NSString *secretKey) {
    NSArray *keys = [[params allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:keys.count];
    for (NSString *k in keys)
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", CCPct(k), CCPct(params[k])]];
    NSString *query = [pairs componentsJoinedByString:@"&"];
    NSString *hostPath = [NSString stringWithFormat:
                          @"asr.cloud.tencent.com/asr/speech_translate/%@", appid];
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
    NSUInteger gen;
    int failures;
    CFAbsoluteTime lastPartialAt;
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
                       speed:(NSString *)pSpeed;
- (void)start;
- (void)stop;
@end

@implementation CCTencentSession

- (instancetype)initWithLocal:(BOOL)local
                        appid:(NSString *)pAppid
                     secretid:(NSString *)pSecretid
                     secretkey:(NSString *)pSecretkey
                       model:(NSString *)pModel
                   voiceType:(NSString *)pVoiceType
                      volume:(NSString *)pVolume
                       speed:(NSString *)pSpeed {
    if ((self = [super init])) {
        isLocal = local;
        tag = local ? @"local" : @"remote";
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
    p[@"source"] = source;
    p[@"target"] = target;
    p[@"trans_model"] = model;
    p[@"enable_tts"] = isLocal ? @"1" : @"0";
    p[@"codec"] = @"pcm";
    p[@"sample_rate"] = @"16000";
    p[@"vad_silence_time"] = @"1000";
    p[@"max_speak_time"] = @"10000";
    p[@"filter_punc"] = @"0";
    p[@"convert_num_mode"] = @"1";
    if (isLocal && voiceType.length) p[@"voice_type"] = voiceType;
    if (isLocal && volume.length) p[@"volume"] = volume;
    if (isLocal && speed.length) p[@"speed"] = speed;
    CCLogf(@"tencent %@ connect model=%@ source=%@ target=%@ voice=%@",
           tag, model, source, target, isLocal ? (voiceType ?: @"?" ) : @"-");
    return CCSignQuery(p, appid, secretkey);
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
            CCLogf(@"tencent %@ open code=0", tag);
            CCASendState(isLocal ? @"● 腾讯我方已连接" : @"● 腾讯对方已连接");
            [self startTimer];
        } else {
            NSString *m = obj[@"message"] ?: @"";
            CCLogf(@"tencent %@ handshake fail code=%ld %@", tag, (long)code, m);
            CCASendState([NSString stringWithFormat:@"● 腾讯%@连接失败(%ld)",
                          isLocal ? @"我方" : @"对方", (long)code]);
            [self fail:[NSString stringWithFormat:@"code %ld", (long)code]];
        }
        return;
    }

    if (code != 0) {
        NSString *m = obj[@"message"] ?: @"";
        CCLogf(@"tencent %@ err code=%ld %@", tag, (long)code, m);
        if (final == 1) [self fail:[NSString stringWithFormat:@"code %ld", (long)code]];
        return;
    }

    NSDictionary *res = obj[@"result"];
    if ([res isKindOfClass:[NSDictionary class]]) [self handleResult:res];

    if (final == 1 && !isLocal) {
        // 远程没有 TTS，final=1 表示整条流结束；通话中则重连。
        if (!ending) [self fail:@"stream final"];
    } else if (final == 2 && isLocal) {
        if (!ending) [self fail:@"stream final2"];
    }
}

- (void)handleResult:(NSDictionary *)res {
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
    if (!end && now - lastPartialAt < 0.25) return;
    if (!end) lastPartialAt = now;

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
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
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
    int16_t buf[3200];
    NSUInteger got = CCRingRead(isLocal ? &g_localRing : &g_remoteRing, buf, 3200);
    if (got < 3200) memset(buf + got, 0, (3200 - got) * sizeof(int16_t));
    NSData *d = [NSData dataWithBytes:buf length:sizeof(buf)];
    NSURLSessionWebSocketTask *t = task;
    NSURLSessionWebSocketMessage *m =
        [[NSURLSessionWebSocketMessage alloc] initWithData:d];
    __weak CCTencentSession *weakSelf = self;
    [t sendMessage:m completionHandler:^(NSError *e) {
        if (!e) return;
        dispatch_async(self->q, ^{
            CCTencentSession *s = weakSelf;
            if (!s || s->ending || s->task != t) return;
            [s fail:e.localizedDescription ?: @"send error"];
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
    if (!isLocal || !d.length) return;
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
        double delay = failures <= 1 ? 1.0 : (failures == 2 ? 3.0 : 5.0);
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
    if (isLocal) CCTencentResetUplinkMarker();
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
    atomic_store(&g_tcActive, 1);
    if (!g_sessions) g_sessions = [NSMutableArray array];

    NSString *remoteModel = CCPrefStr(CC_K_TC_REMOTE_MODEL, @"hunyuan-translation");
    if (![remoteModel isEqualToString:@"hunyuan-translation"])
        remoteModel = @"hunyuan-translation";   // lite 不支持 en->zh
    NSString *localModel = CCPrefStr(CC_K_TC_LOCAL_MODEL, @"hunyuan-translation-lite");
    NSString *localVoice = CCPrefStr(CC_K_TC_LOCAL_VOICE, @"501009");
    NSString *localVol = CCPrefStr(CC_K_TC_LOCAL_VOLUME, @"6");
    NSString *localSpeed = CCPrefStr(CC_K_TC_LOCAL_SPEED, @"0");

    if (remoteOn) {
        CCTencentSession *s = [[CCTencentSession alloc] initWithLocal:NO
            appid:appid secretid:sid secretkey:skey model:remoteModel
            voiceType:@"" volume:@"" speed:@""];
        [g_sessions addObject:s];
        dispatch_async(s->q, ^{ [s start]; });
    }
    if (localOn) {
        CCTencentSession *s = [[CCTencentSession alloc] initWithLocal:YES
            appid:appid secretid:sid secretkey:skey model:localModel
            voiceType:localVoice volume:localVol speed:localSpeed];
        [g_sessions addObject:s];
        dispatch_async(s->q, ^{ [s start]; });
    }
    CCLogf(@"tencent started remote=%d local=%d", remoteOn, localOn);
    CCASendState(@"● 腾讯翻译已启动");
}

void CCTencentStop(void) {
    if (!atomic_load(&g_tcActive)) return;
    atomic_store(&g_tcActive, 0);
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
    if (!atomic_load(&g_tcActive)) return;
    CCRingPush(&g_localRing, samples, count);
}
