TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = DebPackUI
DebPackUI_FILES = main.m AppDelegate.m RootViewController.m
DebPackUI_FRAMEWORKS = UIKit Foundation
DebPackUI_CFLAGS = -fobjc-arc -Wno-unused-parameter
DebPackUI_CODESIGN_FLAGS = -Sentitlements.plist
DebPackUI_INSTALL_PATH = /Applications

include $(THEOS)/makefiles/application.mk
