THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

# ===== CallCaption Pro：完全独立的包，不与稳定版共享域/目录/通知 =====
TWEAK_NAME = CallCaptionPro CallCaptionProAudioHook CallCaptionProAppProbe
CallCaptionPro_FILES = Tweak.x CCSupport.m CCTranslator.m CCEngine.m CCUI.m CCMicCapture.m CCSettings.m
CallCaptionPro_FRAMEWORKS = Foundation UIKit AudioToolbox CoreTelephony AVFoundation Speech CoreFoundation CallKit
CallCaptionPro_CFLAGS = -fobjc-arc -DCC_PRO -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-command-line-argument -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionPro_LDFLAGS = -Wl,-fixup_chains

# 阶段 1：AudioUnitRender/AudioUnitProcess 观察（只打 RMS，不改音频）
CallCaptionProAudioHook_FILES = CCAudioHook.m
CallCaptionProAudioHook_FRAMEWORKS = Foundation AudioToolbox
CallCaptionProAudioHook_CFLAGS = -fobjc-arc -DCC_PRO -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionProAudioHook_LDFLAGS = -Wl,-fixup_chains

# 阶段 2：注入 WhatsApp，包住 AudioUnit render callback 抓对方 PCM
CallCaptionProAppProbe_FILES = CCAppProbe.m
CallCaptionProAppProbe_FRAMEWORKS = Foundation AudioToolbox
CallCaptionProAppProbe_CFLAGS = -fobjc-arc -DCC_PRO -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionProAppProbe_LDFLAGS = -Wl,-fixup_chains

BUNDLE_NAME = CallCaptionProPrefs
CallCaptionProPrefs_FILES = CallCaptionRootListController.m CCSettings.m
CallCaptionProPrefs_FRAMEWORKS = Foundation UIKit AVFoundation
CallCaptionProPrefs_CFLAGS = -fobjc-arc -Iinclude -DCC_PRO -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionProPrefs_LDFLAGS = -Wl,-fixup_chains -Wl,-undefined,dynamic_lookup

# 独立音频守护进程（系统级 Tap）
TOOL_NAME = CallCaptionProAudioService
CallCaptionProAudioService_FILES = CCAudioService.m CCSupport.m CCTranslator.m CCTencentTranslate.m
CallCaptionProAudioService_FRAMEWORKS = Foundation AudioToolbox AVFAudio AVFoundation Speech CoreFoundation
CallCaptionProAudioService_CFLAGS = -fobjc-arc -DCC_TOOL -DCC_PRO -Wno-deprecated-declarations -Wno-arc-performSelector-leaks -Wno-unused-variable -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionProAudioService_LDFLAGS = -Wl,-fixup_chains
CallCaptionProAudioService_CODESIGN_FLAGS = -Sentitlements/CallCaptionProAudioService.plist
CallCaptionProAudioService_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
include $(THEOS_MAKE_PATH)/tool.mk
