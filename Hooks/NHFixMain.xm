#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "NHFixPrivate.h"
#import "NHFixHookSlot.h"
#import "NHFixDiag.h"
#import "NHFixUtil.h"
#include <string.h>
#include <stdlib.h>

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


#pragma mark - Discovery (0.5.4 diagnostic: which modifier drives the switcher-entered exit?)

static NSMutableArray<NHFixHookSlot *> *sNHFixDiscoBeginSlots;
static NSMutableArray<NHFixHookSlot *> *sNHFixDiscoFrameSlots;
static NSMutableArray<NHFixHookSlot *> *sNHFixDiscoScaleSlots;

static NHFixHookSlot *nhfix_discoSlotFor(NSArray<NHFixHookSlot *> *slots, id object) {
    const char *name = object_getClassName(object);
    if (!name) {
        return nil;
    }
    NSString *className = [NSString stringWithUTF8String:name];
    for (NHFixHookSlot *slot in slots) {
        if ([slot.className isEqualToString:className]) {
            return slot;
        }
    }
    return nil;
}

static id nhfix_discoWillBegin(id self, SEL _cmd) {
    static NSUInteger logs = 0;
    if (logs < 80) {
        logs++;
        nhfix_diagLogF("disco begin class=%s self=%p", object_getClassName(self), self);
    }
    IMP orig = nhfix_savedIMP(nhfix_discoSlotFor(sNHFixDiscoBeginSlots, self));
    return orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
}

static CGRect nhfix_discoFrame(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(nhfix_discoSlotFor(sNHFixDiscoFrameSlots, self));
    CGRect result = orig ? ((CGRect (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : CGRectZero;
    static NSUInteger logs = 0;
    if (logs < 80) {
        logs++;
        nhfix_diagLogF("disco frame class=%s idx=%lu from=(%.0f,%.0f,%.0f,%.0f)",
            object_getClassName(self), (unsigned long)index,
            CGRectGetMinX(result), CGRectGetMinY(result),
            CGRectGetWidth(result), CGRectGetHeight(result));
    }
    return result;
}

static double nhfix_discoScale(id self, SEL _cmd, NSUInteger index) {
    IMP orig = nhfix_savedIMP(nhfix_discoSlotFor(sNHFixDiscoScaleSlots, self));
    double result = orig ? ((double (*)(id, SEL, NSUInteger))orig)(self, _cmd, index) : 1.0;
    static NSUInteger logs = 0;
    if (logs < 80) {
        logs++;
        nhfix_diagLogF("disco scale class=%s idx=%lu from=%.3f",
            object_getClassName(self), (unsigned long)index, result);
    }
    return result;
}

static BOOL nhfix_isSubclassOf(Class cls, Class base) {
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == base) {
            return YES;
        }
    }
    return NO;
}

static BOOL nhfix_ownsMethod(Class cls, SEL selector, Class base) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }
    if (!base) {
        return YES;
    }
    Method baseMethod = class_getInstanceMethod(base, selector);
    if (!baseMethod) {
        return YES;
    }
    return method_getImplementation(method) != method_getImplementation(baseMethod);
}

static BOOL nhfix_discoAlreadyHooked(NSArray<NHFixHookSlot *> *slots, NSString *className) {
    for (NHFixHookSlot *slot in slots) {
        if ([slot.className isEqualToString:className]) {
            return YES;
        }
    }
    return NO;
}

static void nhfix_discoveryInstall(void) {
    if (!sNHFixDiscoBeginSlots) {
        sNHFixDiscoBeginSlots = [NSMutableArray array];
        sNHFixDiscoFrameSlots = [NSMutableArray array];
        sNHFixDiscoScaleSlots = [NSMutableArray array];
    }
    Class base = NSClassFromString(@"SBSwitcherModifier");
    SEL beginSel = NSSelectorFromString(@"transitionWillBegin");
    SEL frameSel = NSSelectorFromString(@"frameForIndex:");
    SEL scaleSel = NSSelectorFromString(@"scaleForIndex:");
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSMutableString *hooked = [NSMutableString string];
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name || !strstr(name, "SwitcherModifier")) {
            continue;
        }
        if (base && !nhfix_isSubclassOf(cls, base)) {
            continue;
        }
        NSString *className = [NSString stringWithUTF8String:name];
        if ([className isEqualToString:kNHFixModifierClass] ||
            [className isEqualToString:kNHFixGestureModifierClass]) {
            continue;
        }
        if (nhfix_ownsMethod(cls, beginSel, base) &&
            !nhfix_discoAlreadyHooked(sNHFixDiscoBeginSlots, className)) {
            NHFixHookSlot *slot = [NHFixHookSlot nhfix_slotWithClassName:className
                                                           selectorName:@"transitionWillBegin"];
            BOOL ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoWillBegin
                                              returnType:"@" argumentTypes:@[]];
            if (!ok) {
                ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoWillBegin
                                             returnType:"v" argumentTypes:@[]];
            }
            if (ok) {
                [sNHFixDiscoBeginSlots addObject:slot];
                [hooked appendFormat:@"%s(begin) ", name];
            }
        }
        if (nhfix_ownsMethod(cls, frameSel, base) &&
            !nhfix_discoAlreadyHooked(sNHFixDiscoFrameSlots, className)) {
            NHFixHookSlot *slot = [NHFixHookSlot nhfix_slotWithClassName:className
                                                           selectorName:@"frameForIndex:"];
            BOOL ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoFrame
                                              returnType:kNHFixCGRectEncoding
                                           argumentTypes:@[@"Q"]];
            if (!ok) {
                ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoFrame
                                             returnType:kNHFixCGRectEncoding
                                          argumentTypes:@[@"I"]];
            }
            if (ok) {
                [sNHFixDiscoFrameSlots addObject:slot];
                [hooked appendFormat:@"%s(frame) ", name];
            }
        }
        if (nhfix_ownsMethod(cls, scaleSel, base) &&
            !nhfix_discoAlreadyHooked(sNHFixDiscoScaleSlots, className)) {
            NHFixHookSlot *slot = [NHFixHookSlot nhfix_slotWithClassName:className
                                                           selectorName:@"scaleForIndex:"];
            BOOL ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoScale
                                              returnType:"d" argumentTypes:@[@"Q"]];
            if (!ok) {
                ok = [slot nhfix_installWithReplacement:(IMP)nhfix_discoScale
                                             returnType:"d" argumentTypes:@[@"I"]];
            }
            if (ok) {
                [sNHFixDiscoScaleSlots addObject:slot];
                [hooked appendFormat:@"%s(scale) ", name];
            }
        }
    }
    free(classes);
    if (hooked.length > 0) {
        nhfix_diagLogF("disco hooked: %s", hooked.UTF8String);
    }
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

    nhfix_discoveryInstall();

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
