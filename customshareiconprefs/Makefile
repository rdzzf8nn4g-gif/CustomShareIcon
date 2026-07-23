TARGET := iphone:clang:14.5:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CustomShareIconPrefs

CustomShareIconPrefs_FILES = CustomShareIconRootListController.m
CustomShareIconPrefs_FRAMEWORKS = UIKit PhotosUI UniformTypeIdentifiers
CustomShareIconPrefs_PRIVATE_FRAMEWORKS = Preferences
CustomShareIconPrefs_INSTALL_PATH = /Library/PreferenceBundles
CustomShareIconPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
