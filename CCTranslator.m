// CCTranslator.m — 翻译引擎：DeepL + AI(OpenAI 兼容) + 会话缓存 + 主备降级
#import "CCCommon.h"

static NSMutableDictionary<NSString *, NSString *> *g_cache;
static NSMutableDictionary<NSString *, NSString *> *g_cacheEng;
static NSMutableArray<NSString *> *g_cacheOrder;
static dispatch_queue_t g_netQ;

static void CacheInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_cache = [NSMutableDictionary dictionary];
        g_cacheEng = [NSMutableDictionary dictionary];
        g_cacheOrder = [NSMutableArray array];
        g_netQ = dispatch_queue_create("net.user.callcaption.translator", DISPATCH_QUEUE_SERIAL);
    });
}

static NSString *CacheKey(NSString *text, NSString *from, NSString *to) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            [from lowercaseString] ?: @"auto", [to lowercaseString] ?: @"zh", text];
}

static NSString *CacheGet(NSString *k) {
    return [g_cache objectForKey:k];
}

static NSString *CacheGetEngine(NSString *k) {
    return [g_cacheEng objectForKey:k];
}

static void CachePut(NSString *k, NSString *v, NSString *engine) {
    if (!k.length || !v.length) return;
    if (!g_cache[k]) [g_cacheOrder addObject:k];
    while (g_cacheOrder.count > 300) {          // 小 LRU，防膨胀
        NSString *old = g_cacheOrder.firstObject;
        [g_cacheOrder removeObjectAtIndex:0];
        if (old) { [g_cache removeObjectForKey:old]; [g_cacheEng removeObjectForKey:old]; }
    }
    g_cache[k] = v;
    if (engine.length) g_cacheEng[k] = engine;
}

// ---------- 语言名映射（AI 提示词用） ----------
static NSString *LangName(NSString *code) {
    NSDictionary *m = @{@"en": @"English", @"zh": @"Simplified Chinese (Mandarin)",
                        @"ja": @"Japanese", @"ko": @"Korean", @"de": @"German",
                        @"fr": @"French", @"es": @"Spanish", @"ru": @"Russian"};
    NSString *n = m[code.lowercaseString];
    return n ?: code;
}

// ---------- DeepL Key ----------
// 自己的 DeepLKey 为空时，复用 LiveCallTranslator 已保存的 DEEPL_API_KEY。
// 这样用户不用在两个插件里重复填同一个 Key；不会把 Key 写进日志。
static NSString *DeepLKey(void) {
    NSString *k = [CCPrefStr(CC_K_DEEPL_KEY, @"")
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    static NSUInteger g_lastOwnLen = 0;
    if (k.length) {
        if (k.length != g_lastOwnLen) {
            g_lastOwnLen = k.length;
            CCLogf(@"deepl key: own key present (len=%lu)", (unsigned long)k.length);
        }
        return k;
    }
    g_lastOwnLen = 0;

    static NSString *g_lctKey = nil;
    static CFAbsoluteTime g_lctAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - g_lctAt > 60.0) {
        g_lctAt = now;
        g_lctKey = nil;
        NSString *path = @"/var/mobile/Library/Preferences/net.limneos.livecalltranslator.plist";
        BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        NSDictionary *d = exists ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        id v = d[@"DEEPL_API_KEY"];
        if ([v isKindOfClass:[NSString class]]) {
            v = [(NSString *)v stringByTrimmingCharactersInSet:
                 [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if ([v isKindOfClass:[NSString class]] && [v length]) {
            g_lctKey = v;
            CCLogf(@"deepl key: using LiveCallTranslator key (len=%lu)",
                   (unsigned long)[v length]);
        } else if (exists) {
            CCLogf(@"deepl key: LCT prefs exists but DEEPL_API_KEY empty");
        } else {
            CCLogf(@"deepl key: LCT prefs not found (%@)", path);
        }
    }
    return g_lctKey ?: @"";
}

// ---------- DeepL ----------
static void DeepLRequest(NSString *text, NSString *from, NSString *to, NSString *key,
                         NSString *endpoint,
                         void (^done)(NSString *, NSError *, NSInteger status)) {
    // DeepL 新版要求 Authorization 头，旧的 auth_key 表单参数会返回
    // 403 "Missing Authorization header"。
    NSMutableString *body = [NSMutableString stringWithFormat:@"text=%@&target_lang=%@",
                             CCEscape(text), to.uppercaseString];
    if (![[from lowercaseString] isEqualToString:@"auto"]) {
        [body appendFormat:@"&source_lang=%@", from.uppercaseString];
    }
    NSURL *url = [NSURL URLWithString:endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"DeepL-Auth-Key %@", key]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 3.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                   ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                if (err || !data) {
                    CCLogf(@"deepl endpoint=%@ http=%ld err=%@", endpoint, (long)status,
                           err.localizedDescription ?: @"no data");
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:2 userInfo:nil], status);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *out = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    NSArray *arr = json[@"translations"];
                    if ([arr isKindOfClass:[NSArray class]] && arr.count > 0)
                        out = arr[0][@"text"];
                }
                if ([out isKindOfClass:[NSString class]] && out.length) {
                    done(out, nil, status);
                    return;
                }
                NSString *rb = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (rb.length > 160) rb = [rb substringToIndex:160];
                rb = [rb stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                CCLogf(@"deepl endpoint=%@ http=%ld body=%@", endpoint, (long)status, rb ?: @"");
                done(nil, [NSError errorWithDomain:CC_DOMAIN code:3
                                          userInfo:@{NSLocalizedDescriptionKey: @"bad deepl response"}],
                     status);
            } @catch (NSException *e) { done(nil, nil, 0); }
        }] resume];
}

