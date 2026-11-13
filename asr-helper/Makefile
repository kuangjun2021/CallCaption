TARGET := iphone:clang:latest:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = CallCaptionProASR
CallCaptionProASR_FILES = ../CCProASR.m
CallCaptionProASR_CFLAGS = -fobjc-arc -DCC_PRO -I.. \
  -I../vendor/sherpa-onnx.xcframework/ios-arm64/SherpaOnnxC.framework/Headers \
  -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
CallCaptionProASR_FRAMEWORKS = Foundation Accelerate CoreML Metal CoreGraphics
CallCaptionProASR_LDFLAGS = \
  -Wl,-force_load,$(CURDIR)/../vendor/sherpa-onnx.xcframework/ios-arm64/SherpaOnnxC.framework/SherpaOnnxC \
  -lc++

include $(THEOS_MAKE_PATH)/tool.mk
