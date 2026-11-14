#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "NHFixPrivate.h"
#import "NHFixHookSlot.h"
#import "NHFixDiag.h"
#import "NHFixUtil.h"
#include <string.h>
#include <stdarg.h>

// zzNotchHomeFix — companion patch for the ORIGINAL NotchHome 0.5.0
// (com.tsangbaby.notchhome). The original dylib is left byte-identical
// and does all of its own work; this dylib loads after it (zz- prefix,
// the same outer-wrap position the wrap loggers proved on device) and
// only supplements ONE missed case:
//
//   A folder app re-entered from the app switcher, then closed to home.
//   The original's geometry gate requires the modifier instance's
//   first _isEffectivelyHome sample to be 0; a switcher-entered
//   closing leg starts inside the switcher session, where home is
//   already effectively presented, so its first sample is 1 and the
//   original passes the whole leg through with stock geometry
//   (device video, 2026-11-14: direct folder launch sucks, the
//   switcher re-entry of the same app does not).
//
// Supplement rule (v2, set by diag_4 on device): all must hold, per
// query, on the zoom modifier:
//   - a transition is in progress on this instance;
//   - the transition direction captured at transitionWillBegin is 1
//     (closing to home; openings are 0 — the v1 first-sample/live-IH
//     rule fired on openings, because both signals read "at home"
//     there too; direction separates the legs without exception);
//   - the original's own output for this index is still the STOCK
//     icon-zoom value (scale ~0.150; frame either the square
//     icon-sized frame, or — diag_5 — the plain fullscreen fallback
//     frame the system returns when the app has no icon position in
//     the current layout, supplemented only for the index the scale
//     hook marked as stock). If the original fired itself (notch
//     frame / 0.061) or the index is a neighbour (fullscreen / 1.0),
//     pass through untouched.
// Supplement values are the original's own measured outputs:
// frame = fullscreen recentered to (boundsW/2, -30), scale 0.061,
// corner radii = boundsW * 0.2; animation attributes use the
// original's measured A/B spring constants, applied only on legs
// armed as above (identical values to the original's own write, so
// an overlap is harmless).

static NSString *const kNHFixModifierClass = @"SBFullScreenToHomeIconZoomSwitcherModifier";
static NSString *const kNHFixGestureModifierClass = @"SBGestureInitiatedIconZoomAnimationAttributesSwitcherModifier";
static const char *const kNHFixCGRectEncoding = "{CGRect={CGPoint=dd}{CGSize=dd}}";
static const char *const kNHFixRadiiEncoding = "{UIRectCornerRadii=dddd}";

static const double kNHFixNotchCenterY = -30.0;
static const double kNHFixNotchScale = 0.061;
static const double kNHFixNotchRadiusFactor = 0.2;

static const double kNHFixZoomPosDamping = 0.979;
static const double kNHFixZoomPosResponse = 0.788;
static const double kNHFixZoomScaleDamping = 0.979;
static const double kNHFixZoomScaleResponse = 0.704;
static const double kNHFixOtherPosDamping = 0.883;
static const double kNHFixOtherPosResponse = 0.434;
static const double kNHFixOtherScaleDamping = 0.979;
static const double kNHFixOtherScaleResponse = 0.550;

static BOOL sNHFixEnabled = NO;

static NHFixHookSlot *sNHFixSlotWillBegin;
static NHFixHookSlot *sNHFixSlotDidEnd;
static NHFixHookSlot *sNHFixSlotInterrupt;
static NHFixHookSlot *sNHFixSlotFrame;
static NHFixHookSlot *sNHFixSlotScale;
static NHFixHookSlot *sNHFixSlotCorner;
static NHFixHookSlot *sNHFixSlotAnimAttrs;

static id sNHFixCurrentModifier = nil;
static id sNHFixCurrentLayout = nil;

@interface NHFixLegState : NSObject
@property (nonatomic, assign) NSInteger sampleAtBegin;
@property (nonatomic, assign) NSInteger direction;
@property (nonatomic, assign) BOOL inTransition;
@property (nonatomic, assign) NSInteger markedIndex;
@property (nonatomic, assign) BOOL supplementFired;
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, assign) BOOL boundsValid;
@end
@implementation NHFixLegState
- (instancetype)init {
    self = [super init];
    if (self) {
        _sampleAtBegin = -1;
        _direction = -9;
        _markedIndex = -1;
        _bounds = CGRectZero;
    }
    return self;
}
@end

