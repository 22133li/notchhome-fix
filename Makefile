DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include NHFixBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = zzNotchHomeFix
zzNotchHomeFix_FILES = $(wildcard Hooks/*.xm Sources/*.m)
zzNotchHomeFix_CFLAGS = -fobjc-arc -I./Headers -I./Sources
zzNotchHomeFix_FRAMEWORKS = UIKit Foundation CoreFoundation
zzNotchHomeFix_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
