// Tweak.x — CallCaption logos 入口：hook 音频渲染 + 进程分流启动
#import "CCCommon.h"

%hookf(OSStatus, AudioUnitRender,
       AudioUnit unit, AudioUnitRenderActionFlags *ioActionFlags,
       const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
       UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus r = %orig;
    if (r == noErr) CCAudioTapObserve(unit, inBusNumber, inNumberFrames, ioData);
    return r;
}

%hookf(OSStatus, AudioUnitProcess,
       AudioUnit inUnit, AudioUnitScope inScope, AudioUnitRenderActionFlags *ioActionFlags,
       const AudioTimeStamp *inTimeStamp, UInt32 inBusNumber,
       UInt32 inNumberFrames, AudioBufferList *ioData) {
    OSStatus r = %orig;
    if (r == noErr) CCAudioTapObserve(inUnit, inBusNumber, inNumberFrames, ioData);
    return r;
}

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
        }
    } @catch (NSException *e) { }
}

%ctor {
    @try {
        CCProcessInit();
        if (CCIsSpringBoard()) {
            // v0.8.2: SB 侧仅 UI + 通知观察——不安装任何音频钩子、不建 CTCallCenter
            CCUIBoot();
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, &SBDarwinCB, NULL, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
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