static void TranslateDeepL(NSString *text, NSString *from, NSString *to,
                           void (^done)(NSString *, NSError *)) {
    NSString *key = DeepLKey();
    if (key.length == 0) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:1 userInfo:@{NSLocalizedDescriptionKey: @"DeepL key not set"}]);
        return;
    }
    // 先走 free 端点；如果是 Pro Key（401/403），再试 api.deepl.com。
    DeepLRequest(text, from, to, key, @"https://api-free.deepl.com/v2/translate",
                 ^(NSString *out, NSError *err, NSInteger status) {
        if (out.length) { done(out, nil); return; }
        if (status == 401 || status == 403) {
            DeepLRequest(text, from, to, key, @"https://api.deepl.com/v2/translate",
                         ^(NSString *out2, NSError *err2, NSInteger status2) {
                if (out2.length) done(out2, nil);
                else done(nil, err2 ?: [NSError errorWithDomain:CC_DOMAIN code:3
                                    userInfo:@{NSLocalizedDescriptionKey: @"bad deepl response"}]);
            });
            return;
        }
        done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:3
                                   userInfo:@{NSLocalizedDescriptionKey: @"bad deepl response"}]);
    });
}

// ---------- URL 编码 ----------
NSString *CCEscape(NSString *s) {
    return (NSString *)CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(
        NULL, (__bridge CFStringRef)s, NULL, (CFStringRef)@"&+=?/", kCFStringEncodingUTF8));
}

