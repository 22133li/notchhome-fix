#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
// Same enable gate as the original package (NHStart): hw.machine in the
// audited 19-model notch list and the disable-repair sentinel absent.
BOOL nhfix_computeEnabled(void);
NSString *nhfix_machineName(void);
BOOL nhfix_sentinelExists(void);
// SpringBoard switcher / home-screen window, found the same way the
// original finds it (connectedScenes -> windows -> class name).
UIWindow *nhfix_findSwitcherWindow(void);
BOOL nhfix_isPlausibleBounds(CGRect rect);
#ifdef __cplusplus
}
#endif
