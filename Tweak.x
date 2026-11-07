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

// 备用观察点（老插件近期使用的 AXSpeech 回调；此版本不改其行为）
%hook AXSpeechManager
- (void)_processAudioBufferCallback:(id)arg1 {
    %orig;
}
%end

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
        CCMark(@"1 ctor enter");
        CCProcessInit();
        CCMark(@"2 procinit done");
        %init(_ungrouped);
        CCMark(@"3 ungrouped hooks installed");
        if (CCIsSpringBoard()) {
            CCMark(@"4 SB branch enter");
            CCUIBoot();
            CCMark(@"5 CCUIBoot done");
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, &SBDarwinCB, NULL, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CCMark(@"6 observer added");
            %init(SBGroup);
            CCMark(@"7 SBGroup init done");
        } else if (CCIsMediaServerd()) {
            CCMark(@"4 MS branch enter");
            CCEngineBoot();
            CCMark(@"5 CCEngineBoot done");
            %init(MSGroup);
            CCMark(@"6 MSGroup init done");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)4 * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                CCPostNotif(@"ms up");
            });
        }
        CCMark(@"8 ctor done");
    } @catch (NSException *e) {
        CCMark(@"ctor EXCEPTION!");
    }
}
