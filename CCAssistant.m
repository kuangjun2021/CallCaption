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
#import <dlfcn.h>

#define CC_ASSIST_DIR  @"/var/mobile/Library/CallCaption"
#define CC_ASSIST_LOG  @"/var/mobile/Library/CallCaption/assistant.log"
#define CC_ASSIST_FALLBACK @"/tmp/ccassistant.log"
#define CC_ASSIST_ARM  @"/var/mobile/Library/CallCaption/armed"
#define CC_ASSIST_WAV  @"/var/mobile/Library/CallCaption/remote16k.wav"
#ifdef CC_ASSISTANT_EMBED
#define CC_ASSIST_PROBE @"/var/mobile/Library/CallCaption/probe.log"
#endif

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
#ifdef CC_ASSISTANT_EMBED
        // 同时写进用户平时发送的 probe.log，省得再找 assistant.log
        NSString *pl = [NSString stringWithFormat:@"[Siri] %@", msg];
        pl = [pl stringByAppendingFormat:@"%c", 10];
        FILE *pfp = fopen(CC_ASSIST_PROBE.fileSystemRepresentation, "a");
        if (pfp) {
            fputs(pl.UTF8String, pfp);
            fclose(pfp);
            chmod(CC_ASSIST_PROBE.fileSystemRepresentation, 0666);
        }
#endif
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

- (void)coreEmbeddedSpeechRecognizer:(id)r didRecognizeTokens:(NSArray *)tokens {
    [self localSpeechRecognizer:r didRecognizeTokens:tokens];
}
- (void)coreEmbeddedSpeechRecognizer:(id)r didCompletionRecognitionWithStatistics:(NSDictionary *)stats error:(NSError *)err {
    [self localSpeechRecognizer:r didCompletionRecognitionWithStatistics:stats error:err];
}
- (void)coreEmbeddedSpeechRecognizer:(id)r didProcessAudioDuration:(double)d {
    [self localSpeechRecognizer:r didProcessAudioDuration:d];
}
- (void)coreEmbeddedSpeechRecognizer:(id)r didRecognizePackage:(id)package {
    [self localSpeechRecognizer:r didRecognizePackage:package];
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

static void CCSetObjSel(id o, NSString *selName, id v) {
    SEL s = NSSelectorFromString(selName);
    if (s && [o respondsToSelector:s])
        [o performSelector:s withObject:v];
}
static void CCSetBoolSel(id o, NSString *selName, BOOL v) {
    SEL s = NSSelectorFromString(selName);
    if (!s || ![o respondsToSelector:s]) return;
    NSMethodSignature *sig = [o methodSignatureForSelector:s];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = o; inv.selector = s;
    [inv setArgument:&v atIndex:2];
    [inv invoke];
}
static void CCSetDoubleSel(id o, NSString *selName, double v) {
    SEL s = NSSelectorFromString(selName);
    if (!s || ![o respondsToSelector:s]) return;
    NSMethodSignature *sig = [o methodSignatureForSelector:s];
    if (!sig) return;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = o; inv.selector = s;
    [inv setArgument:&v atIndex:2];
    [inv invoke];
}

@implementation CCAssistantRunner

+ (instancetype)shared {
    static CCAssistantRunner *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [CCAssistantRunner new]; });
    return r;
}

- (void)loadSiriFrameworks {
    static BOOL tried = NO;
    if (tried) return;
    tried = YES;
    const char *cands[] = {
        "/System/Library/PrivateFrameworks/CoreEmbeddedSpeechRecognition.framework/CoreEmbeddedSpeechRecognition",
        "/System/Library/PrivateFrameworks/SiriCore.framework/SiriCore",
        "/System/Library/PrivateFrameworks/AssistantServices.framework/AssistantServices",
        "/System/Library/PrivateFrameworks/SpeechRecognitionCore.framework/SpeechRecognitionCore",
        "/System/Library/PrivateFrameworks/EmbeddedAcousticRecognition.framework/EmbeddedAcousticRecognition",
        "/usr/lib/libSiriCore.dylib"
    };
    for (size_t i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        void *h = dlopen(cands[i], RTLD_LAZY | RTLD_GLOBAL);
        CCLogA(@"dlopen %s -> %s%s", cands[i], h ? "OK" : "FAIL",
               h ? "" : (dlerror() ?: ""));
    }
}

