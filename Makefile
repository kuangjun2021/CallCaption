THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallCaption
CallCaption_FILES = Tweak.x CCSupport.m CCTranslator.m CCEngine.m CCUI.m CCMicCapture.m
CallCaption_FRAMEWORKS = Foundation UIKit AudioToolbox CoreTelephony AVFoundation Speech CoreFoundation CallKit
CallCaption_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-command-line-argument -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaption_LDFLAGS = -Wl,-fixup_chains

BUNDLE_NAME = CallCaptionPrefs
CallCaptionPrefs_FILES = CallCaptionRootListController.m
CallCaptionPrefs_FRAMEWORKS = Foundation UIKit AVFoundation

CallCaptionPrefs_CFLAGS = -fobjc-arc -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
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
