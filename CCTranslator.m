// CCTranslator.m — 翻译引擎：DeepL + AI(OpenAI 兼容) + 会话缓存 + 主备降级
#import "CCCommon.h"

static NSMutableDictionary<NSString *, NSString *> *g_cache;
static dispatch_queue_t g_netQ;

static void CacheInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_cache = [NSMutableDictionary dictionary];
        g_netQ = dispatch_queue_create("net.user.callcaption.translator", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *CacheGet(NSString *k) {
    return [g_cache objectForKey:k];
}

static void CachePut(NSString *k, NSString *v) {
    if (g_cache.count > 500) [g_cache removeAllObjects]; // 简单上限，防膨胀
    [g_cache setObject:v forKey:k];
}

// ---------- 语言名映射（AI 提示词用） ----------
static NSString *LangName(NSString *code) {
    NSDictionary *m = @{@"en": @"English", @"zh": @"Simplified Chinese (Mandarin)",
                        @"ja": @"Japanese", @"ko": @"Korean", @"de": @"German",
                        @"fr": @"French", @"es": @"Spanish", @"ru": @"Russian"};
    NSString *n = m[code.lowercaseString];
    return n ?: code;
}

// ---------- DeepL ----------
static void TranslateDeepL(NSString *text, NSString *from, NSString *to,
                           void (^done)(NSString *, NSError *)) {
    NSString *key = CCPrefStr(CC_K_DEEPL_KEY, @"");
    if (key.length == 0) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:1 userInfo:@{NSLocalizedDescriptionKey: @"DeepL key not set"}]);
        return;
    }
    NSMutableString *body = [NSMutableString stringWithFormat:@"auth_key=%@&text=%@&target_lang=%@",
                             CCEscape(key), CCEscape(text), to.uppercaseString];
    if (![[from lowercaseString] isEqualToString:@"auto"]) {
        [body appendFormat:@"&source_lang=%@", from.uppercaseString];
    }
    NSURL *url = [NSURL URLWithString:@"https://api-free.deepl.com/v2/translate"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 15;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                if (err || !data) {
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:2 userInfo:nil]);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *out = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *arr = json[@"translations"];
                    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0)
                        out = arr[0][@"text"];
                }
                if ([out isKindOfClass:[NSString class]] && out.length) done(out, nil);
                else done(nil, [NSError errorWithDomain:CC_DOMAIN code:3 userInfo:@{NSLocalizedDescriptionKey: @"bad deepl response"}]);
            } @catch (NSException *e) { done(nil, nil); }
        }];
    [task resume];
}

// ---------- URL 编码 ----------
NSString *CCEscape(NSString *s) {
    return (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(
        NULL, (__bridge CFStringRef)s, NULL, (CFStringRef)@"&+=?/", kCFStringEncodingUTF8));
}

// ---------- AI（OpenAI 兼容 chat/completions） ----------
static void TranslateAI(NSString *text, NSString *from, NSString *to,
                        void (^done)(NSString *, NSError *)) {
    NSString *urlStr = CCPrefStr(CC_K_AI_URL, @"");
    NSString *key = CCPrefStr(CC_K_AI_KEY, @"");
    NSString *model = CCPrefStr(CC_K_AI_MODEL, @"deepseek-chat");
    if (urlStr.length == 0) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:11 userInfo:@{NSLocalizedDescriptionKey: @"AI URL not set"}]);
        return;
    }
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (key.length) [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 25;

    NSString *sys = [NSString stringWithFormat:
        @"You are a real-time spoken interpreter. Translate the user's message from %@ to %@. "
        @"Keep it natural and conversational. Output ONLY the translation, nothing else.",
        LangName(from), LangName(to)];
    NSDictionary *body = @{
        @"model": model,
        @"temperature": @0.2,
        @"max_tokens": @500,
        @"stream": @NO,
        @"messages": @[
            @{@"role": @"system", @"content": sys},
            @{@"role": @"user",   @"content": text},
        ],
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                if (err || !data) {
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:12 userInfo:nil]);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *out = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *choices = json[@"choices"];
                    if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                        id msg = choices[0][@"message"];
                        if ([msg isKindOfClass:[NSDictionary class]])
                            out = msg[@"content"];
                        // 兼容部分中转站的 choices[0].text
                        if (!out) out = choices[0][@"text"];
                    }
                }
                if ([out isKindOfClass:[NSString class]]) {
                    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    // 去掉模型偶尔自作主张的引号和前缀
                    if ([out hasPrefix:@"\""] && [out hasSuffix:@"\""] && out.length >= 2)
                        out = [out substringWithRange:NSMakeRange(1, out.length - 2)];
                }
                if (out.length) done(out, nil);
                else done(nil, [NSError errorWithDomain:CC_DOMAIN code:13 userInfo:@{NSLocalizedDescriptionKey: @"bad ai response"}]);
            } @catch (NSException *e) { done(nil, nil); }
        }];
    [task resume];
}