// ---------- AI（OpenAI 兼容 chat/completions） ----------
static void TranslateAI(NSString *text, NSString *from, NSString *to,
                        void (^done)(NSString *, NSError *)) {
    NSString *urlStr = CCPrefStr(CC_K_AI_URL, @"https://api.deepseek.com/v1/chat/completions");
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
    req.timeoutInterval = 4.0;

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

// ---------- Google 免费 web 接口（无需 Key，兜底） ----------
static void TranslateGoogleFree(NSString *text, NSString *from, NSString *to,
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
    req.timeoutInterval = 3.0;

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

// ---------- MyMemory（LCT 默认免费服务，无需 Key） ----------
static NSString *CCUnescapeHTML(NSString *s);
static NSString *MyMemoryLang(NSString *code) {
    NSString *c = [code lowercaseString];
    if ([c hasPrefix:@"zh"]) return @"zh-CN";
    if ([c isEqualToString:@"en"] || [c hasPrefix:@"en-"]) return @"en";
    if (c.length == 0 || [c isEqualToString:@"auto"]) return @"en";
    return c;
}

static void TranslateMyMemory(NSString *text, NSString *from, NSString *to,
                              void (^done)(NSString *, NSError *)) {
    NSString *fl = MyMemoryLang(from);
    NSString *tl = MyMemoryLang(to);
    NSString *urlStr = [NSString stringWithFormat:
        @"https://api.mymemory.translated.net/get?q=%@&langpair=%@%%7C%@",
        CCEscape(text), CCEscape(fl), CCEscape(tl)];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:51
                                   userInfo:@{NSLocalizedDescriptionKey: @"bad mymemory url"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 4.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                if (err || !data) {
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:52 userInfo:nil]);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *out = nil;
                NSString *detail = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id rd = json[@"responseData"];
                    if ([rd isKindOfClass:[NSDictionary class]]) out = rd[@"translatedText"];
                    if ([json[@"responseDetails"] isKindOfClass:[NSString class]])
                        detail = json[@"responseDetails"];
                }
                if ([out isKindOfClass:[NSString class]] &&
                    out.length && ![out containsString:@"MYMEMORY WARNING"]) {
                    done(CCUnescapeHTML(out), nil);
                } else {
                    done(nil, [NSError errorWithDomain:CC_DOMAIN code:53
                        userInfo:@{NSLocalizedDescriptionKey:
                        detail.length ? detail : @"bad mymemory response"}]);
                }
            } @catch (NSException *e) { done(nil, nil); }
        }] resume];
}

// ---------- Google Cloud Translation API（填了 Key 时优先） ----------
static NSString *CCUnescapeHTML(NSString *s) {
    NSMutableString *m = [s mutableCopy];
    NSArray *pairs = @[@[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&apos;", @"'"],
                       @[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&amp;", @"&"]];
    for (NSArray *p in pairs) {
        [m replaceOccurrencesOfString:p[0] withString:p[1]
                              options:0 range:NSMakeRange(0, m.length)];
    }
    return m;
}

static void TranslateGoogleCloud(NSString *text, NSString *from, NSString *to, NSString *key,
                                 void (^done)(NSString *, NSError *)) {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://translation.googleapis.com/language/translate/v2?key=%@", CCEscape(key)];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        done(nil, [NSError errorWithDomain:CC_DOMAIN code:31
                                   userInfo:@{NSLocalizedDescriptionKey: @"bad google cloud url"}]);
        return;
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    NSMutableString *body = [NSMutableString stringWithFormat:@"q=%@&target=%@&format=text",
                             CCEscape(text), [to lowercaseString]];
    if (![[from lowercaseString] isEqualToString:@"auto"])
        [body appendFormat:@"&source=%@", [from lowercaseString]];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 3.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                if (err || !data) {
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:32 userInfo:nil]);
                    return;
                }
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *out = nil;
                if ([json isKindOfClass:[NSDictionary class]]) {
                    id d = json[@"data"];
                    if ([d isKindOfClass:[NSDictionary class]]) {
                        id tr = d[@"translations"];
                        if ([tr isKindOfClass:[NSArray class]] && [tr count] > 0) {
                            id first = tr[0];
                            if ([first isKindOfClass:[NSDictionary class]])
                                out = first[@"translatedText"];
                        }
                    }
                }
                if ([out isKindOfClass:[NSString class]] && out.length)
                    done(CCUnescapeHTML(out), nil);
                else done(nil, [NSError errorWithDomain:CC_DOMAIN code:33
                                               userInfo:@{NSLocalizedDescriptionKey: @"bad google cloud response"}]);
            } @catch (NSException *e) { done(nil, nil); }
        }];
    [task resume];
}

// ---------- Google 统一入口：有 Key 走 Cloud，失败回退免费接口 ----------
static void TranslateGoogle(NSString *text, NSString *from, NSString *to,
                            void (^done)(NSString *, NSError *)) {
    NSString *key = CCPrefStr(CC_K_GOOGLE_KEY, @"");
    if (key.length > 0) {
        TranslateGoogleCloud(text, from, to, key, ^(NSString *r, NSError *e) {
            if (r.length) { done(r, nil); return; }
            if (e) CCLogf(@"translate[google-cloud] failed: %@", e.localizedDescription);
            TranslateGoogleFree(text, from, to, done);
        });
    } else {
        TranslateGoogleFree(text, from, to, done);
    }
}

