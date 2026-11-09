// CCAssistant.m — Stage A: assistantd 内本地 Siri 识别器验证
//
// 目标（不是最终产品）：
//   1) 证明 iOS 16.4 的 assistantd 里可以创建 SiriCoreLocalSpeechRecognizer；
//   2) 证明可以把 remote16k.wav 的 16k PCM 喂进去；
//   3) 记录 partial（didRecognizeTokens）与 completion（didCompletionRecognition…）
//      以及错误码，判断本地 Siri 端点是否可用。
//
// 只在 CallCaption 的 armed 文件存在（通话中）时启动；不碰 Siri 正常流程。
// 日志：/var/mobile/Library/CallCaption/assistant.log（失败则 /tmp/ccassistant.log）
//
// 注意：全部私有 API 通过 NSClassFromString + NSInvocation 动态调用，
// 编译期不链接 SiriCore/AssistantServices，避免任何符号依赖。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdio.h>
#import <unistd.h>
#import <sys/stat.h>
#import <uuid/uuid.h>

#define CC_ASSIST_DIR  @"/var/mobile/Library/CallCaption"
#define CC_ASSIST_LOG  @"/var/mobile/Library/CallCaption/assistant.log"
#define CC_ASSIST_FALLBACK @"/tmp/ccassistant.log"
#define CC_ASSIST_ARM  @"/var/mobile/Library/CallCaption/armed"
#define CC_ASSIST_WAV  @"/var/mobile/Library/CallCaption/remote16k.wav"

static void CCLogA(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"MM-dd HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        const char *paths[2] = {
            CC_ASSIST_LOG.fileSystemRepresentation,
            CC_ASSIST_FALLBACK.fileSystemRepresentation
        };
        for (int i = 0; i < 2; i++) {
            FILE *fp = fopen(paths[i], "a");
            if (!fp) continue;
            fputs(line.UTF8String, fp);
            fclose(fp);
            chmod(paths[i], 0666);
        }
    }
}

// ---------- 文本提取（AFSpeechToken / AFSpeechRecognition / AFSpeechPackage） ----------
static NSString *CCTextFromObject(id o) {
    if (!o) return nil;
    @try {
        if ([o isKindOfClass:[NSString class]]) return o;
        id v = nil;
        for (NSString *k in @[@"formattedString", @"text"]) {
            v = [o valueForKey:k];
            if ([v isKindOfClass:[NSString class]] && [v length]) return v;
        }
        v = [o valueForKey:@"bestTranscription"];
        if (v) {
            NSString *s = CCTextFromObject(v);
            if (s.length) return s;
        }
        v = [o valueForKey:@"recognition"];
        if (v) {
            NSString *s = CCTextFromObject(v);
            if (s.length) return s;
        }
        v = [o valueForKey:@"tokens"];
        if ([v isKindOfClass:[NSArray class]]) {
            NSMutableString *ms = [NSMutableString string];
            for (id t in v) {
                NSString *s = CCTextFromObject(t);
                if (s.length) { if (ms.length) [ms appendString:@" "]; [ms appendString:s]; }
            }
            if (ms.length) return ms;
        }
    } @catch (NSException *e) { }
    return nil;
}

// ---------- 本地识别器 delegate ----------
@interface CCAssistantDelegate : NSObject
@property (nonatomic, copy) NSString *lastTokens;
@property (nonatomic, copy) NSString *lastPackage;
@end

@implementation CCAssistantDelegate

- (void)localSpeechRecognizer:(id)r didRecognizeTokens:(NSArray *)tokens {
    @try {
        NSMutableString *ms = [NSMutableString string];
        for (id t in tokens) {
            NSString *s = CCTextFromObject(t);
            if (s.length) { if (ms.length) [ms appendString:@" "]; [ms appendString:s]; }
        }
        if (ms.length) {
            self.lastTokens = ms;
            CCLogA(@"LOCAL tokens: %@", ms);
        } else {
            CCLogA(@"LOCAL tokens: (count=%lu, no text extracted)", (unsigned long)tokens.count);
        }
    } @catch (NSException *e) { CCLogA(@"tokens exc %@", e.reason); }
}

- (void)localSpeechRecognizer:(id)r didCompletionRecognitionWithStatistics:(NSDictionary *)stats error:(NSError *)err {
    @try {
        CCLogA(@"LOCAL completion err=%@ statsKeys=%@", err,
               stats ? [[stats allKeys] componentsJoinedByString:@","] : @"-");
        NSString *txt = CCTextFromObject(stats);
        if (txt.length) CCLogA(@"LOCAL completion text: %@", txt);
    } @catch (NSException *e) { CCLogA(@"completion exc %@", e.reason); }
}

