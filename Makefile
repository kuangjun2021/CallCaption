THEOS_PACKAGE_SCHEME = rootless
TARGET := iphone:clang:latest:16.0
ARCHS = arm64e
INSTALL_TARGET_PROCESSES = SpringBoard mediaserverd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallCaption
CallCaption_FILES = Tweak.x CCSupport.m CCTranslator.m CCEngine.m CCUI.m
CallCaption_FRAMEWORKS = Foundation UIKit AudioToolbox CoreTelephony AVFoundation Speech CoreFoundation
CallCaption_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-command-line-argument -Wno-unused-function -fno-objc-msgsend-selector-stubs -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaption_LDFLAGS = -Wl,-fixup_chains

BUNDLE_NAME = CallCaptionPrefs
CallCaptionPrefs_FILES = CallCaptionRootListController.m
CallCaptionPrefs_FRAMEWORKS = Foundation UIKit

CallCaptionPrefs_CFLAGS = -fobjc-arc -fptrauth-intrinsics -fptrauth-calls -fptrauth-returns
CallCaptionPrefs_LDFLAGS = -Wl,-fixup_chains -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