// ---------- Bing（Edge 免费接口：国内可用、无需 Key） ----------
static NSString *g_bingToken = nil;
static CFAbsoluteTime g_bingTokenAt = 0;
static CFAbsoluteTime g_bingDeadUntil = 0;

static NSString *BingLang(NSString *code) {
    NSString *c = [code lowercaseString];
    if (c.length == 0 || [c isEqualToString:@"auto"]) return @"";
    if ([c isEqualToString:@"zh"] || [c hasPrefix:@"zh-cn"] || [c hasPrefix:@"zh-hans"])
        return @"zh-Hans";
    if ([c hasPrefix:@"zh-tw"] || [c hasPrefix:@"zh-hant"]) return @"zh-Hant";
    return c;
}

static void TranslateBing(NSString *text, NSString *from, NSString *to,
                          void (^done)(NSString *, NSError *)) {
    void (^doTranslate)(NSString *) = ^(NSString *token) {
        NSString *fl = BingLang(from);
        NSString *tl = BingLang(to);
        NSString *urlStr = [NSString stringWithFormat:
            @"https://api-edge.cognitive.microsofttranslator.com/translate?api-version=3.0&to=%@%@",
            CCEscape(tl), fl.length ? [NSString stringWithFormat:@"&from=%@", CCEscape(fl)] : @""];
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) {
            done(nil, [NSError errorWithDomain:CC_DOMAIN code:41
                                       userInfo:@{NSLocalizedDescriptionKey: @"bad bing url"}]);
            return;
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        req.HTTPMethod = @"POST";
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
   forHTTPHeaderField:@"Authorization"];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@[@{@"Text": text}]
                                                       options:0 error:nil];
        req.timeoutInterval = 3.0;

        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                @try {
                    if (err || !data) {
                        done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:42 userInfo:nil]);
                        return;
                    }
                    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    NSString *out = nil;
                    if ([json isKindOfClass:[NSArray class]] && [(NSArray *)json count] > 0) {
                        id first = [(NSArray *)json objectAtIndex:0];
                        if ([first isKindOfClass:[NSDictionary class]]) {
                            id tr = first[@"translations"];
                            if ([tr isKindOfClass:[NSArray class]] && [tr count] > 0) {
                                id t0 = tr[0];
                                if ([t0 isKindOfClass:[NSDictionary class]]) out = t0[@"text"];
                            }
                        }
                    }
                    if ([out isKindOfClass:[NSString class]] && out.length)
                        done(out, nil);
                    else done(nil, [NSError errorWithDomain:CC_DOMAIN code:43
                                                   userInfo:@{NSLocalizedDescriptionKey: @"bad bing response"}]);
                } @catch (NSException *e) { done(nil, nil); }
            }] resume];
    };

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (g_bingToken.length && now - g_bingTokenAt < 480) {
        doTranslate(g_bingToken);
        return;
    }
    NSMutableURLRequest *treq = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://edge.microsoft.com/translate/auth"]];
    treq.timeoutInterval = 2.5;
    [[[NSURLSession sharedSession] dataTaskWithRequest:treq
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            @try {
                NSString *token = nil;
                if (data) {
                    token = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                             stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                }
                if (token.length) {
                    g_bingToken = token;
                    g_bingTokenAt = CFAbsoluteTimeGetCurrent();
                    doTranslate(token);
                } else {
                    g_bingDeadUntil = CFAbsoluteTimeGetCurrent() + 600.0;  // Bing 令牌失败：冷却 10 分钟
                    done(nil, err ?: [NSError errorWithDomain:CC_DOMAIN code:44
                                                     userInfo:@{NSLocalizedDescriptionKey: @"bing auth failed"}]);
                }
            } @catch (NSException *e) { done(nil, nil); }
        }] resume];
}

// ---------- 对外入口（会话缓存 + 多引擎降级链） ----------

