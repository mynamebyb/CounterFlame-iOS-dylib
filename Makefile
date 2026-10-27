TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = CounterFlameTool
CounterFlameTool_FILES = src/CounterFlameTool.mm
CounterFlameTool_CFLAGS = -fobjc-arc -Wno-error -Wno-deprecated-declarations \
	-Wno-unused-variable -Wno-unused-function -Wno-unused-value \
	-Wno-nullability-completeness -Wno-c++11-extensions -Wno-format
CounterFlameTool_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics
CounterFlameTool_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
