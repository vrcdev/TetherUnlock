TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = misd

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TetherUnlock

TetherUnlock_FILES = Tweak.x
TetherUnlock_CFLAGS = -fobjc-arc
TetherUnlock_LIBRARIES = substrate
TetherUnlock_FRAMEWORKS = Foundation CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