static void CCTranslateTry(NSArray<NSString *> *order, NSUInteger idx,
                           NSString *text, NSString *fromLang, NSString *toLang,
                           void (^done)(NSString *translated, NSString *engine)) {
    if (idx >= order.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(nil, nil); });
        return;
    }
    NSString *eng = order[idx];
    void (^cb)(NSString *, NSError *) = ^(NSString *r, NSError *e) {
        if (r.length) {
            CachePut(CacheKey(text, fromLang, toLang), r, eng);
            CCLogf(@"translate[%@] ok", eng);
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(r, eng); });
            return;
        }
        if (e) CCLogf(@"translate[%@] failed: %@", eng, e.localizedDescription);
        CCTranslateTry(order, idx + 1, text, fromLang, toLang, done);
    };
    if ([eng isEqualToString:@"deepl"]) TranslateDeepL(text, fromLang, toLang, cb);
    else if ([eng isEqualToString:@"ai"]) TranslateAI(text, fromLang, toLang, cb);
    else if ([eng isEqualToString:@"mymemory"]) TranslateMyMemory(text, fromLang, toLang, cb);
    else if ([eng isEqualToString:@"bing"]) TranslateMyMemory(text, fromLang, toLang, cb);
    else TranslateGoogle(text, fromLang, toLang, cb);
}

void CCTranslateWithEngine(NSString *text, NSString *fromLang, NSString *toLang,
                           NSString *engineIn,
                           void (^done)(NSString *translated, NSString *engine)) {
    CacheInit();
    if (text.length == 0) { if (done) done(nil, nil); return; }

    dispatch_async(g_netQ, ^{
        NSString *key = CacheKey(text, fromLang, toLang);
        NSString *cached = CacheGet(key);
        if (cached) {
            NSString *eng = CacheGetEngine(key) ?: @"cache";
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(cached, eng); });
            return;
        }

        NSString *engine = engineIn.length ? engineIn.lowercaseString
                                           : CCPrefStr(CC_K_ENGINE, @"auto").lowercaseString;
        // 兼容旧设置：Bing 免费端点已下线，统一走 MyMemory。
        if ([engine isEqualToString:@"bing"]) engine = @"mymemory";
        NSString *dk = DeepLKey();
        BOOL aiReady = CCPrefStr(CC_K_AI_URL, @"https://api.deepseek.com/v1/chat/completions").length > 0 &&
                       CCPrefStr(CC_K_AI_KEY, @"").length > 0;

        // 引擎优先级：选中的排第一；免费兜底用 Google / MyMemory。
        NSMutableArray<NSString *> *order = [NSMutableArray array];
        if ([engine isEqualToString:@"deepl"]) {
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
            [order addObject:@"google"];
            [order addObject:@"mymemory"];
        } else if ([engine isEqualToString:@"ai"]) {
            if (aiReady) [order addObject:@"ai"];
            if (dk.length) [order addObject:@"deepl"];
            [order addObject:@"google"];
            [order addObject:@"mymemory"];
        } else if ([engine isEqualToString:@"mymemory"]) {
            [order addObject:@"mymemory"];
            [order addObject:@"google"];
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
        } else if ([engine isEqualToString:@"google"]) {
            [order addObject:@"google"];
            [order addObject:@"mymemory"];
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
        } else { // auto
            if (dk.length) [order addObject:@"deepl"];
            if (aiReady) [order addObject:@"ai"];
            [order addObject:@"google"];
            [order addObject:@"mymemory"];
        }

        NSString *orderStr = [order componentsJoinedByString:@","];
        static NSString *g_lastOrder = nil;
        if (![g_lastOrder isEqualToString:orderStr]) {
            g_lastOrder = orderStr;
            CCLogf(@"translate order=%@ (engine=%@ deeplKey=%d aiReady=%d)",
                   orderStr, engine, dk.length > 0, aiReady);
        }
        if ([engine isEqualToString:@"deepl"] && !dk.length)
            CCLogf(@"deepl selected but key missing (own + LiveCallTranslator), fallback");

        CCTranslateTry(order, 0, text, fromLang, toLang, done);
    });
}

void CCTranslateEx(NSString *text, NSString *fromLang, NSString *toLang,
                   void (^done)(NSString *translated, NSString *engine)) {
    CCTranslateWithEngine(text, fromLang, toLang,
                          CCPrefStr(CC_K_ENGINE, @"auto"), done);
}

void CCTranslate(NSString *text, NSString *fromLang, NSString *toLang,
                 void (^done)(NSString *translated)) {
    CCTranslateEx(text, fromLang, toLang, ^(NSString *out, NSString *engine) {
        if (done) done(out);
    });
}
