// CCSupport.m — 进程判断 / 设置 / 日志 / Darwin 通知 / 结果传输
#import "CCCommon.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>

static BOOL g_sb = NO, g_ms = NO, g_as = NO;
static NSDictionary *g_prefs = nil;

BOOL CCIsSpringBoard(void) { return g_sb; }
BOOL CCIsMediaServerd(void) { return g_ms; }
BOOL CCIsAudioService(void) { return g_as; }

void CCProcessInit(void) {
    NSString *pn = [[NSProcessInfo processInfo] processName];
    g_sb = [pn isEqualToString:@"SpringBoard"];
    g_ms = [pn isEqualToString:@"mediaserverd"];
    g_as = [pn isEqualToString:@"CallCaptionAudioService"];
}

// ============ 设置 ============

static NSDictionary *CCReadGlobalPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                       @"/var/mobile/Library/Preferences/net.user.callcaption.plist"];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

// Settings.app 在沙盒里通过 CFPreferences 写设置时，可能落在自己的容器而不是
// /var/mobile/Library/Preferences。守护进程是 root，可以扫描容器把值找回来。
static NSDate *g_containerPrefsDate = nil;
static NSDate *CCContainerPrefsDate(void) { return g_containerPrefsDate; }

static NSDictionary *CCFindContainerPrefs(void) {
    static NSDictionary *cache = nil;
    static CFAbsoluteTime cacheAt = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (cache && now - cacheAt < 1.0) return cache;
    cacheAt = now;
    cache = nil;

    NSString *base = @"/var/mobile/Containers/Data/Application";
    NSArray *apps = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
    NSDate *bestDate = nil;
    for (NSString *app in apps) {
        NSString *p = [[base stringByAppendingPathComponent:app]
                       stringByAppendingPathComponent:@"Library/Preferences/net.user.callcaption.plist"];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        if (!attrs) continue;
        NSDate *m = attrs[NSFileModificationDate];
        if (cache && m && bestDate && [m compare:bestDate] != NSOrderedDescending) continue;
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]]) {
            cache = d;
            bestDate = m;
            g_containerPrefsDate = m;
            static NSString *loggedPath = nil;
            if (![loggedPath isEqualToString:p]) {
                loggedPath = p;
                CCLogf(@"prefs: found Settings.app container prefs (%@)", p);
            }
        }
    }
    return cache;
}