- (void)logEnvironment {
    [self loadSiriFrameworks];
    Class cls = NSClassFromString(@"CoreEmbeddedSpeechRecognizer");
    CCLogA(@"env: CoreEmbeddedSpeechRecognizer=%@ CESRSpeechParameters=%@",
           cls ? @"YES" : @"NO",
           NSClassFromString(@"CESRSpeechParameters") ? @"YES" : @"NO");
    Class oldCls = NSClassFromString(@"SiriCoreLocalSpeechRecognizer");
    CCLogA(@"env: SiriCoreLocalSpeechRecognizer=%@", oldCls ? @"YES" : @"NO");
    cls = oldCls;
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

- (BOOL)startCoreEmbedded:(Class)cls {
    CCAssistantDelegate *d = [CCAssistantDelegate new];
    self.delegate = d;
    id rec = [[cls alloc] init];
    if (!rec) { CCLogA(@"core: init failed"); return NO; }
    @try { [rec setValue:d forKey:@"delegate"]; }
    @catch (NSException *e) { CCLogA(@"core: set delegate exc %@", e.reason); }
    self.recognizer = rec;

    Class pc = NSClassFromString(@"CESRSpeechParameters");
    SEL builderSel = NSSelectorFromString(@"newWithBuilder:");
    id params = nil;
    if (pc && [pc respondsToSelector:builderSel]) {
        void (^build)(id) = [^(id b) {
            CCSetObjSel(b, @"setLanguage:", @"en-US");
            CCSetObjSel(b, @"setTask:", @"dictation");
            CCSetObjSel(b, @"setApplicationName:", @"CallCaption");
            CCSetBoolSel(b, @"setNarrowband:", YES);
            CCSetBoolSel(b, @"setDetectUtterances:", YES);
            CCSetBoolSel(b, @"setSecureOfflineOnly:", YES);
            CCSetBoolSel(b, @"setCensorSpeech:", NO);
            CCSetBoolSel(b, @"setFarField:", NO);
            CCSetBoolSel(b, @"setShouldStoreAudioOnDevice:", NO);
            CCSetBoolSel(b, @"setEnableAutoPunctuation:", YES);
            CCSetDoubleSel(b, @"setMaximumRecognitionDuration:", 60.0);
        } copy];
        @try { params = [pc performSelector:builderSel withObject:build]; }
        @catch (NSException *e) { CCLogA(@"core: params exc %@", e.reason); }
    }
    CCLogA(@"core: params=%@", params ? @"OK" : @"nil");

    SEL startSel = NSSelectorFromString(@"startSpeechRecognitionWithParameters:didStartHandler:");
    if (!params || ![rec respondsToSelector:startSel]) {
        CCLogA(@"core: start selector/params missing");
        return NO;
    }
    void (^started)(BOOL) = [^(BOOL ok) {
        CCLogA(@"core: didStartHandler ok=%d", ok);
    } copy];
    @try {
        [rec performSelector:startSel withObject:params withObject:started];
        CCLogA(@"core: start invoked");
    } @catch (NSException *e) {
        CCLogA(@"core: start exc %@", e.reason);
        return NO;
    }

    self.running = YES;
    self.offset = 44;
    self.packetNumber = 0;
    self.feedLogged = NO;
#ifndef CC_ASSISTANT_EMBED
    self.feedTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                      target:self
                                                    selector:@selector(feedTick:)
                                                    userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.feedTimer forMode:NSRunLoopCommonModes];
#endif
    return YES;
}

- (BOOL)startRecognizer {
    if (self.running) return YES;
    [self loadSiriFrameworks];
    Class coreCls = NSClassFromString(@"CoreEmbeddedSpeechRecognizer");
    if (coreCls) {
        CCLogA(@"start: using CoreEmbeddedSpeechRecognizer");
        return [self startCoreEmbedded:coreCls];
    }
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
#ifndef CC_ASSISTANT_EMBED
    self.feedTimer = [NSTimer scheduledTimerWithTimeInterval:0.10
                                                      target:self
                                                    selector:@selector(feedTick:)
                                                    userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.feedTimer forMode:NSRunLoopCommonModes];
#endif
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
    [self feedOnce];
}

- (void)feedOnce {
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

#ifdef CC_ASSISTANT_EMBED
// 嵌入模式：编进 CallCaptionAudioService，由守护进程的 CheckArm 每 0.5 秒调用
void CCAssistantEmbedInit(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:CC_ASSIST_DIR
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0777}
                                                        error:nil];
        CCLogA(@"=== CallCaption Siri embed init pid=%d ===", getpid());
        [[CCAssistantRunner shared] logEnvironment];
    }
}

void CCAssistantEmbedTick(void) {
    @autoreleasepool {
        CCAssistantRunner *r = [CCAssistantRunner shared];
        BOOL armed = [[NSFileManager defaultManager] fileExistsAtPath:CC_ASSIST_ARM];
        if (armed && !r.running) {
            CCLogA(@"arm detected, starting Siri local recognizer");
            [r startRecognizer];
        } else if (!armed && r.running) {
            CCLogA(@"disarm detected, stopping");
            [r stopRecognizer];
        }
        if (r.running) [r feedOnce];
    }
}
#endif

#if defined(CC_ASSISTANT_TOOL)
// 独立守护进程模式：不依赖 assistantd 注入，用自己进程的 Siri 权限
int main(int argc, char *argv[]) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:CC_ASSIST_DIR
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0777}
                                                        error:nil];
        CCLogA(@"=== CallCaptionSiriHelper started pid=%d ===", getpid());
        CCAssistantRunner *r = [CCAssistantRunner shared];
        [r logEnvironment];
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:r
                                       selector:@selector(tick:)
                                       userInfo:nil repeats:YES];
        while (1) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:60]];
            }
        }
    }
    return 0;
}
#elif !defined(CC_ASSISTANT_EMBED)
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
#endif
