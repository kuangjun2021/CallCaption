// Tweak.x — CallCaption logos 入口：hook 音频渲染 + 进程分流启动
#import "CCCommon.h"

// v0.8.3 诊断：彻底移除函数钩子（AudioUnitRender/AudioUnitProcess）。
// 理论：此越狱环境的函数钩取（trampoline）在 arm64e 上有缺陷，
// 会毒化 mediaserverd 的音频函数 → 通话音频会话建立失败。
// 电话助手（正常工作的录音插件）只用 ObjC 方法钩取，不用函数钩取。

%group MSGroup
%end

%group SBGroup
%end

static void SBDarwinCB(CFNotificationCenterRef center, void *observer,
                       CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @try {
        NSString *n = (__bridge NSString *)name;
        if (![n hasPrefix:CC_NOTIF_PREFIX]) return;
        NSString *suffix = [n substringFromIndex:CC_NOTIF_PREFIX.length];
        if ([suffix isEqualToString:@"line"]) {
            CCTransportDrain();
        } else if ([suffix hasPrefix:@"msg."]) {
            CCTransportHandleChunk(suffix);
        } else if ([suffix hasPrefix:@"log "]) {
            CCLogLine([suffix substringFromIndex:4]);
        } else if ([suffix hasPrefix:@"mark "]) {
            CCMark([@"ms " stringByAppendingString:[suffix substringFromIndex:5]]);
        } else if ([suffix isEqualToString:@"call"]) {
            CCUICallStateChanged(@"CALL CONNECTED");
        } else if ([suffix isEqualToString:@"callend"]) {
            CCUICallStateChanged(@"CALL ENDED");
        } else if ([suffix isEqualToString:@"act"]) {
            // 心跳（忽略内容）
        } else if ([suffix isEqualToString:@"prefschanged"]) {
            CCPrefsReload();
            CCUIRefreshPanel();
        }
    } @catch (NSException *e) { }
}

%ctor {
    @try {
        CCProcessInit();
        if (CCIsSpringBoard()) {
            // 注入存活标记：这行进了 probe.log，就说明 SpringBoard 侧 dylib 正常加载
            CCLogLine(@"SB dylib injected");
            CCMark(@"sb dylib injected");
            // v0.8.2: SB 侧仅 UI + 通知观察——不安装任何音频钩子、不建 CTCallCenter
            CCUIBoot();
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, &SBDarwinCB, NULL, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            // v0.10.2: 显式再注册 "line"（NULL 通配注册在部分场景收不到命名通知）
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, &SBDarwinCB,
                (__bridge CFStringRef)[CC_NOTIF_PREFIX stringByAppendingString:@"line"],
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, &SBDarwinCB,
                (__bridge CFStringRef)[CC_NOTIF_PREFIX stringByAppendingString:@"prefschanged"],
                NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            %init(SBGroup);
        } else if (CCIsMediaServerd()) {
            %init(_ungrouped);   // 音频钩子只在 mediaserverd 安装
            CCEngineBoot();
            %init(MSGroup);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)4 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                CCPostNotif(@"ms up");
            });
        }
    } @catch (NSException *e) {
        CCMark(@"ctor EXCEPTION!");
    }
}
