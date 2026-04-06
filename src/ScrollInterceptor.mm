#import "ScrollInterceptor.hpp"
#import "SmoothScrollEngine.hpp"
#include <atomic>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

static const double kBaseVelocity    = 500.0;
static const double kAccelFactorMin  = 0.5;
static const double kAccelFactorMax  = 8.0;

static const NSTimeInterval kHealthCheckInterval = 30.0;

@implementation ScrollInterceptor {
    CFMachPortRef      eventTap_;
    CFRunLoopSourceRef runLoopSource_;
    SmoothScrollEngine* smoothEngine_;
    NSTimeInterval     lastEventTime_;
    double             lastVelocity_;
    std::atomic<bool>  isRunning_;
    NSTimer*           healthTimer_;
    std::atomic<double> lastEventSeen_;
    std::atomic<double> lastTapReenableTime_;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _speedFactor       = 2.0;
        _accelerationCurve = 1.5;
        _smoothDecayFactor = 0.85;
        _backButtonEnabled = NO;
        lastEventTime_     = 0.0;
        lastVelocity_      = 0.0;
        isRunning_.store(false);
        healthTimer_       = nil;
        lastEventSeen_.store(0.0);
        lastTapReenableTime_.store(0.0);

        smoothEngine_ = [[SmoothScrollEngine alloc] init];
        __weak ScrollInterceptor* weakSelf = self;
        smoothEngine_.onTick = ^(double dx, double dy) {
            ScrollInterceptor* s = weakSelf;
            if (!s || !s->isRunning_.load()) return;
            CGEventRef e = CGEventCreateScrollWheelEvent2(
                NULL, kCGScrollEventUnitPixel, 2,
                (int32_t)round(dy), (int32_t)round(dx), 0);
            if (e) {
                CGEventPost(kCGHIDEventTap, e);
                CFRelease(e);
            }
        };
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning { return isRunning_.load(); }

#pragma mark - Accessibility

+ (BOOL)hasAccessibilityPermission {
    return AXIsProcessTrusted();
}

+ (void)requestAccessibilityPermission {
    NSURL* url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Lifecycle

- (BOOL)startWithError:(NSError**)error {
    __block BOOL success = NO;
    __block NSError* internalError = nil;

    void (^startBlock)(void) = ^{
        if (self->isRunning_.load()) {
            success = YES;
            return;
        }

        if (!AXIsProcessTrusted()) {
            internalError = [NSError errorWithDomain:@"ScrollInterceptor"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"Accessibility permission required"}];
            return;
        }

        self->eventTap_ = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionDefault,
            CGEventMaskBit(kCGEventScrollWheel) | CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp),
            scrollEventCallback,
            (__bridge void*)self);

        if (!self->eventTap_) {
            internalError = [NSError errorWithDomain:@"ScrollInterceptor"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                @"Failed to create CGEventTap"}];
            return;
        }

        self->runLoopSource_ = CFMachPortCreateRunLoopSource(NULL, self->eventTap_, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), self->runLoopSource_, kCFRunLoopCommonModes);
        CGEventTapEnable(self->eventTap_, self->_masterEnabled ? true : false);

        self->isRunning_.store(true);
        self->lastEventSeen_.store([NSDate timeIntervalSinceReferenceDate]);

        self->healthTimer_ = [NSTimer scheduledTimerWithTimeInterval:kHealthCheckInterval
                                                        target:self
                                                      selector:@selector(healthCheck:)
                                                      userInfo:nil
                                                       repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self->healthTimer_ forMode:NSRunLoopCommonModes];

        success = YES;
    };

    if ([NSThread isMainThread]) {
        startBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), startBlock);
    }

    if (error) *error = internalError;
    return success;
}

- (void)stop {
    void (^stopBlock)(void) = ^{
        if (!self->isRunning_.load()) return;
        [self->smoothEngine_ cancelMomentum];
        if (self->healthTimer_) {
            [self->healthTimer_ invalidate];
            self->healthTimer_ = nil;
        }
        CGEventTapEnable(self->eventTap_, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self->runLoopSource_, kCFRunLoopCommonModes);
        CFRelease(self->runLoopSource_); self->runLoopSource_ = NULL;
        CFRelease(self->eventTap_);      self->eventTap_      = NULL;
        self->isRunning_.store(false);
    };

    if ([NSThread isMainThread]) {
        stopBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), stopBlock);
    }
}

#pragma mark - Setters that sync to engine

- (void)setMasterEnabled:(BOOL)v {
    _masterEnabled = v;
    if (isRunning_.load() && eventTap_) {
        CGEventTapEnable(eventTap_, v ? true : false);
    }
}

- (void)setSmoothEnabled:(BOOL)v      { _smoothEnabled      = v; smoothEngine_.enabled     = v; }
- (void)setSmoothDecayFactor:(double)v{ _smoothDecayFactor   = v; smoothEngine_.decayFactor = v; }