- (void)localSpeechRecognizer:(id)r didProcessAudioDuration:(double)d {
    CCLogA(@"LOCAL audio duration %.2fs", d);
}

- (void)localSpeechRecognizer:(id)r didRecognizePackage:(id)package {
    @try {
        NSString *txt = CCTextFromObject(package);
        if (txt.length) { self.lastPackage = txt; CCLogA(@"LOCAL package: %@", txt); }
        else CCLogA(@"LOCAL package: (no text)");
    } @catch (NSException *e) { CCLogA(@"package exc %@", e.reason); }
}

- (void)localSpeechRecognizer:(id)r didRecognizeRawEagerRecognitionCandidate:(id)cand {
    @try {
        NSString *txt = CCTextFromObject(cand);
        if (txt.length) CCLogA(@"LOCAL eager: %@", txt);
    } @catch (NSException *e) { }
}
@end

// ---------- 动态调用工具 ----------
static void CCSetArg(NSInvocation *inv, NSUInteger idx, const char *type,
                     id obj, BOOL b, double d, NSInteger i, void *ptr) {
    if (type[0] == '@' || type[0] == '#') {
        id v = obj;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    } else if (type[0] == 'B' || type[0] == 'c') {
        BOOL v = b;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    } else if (type[0] == 'd') {
        double v = d;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    } else if (type[0] == 'q' || type[0] == 'i' || type[0] == 'l' || type[0] == 'Q') {
        NSInteger v = i;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    } else if (type[0] == '*' || type[0] == '^') {
        void *v = ptr;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    } else {
        id v = obj;
        [inv setArgument:&v atIndex:(NSInteger)idx];
    }
}

// ---------- 运行器 ----------
@interface CCAssistantRunner : NSObject
@property (nonatomic, strong) id recognizer;
@property (nonatomic, strong) CCAssistantDelegate *delegate;
@property (nonatomic, strong) NSTimer *feedTimer;
@property (nonatomic) unsigned long long offset;
@property (nonatomic) long long packetNumber;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL feedLogged;
@end

@implementation CCAssistantRunner

+ (instancetype)shared {
    static CCAssistantRunner *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [CCAssistantRunner new]; });
    return r;
}

- (void)logEnvironment {
    Class cls = NSClassFromString(@"SiriCoreLocalSpeechRecognizer");
    CCLogA(@"env: SiriCoreLocalSpeechRecognizer=%@", cls ? @"YES" : @"NO");
    if (cls) {
        SEL s16 = NSSelectorFromString(@"startSpeechRecognitionWithLanguage:interactionIdentifier:task:context:narrowband:detectUtterances:maximumRecognitionDuration:farField:secureOfflineOnly:censorSpeech:originalAudioFileURL:overrides:modelOverrideURL:applicationName:shouldStoreAudioOnDevice:didStartHandler:");
        SEL s13 = NSSelectorFromString(@"startSpeechRecognitionWithLanguage:task:context:narrowband:detectUtterances:maximumRecognitionDuration:farField:secureOfflineOnly:censorSpeech:originalAudioFileURL:overrides:modelOverrideURL:didStartHandler:");
        CCLogA(@"env: startSelector 16arg=%@ 13arg=%@",
               [cls instancesRespondToSelector:s16] ? @"YES" : @"NO",
               [cls instancesRespondToSelector:s13] ? @"YES" : @"NO");
        CCLogA(@"env: addAudioPacket=%@ finishAudio=%@ invalidate=%@ init=%@",
               [cls instancesRespondToSelector:NSSelectorFromString(@"addAudioPacket:")] ? @"YES" : @"NO",
               [cls instancesRespondToSelector:NSSelectorFromString(@"finishAudio")] ? @"YES" : @"NO",
               [cls instancesRespondToSelector:NSSelectorFromString(@"invalidate")] ? @"YES" : @"NO",
               [cls instancesRespondToSelector:NSSelectorFromString(@"init")] ? @"YES" : @"NO");
    }
    CCLogA(@"env: SiriCoreSpeechPacket=%@ SASSpeechPacket=%@",
           NSClassFromString(@"SiriCoreSpeechPacket") ? @"YES" : @"NO",
           NSClassFromString(@"SASSpeechPacket") ? @"YES" : @"NO");
}

