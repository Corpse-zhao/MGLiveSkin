TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MGLiveSkin
MGLiveSkin_FILES = Tweak.x MGManager.m
MGLiveSkin_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
MGLiveSkin_FRAMEWORKS = UIKit Foundation PhotosUI ImageIO
MGLiveSkin_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