#pragma mark - CGEventTap callback

static CGEventRef scrollEventCallback(CGEventTapProxy proxy,
                                      CGEventType type,
                                      CGEventRef event,
                                      void* userInfo)
{
    (void)proxy;
    ScrollInterceptor* self = (__bridge ScrollInterceptor*)userInfo;

    self->lastEventSeen_.store([NSDate timeIntervalSinceReferenceDate]);

    // Re-enable tap on timeout, but throttle to max once per second to prevent
    // feedback loop with WindowServer (high polling rate mice can overwhelm it)
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (self->_masterEnabled) {
            double now = [NSDate timeIntervalSinceReferenceDate];
            double last = self->lastTapReenableTime_.load(std::memory_order_relaxed);
            if (now - last > 1.0) {
                self->lastTapReenableTime_.store(now, std::memory_order_relaxed);
                CGEventTapEnable(self->eventTap_, true);
                NSLog(@"[ScrollInterceptor] Tap re-enabled after system timeout");
            }
        }
        return event;
    }

    // Don't intercept events when master is disabled
    if (!self->_masterEnabled) {
        return event;
    }

    return [self handleEvent:event];
}

- (CGEventRef)handleEvent:(CGEventRef)event {
    if (!_masterEnabled) {
        return event;
    }

    CGEventType type = CGEventGetType(event);

    // --- BACK BUTTON (Mouse Button 4) ---
    if ((type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) && _backButtonEnabled) {
        int32_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        if (button == 3) {
            NSRunningApplication* front = NSWorkspace.sharedWorkspace.frontmostApplication;
            NSString* bid = front.bundleIdentifier;

            // Apps that need Cmd+[ injection for back navigation
            // (browsers handle mouse button 4 natively)
            static NSSet* needsInjection = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                needsInjection = [NSSet setWithObjects:
                    @"com.apple.finder",
                    nil];
            });

            if ([needsInjection containsObject:bid]) {
                if (type == kCGEventOtherMouseDown) {
                    // Inject Cmd+[ as a single keystroke — post at session level
                    // to bypass event taps and reach the target app directly
                    CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_ANSI_LeftBracket, true);
                    CGEventRef keyUp   = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_ANSI_LeftBracket, false);
                    CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
                    CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);

                    CGEventPost(kCGSessionEventTap, keyDown);
                    CGEventPost(kCGSessionEventTap, keyUp);

                    CFRelease(keyDown);
                    CFRelease(keyUp);

                    return (CGEventRef)NULL;
                }
                return event;
            }
        }
        return event;
    }

    // Skip trackpad continuous events — only process discrete mouse wheel
    int64_t isContinuous = CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
    if (isContinuous) return event;

    // Fast path: nothing to do
    if (!_reverseEnabled && !_speedEnabled && !_accelerationEnabled && !_smoothEnabled) {
        return event;
    }

    // Cancel momentum if user scrolls again
    if (_smoothEnabled) {
        [smoothEngine_ cancelMomentum];
    }

    double dy = (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    double dx = (double)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);

    if (dy == 0.0 && dx == 0.0) return event;

    // 1. Reverse
    if (_reverseEnabled) {
        dx = -dx;
        dy = -dy;
    }

    // 2. Speed
    if (_speedEnabled) {
        dx *= _speedFactor;
        dy *= _speedFactor;
    }

    // 3. Acceleration
    if (_accelerationEnabled) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        double dt = now - lastEventTime_;
        if (dt < 0.005) dt = 0.005;
        if (dt > 0.5)   dt = 0.5;
        lastEventTime_ = now;

        double magnitude = hypot(dx, dy);
        double velocity  = magnitude / dt;
        double smoothV   = lastVelocity_ * 0.6 + velocity * 0.4;
        lastVelocity_    = smoothV;

        double factor = pow(smoothV / kBaseVelocity, _accelerationCurve - 1.0);
        if (factor < kAccelFactorMin) factor = kAccelFactorMin;
        if (factor > kAccelFactorMax) factor = kAccelFactorMax;

        dx *= factor;
        dy *= factor;
    }

    // 4. Smooth — feed engine, suppress original event
    if (_smoothEnabled) {
        [smoothEngine_ feedDeltaX:dx deltaY:dy];
        return NULL;
    }

    // Write back modified deltas
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, (int64_t)round(dy));
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, (int64_t)round(dx));
    return event;
}

#pragma mark - Health Check

- (void)healthCheck:(NSTimer*)timer {
    (void)timer;
    if (!isRunning_.load()) return;

    // Re-enable tap if it was silently disabled by the system
    if (eventTap_ != NULL && !CGEventTapIsEnabled(eventTap_) && _masterEnabled) {
        NSLog(@"[ScrollInterceptor] Tap was disabled by system, re-enabling");
        CGEventTapEnable(eventTap_, true);
    }
}

@end