- (BOOL)startRecognizer {
    if (self.running) return YES;
    Class cls = NSClassFromString(@"SiriCoreLocalSpeechRecognizer");
    if (!cls) { CCLogA(@"start: class missing"); return NO; }

    CCAssistantDelegate *d = [CCAssistantDelegate new];
    self.delegate = d;

    id rec = [[cls alloc] init];
    if (!rec) { CCLogA(@"start: init failed"); return NO; }
    // delegate 是 readonly 属性；直接 KVC 写 ivar
    @try { [rec setValue:d forKey:@"delegate"]; }
    @catch (NSException *e) { CCLogA(@"start: set delegate exc %@", e.reason); }
    self.recognizer = rec;

    SEL sel16 = NSSelectorFromString(@"startSpeechRecognitionWithLanguage:interactionIdentifier:task:context:narrowband:detectUtterances:maximumRecognitionDuration:farField:secureOfflineOnly:censorSpeech:originalAudioFileURL:overrides:modelOverrideURL:applicationName:shouldStoreAudioOnDevice:didStartHandler:");
    SEL sel13 = NSSelectorFromString(@"startSpeechRecognitionWithLanguage:task:context:narrowband:detectUtterances:maximumRecognitionDuration:farField:secureOfflineOnly:censorSpeech:originalAudioFileURL:overrides:modelOverrideURL:didStartHandler:");
    SEL sel = [rec respondsToSelector:sel16] ? sel16 : ([rec respondsToSelector:sel13] ? sel13 : NULL);
    if (!sel) { CCLogA(@"start: no start selector"); return NO; }

    NSMethodSignature *sig = [rec methodSignatureForSelector:sel];
    if (!sig) { CCLogA(@"start: no signature"); return NO; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = rec;
    inv.selector = sel;

    NSString *lang = @"en-US";
    NSString *interaction = [[NSUUID UUID] UUIDString];
    __block BOOL started = NO;
    void (^didStart)(BOOL) = [^(BOOL ok) {
        started = ok;
        CCLogA(@"start: didStartHandler ok=%d", ok);
    } copy];
    uuid_t uu; uuid_generate(uu);

    NSUInteger argCount = sig.numberOfArguments;
    CCLogA(@"start: selector=%@ argCount=%lu", NSStringFromSelector(sel),
           (unsigned long)argCount);
    // 参数顺序（16arg）：2 lang,3 interaction,4 task,5 context,6 narrow,7 detect,
    // 8 maxDuration,9 farField,10 offlineOnly,11 censor,12 audioURL,13 overrides,
    // 14 modelURL,15 appName,16 storeAudio,17 didStart
    BOOL is16 = (sel == sel16);
    NSUInteger base = 2;
    for (NSUInteger idx = base; idx < argCount; idx++) {
        const char *t = [sig getArgumentTypeAtIndex:idx];
        NSUInteger pos = idx - base;   // 0-based position
        id obj = nil; BOOL b = NO; double dd = 0; NSInteger ii = 0; void *ptr = NULL;
        if (is16) {
            switch (pos) {
                case 0: obj = lang; break;
                case 1: obj = interaction; break;
                case 2: ii = 0; break;              // task
                case 3: obj = nil; break;           // context
                case 4: b = YES; break;             // narrowband
                case 5: b = YES; break;             // detectUtterances
                case 6: dd = 60.0; break;           // max duration
                case 7: b = NO; break;              // farField
                case 8: b = YES; break;             // secureOfflineOnly
                case 9: b = NO; break;              // censorSpeech
                case 10: obj = nil; break;          // originalAudioFileURL
                case 11: obj = nil; break;          // overrides
                case 12: obj = nil; break;          // modelOverrideURL
                case 13: obj = @"CallCaption"; break;
                case 14: b = NO; break;             // shouldStoreAudioOnDevice
                case 15: obj = didStart; break;     // block
                default: break;
            }
        } else {
            switch (pos) {
                case 0: obj = lang; break;
                case 1: ii = 0; break;              // task
                case 2: obj = nil; break;           // context
                case 3: b = YES; break;
                case 4: b = YES; break;
                case 5: dd = 60.0; break;
                case 6: b = NO; break;
                case 7: b = YES; break;
                case 8: b = NO; break;
                case 9: obj = nil; break;
                case 10: obj = nil; break;
                case 11: obj = nil; break;
                case 12: obj = didStart; break;
                default: break;
            }
        }
        if (t[0] == '*' || t[0] == '^') ptr = uu;
        CCSetArg(inv, idx, t, obj, b, dd, ii, ptr);
    }

    @try {
        [inv invoke];
        CCLogA(@"start: invoked ok (started=%d)", started);
    } @catch (NSException *e) {
        CCLogA(@"start: invoke exc %@", e.reason);
        return NO;
    }

    self.running = YES;
    self.offset = 44;
    self.packetNumber = 0;
    self.feedLogged = NO;
    self.feedTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                      target:self
                                                    selector:@selector(feedTick:)
                                                    userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.feedTimer forMode:NSRunLoopCommonModes];
    return YES;
}

