#import "ScrollInterceptor.hpp"
#import "SmoothScrollEngine.hpp"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

static const double kBaseVelocity    = 500.0;
static const double kAccelFactorMin  = 0.5;
static const double kAccelFactorMax  = 8.0;

static const NSTimeInterval kHealthCheckInterval = 30.0;
static const NSTimeInterval kTapDeadThreshold    = 60.0;
static const int            kMaxRestartAttempts  = 5;
static const NSTimeInterval kRestartBackoffBase  = 5.0;

@implementation ScrollInterceptor {
    CFMachPortRef      eventTap_;
    CFRunLoopSourceRef runLoopSource_;
    SmoothScrollEngine* smoothEngine_;
    NSTimeInterval     lastEventTime_;
    double             lastVelocity_;
    BOOL               isRunning_;
    NSTimer*           healthTimer_;
    NSTimeInterval     lastEventSeen_;
    int                restartAttemptCount_;
    BOOL               isRestarting_;
    dispatch_block_t   pendingRestart_;
    dispatch_queue_t   restartQueue_;
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
        isRunning_         = NO;
        healthTimer_       = nil;
        lastEventSeen_     = 0.0;
        restartAttemptCount_ = 0;
        isRestarting_      = NO;
        restartQueue_      = dispatch_queue_create("no.ulfsec.scrollrestart", DISPATCH_QUEUE_SERIAL);

        smoothEngine_ = [[SmoothScrollEngine alloc] init];
        __weak ScrollInterceptor* weakSelf = self;
        smoothEngine_.onTick = ^(double dx, double dy) {
            ScrollInterceptor* s = weakSelf;
            if (!s || !s->isRunning_) return;
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
    pendingRestart_ = nil;
    [self stop];
}

- (BOOL)isRunning { return isRunning_; }

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
        if (self->isRunning_) {
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
        
        self->isRunning_ = YES;
        self->lastEventSeen_ = [NSDate timeIntervalSinceReferenceDate];
        self->restartAttemptCount_ = 0;
        self->isRestarting_ = NO;

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
        if (!self->isRunning_) return;
        [self->smoothEngine_ cancelMomentum];
        if (self->healthTimer_) {
            [self->healthTimer_ invalidate];
            self->healthTimer_ = nil;
        }
        CGEventTapEnable(self->eventTap_, false);
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self->runLoopSource_, kCFRunLoopCommonModes);
        CFRelease(self->runLoopSource_); self->runLoopSource_ = NULL;
        CFRelease(self->eventTap_);      self->eventTap_      = NULL;
        self->isRunning_ = NO;
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
    if (isRunning_ && eventTap_) {
        // Toggle the actual OS-level tap to ensure 0 overhead when disabled
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
    ScrollInterceptor* self = (__bridge ScrollInterceptor*)userInfo;

    self->lastEventSeen_ = [NSDate timeIntervalSinceReferenceDate];

    // Always re-enable tap on timeout — this fixes the freeze seen in LinearMouse/Mos
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(self->eventTap_, true);
        return event;
    }

    // Don't intercept events when master is disabled - this fixes menu click issue
    if (!self->_masterEnabled) {
        return event;
    }

    return [self handleEvent:event];
}