static const void *kNHFixLegStateKey = &kNHFixLegStateKey;

static NHFixLegState *nhfix_legState(id object, BOOL create) {
    if (!object) {
        return nil;
    }
    NHFixLegState *state = objc_getAssociatedObject(object, kNHFixLegStateKey);
    if (!state && create) {
        state = [[NHFixLegState alloc] init];
        objc_setAssociatedObject(object, kNHFixLegStateKey, state,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

static IMP nhfix_savedIMP(NHFixHookSlot *slot) {
    if (!slot) {
        return NULL;
    }
    [slot.lock lock];
    IMP saved = slot.saved;
    [slot.lock unlock];
    return saved;
}

// Live stock _isEffectivelyHome, called through the whole chain (the
// original's replacement returns the stock value unchanged and only
// backfills its own state, exactly as a system query would).
static BOOL nhfix_liveIsEffectivelyHome(id modifier) {
    if (!modifier || ![modifier respondsToSelector:NSSelectorFromString(@"_isEffectivelyHome")]) {
        return NO;
    }
    BOOL result = NO;
    @try {
        result = ((BOOL (*)(id, SEL))objc_msgSend)(modifier, NSSelectorFromString(@"_isEffectivelyHome"));
    } @catch (NSException *exception) {
        result = NO;
    }
    return result;
}

static BOOL nhfix_armed(NHFixLegState *state, id modifier) {
    if (!sNHFixEnabled || ![NSThread isMainThread] || !state) {
        return NO;
    }
    // v2 (diag_4, 2026-11-15): the v1 discriminator was wrong on
    // device. Every opening leg sampled 1 AND returned live
    // _isEffectivelyHome == YES during its geometry queries, so v1
    // supplemented OPENINGS (app opened out of the notch), while the
    // missed closing legs sample 0 at willBegin and were skipped.
    // The signal that separates the legs cleanly in the log is the
    // transition direction captured at willBegin: openings are 0,
    // closings are 1, without exception in the captured session.
    // Combined with the stock-output check in each geometry hook
    // (the original's own fired legs present notch values, not
    // stock), direction == 1 supplements exactly the closing legs
    // the original missed and nothing else.
    (void)modifier;
    return state.inTransition && state.direction == 1 && state.boundsValid;
}

#pragma mark - Lifecycle hooks

static id nhfix_hookWillBegin(id self, SEL _cmd) {
    nhfix_diagWillBegin++;
    if (sNHFixEnabled && [NSThread isMainThread]) {
        @try {
            NHFixLegState *state = nhfix_legState(self, YES);
            // Sample BEFORE the original's willBegin handler runs:
            // this is the first-sample value the original's own gate
            // will (races aside) hold for this leg.
            state.sampleAtBegin = nhfix_liveIsEffectivelyHome(self) ? 1 : 0;
            state.inTransition = YES;
            state.markedIndex = -1;
            state.supplementFired = NO;
            UIWindow *window = nhfix_findSwitcherWindow();
            CGRect bounds = window ? window.bounds : CGRectZero;
            if (!nhfix_isPlausibleBounds(bounds)) {
                bounds = [[UIScreen mainScreen] bounds];
            }
            state.bounds = bounds;
            state.boundsValid = nhfix_isPlausibleBounds(bounds);
            sNHFixCurrentModifier = self;
            sNHFixCurrentLayout = nil;
            @try {
                sNHFixCurrentLayout = [self valueForKey:@"appLayout"];
            } @catch (NSException *exception) {
                sNHFixCurrentLayout = nil;
            }
            long long dirValue = -9;
            @try {
                id dirObj = [self valueForKey:@"direction"];
                if ([dirObj isKindOfClass:[NSNumber class]]) {
                    dirValue = [dirObj longLongValue];
                }
            } @catch (NSException *exception) {
                dirValue = -8;
            }
            state.direction = dirValue;
            nhfix_diagLogF("fix begin self=%p sample=%lld dir=%lld boundsOK=%d layout=%p",
                self, (long long)state.sampleAtBegin, dirValue,
                state.boundsValid ? 1 : 0, sNHFixCurrentLayout);
        } @catch (NSException *exception) {
        }
    }
    IMP orig = nhfix_savedIMP(sNHFixSlotWillBegin);
    return orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
}

static void nhfix_postEnd(id self) {
    nhfix_diagDidEnd++;
    if ([NSThread isMainThread]) {
        NHFixLegState *state = nhfix_legState(self, NO);
        if (state) {
            nhfix_diagLogF("fix end self=%p sample=%lld fired=%d frameFix=%lu scaleFix=%lu cornerFix=%lu animResp=%lu",
                self, (long long)state.sampleAtBegin, state.supplementFired ? 1 : 0,
                (unsigned long)nhfix_diagFrameActive, (unsigned long)nhfix_diagIconOK,
                (unsigned long)nhfix_diagCornerCalls, (unsigned long)nhfix_diagAnimResp);
            state.inTransition = NO;
        }
    }
}

static id nhfix_hookDidEnd(id self, SEL _cmd) {
    IMP orig = nhfix_savedIMP(sNHFixSlotDidEnd);
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    if (sNHFixEnabled) {
        nhfix_postEnd(self);
    }
    return result;
}

static id nhfix_hookInterrupt(id self, SEL _cmd) {
    IMP orig = nhfix_savedIMP(sNHFixSlotInterrupt);
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    if (sNHFixEnabled) {
        nhfix_postEnd(self);
    }
    return result;
}

#pragma mark - Geometry supplement hooks

static CGRect nhfix_hookFrame(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(sNHFixSlotFrame);
    CGRect original = orig ? ((CGRect (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : CGRectZero;
    NHFixLegState *state = nhfix_legState(self, NO);
    if (!state || !state.inTransition) {
        // Discovery (0.5.4): geometry queries on this class OUTSIDE a
        // logged transition — the signature of an event-driven exit
        // that never calls transitionWillBegin (diag_6: a switcher-
        // entered app's exit produced no begin line at all).
        static NSUInteger ntLogs = 0;
        if (ntLogs < 12) {
            ntLogs++;
            nhfix_diagLogF("fix geo-notrans frame idx=%lu from=(%.0f,%.0f,%.0f,%.0f)",
                (unsigned long)index, CGRectGetMinX(original), CGRectGetMinY(original),
                CGRectGetWidth(original), CGRectGetHeight(original));
        }
    }
    if (!nhfix_armed(state, self)) {
        return original;
    }
    CGFloat w = CGRectGetWidth(original);
    CGFloat h = CGRectGetHeight(original);
    if (h > w + 1.0) {
        // Fullscreen-sized. Two shapes reach here (diag_5):
        //  - the original FIRED: fullscreen frame recentered to the
        //    notch (midY == -30). Pass through.
        //  - the STOCK fullscreen fallback: when the app has no icon
        //    position in the current layout (folder app re-entered
        //    from the switcher), the system returns the plain
        //    fullscreen frame (origin 0,0, bounds size) while scale
        //    stays the stock icon-zoom 0.150. v2 passed this through,
        //    so scale shrank the window in place instead of flying
        //    it to the notch. Supplement it — but only for the index
        //    the scale hook has marked as stock this leg, so a
        //    neighbour's fullscreen frame (scale 1.0) is untouched.
        CGFloat bw0 = CGRectGetWidth(state.bounds);
        CGFloat bh0 = CGRectGetHeight(state.bounds);
        BOOL stockFallback = fabs(CGRectGetMinX(original)) < 1.0 &&
            fabs(CGRectGetMinY(original)) < 1.0 &&
            fabs(w - bw0) < 1.0 && fabs(h - bh0) < 1.0;
        BOOL marked = state.markedIndex == (NSInteger)index;
        static NSUInteger fsLogs = 0;
        if (fsLogs < 20) {
            fsLogs++;
            nhfix_diagLogF("fix framefs idx=%lu from=(%.0f,%.0f,%.0f,%.0f) fallback=%d marked=%lld",
                (unsigned long)index, CGRectGetMinX(original), CGRectGetMinY(original),
                w, h, stockFallback, (long long)state.markedIndex);
        }
        if (stockFallback && marked) {
            state.supplementFired = YES;
            nhfix_diagFrameActive++;
            return CGRectMake(0.0, kNHFixNotchCenterY - bh0 / 2.0, bw0, bh0);
        }
        return original;
    }
    if (w <= 0.0 || h <= 0.0) {
        return original;
    }
    // Stock icon-zoom frame (square, icon-sized): the original missed
    // this leg. Supplement with its own measured notch frame.
    state.markedIndex = (NSInteger)index;
    state.supplementFired = YES;
    nhfix_diagFrameActive++;
    static NSUInteger frameLogs = 0;
    if (frameLogs < 20) {
        frameLogs++;
        nhfix_diagLogF("fix frame idx=%lu from=(%.0f,%.0f,%.0f,%.0f)",
            (unsigned long)index, CGRectGetMinX(original), CGRectGetMinY(original), w, h);
    }
    CGFloat bw = CGRectGetWidth(state.bounds);
    CGFloat bh = CGRectGetHeight(state.bounds);
    return CGRectMake(0.0, kNHFixNotchCenterY - bh / 2.0, bw, bh);
}

static double nhfix_hookScale(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(sNHFixSlotScale);
    double original = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    NHFixLegState *state = nhfix_legState(self, NO);
    if (!state || !state.inTransition) {
        static NSUInteger ntLogs = 0;
        if (ntLogs < 12) {
            ntLogs++;
            nhfix_diagLogF("fix geo-notrans scale idx=%lu from=%.3f",
                (unsigned long)index, original);
        }
    }
    if (!nhfix_armed(state, self)) {
        return original;
    }
    if (original > 0.10 && original < 0.20) {
        // Stock icon-zoom scale (~0.150): missed leg, supplement.
        state.markedIndex = (NSInteger)index;
        state.supplementFired = YES;
        nhfix_diagIconOK++;
        static NSUInteger scaleLogs = 0;
        if (scaleLogs < 20) {
            scaleLogs++;
            nhfix_diagLogF("fix scale idx=%lu from=%.3f", (unsigned long)index, original);
        }
        return kNHFixNotchScale;
    }
    return original;
}

static NHFixCornerRadii nhfix_hookCorner(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(sNHFixSlotCorner);
    NHFixCornerRadii original = {0, 0, 0, 0};
    if (orig) {
        original = ((NHFixCornerRadii (*)(id, SEL, NSUInteger))orig)(self, _cmd, index);
    }
    NHFixLegState *state = nhfix_legState(self, NO);
    if (!nhfix_armed(state, self)) {
        return original;
    }
    if (state.markedIndex < 0 || (NSUInteger)state.markedIndex != index) {
        return original;
    }
    nhfix_diagCornerCalls++;
    double radius = CGRectGetWidth(state.bounds) * kNHFixNotchRadiusFactor;
    NHFixCornerRadii radii = {radius, radius, radius, radius};
    return radii;
}

#pragma mark - Animation attributes supplement

static BOOL nhfix_writeSettings(id attributes, SEL settingsGetter,
                                double damping, double response) {
    if (![attributes respondsToSelector:settingsGetter]) {
        return NO;
    }
    id settings = ((id (*)(id, SEL))objc_msgSend)(attributes, settingsGetter);
    if (!settings || ![settings respondsToSelector:@selector(setDampingRatio:)]) {
        return NO;
    }
    // Write in place on the attributes copy's own settings instances
    // (SBFFluidBehaviorSettings has no mutableCopy; the attributes
    // object's mutable copy already carries its own instances).
    ((void (*)(id, SEL, double))objc_msgSend)(settings, @selector(setDampingRatio:), damping);
    if ([settings respondsToSelector:@selector(setResponse:)]) {
        ((void (*)(id, SEL, double))objc_msgSend)(settings, @selector(setResponse:), response);
    }
    if ([settings respondsToSelector:@selector(response)]) {
        double readBack = ((double (*)(id, SEL))objc_msgSend)(settings, @selector(response));
        if (readBack > response - 0.001 && readBack < response + 0.001) {
            nhfix_diagAnimResp++;
        }
    }
    return YES;
}

static id nhfix_hookAnimAttrs(id self, SEL _cmd, id element) {
    IMP orig = nhfix_savedIMP(sNHFixSlotAnimAttrs);
    id result = orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, element) : nil;
    if (!sNHFixEnabled || !result || !element || !sNHFixCurrentModifier) {
        return result;
    }
    NHFixLegState *state = nhfix_legState(sNHFixCurrentModifier, NO);
    if (!state || !state.inTransition || state.direction != 1) {
        return result;
    }
    const char *elemClass = object_getClassName(element);
    if (!elemClass || strcmp(elemClass, "SBAppLayout") != 0 || !sNHFixCurrentLayout) {
        return result;
    }
    nhfix_diagAnimCalls++;
    @try {
        id copy = [result mutableCopy];
        if (!copy) {
            return result;
        }
        BOOL isZoomLayout = (element == sNHFixCurrentLayout);
        double posDamping = isZoomLayout ? kNHFixZoomPosDamping : kNHFixOtherPosDamping;
        double posResponse = isZoomLayout ? kNHFixZoomPosResponse : kNHFixOtherPosResponse;
        double scaleDamping = isZoomLayout ? kNHFixZoomScaleDamping : kNHFixOtherScaleDamping;
        double scaleResponse = isZoomLayout ? kNHFixZoomScaleResponse : kNHFixOtherScaleResponse;
        BOOL wrotePosition = nhfix_writeSettings(copy, @selector(positionSettings),
                                                 posDamping, posResponse);
        BOOL wroteScale = nhfix_writeSettings(copy, @selector(scaleSettings),
                                              scaleDamping, scaleResponse);
        if (!wrotePosition && !wroteScale) {
            nhfix_diagAnimSkip++;
            return result;
        }
        return copy;
    } @catch (NSException *exception) {
        return result;
    }
}



static NHFixHookSlot *nhfix_slot(NHFixHookSlot *__strong *slot,
                                 NSString *className, NSString *selectorName);

#pragma mark - HomeGesture single-class probe (0.5.6, log-only)

// The Dosido probe (0.5.5, diag_8) installed cleanly but recorded
// ZERO calls during the target exit — Dosido is not the path. The
// exit is digested inside the switcher gesture chain; the one
// class with device evidence of streaming geometry for the apps
// during gestures is SBHomeGestureSwitcherModifier (diag_7 disco
// lines: its frame/scale for the app indices track the gesture).
// This probe hooks THIS ONE class only, log-only, reentrancy
// guard on begin. Goal: see the frame/scale it serves for the
// exiting app during a switcher-entered exit.


// HG probe data goes to its own small file (0.5.8): the geometry
// stream floods diag.txt and the field snapshots (the part that
// matters) kept getting lost from the copies the user could send.
static void nhfix_hgLogF(const char *format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    NSString *dir = @"/var/mobile/Library/Logs/NotchHomeFix";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"hgdiag.txt"];
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                       dateStyle:NSDateFormatterNoStyle
                                                       timeStyle:NSDateFormatterMediumStyle];
    NSString *line = [NSString stringWithFormat:@"%@ %s\n", stamp, buffer];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } else {
        [data writeToFile:path atomically:YES];
    }
}

// Field-table dump + scalar sampling for the HG probe (0.5.7):
// names/offsets/encodings once per process; scalar values (BOOL and
// integer/float ivars, read by offset — no KVC, no side effects) at
// begin, at the first geometry query of the leg, and at end. A
// committed-home exit vs these snapshots should expose the field
// that carries the destination/commit state.
static BOOL sNHFixHGFieldsDumped = NO;
static BOOL sNHFixHGMidDumped = NO;

static void nhfix_hgDumpFieldsOnce(id object) {
    if (sNHFixHGFieldsDumped || !object) {
        return;
    }
    sNHFixHGFieldsDumped = YES;
    Class stop = NSClassFromString(@"NSObject");
    for (Class cls = object_getClass(object); cls && cls != stop; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *enc = ivar_getTypeEncoding(ivars[i]);
            nhfix_hgLogF("hg field %s %s %s @%td",
                class_getName(cls), name ? name : "?", enc ? enc : "?",
                ivar_getOffset(ivars[i]));
        }
        free(ivars);
    }
}

static void nhfix_hgDumpVals(id object, const char *tag) {
    if (!object) {
        return;
    }
    @try {
        Class stop = NSClassFromString(@"NSObject");
        NSMutableString *chunk = [NSMutableString string];
        int chunkIndex = 0;
        int inChunk = 0;
        for (Class cls = object_getClass(object); cls && cls != stop; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc) {
                    continue;
                }
                char kind = enc[0];
                if (kind != 'B' && kind != 'c' && kind != 'i' && kind != 's' &&
                    kind != 'l' && kind != 'q' && kind != 'I' && kind != 'S' &&
                    kind != 'L' && kind != 'Q' && kind != 'f' && kind != 'd') {
                    continue;
                }
                const char *name = ivar_getName(ivars[i]);
                char *base = (char *)(__bridge void *)object + ivar_getOffset(ivars[i]);
                char value[64];
                if (kind == 'f') {
                    snprintf(value, sizeof(value), "%.3f", (double)*(float *)base);
                } else if (kind == 'd') {
                    snprintf(value, sizeof(value), "%.3f", *(double *)base);
                } else if (kind == 'B' || kind == 'c') {
                    snprintf(value, sizeof(value), "%d", (int)*(signed char *)base);
                } else if (kind == 's') {
                    snprintf(value, sizeof(value), "%d", (int)*(short *)base);
                } else if (kind == 'i') {
                    snprintf(value, sizeof(value), "%d", *(int *)base);
                } else if (kind == 'l' || kind == 'q') {
                    snprintf(value, sizeof(value), "%lld", *(long long *)base);
                } else if (kind == 'S') {
                    snprintf(value, sizeof(value), "%u", (unsigned int)*(unsigned short *)base);
                } else if (kind == 'I') {
                    snprintf(value, sizeof(value), "%u", *(unsigned int *)base);
                } else {
                    snprintf(value, sizeof(value), "%llu", *(unsigned long long *)base);
                }
                [chunk appendFormat:@"%s=%s ", name ? name : "?", value];
                inChunk++;
                if (inChunk >= 8) {
                    nhfix_hgLogF("hg vals@%s #%d: %s", tag, chunkIndex++, chunk.UTF8String);
                    [chunk setString:@""];
                    inChunk = 0;
                }
            }
            free(ivars);
        }
        if (inChunk > 0) {
            nhfix_hgLogF("hg vals@%s #%d: %s", tag, chunkIndex, chunk.UTF8String);
        }
    } @catch (NSException *exception) {
        nhfix_hgLogF("hg vals@%s failed", tag);
    }
}

