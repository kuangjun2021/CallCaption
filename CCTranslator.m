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

// ---------- 对外入口（含缓存与主备降级） ----------

void CCTranslate(NSString *text, NSString *fromLang, NSString *toLang,
                 void (^done)(NSString *translated)) {
    CacheInit();
    if (text.length == 0) { done(nil); return; }

    dispatch_async(g_netQ, ^{
        NSString *cached = CacheGet(text);
        if (cached) { done(cached); return; }

        NSString *engine = CCPrefStr(CC_K_ENGINE, @"auto").lowercaseString;
        NSString *dk = CCPrefStr(CC_K_DEEPL_KEY, @"");
        BOOL aiReady = CCPrefStr(CC_K_AI_URL, @"").length > 0;

        void (^handle)(NSString *res, NSString *primary, NSError *perr) =
            ^(NSString *res, NSString *primary, NSError *perr) {
            if (res.length) {
                CachePut(text, res);
                dispatch_async(dispatch_get_main_queue(), ^{ done(res); });
                return;
            }
            // 降级：primary 失败，试另一个
            if ([primary isEqualToString:@"deepl"] && aiReady) {
                TranslateAI(text, fromLang, toLang, ^(NSString *r2, NSError *e2) {
                    if (r2.length) CachePut(text, r2);
                    dispatch_async(dispatch_get_main_queue(), ^{ done(r2); });
                });
            } else if ([primary isEqualToString:@"ai"] && dk.length) {
                TranslateDeepL(text, fromLang, toLang, ^(NSString *r2, NSError *e2) {
                    if (r2.length) CachePut(text, r2);
                    dispatch_async(dispatch_get_main_queue(), ^{ done(r2); });
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
            }
        };

        if ([engine isEqualToString:@"deepl"] || ([engine isEqualToString:@"auto"] && dk.length)) {
            TranslateDeepL(text, fromLang, toLang, ^(NSString *r, NSError *e) { handle(r, @"deepl", e); });
        } else if ([engine isEqualToString:@"ai"] || ([engine isEqualToString:@"auto"] && aiReady)) {
            TranslateAI(text, fromLang, toLang, ^(NSString *r, NSError *e) { handle(r, @"ai", e); });
        } else {
            done(nil); // 没配任何引擎
        }
    });
}