void CCPrefsReload(void) {
    @try {
        // 读取顺序：全局 plist 为准；如果 Settings.app 的容器 plist 比全局文件更新，
        // 说明用户刚在设置 App 里改过 → 用容器值覆盖（否则会出现“开关开着、日志 cloud=0”）。
        if (CCIsAudioService() || CCIsSpringBoard()) {
            NSString *gpath = @"/var/mobile/Library/Preferences/net.user.callcaption.plist";
            NSDictionary *global = CCReadGlobalPrefs();
            NSMutableDictionary *m = [global mutableCopy] ?: [NSMutableDictionary dictionary];
            NSDictionary *container = CCFindContainerPrefs();
            NSDate *cdate = CCContainerPrefsDate();
            NSDate *gdate = [[NSFileManager defaultManager]
                             attributesOfItemAtPath:gpath error:nil][NSFileModificationDate];
            BOOL containerWins = container.count && cdate &&
                                 (!gdate || [cdate compare:gdate] == NSOrderedDescending);
            BOOL changed = NO;
            if (container.count) {
                for (id k in container) {
                    id v = container[k];
                    if (containerWins) {
                        if (![m[k] isEqual:v]) { m[k] = v; changed = YES; }
                    } else if (!m[k] ||
                               ([m[k] isKindOfClass:[NSString class]] && ![m[k] length])) {
                        m[k] = v;
                        changed = YES;
                    }
                }
            }
            if (changed && CCIsAudioService()) {
                BOOL ok = [m writeToFile:gpath atomically:YES];
                [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666}
                                                 ofItemAtPath:gpath error:nil];
                CCLogf(@"prefs: merged Settings.app values into global ok=%d (deeplKeyLen=%lu engine=%@ cloud=%d)",
                       ok, (unsigned long)[(m[@"DeepLKey"] ?: @"") length], m[@"Engine"] ?: @"?",
                       [m[@"CloudASR"] boolValue]);
            }
            g_prefs = m;
            return;
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
        CFDictionaryRef dref = CFPreferencesCopyMultiple(NULL,
            (__bridge CFStringRef)CC_DOMAIN, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        NSDictionary *d = (__bridge_transfer NSDictionary *)dref;
        if ([d isKindOfClass:[NSDictionary class]]) g_prefs = d;
        else g_prefs = @{};
    } @catch (NSException *e) {
        g_prefs = @{};
    }
}

id CCPref(NSString *key) {
    if (!g_prefs) CCPrefsReload();
    return [g_prefs objectForKey:key];
}

BOOL CCPrefBool(NSString *key, BOOL def) {
    id v = CCPref(key);
    if (!v) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [v boolValue] || [v isEqualToString:@"YES"] || [v isEqualToString:@"1"];
    return def;
}

NSString *CCPrefStr(NSString *key, NSString *def) {
    id v = CCPref(key);
    if ([v isKindOfClass:[NSString class]] && ((NSString *)v).length > 0) return v;
    return def;
}

// ============ 日志 ============

static void SBWriteLog(NSString *line) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:CC_DIR])
            [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *attrs = [fm attributesOfItemAtPath:CC_LOG_PATH error:nil];
        if (attrs && [attrs fileSize] > 1024 * 1024)
            [fm removeItemAtPath:CC_LOG_PATH error:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:CC_LOG_PATH];
        if (!fh) {
            [line writeToFile:CC_LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
        // 守护进程(root)与 SpringBoard(mobile) 互写：日志始终 0666
        [fm setAttributes:@{NSFilePosixPermissions: @0666} ofItemAtPath:CC_LOG_PATH error:nil];
    } @catch (NSException *e) { }
}

void CCLogf(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    CCLogLine(msg);
}

void CCLogLine(NSString *msg) {
    @try {
        static NSDateFormatter *fmt;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"MM-dd HH:mm:ss";
            fmt.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        });
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
        if (CCIsSpringBoard() || CCIsAudioService()) {
            SBWriteLog(line);
        } else if (CCIsMediaServerd()) {
            // MS 侧没有文件权限，日志经通知名带到 SB（内容截 80 字符）
            NSString *s = msg.length > 80 ? [msg substringToIndex:80] : msg;
            CCPostNotif([NSString stringWithFormat:@"log %@", s]);
        }
    } @catch (NSException *e) { }
}

// 启动路标：每个阶段一行，独立于其它任何逻辑，专用于定位挂死点
void CCMark(NSString *tag) {
    @try {
        NSString *line = [NSString stringWithFormat:@"[MARK %@] %@\n",
                          [NSDate date], tag];
        NSString *path = @"/var/mobile/Library/CallCaption/markers.log";
        if (CCIsSpringBoard() || CCIsAudioService()) {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                NSFileManager *fm = [NSFileManager defaultManager];
                if (![fm fileExistsAtPath:CC_DIR])
                    [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES attributes:nil error:nil];
                [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                return;
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } else if (CCIsMediaServerd()) {
            CCPostNotif([NSString stringWithFormat:@"mark %@", tag]);
        }
    } @catch (NSException *e) { }
}

// ============ Darwin 通知 ============

void CCPostNotif(NSString *suffix) {
    @try {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)[CC_NOTIF_PREFIX stringByAppendingString:suffix],
            NULL, NULL, TRUE);
    } @catch (NSException *e) { }
}

// ============ v0.10 采集开关（SB 侧写文件，守护进程监视） ============

void CCSetArmed(BOOL armed) {
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (armed && ![fm fileExistsAtPath:CC_DIR]) {
            [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES
                            attributes:@{NSFilePosixPermissions: @0777} error:nil];
        }
        if (armed) {
            [@"" writeToFile:CC_ARM_PATH atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
            [fm setAttributes:@{NSFilePosixPermissions: @0666}
                   ofItemAtPath:CC_ARM_PATH error:nil];
        } else {
            [fm removeItemAtPath:CC_ARM_PATH error:nil];
        }
        CCPostNotif(armed ? @"arm" : @"disarm");
    } @catch (NSException *e) { }
}

void CCSetPrefBool(NSString *key, BOOL value) {
    @try {
        // v0.13.16: 面板按钮也直接写守护进程读取的 mobile plist。
        // 之前只写 CFPreferences，而 CCPrefsReload 已改成读文件，导致面板开关“点了没反应”。
        NSString *path = @"/var/mobile/Library/Preferences/net.user.callcaption.plist";
        NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
        d[key] = @(value);
        BOOL ok = [d writeToFile:path atomically:YES];
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0666}
                                         ofItemAtPath:path error:nil];
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)@(value),
                                 (__bridge CFStringRef)CC_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)CC_DOMAIN);
        CCPrefsReload();          // 立即刷新 SpringBoard 内存缓存，否则按钮状态看不到变化
        CCPostNotif(@"prefschanged");
        CCLogf(@"pref set %@=%d file=%d", key, value, ok);
    } @catch (NSException *e) { }
}

