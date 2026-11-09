THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallCaption CallCaptionAudioHook CallCaptionAppProbe CallCaptionAssistant
CallCaption_FILES = Tweak.x CCSupport.m CCTranslator.m CCEngine.m CCUI.m CCMicCapture.m CCSettings.m
CallCaption_FRAMEWORKS = Foundation UIKit AudioToolbox CoreTelephony AVFoundation Speech CoreFoundation CallKit
CallCaption_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-command-line-argument -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaption_LDFLAGS = -Wl,-fixup_chains

# 阶段 1：LCT 同款 AudioUnitRender/AudioUnitProcess 观察（只打 RMS，不改音频）
CallCaptionAudioHook_FILES = CCAudioHook.m
CallCaptionAudioHook_FRAMEWORKS = Foundation AudioToolbox
CallCaptionAudioHook_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionAudioHook_LDFLAGS = -Wl,-fixup_chains

# 阶段 2 诊断：注入通话 App（WhatsApp），包住 AudioUnit 的 render callback 抓对方 PCM
CallCaptionAppProbe_FILES = CCAppProbe.m
CallCaptionAppProbe_FRAMEWORKS = Foundation AudioToolbox
CallCaptionAppProbe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionAppProbe_LDFLAGS = -Wl,-fixup_chains

# Stage A：assistantd 内本地 Siri 识别器验证（独立 dylib，全部私有 API 动态调用）
CallCaptionAssistant_FILES = CCAssistant.m
CallCaptionAssistant_FRAMEWORKS = Foundation
CallCaptionAssistant_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionAssistant_LDFLAGS = -Wl,-fixup_chains -Wl,-undefined,dynamic_lookup

BUNDLE_NAME = CallCaptionPrefs
CallCaptionPrefs_FILES = CallCaptionRootListController.m CCSettings.m
CallCaptionPrefs_FRAMEWORKS = Foundation UIKit AVFoundation

CallCaptionPrefs_CFLAGS = -fobjc-arc -Iinclude -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionPrefs_LDFLAGS = -Wl,-fixup_chains -Wl,-undefined,dynamic_lookup

# v0.10: 独立音频守护进程（系统级 Tap 抓取通话对方声音，无钩子/无 mediaserverd）
TOOL_NAME = CallCaptionAudioService
CallCaptionAudioService_FILES = CCAudioService.m CCSupport.m CCTranslator.m
CallCaptionAudioService_FRAMEWORKS = Foundation AudioToolbox AVFAudio AVFoundation Speech CoreFoundation
CallCaptionAudioService_CFLAGS = -fobjc-arc -DCC_TOOL -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionAudioService_LDFLAGS = -Wl,-fixup_chains
CallCaptionAudioService_CODESIGN_FLAGS = -Sentitlements/CallCaptionAudioService.plist
CallCaptionAudioService_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/tool.mk
