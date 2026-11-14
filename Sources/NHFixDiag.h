#pragma once

#import <Foundation/Foundation.h>

// Diagnostic build support: appends plain-text lines to
// /var/mobile/Library/Logs/NHFix/diag.txt so an on-device run can
// report which link of the chain (gate, install, state, geometry) failed.
#ifdef __cplusplus
extern "C" {
#endif
void nhfix_diagLogF(const char *format, ...);
extern NSUInteger nhfix_diagWillBegin;
extern NSUInteger nhfix_diagDidEnd;
extern NSUInteger nhfix_diagFrameCalls;
extern NSUInteger nhfix_diagFrameActive;
extern NSUInteger nhfix_diagIconOK;
extern NSUInteger nhfix_diagScaleCalls;
extern NSUInteger nhfix_diagCornerCalls;
extern NSUInteger nhfix_diagMatchCalls;
extern NSUInteger nhfix_diagAnimCalls;
extern NSUInteger nhfix_diagAnimSkip;
extern NSUInteger nhfix_diagAnimResp;
extern NSUInteger nhfix_diagLayoutResp;
extern NSInteger nhfix_diagLastStartedAtHome;
extern NSInteger nhfix_diagLastBoundsOK;
#ifdef __cplusplus
}
#endif