- (id)makePacketWithData:(NSData *)data {
    Class sp = NSClassFromString(@"SiriCoreSpeechPacket");
    if (!sp) sp = NSClassFromString(@"SASSpeechPacket");
    if (!sp) return nil;
    id p = [[sp alloc] init];
    @try { [p setValue:@[data] forKey:@"packets"]; } @catch (NSException *e) { }
    @try { [p setValue:@(self.packetNumber) forKey:@"packetNumber"]; } @catch (NSException *e) { }
    @try {
        NSString *ace = [[NSUUID UUID] UUIDString];
        [p setValue:ace forKey:@"aceId"];
        [p setValue:ace forKey:@"refId"];
    } @catch (NSException *e) { }
    self.packetNumber++;
    return p;
}

- (void)feedTick:(NSTimer *)t {
    @try {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:CC_ASSIST_WAV error:nil];
        if (!at) return;
        unsigned long long size = [at[NSFileSize] unsignedLongLongValue];
        if (size < 44) return;
        if (size < self.offset) self.offset = 44;   // 文件被新通话截断
        if (size <= self.offset) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:CC_ASSIST_WAV];
        if (!fh) return;
        [fh seekToFileOffset:self.offset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        NSUInteger n = d.length & ~(NSUInteger)1;
        if (n == 0) return;
        self.offset += n;
        const int16_t *s = (const int16_t *)d.bytes;
        NSUInteger total = n / 2;
        NSUInteger chunk = 3200;   // 0.1s @16k
        for (NSUInteger i = 0; i < total; i += chunk) {
            NSUInteger cnt = MIN(chunk, total - i);
            NSData *pcm = [NSData dataWithBytes:s + i length:cnt * 2];
            id pkt = [self makePacketWithData:pcm];
            if (!pkt) {
                if (!self.feedLogged) {
                    self.feedLogged = YES;
                    CCLogA(@"feed: no packet class");
                }
                return;
            }
            @try {
                [self.recognizer performSelector:NSSelectorFromString(@"addAudioPacket:")
                                      withObject:pkt];
                if (!self.feedLogged) {
                    self.feedLogged = YES;
                    CCLogA(@"feed: first packet sent (%lu samples)", (unsigned long)cnt);
                }
            } @catch (NSException *e) {
                if (!self.feedLogged) {
                    self.feedLogged = YES;
                    CCLogA(@"feed: addAudioPacket exc %@", e.reason);
                }
            }
        }
    } @catch (NSException *e) {
        CCLogA(@"feed exc %@", e.reason);
    }
}

- (void)stopRecognizer {
    if (!self.running) return;
    self.running = NO;
    [self.feedTimer invalidate];
    self.feedTimer = nil;
    @try {
        if ([self.recognizer respondsToSelector:NSSelectorFromString(@"finishAudio")])
            [self.recognizer performSelector:NSSelectorFromString(@"finishAudio")];
    } @catch (NSException *e) { }
    @try {
        if ([self.recognizer respondsToSelector:NSSelectorFromString(@"invalidate")])
            [self.recognizer performSelector:NSSelectorFromString(@"invalidate")];
    } @catch (NSException *e) { }
    self.recognizer = nil;
    self.delegate = nil;
    CCLogA(@"stop: recognizer finished");
}

- (void)tick:(NSTimer *)t {
    BOOL armed = [[NSFileManager defaultManager] fileExistsAtPath:CC_ASSIST_ARM];
    if (armed && !self.running) {
        CCLogA(@"arm detected, starting Siri local recognizer");
        [self startRecognizer];
    } else if (!armed && self.running) {
        CCLogA(@"disarm detected, stopping");
        [self stopRecognizer];
    }
}
@end

__attribute__((constructor))
static void CCAssistantInit(void) {
    @autoreleasepool {
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        if (![proc isEqualToString:@"assistantd"]) return;
        CCLogA(@"=== CallCaptionAssistant loaded in %@ pid=%d ===", proc, getpid());
        CCAssistantRunner *r = [CCAssistantRunner shared];
        [r logEnvironment];
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:r
                                       selector:@selector(tick:)
                                       userInfo:nil repeats:YES];
    }
}
