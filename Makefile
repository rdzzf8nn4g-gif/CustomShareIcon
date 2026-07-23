DEBUG = 0
FINALPACKAGE = 1
PACKAGE_VERSION = 0.0.1

TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CustomShareIcon
CustomShareIcon_FILES = Tweak.x
CustomShareIcon_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += customshareiconprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