// ============ 传输：MS → SB 的结果行 ============
// 主路径：spool 文件追加（SB 以 mobile 身份预创建 0666 文件，MS 追加写入）
// 兜底：Darwin 通知名分片 msg.<seq>.<i>/<n>.<payload>
// SB 侧收到 "line" 通知即排空 spool；收到 "msg." 分片则重组。

static long g_seq = 0;

static void MSSendViaSpool(NSString *line) {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:CC_SPOOL_PATH];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        NSData *d = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [fh writeData:d];
        [fh closeFile];
        CCPostNotif(@"line");
    } @catch (NSException *e) {
        @try { [fh closeFile]; } @catch (NSException *e2) { }
    }
}

static void MSSendViaChunks(NSString *line) {
    long seq = ++g_seq;
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger total = (d.length + 59) / 60;
    if (total == 0) total = 1;
    for (NSUInteger i = 0; i < total; i++) {
        NSRange r = NSMakeRange(i * 60, MIN(60, d.length - i * 60));
        NSString *part = [[NSString alloc] initWithData:[d subdataWithRange:r] encoding:NSUTF8StringEncoding];
        CCPostNotif([NSString stringWithFormat:@"msg.%ld.%lu_%lu.%@", seq, (unsigned long)(i + 1), (unsigned long)total, part]);
    }
}

void CCTransportSendLine(NSString *line) {
    if (line.length == 0) return;
    @try {
        MSSendViaSpool(line);
        // 无法确认写入是否成功（句柄非空但沙盒可能拦截），做一份兜底分片太吵；
        // 约定：只有句柄为空才走兜底。
    } @catch (NSException *e) {
        MSSendViaChunks(line);
    }
}

// ---------- SB 侧：目录/文件初始化 + 排空 ----------

static long g_spoolOffset = 0;
static NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *g_chunks;
static void SBDeliverLine(NSString *line);

void CCTransportDrain(void) {
    @try {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:CC_SPOOL_PATH];
        if (!fh) return;
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:CC_SPOOL_PATH error:nil];
        unsigned long long size = attrs ? [attrs fileSize] : 0;
        if (size <= (unsigned long long)g_spoolOffset) { [fh closeFile]; return; }
        [fh seekToFileOffset:(unsigned long long)g_spoolOffset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        g_spoolOffset += d.length;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
            if (line.length) SBDeliverLine(line);
        }
        // 过大则重置
        if (size > 256 * 1024) {
            @try {
                NSFileHandle *w = [NSFileHandle fileHandleForWritingAtPath:CC_SPOOL_PATH];
                if (w) { [w truncateFileAtOffset:0]; [w closeFile]; }
                g_spoolOffset = 0;
            } @catch (NSException *e) { }
        }
    } @catch (NSException *e) { }
}

