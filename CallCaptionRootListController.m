// CallCaptionRootListController.m — v0.12.8 标准 PreferenceLoader 面板
// 使用 theos/headers 的真实 Preferences 头文件 + 标准 Root.plist，走系统原生渲染路径。
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <AVFoundation/AVFoundation.h>

#define CC_DOMAIN @"net.user.callcaption"
#define CC_NOTIF  @"net.user.callcaption.prefschanged"
#define CC_PREF_PATH @"/var/mobile/Library/Preferences/net.user.callcaption.plist"

static void SLog(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *path = @"/var/mobile/Library/CallCaption/settings.log";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (NSException *e) { }
}

static void CCMigrateCFPrefsToFile(void);

__attribute__((visibility("default")))
@interface CallCaptionRootListController : PSListController
@end

@implementation CallCaptionRootListController

+ (void)load { SLog(@"bundle loaded"); }

- (NSArray *)specifiers {
    if (!_specifiers) {
        CCMigrateCFPrefsToFile();
        NSBundle *b = self.bundle;
        if (!b) {
            b = [NSBundle bundleWithPath:@"/var/jb/Library/PreferenceBundles/CallCaptionPrefs.bundle"];
            if (b) self.bundle = b;
        }
        NSString *path = [b pathForResource:@"Root" ofType:@"plist"];
        NSArray *dicts = [NSArray arrayWithContentsOfFile:path];
        SLog(@"manual load path=%@ dicts=%lu", path, (unsigned long)dicts.count);

        if (dicts.count) {
            NSMutableArray *arr = [NSMutableArray array];
            for (NSDictionary *d in dicts) {
                if (![d isKindOfClass:[NSDictionary class]]) continue;
                NSString *cellStr = d[@"cell"] ?: @"PSGroupCell";
                PSCellType type = [PSTableCell cellTypeFromString:cellStr];
                NSString *label = d[@"label"] ?: @"";

                // 关键：开关/输入框必须挂上默认的 get/set 选择器，否则系统会把行渲染成不可用（灰掉）
                BOOL needKV = (type == PSSwitchCell || type == PSEditTextCell ||
                               type == PSTitleValueCell || type == PSListItemCell ||
                               type == PSSecureEditTextCell);
                SEL setSel = needKV ? @selector(setPreferenceValue:specifier:) : NULL;
                SEL getSel = needKV ? @selector(readPreferenceValue:) : NULL;

                PSSpecifier *sp = [PSSpecifier preferenceSpecifierNamed:label
                                                                target:self
                                                                   set:setSel
                                                                   get:getSel
                                                                detail:nil
                                                                  cell:type
                                                                  edit:nil];
                for (NSString *k in d) {
                    if ([k isEqualToString:@"cell"] || [k isEqualToString:@"label"]) continue;
                    [sp setProperty:d[k] forKey:k];
                }
                NSString *act = d[@"action"];
                if ([act isKindOfClass:[NSString class]] && act.length) {
                    sp.buttonAction = NSSelectorFromString(act);
                    [sp setProperty:act forKey:@"action"];
                }
                [arr addObject:sp];
            }
            _specifiers = arr;
            SLog(@"manual specs=%lu", (unsigned long)arr.count);
        }

        if (!_specifiers.count) {
            _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self bundle:b];
            SLog(@"native fallback count=%lu", (unsigned long)_specifiers.count);
        }
    }
    return _specifiers;
}

// ---------- 设置读写 ----------

static NSDictionary *CCReadPrefsFile(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:CC_PREF_PATH];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

static NSString *CCObjString(NSString *key, NSString *def) {
    id v = CCReadPrefsFile()[key];
    if (!v) v = (__bridge_transfer id)CFPreferencesCopyAppValue(
                    (__bridge CFStringRef)key, (__bridge CFStringRef)CC_DOMAIN);
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return def;
}