// ---------- Google（免费 web 接口，无需 Key） ----------
static void TranslateGoogle(NSString *text, NSString *from, NSString *to,
                            void (^done)(NSString *, NSError *)) {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=%@&tl=%@&dt=t&q=%@",
        [from lowercaseString], [to lowercaseString], CCEscape(text)];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:21
                                   userInfo:@{NSLocalizedDescriptionKey: @"bad google url"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 15;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                if (err || !data) {
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:22 userInfo:nil]);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSMutableString *out = [NSMutableString string];
                if ([json isKindOfClass:[NSArray class]] && [(NSArray *)json count] > 0) {
                    id segs = [(NSArray *)json objectAtIndex:0];
                    if ([segs isKindOfClass:[NSArray class]]) {
                        for (id seg in (NSArray *)segs) {
                            if ([seg isKindOfClass:[NSArray class]] && [(NSArray *)seg count] > 0) {
                                id piece = [(NSArray *)seg objectAtIndex:0];
                                if ([piece isKindOfClass:[NSString class]]) [out appendString:piece];
                            }
                        }
                    }
                }
                NSString *res = [out stringByTrimmingCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (res.length) done(res, nil);
                else done(nil, [NSError errorWithDomain:CC_DOMAIN code:23
                                               userInfo:@{NSLocalizedDescriptionKey: @"bad google response"}]);
            } @catch (NSException *e) { done(nil, nil); }
        }];
    [task resume];
}

// ---------- 对外入口（会话缓存 + 多引擎降级链） ----------

static void CCTranslateTry(NSArray<NSString *> *order, NSUInteger idx,
                           NSString *text, NSString *fromLang, NSString *toLang,
                           void (^done)(NSString *translated)) {
    if (idx >= order.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
        return;
    }
    NSString *eng = order[idx];
    void (^cb)(NSString *, NSError *) = ^(NSString *r, NSError *e) {
        if (r.length) {
            CachePut(text, r);
            dispatch_async(dispatch_get_main_queue(), ^{ done(r); });
            return;
        }
        if (e) CCLogf(@"translate[%@] failed: %@", eng, e.localizedDescription);
        CCTranslateTry(order, idx + 1, text, fromLang, toLang, done);
    };
    if ([eng isEqualToString:@"deepl"]) TranslateDeepL(text, fromLang, toLang, cb);
    else if ([eng isEqualToString:@"ai"]) TranslateAI(text, fromLang, toLang, cb);
    else TranslateGoogle(text, fromLang, toLang, cb);
}

void CCTranslate(NSString *text, NSString *fromLang, NSString *toLang,
                 void (^done)(NSString *translated)) {
    CacheInit();
    if (text.length == 0) { done(nil); return; }

    dispatch_async(g_netQ, ^{
        NSString *cached = CacheGet(text);
        if (cached) { done(cached); return; }

        NSString *engine = CCPrefStr(CC_K_ENGINE, @"auto").lowercaseString;
        NSString *dk = CCPrefStr(CC_K_DEEPL_KEY, @"");
        BOOL aiReady = CCPrefStr(CC_K_AI_URL, @"").length > 0 &&
                       CCPrefStr(CC_K_AI_KEY, @"").length > 0;

        // 引擎优先级：选中的排第一，其余按可用性降级，Google 永远兜底
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        if ([engine isEqualToString:@"deepl"]) {
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
            [order addObject:@"google"];
        } else if ([engine isEqualToString:@"ai"]) {
            if (aiReady) [order addObject:@"ai"];
            if (dk.length) [order addObject:@"deepl"];
            [order addObject:@"google"];
        } else if ([engine isEqualToString:@"google"]) {
            [order addObject:@"google"];
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
        } else { // auto
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
            [order addObject:@"google"];
        }

        CCTranslateTry(order, 0, text, fromLang, toLang, done);
    });
}