static void SBDeliverLine(NSString *line) {
#ifdef CC_TOOL
    (void)line;   // 守护进程不消费结果行（只生产）
#else
    CCPrefsReload();   // 设置面板改动后即时生效

    // 防御：同一内容行 1.2 秒内重复到达时丢弃，避免任何识别/翻译异常把字幕计时器无限重置。
    BOOL content = [line hasPrefix:@"R|"] || [line hasPrefix:@"RP|"] ||
                   [line hasPrefix:@"I|"] || [line hasPrefix:@"LR|"] ||
                   [line hasPrefix:@"LRP|"] || [line hasPrefix:@"LI|"];
    static NSString *lastLine = nil;
    static CFAbsoluteTime lastLineAt = 0;
    CFAbsoluteTime nowLine = CFAbsoluteTimeGetCurrent();
    if (content) {
        if (lastLine && [lastLine isEqualToString:line] && nowLine - lastLineAt < 1.2) return;
        lastLine = line;
        lastLineAt = nowLine;
    }

    NSString *dbg = line.length > 70 ? [line substringToIndex:70] : line;
    CCLogf(@"ui line: %@", dbg);
    // 行格式： R|<最终译文>  /  RP|<临时译文>  /  I|<原文>  /  S|<状态>
    //          LR|<我方最终英文译文>  /  LRP|<我方临时译文>  /  LI|<我方原文>
    //          RE|<对方实际引擎>  /  LE|<我方实际引擎>
    // 只有最终译文才 TTS；临时译文只更新字幕，避免 partial 阶段反复播报。
    if ([line hasPrefix:@"LRP|"]) {
        CCUIDeliverLocalTranslated([line substringFromIndex:4]);
    } else if ([line hasPrefix:@"LR|"]) {
        CCUIDeliverLocalTranslated([line substringFromIndex:3]);
    } else if ([line hasPrefix:@"LI|"]) {
        CCUIDeliverLocalOriginal([line substringFromIndex:3]);
    } else if ([line hasPrefix:@"RP|"]) {
        CCUIDeliverRemoteTranslated([line substringFromIndex:3]);
    } else if ([line hasPrefix:@"R|"]) {
        NSString *t = [line substringFromIndex:2];
        CCUIDeliverRemoteTranslated(t);
        if (CCPrefBool(CC_K_TTS_ENABLED, YES)) CCUIEnqueueRemoteTTS(t);
    } else if ([line hasPrefix:@"I|"]) {
        CCUIDeliverRemoteOriginal([line substringFromIndex:2]);
    } else if ([line hasPrefix:@"RE|"]) {
        CCUIDeliverRemoteEngine([line substringFromIndex:3]);
    } else if ([line hasPrefix:@"LE|"]) {
        CCUIDeliverLocalEngine([line substringFromIndex:3]);
    } else if ([line hasPrefix:@"S|"]) {
        CCUIDeliverState([line substringFromIndex:2]);
    }
#endif
}

void CCTransportHandleChunk(NSString *suffix) {
    // 分片格式：msg.<seq>.<i>_<total>.<payload...>（payload 内的 "." 已在重组时还原）
    @try {
        if (!g_chunks || ![suffix hasPrefix:@"msg."]) return;
        NSString *rest = [suffix substringFromIndex:4];
        NSArray *parts = [rest componentsSeparatedByString:@"."];
        if (parts.count < 3) return;
        long seq = [parts[0] longLongValue];
        NSArray *it = [parts[1] componentsSeparatedByString:@"_"];
        if (it.count != 2) return;
        int idx = [it[0] intValue];
        int total = [it[1] intValue];
        if (total <= 0 || idx <= 0 || idx > total) return;
        NSMutableString *payload = [NSMutableString string];
        for (NSUInteger i = 2; i < parts.count; i++) {
            [payload appendString:parts[i]];
            if (i < parts.count - 1) [payload appendString:@"."];
        }
        NSNumber *key = @(seq);
        NSMutableArray<NSString *> *arr = g_chunks[key];
        if (!arr) {
            arr = [NSMutableArray arrayWithCapacity:(NSUInteger)total];
            g_chunks[key] = arr;
        }
        while ((int)arr.count < total) [arr addObject:@""];
        arr[(NSUInteger)(idx - 1)] = payload;
        BOOL complete = YES;
        for (NSString *p in arr) if (p.length == 0) { complete = NO; break; }
        if (complete) {
            NSMutableString *full = [NSMutableString string];
            for (NSString *p in arr) [full appendString:p];
            [g_chunks removeObjectForKey:key];
            SBDeliverLine(full);
        }
        if (g_chunks.count > 32) [g_chunks removeAllObjects]; // 防堆积
    } @catch (NSException *e) { }
}

void CCTransportBoot(void) {
    @try {
        if (!CCIsSpringBoard()) return;
        g_chunks = [NSMutableDictionary dictionary];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:CC_DIR])
            [fm createDirectoryAtPath:CC_DIR withIntermediateDirectories:YES
                          attributes:@{NSFilePosixPermissions: @0777} error:nil];
        if (![fm fileExistsAtPath:CC_SPOOL_PATH])
            [@"" writeToFile:CC_SPOOL_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // 确保权限放开（供守护进程追加），并清空上次遗留
        NSDictionary *attr = @{NSFilePosixPermissions: @0666};
        [fm setAttributes:attr ofItemAtPath:CC_SPOOL_PATH error:nil];
        @try {
            NSFileHandle *w = [NSFileHandle fileHandleForWritingAtPath:CC_SPOOL_PATH];
            if (w) { [w truncateFileAtOffset:0]; [w closeFile]; }
        } @catch (NSException *e) { }
        g_spoolOffset = 0;
        [fm setAttributes:@{NSFilePosixPermissions: @0777} ofItemAtPath:CC_DIR error:nil];
    } @catch (NSException *e) { }
}