// 旧版本/CFPreferences 可能把值写进了 Settings.app 的容器，而守护进程读的是
// /var/mobile/Library/Preferences/net.user.callcaption.plist。这里把旧值迁移到
// 守护进程真正读取的文件里，避免用户重新填一遍。
static void CCMigrateCFPrefsToFile(void) {
    NSArray *keys = @[@"Enabled", @"RemoteEnabled", @"LocalEnabled", @"TTSEnabled",
                      @"CloudASR", @"ShowRecognized", @"ShowTranslated", @"LargeCaptions",
                      @"AlwaysShowPanel", @"RemoteLocale", @"LocalLocale", @"Engine",
                      @"DeepLKey", @"GoogleKey", @"AIURL", @"AIKey", @"AIModel",
                      @"TTSVoice", @"LocalVoice", @"Diagnostics"];
    NSMutableDictionary *d = [CCReadPrefsFile() mutableCopy] ?: [NSMutableDictionary dictionary];
    NSUInteger moved = 0;
    for (NSString *k in keys) {
        if (d[k]) continue;
        id v = (__bridge_transfer id)CFPreferencesCopyAppValue(
                   (__bridge CFStringRef)k, (__bridge CFStringRef)CC_DOMAIN);
        if (v) { d[k] = v; moved++; }
    }
    if (moved) {
        BOOL ok = [d writeToFile:CC_PREF_PATH atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                         ofItemAtPath:CC_PREF_PATH error:nil];
        SLog(@"migrate CFPreferences -> file keys=%lu ok=%d", (unsigned long)moved, ok);
    }
}

- (void)saveValue:(id)value forKey:(NSString *)key {
    // 只记录非敏感值；API Key 只记长度，避免日志泄露
    if ([key isEqualToString:@"DeepLKey"] || [key isEqualToString:@"GoogleKey"] ||
        [key isEqualToString:@"AIKey"]) {
        SLog(@"save %@ len=%lu", key, (unsigned long)[[value description] length]);
    } else {
        SLog(@"save %@ = %@", key, value);
    }
    // 直接写守护进程读取的那份 plist，绕开 Settings.app 容器/CFPreferences 缓存。
    NSMutableDictionary *d = [CCReadPrefsFile() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value) d[key] = value;
    else [d removeObjectForKey:key];
    BOOL ok = [d writeToFile:CC_PREF_PATH atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                     ofItemAtPath:CC_PREF_PATH error:nil];
    if (!ok) SLog(@"save direct FAILED %@", key);
    // 双写：万一 Settings.app 沙盒不让我写 /var/mobile/Library/Preferences，
    // 至少 CFPreferences 容器里还有一份，守护进程会扫描容器补回来。
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)CC_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CC_NOTIF, NULL, NULL, YES);
}

// 设置页显示/读取也直接走同一个文件，避免界面显示和守护进程看到的值不一致。
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    id k = [specifier propertyForKey:@"key"];
    if ([k isKindOfClass:[NSString class]] && [k length]) {
        id v = CCReadPrefsFile()[k];
        if (!v) v = (__bridge_transfer id)CFPreferencesCopyAppValue(
                        (__bridge CFStringRef)k, (__bridge CFStringRef)CC_DOMAIN);
        if (v) return v;
        id def = [specifier propertyForKey:@"default"];
        return def ?: @"";
    }
    return [super readPreferenceValue:specifier];
}

// 所有带 key 的单元格（开关/输入框）都显式写入 net.user.callcaption 域，
// 避免 Preferences 默认 setter 在 rootless 环境把值写到别的域或没同步。
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    id k = [specifier propertyForKey:@"key"];
    if ([k isKindOfClass:[NSString class]] && [k length]) {
        [self saveValue:value forKey:(NSString *)k];
    } else {
        [super setPreferenceValue:value specifier:specifier];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CCMigrateCFPrefsToFile();
    NSString *dk = CCObjString(@"DeepLKey", @"");
    NSString *gk = CCObjString(@"GoogleKey", @"");
    SLog(@"viewWillAppear Engine=%@ DeepLKeyLen=%lu GoogleKeyLen=%lu",
         CCObjString(@"Engine", @"auto"),
         (unsigned long)dk.length, (unsigned long)gk.length);
}