static NSString *const kNHFixHGClass = @"SBHomeGestureSwitcherModifier";
static NHFixHookSlot *sNHFixSlotHGBegin;
static NHFixHookSlot *sNHFixSlotHGEnd;
static NHFixHookSlot *sNHFixSlotHGFrame;
static NHFixHookSlot *sNHFixSlotHGScale;
static BOOL sNHFixHGInBegin = NO;

static id nhfix_hgBegin(id self, SEL _cmd) {
    IMP orig = nhfix_savedIMP(sNHFixSlotHGBegin);
    if (sNHFixHGInBegin) {
        return orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    }
    sNHFixHGInBegin = YES;
    static NSUInteger logs = 0;
    if (logs < 20) {
        logs++;
        long long dirValue = -9;
        @try {
            id dirObj = [self valueForKey:@"direction"];
            if ([dirObj isKindOfClass:[NSNumber class]]) {
                dirValue = [dirObj longLongValue];
            }
        } @catch (NSException *exception) {
            dirValue = -8;
        }
        id layout = nil;
        @try {
            layout = [self valueForKey:@"appLayout"];
        } @catch (NSException *exception) {
            layout = nil;
        }
        nhfix_diagLogF("hg begin self=%p dir=%lld layout=%p", self, dirValue, layout);
        nhfix_hgDumpFieldsOnce(self);
        sNHFixHGMidDumped = NO;
        nhfix_hgDumpVals(self, "begin");
    }
    id result = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    sNHFixHGInBegin = NO;
    return result;
}