- (CGEventRef)handleEvent:(CGEventRef)event {
    if (!_masterEnabled) {
        NSLog(@"[ScrollInterceptor] Master disabled, passing event through");
        return event;
    }

    CGEventType type = CGEventGetType(event);
    
    // Debug: log mouse events that could interfere with menu clicks
    if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) {
        int32_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        NSLog(@"[ScrollInterceptor] Mouse event: button=%d type=%d", button, type);
    }

    // --- BACK BUTTON (Mouse Button 4) ---
    if ((type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) && _backButtonEnabled) {
        int32_t button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
        if (button == 3) {
            NSRunningApplication* front = NSWorkspace.sharedWorkspace.frontmostApplication;
            NSString* bid = front.bundleIdentifier;

            static NSSet* needsInjection = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                needsInjection = [NSSet setWithObjects:
                    @"com.apple.finder",
                    @"com.apple.systempreferences",
                    @"com.apple.systemsettings",
                    nil];
            });

            if ([needsInjection containsObject:bid]) {
                // For MouseDown: inject Cmd+[ and suppress original event
                if (type == kCGEventOtherMouseDown) {
                    CGEventFlags cmdFlag = kCGEventFlagMaskCommand;

                    CGEventRef cmdDown = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_Command, true);
                    CGEventRef cmdUp   = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_Command, false);
                    // kVK_ANSI_LeftBracket = 33 (0x21)
                    CGEventRef bracketDown = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_ANSI_LeftBracket, true);
                    CGEventRef bracketUp   = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)kVK_ANSI_LeftBracket, false);

                    CGEventSetFlags(cmdDown, cmdFlag);
                    CGEventSetFlags(bracketDown, cmdFlag);

                    CGEventPost(kCGHIDEventTap, cmdDown);
                    CGEventPost(kCGHIDEventTap, bracketDown);
                    CGEventPost(kCGHIDEventTap, bracketUp);
                    CGEventPost(kCGHIDEventTap, cmdUp);

                    CFRelease(cmdDown);
                    CFRelease(cmdUp);
                    CFRelease(bracketDown);
                    CFRelease(bracketUp);

                    return NULL; // Suppress original mouse down event
                }
                
                // For MouseUp: allow it to pass through so OS sees complete click
                // This fixes the "click sound but no action" issue
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
        // Low-pass filter to smooth out velocity spikes
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
        return NULL; // Suppress; engine posts synthetic events
    }

    // Write back modified deltas
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, (int64_t)round(dy));
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, (int64_t)round(dx));
    return event;
}

#pragma mark - Health Check & Auto-Restart

- (void)healthCheck:(NSTimer*)timer {
    (void)timer;
    if (!isRunning_) return;
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval idle = now - lastEventSeen_;

    if (idle > kTapDeadThreshold && eventTap_ != NULL && !isRestarting_) {
        NSLog(@"[ScrollInterceptor] Tap appears dead (%.0fs idle), attempting restart", idle);
        // Dispatch to restart queue to serialize with any pending restarts
        dispatch_async(restartQueue_, ^{
            [self attemptAutoRestart];
        });
    }
}

- (void)attemptAutoRestart {
    if (!isRunning_) return;  // Don't restart if already stopped
    if (isRestarting_) return;
    if (restartAttemptCount_ >= kMaxRestartAttempts) {
        NSLog(@"[ScrollInterceptor] Max restart attempts (%d) reached, giving up", kMaxRestartAttempts);
        isRunning_ = NO;
        return;
    }

    isRestarting_ = YES;
    restartAttemptCount_++;

    NSTimeInterval delay = kRestartBackoffBase * restartAttemptCount_;
    NSLog(@"[ScrollInterceptor] Restart attempt %d/%d in %.0fs", restartAttemptCount_, kMaxRestartAttempts, delay);

    __weak ScrollInterceptor* weakSelf = self;
    pendingRestart_ = ^{
        ScrollInterceptor* strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->isRunning_) {
            // App was stopped while waiting - abort restart
            if (strongSelf) strongSelf->isRestarting_ = NO;
            return;
        }
        strongSelf->pendingRestart_ = nil;
        [strongSelf stop];

        NSError* error = nil;
        if ([strongSelf startWithError:&error]) {
            NSLog(@"[ScrollInterceptor] Auto-restart succeeded");
            strongSelf->isRestarting_ = NO;
        } else {
            NSLog(@"[ScrollInterceptor] Auto-restart failed: %@", error.localizedDescription);
            strongSelf->isRestarting_ = NO;
            // Check isRunning_ again before retrying
            if (strongSelf->isRunning_ && strongSelf->restartAttemptCount_ < kMaxRestartAttempts) {
                [strongSelf attemptAutoRestart];
            } else {
                strongSelf->isRunning_ = NO;
            }
        }
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), restartQueue_, pendingRestart_);
}

@end