- (void)presentSheet:(UIAlertController *)sheet {
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect =
            CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

// ---------- 引擎 ----------

- (void)chooseEngine {
    NSArray *vals = @[@"auto", @"deepl", @"bing", @"google", @"ai"];
    NSArray *titles = @[@"自动（推荐）", @"DeepL", @"Bing（免费·国内推荐）",
                        @"Google（免费 / Key）", @"AI 自定义"];
    NSString *cur = CCObjString(@"Engine", @"auto");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"翻译引擎"
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < vals.count; i++) {
        NSString *mark = [vals[i] isEqualToString:cur] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[mark stringByAppendingString:titles[i]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self saveValue:vals[i] forKey:@"Engine"];
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

// ---------- 音色 ----------

- (void)chooseVoiceForPrefix:(NSString *)prefix key:(NSString *)key title:(NSString *)title {
    NSMutableArray *vals = [NSMutableArray arrayWithObject:@""];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"系统默认"];
    for (AVSpeechSynthesisVoice *v in [AVSpeechSynthesisVoice speechVoices]) {
        if ([[v.language lowercaseString] hasPrefix:prefix]) {
            [vals addObject:v.identifier];
            NSString *q = (v.quality == AVSpeechSynthesisVoiceQualityEnhanced) ? @" · 增强" : @"";
            [titles addObject:[NSString stringWithFormat:@"%@（%@%@）", v.name, v.language, q]];
        }
    }
    NSString *cur = CCObjString(key, @"");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < vals.count; i++) {
        NSString *mark = [vals[i] isEqualToString:cur] ? @"✓ " : @"";
        [sheet addAction:[UIAlertAction actionWithTitle:[mark stringByAppendingString:titles[i]]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            [self saveValue:vals[i] forKey:key];
            [self reload];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

- (void)chooseZhVoice { [self chooseVoiceForPrefix:@"zh" key:@"TTSVoice" title:@"中文播报音色"]; }
- (void)chooseEnVoice { [self chooseVoiceForPrefix:@"en" key:@"LocalVoice" title:@"英文播报音色"]; }

// ---------- 日志 ----------

- (void)openLog {
    NSString *path = @"/var/mobile/Library/CallCaption/probe.log";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"诊断日志"
                                                                  message:path
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"用 Filza 打开" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        NSURL *u = [NSURL URLWithString:@"filza://view/var/mobile/Library/CallCaption/probe.log"];
        [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = path;
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet];
}

// ---------- 接口测试 ----------
static NSString *CCApiEsc(NSString *s) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *CCApiSnippet(NSData *data) {
    if (!data) return @"";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return @"";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    s = [s stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (s.length > 120) s = [s substringToIndex:120];
    return s;
}

- (void)deeplTestKey:(NSString *)key endpoint:(NSString *)endpoint
          completion:(void (^)(NSInteger status, NSString *summary))done {
    NSMutableString *body = [NSMutableString stringWithFormat:
        @"auth_key=%@&text=Hello&source_lang=EN&target_lang=ZH", CCApiEsc(key)];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    req.timeoutInterval = 4.0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                               ? [(NSHTTPURLResponse *)resp statusCode] : 0;
            if (err) {
                done(status, [NSString stringWithFormat:@"HTTP %ld · 网络错误：%@",
                              (long)status, err.localizedDescription]);
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *out = nil;
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSArray *arr = json[@"translations"];
                if ([arr isKindOfClass:[NSArray class]] && arr.count > 0) out = arr[0][@"text"];
            }
            if ([out isKindOfClass:[NSString class]] && out.length)
                done(status, [NSString stringWithFormat:@"HTTP %ld · 成功：%@", (long)status, out]);
            else
                done(status, [NSString stringWithFormat:@"HTTP %ld · %@", (long)status, CCApiSnippet(data)]);
        }] resume];
}

- (void)testTranslationAPI {
    NSString *engine = CCObjString(@"Engine", @"auto");
    NSString *dk = CCObjString(@"DeepLKey", @"");
    NSString *gk = CCObjString(@"GoogleKey", @"");
    NSString *aiURL = CCObjString(@"AIURL", @"");
    NSString *aiKey = CCObjString(@"AIKey", @"");
    NSString *aiModel = CCObjString(@"AIModel", @"deepseek-chat");

    SLog(@"api test start engine=%@ deeplKeyLen=%lu googleKeyLen=%lu aiURL=%@ aiKeyLen=%lu",
         engine, (unsigned long)dk.length, (unsigned long)gk.length, aiURL,
         (unsigned long)aiKey.length);

    UIAlertController *loading = [UIAlertController alertControllerWithTitle:@"接口测试"
        message:@"正在请求 DeepL / Google / AI / Bing…" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:loading animated:YES completion:nil];

    NSMutableDictionary *res = [NSMutableDictionary dictionary];
    dispatch_group_t group = dispatch_group_create();

    if (!dk.length) {
        res[@"DeepL"] = @"未填 Key";
    } else {
        dispatch_group_enter(group);
        [self deeplTestKey:dk endpoint:@"https://api-free.deepl.com/v2/translate"
              completion:^(NSInteger status, NSString *summary) {
            if (status == 401 || status == 403) {
                [self deeplTestKey:dk endpoint:@"https://api.deepl.com/v2/translate"
                      completion:^(NSInteger s2, NSString *sum2) {
                    @synchronized(res) {
                        res[@"DeepL"] = [NSString stringWithFormat:@"free %@ · pro %@", summary, sum2];
                    }
                    dispatch_group_leave(group);
                }];
            } else {
                @synchronized(res) { res[@"DeepL"] = summary; }
                dispatch_group_leave(group);
            }
        }];
    }

    dispatch_group_enter(group);
    {
        NSString *urlStr;
        if (gk.length) {
            urlStr = [NSString stringWithFormat:
                @"https://translation.googleapis.com/language/translate/v2?key=%@&q=Hello&source=en&target=zh",
                CCApiEsc(gk)];
        } else {
            urlStr = @"https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh&dt=t&q=Hello";
        }
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        req.timeoutInterval = 4.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                   ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line;
                if (err) {
                    line = [NSString stringWithFormat:@"%@ HTTP %ld · 网络错误：%@",
                            gk.length ? @"Cloud" : @"免费", (long)status, err.localizedDescription];
                } else {
                    line = [NSString stringWithFormat:@"%@ HTTP %ld · %@",
                            gk.length ? @"Cloud" : @"免费", (long)status, CCApiSnippet(data)];
                }
                @synchronized(res) { res[@"Google"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    if (!aiURL.length || !aiKey.length) {
        res[@"AI"] = @"未配置 URL/Key";
    } else {
        dispatch_group_enter(group);
        NSDictionary *body = @{
            @"model": aiModel.length ? aiModel : @"deepseek-chat",
            @"temperature": @0,
            @"max_tokens": @40,
            @"messages": @[
                @{@"role": @"system", @"content": @"Translate to Chinese. Output only the translation."},
                @{@"role": @"user", @"content": @"Hello"},
            ],
        };
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:aiURL]];
        req.HTTPMethod = @"POST";
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", aiKey] forHTTPHeaderField:@"Authorization"];
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        req.timeoutInterval = 6.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:req
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                   ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *line;
                if (err) {
                    line = [NSString stringWithFormat:@"HTTP %ld · 网络错误：%@",
                            (long)status, err.localizedDescription];
                } else {
                    line = [NSString stringWithFormat:@"HTTP %ld · %@",
                            (long)status, CCApiSnippet(data)];
                }
                @synchronized(res) { res[@"AI"] = line; }
                dispatch_group_leave(group);
            }] resume];
    }

    dispatch_group_enter(group);
    {
        NSMutableURLRequest *auth = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://edge.microsoft.com/translate/auth"]];
        auth.timeoutInterval = 4.0;
        [[[NSURLSession sharedSession] dataTaskWithRequest:auth
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]]
                                   ? [(NSHTTPURLResponse *)resp statusCode] : 0;
                NSString *token = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                token = [token stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (err || !token.length) {
                    @synchronized(res) {
                        res[@"Bing"] = [NSString stringWithFormat:@"auth HTTP %ld · %@",
                                        (long)status, err.localizedDescription ?: CCApiSnippet(data)];
                    }
                    dispatch_group_leave(group);
                    return;
                }
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
                    [NSURL URLWithString:@"https://api-edge.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans&from=en"]];
                req.HTTPMethod = @"POST";
                [req setValue:[NSString stringWithFormat:@"Bearer %@", token]
           forHTTPHeaderField:@"Authorization"];
                [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
                req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@[@{@"Text": @"Hello"}]
                                                               options:0 error:nil];
                req.timeoutInterval = 5.0;
                [[[NSURLSession sharedSession] dataTaskWithRequest:req
                    completionHandler:^(NSData *data2, NSURLResponse *resp2, NSError *err2) {
                        NSInteger st2 = [resp2 isKindOfClass:[NSHTTPURLResponse class]]
                                         ? [(NSHTTPURLResponse *)resp2 statusCode] : 0;
                        NSString *line = err2
                            ? [NSString stringWithFormat:@"HTTP %ld · 网络错误：%@",
                               (long)st2, err2.localizedDescription]
                            : [NSString stringWithFormat:@"HTTP %ld · %@",
                               (long)st2, CCApiSnippet(data2)];
                        @synchronized(res) { res[@"Bing"] = line; }
                        dispatch_group_leave(group);
                    }] resume];
            }] resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSArray *order = @[@"DeepL", @"Google", @"AI", @"Bing"];
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *k in order) {
            NSString *v = res[k] ?: @"未测试";
            [lines addObject:[NSString stringWithFormat:@"%@：%@", k, v]];
            SLog(@"api test %@: %@", k, v);
        }
        NSString *summary = [lines componentsJoinedByString:@"\n"];
        [loading dismissViewControllerAnimated:YES completion:^{
            UIAlertController *result = [UIAlertController alertControllerWithTitle:@"接口测试结果"
                message:summary preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"复制结果"
                style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
                [UIPasteboard generalPasteboard].string = summary;
            }]];
            [result addAction:[UIAlertAction actionWithTitle:@"确定"
                style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:result animated:YES completion:nil];
        }];
    });
}

@end