static id nhfix_hgEnd(id self, SEL _cmd) {
    static NSUInteger logs = 0;
    if (logs < 20) {
        logs++;
        nhfix_diagLogF("hg end self=%p", self);
        nhfix_hgDumpVals(self, "end");
    }
    IMP orig = nhfix_savedIMP(sNHFixSlotHGEnd);
    return orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
}

static CGRect nhfix_hgFrame(id self, SEL _cmd, NSUInteger index) {
    nhfix_hgDumpFieldsOnce(self);
    IMP orig = nhfix_savedIMP(sNHFixSlotHGFrame);
    CGRect result = orig ? ((CGRect (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : CGRectZero;
    if (!sNHFixHGMidDumped) {
        sNHFixHGMidDumped = YES;
        nhfix_hgDumpVals(self, "mid");
    }
    static NSUInteger logs = 0;
    if (logs < 25) {
        logs++;
        nhfix_diagLogF("hg frame idx=%lu from=(%.0f,%.0f,%.0f,%.0f)",
            (unsigned long)index, CGRectGetMinX(result), CGRectGetMinY(result),
            CGRectGetWidth(result), CGRectGetHeight(result));
    }
    return result;
}

static double nhfix_hgScale(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(sNHFixSlotHGScale);
    double result = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    if (index == 0) {
        static NSUInteger idx0Queries = 0;
        static NSUInteger trajSamples = 0;
        idx0Queries++;
        if ((idx0Queries % 20) == 0 && trajSamples < 30) {
            trajSamples++;
            char tag[16];
            snprintf(tag, sizeof(tag), "traj%lu", (unsigned long)trajSamples);
            nhfix_hgDumpVals(self, tag);
        }
        // Post-release sampling (0.5.9): while the finger is down the
        // touch timestamp keeps changing; once it has been frozen for
        // several consecutive geometry queries the system is running
        // the outcome animation — sample the fields exactly there.
        // Offsets from the 0.5.8 field dump of this class on iOS 15.4:
        // _lastTouchTimestamp (double) @400, _gestureHasEnded (BOOL) @483.
        char *hgBase = (char *)(__bridge void *)self;
        double touchTs = *(double *)(hgBase + 400);
        BOOL gestureEnded = *(BOOL *)(hgBase + 483);
        static double sLastTouchTs = 0;
        static NSUInteger sFrozenQueries = 0;
        static BOOL sEpisodeSampled = NO;
        static NSUInteger sEpisodes = 0;
        if (touchTs != sLastTouchTs) {
            sLastTouchTs = touchTs;
            sFrozenQueries = 0;
            sEpisodeSampled = NO;
        } else {
            sFrozenQueries++;
            if (sFrozenQueries >= 5 && !sEpisodeSampled && sEpisodes < 6) {
                sEpisodeSampled = YES;
                sEpisodes++;
                char tag[20];
                snprintf(tag, sizeof(tag), "post%lu", (unsigned long)sEpisodes);
                nhfix_hgDumpVals(self, tag);
                nhfix_hgLogF("hg post-note ep=%lu ended=%d scale=%.3f",
                    (unsigned long)sEpisodes, (int)gestureEnded, result);
            }
        }
    }
    static NSUInteger logs = 0;
    if (logs < 25) {
        logs++;
        nhfix_diagLogF("hg scale idx=%lu from=%.3f", (unsigned long)index, result);
    }
    return result;
}

static void nhfix_hgInstall(void) {
    nhfix_slot(&sNHFixSlotHGBegin, kNHFixHGClass, @"transitionWillBegin");
    if (![sNHFixSlotHGBegin nhfix_installWithReplacement:(IMP)nhfix_hgBegin
                                               returnType:"@" argumentTypes:@[]]) {
        [sNHFixSlotHGBegin nhfix_installWithReplacement:(IMP)nhfix_hgBegin
                                              returnType:"v" argumentTypes:@[]];
    }
    nhfix_slot(&sNHFixSlotHGEnd, kNHFixHGClass, @"transitionDidEnd");
    if (![sNHFixSlotHGEnd nhfix_installWithReplacement:(IMP)nhfix_hgEnd
                                             returnType:"@" argumentTypes:@[]]) {
        [sNHFixSlotHGEnd nhfix_installWithReplacement:(IMP)nhfix_hgEnd
                                            returnType:"v" argumentTypes:@[]];
    }
    nhfix_slot(&sNHFixSlotHGFrame, kNHFixHGClass, @"frameForIndex:");
    if (![sNHFixSlotHGFrame nhfix_installWithReplacement:(IMP)nhfix_hgFrame
                                               returnType:kNHFixCGRectEncoding
                                            argumentTypes:@[@"Q"]]) {
        [sNHFixSlotHGFrame nhfix_installWithReplacement:(IMP)nhfix_hgFrame
                                              returnType:kNHFixCGRectEncoding
                                           argumentTypes:@[@"I"]];
    }
    nhfix_slot(&sNHFixSlotHGScale, kNHFixHGClass, @"scaleForIndex:");
    if (![sNHFixSlotHGScale nhfix_installWithReplacement:(IMP)nhfix_hgScale
                                               returnType:"d" argumentTypes:@[@"Q"]]) {
        [sNHFixSlotHGScale nhfix_installWithReplacement:(IMP)nhfix_hgScale
                                              returnType:"d" argumentTypes:@[@"I"]];
    }
    nhfix_diagLogF("hg installs: begin=%d end=%d frame=%d scale=%d",
        (int)sNHFixSlotHGBegin.installed, (int)sNHFixSlotHGEnd.installed,
        (int)sNHFixSlotHGFrame.installed, (int)sNHFixSlotHGScale.installed);
}

#pragma mark - Installation

static NHFixHookSlot *nhfix_slot(NHFixHookSlot *__strong *slot,
                                 NSString *className, NSString *selectorName) {
    if (!*slot) {
        *slot = [NHFixHookSlot nhfix_slotWithClassName:className selectorName:selectorName];
    }
    return *slot;
}

static void nhfix_installAll(void) {
    NSString *modifier = kNHFixModifierClass;

    nhfix_slot(&sNHFixSlotWillBegin, modifier, @"transitionWillBegin");
    [sNHFixSlotWillBegin nhfix_installWithReplacement:(IMP)nhfix_hookWillBegin
                                           returnType:"@" argumentTypes:@[]];

    nhfix_slot(&sNHFixSlotDidEnd, modifier, @"transitionDidEnd");
    [sNHFixSlotDidEnd nhfix_installWithReplacement:(IMP)nhfix_hookDidEnd
                                        returnType:"@" argumentTypes:@[]];

    nhfix_slot(&sNHFixSlotInterrupt, modifier, @"interruptAndEndTransition");
    if (![sNHFixSlotInterrupt nhfix_installWithReplacement:(IMP)nhfix_hookInterrupt
                                                returnType:"@" argumentTypes:@[]]) {
        [sNHFixSlotInterrupt nhfix_installWithReplacement:(IMP)nhfix_hookInterrupt
                                               returnType:"v" argumentTypes:@[]];
    }

    nhfix_slot(&sNHFixSlotFrame, modifier, @"frameForIndex:");
    if (![sNHFixSlotFrame nhfix_installWithReplacement:(IMP)nhfix_hookFrame
                                            returnType:kNHFixCGRectEncoding
                                         argumentTypes:@[@"Q"]]) {
        [sNHFixSlotFrame nhfix_installWithReplacement:(IMP)nhfix_hookFrame
                                            returnType:kNHFixCGRectEncoding
                                         argumentTypes:@[@"I"]];
    }

    nhfix_slot(&sNHFixSlotScale, modifier, @"scaleForIndex:");
    if (![sNHFixSlotScale nhfix_installWithReplacement:(IMP)nhfix_hookScale
                                            returnType:"d" argumentTypes:@[@"Q"]]) {
        [sNHFixSlotScale nhfix_installWithReplacement:(IMP)nhfix_hookScale
                                            returnType:"d" argumentTypes:@[@"I"]];
    }

    nhfix_slot(&sNHFixSlotCorner, modifier, @"cornerRadiiForIndex:");
    if (![sNHFixSlotCorner nhfix_installWithReplacement:(IMP)nhfix_hookCorner
                                             returnType:kNHFixRadiiEncoding
                                          argumentTypes:@[@"Q"]]) {
        [sNHFixSlotCorner nhfix_installWithReplacement:(IMP)nhfix_hookCorner
                                             returnType:kNHFixRadiiEncoding
                                          argumentTypes:@[@"I"]];
    }

    nhfix_slot(&sNHFixSlotAnimAttrs, kNHFixGestureModifierClass,
               @"animationAttributesForLayoutElement:");
    [sNHFixSlotAnimAttrs nhfix_installWithReplacement:(IMP)nhfix_hookAnimAttrs
                                           returnType:"@" argumentTypes:@[@"@"]];

    nhfix_hgInstall();

    nhfix_diagLogF("fix installs: begin=%d end=%d int=%d frame=%d scale=%d corner=%d anim=%d",
        (int)sNHFixSlotWillBegin.installed, (int)sNHFixSlotDidEnd.installed,
        (int)sNHFixSlotInterrupt.installed, (int)sNHFixSlotFrame.installed,
        (int)sNHFixSlotScale.installed, (int)sNHFixSlotCorner.installed,
        (int)sNHFixSlotAnimAttrs.installed);
}

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            return;
        }
        sNHFixEnabled = nhfix_computeEnabled();
        nhfix_diagLogF("=== fix load: machine=%s sentinel=%d enabled=%d",
            nhfix_machineName().UTF8String,
            (int)nhfix_sentinelExists(), (int)sNHFixEnabled);
        dispatch_async(dispatch_get_main_queue(), ^{
            nhfix_installAll();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            nhfix_installAll();
        });
    }
}
