#import "SmoothScrollEngine.hpp"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

static const double kVelocityCap     = 200.0;
static const double kStopThreshold   = 0.1;

// WeakProxy to break CADisplayLink retain cycle
@interface SmoothScrollProxy : NSObject
@property (nonatomic, weak) id target;
@property (nonatomic) SEL selector;
@end

@implementation SmoothScrollProxy
- (void)tick:(id)sender {
    id strongTarget = self.target;
    if (strongTarget) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [strongTarget performSelector:self.selector withObject:sender];
#pragma clang diagnostic pop
    }
}
@end

@interface SmoothScrollEngine ()
// Use id for backwards compatibility with older SDKs, but it will hold a CADisplayLink on macOS 14+
@property (nonatomic, strong) id displayLink;
@end

@implementation SmoothScrollEngine {
    CVDisplayLinkRef  cvDisplayLink_;
    os_unfair_lock    lock_;
    double            velocityX_;
    double            velocityY_;
    BOOL              isRunning_;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _decayFactor = 0.85;
        _enabled     = NO;
        lock_        = OS_UNFAIR_LOCK_INIT;
        velocityX_   = 0.0;
        velocityY_   = 0.0;
        cvDisplayLink_ = NULL;
        isRunning_   = NO;
    }
    return self;
}

- (void)dealloc {
    [self cancelMomentum];
}

// Called from CGEventTap thread — must be lock-safe
- (void)feedDeltaX:(double)dx deltaY:(double)dy {
    os_unfair_lock_lock(&lock_);
    velocityX_ += dx;
    velocityY_ += dy;
    // Cap to prevent runaway momentum
    if (velocityX_ >  kVelocityCap) velocityX_ =  kVelocityCap;
    if (velocityX_ < -kVelocityCap) velocityX_ = -kVelocityCap;
    if (velocityY_ >  kVelocityCap) velocityY_ =  kVelocityCap;
    if (velocityY_ < -kVelocityCap) velocityY_ = -kVelocityCap;
    os_unfair_lock_unlock(&lock_);

    [self startDisplayLinkIfNeeded];
}

- (void)cancelMomentum {
    os_unfair_lock_lock(&lock_);
    velocityX_ = 0.0;
    velocityY_ = 0.0;
    os_unfair_lock_unlock(&lock_);
    [self stopDisplayLink];
}

#pragma mark - CVDisplayLink / CADisplayLink

- (void)startDisplayLinkIfNeeded {
    os_unfair_lock_lock(&lock_);
    if (isRunning_) {
        os_unfair_lock_unlock(&lock_);
        return;
    }
    isRunning_ = YES;
    os_unfair_lock_unlock(&lock_);

    __weak SmoothScrollEngine *weakSelf = self;
    void (^createDisplayLink)(void) = ^{
        SmoothScrollEngine *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (@available(macOS 14.0, *)) {
            if (!strongSelf.displayLink) {
                SmoothScrollProxy *proxy = [[SmoothScrollProxy alloc] init];
                proxy.target = strongSelf;
                proxy.selector = @selector(tick:);
                CADisplayLink *link = [NSScreen.mainScreen displayLinkWithTarget:proxy selector:@selector(tick:)];
                [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                strongSelf.displayLink = link;
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (strongSelf->cvDisplayLink_ == NULL) {
                CVDisplayLinkCreateWithActiveCGDisplays(&strongSelf->cvDisplayLink_);
                CVDisplayLinkSetOutputCallback(strongSelf->cvDisplayLink_, cvDisplayLinkCallback, (__bridge void*)strongSelf);
                CVDisplayLinkStart(strongSelf->cvDisplayLink_);
            }
#pragma clang diagnostic pop
        }
    };

    if ([NSThread isMainThread]) {
        createDisplayLink();
    } else {
        dispatch_sync(dispatch_get_main_queue(), createDisplayLink);
    }
}

- (void)stopDisplayLink {
    os_unfair_lock_lock(&lock_);
    if (!isRunning_) {
        os_unfair_lock_unlock(&lock_);
        return;
    }
    isRunning_ = NO;
    os_unfair_lock_unlock(&lock_);

    __weak SmoothScrollEngine *weakSelf = self;
    void (^destroyDisplayLink)(void) = ^{
        SmoothScrollEngine *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (@available(macOS 14.0, *)) {
            if (strongSelf.displayLink) {
                [((CADisplayLink*)strongSelf.displayLink) invalidate];
                strongSelf.displayLink = nil;
            }
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if (strongSelf->cvDisplayLink_ != NULL) {
                CVDisplayLinkStop(strongSelf->cvDisplayLink_);
                CVDisplayLinkRelease(strongSelf->cvDisplayLink_);
                strongSelf->cvDisplayLink_ = NULL;
            }
#pragma clang diagnostic pop
        }
    };

    if ([NSThread isMainThread]) {
        destroyDisplayLink();
    } else {
        dispatch_sync(dispatch_get_main_queue(), destroyDisplayLink);
    }
}

- (void)tick:(id)sender {
    (void)sender;
    [self processTick];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static CVReturn cvDisplayLinkCallback(CVDisplayLinkRef displayLink,
                                      const CVTimeStamp* now,
                                      const CVTimeStamp* outputTime,
                                      CVOptionFlags flagsIn,
                                      CVOptionFlags* flagsOut,
                                      void* userInfo)
{
    (void)displayLink; (void)now; (void)outputTime; (void)flagsIn; (void)flagsOut;
    SmoothScrollEngine* engine = (__bridge SmoothScrollEngine*)userInfo;
    [engine processTick];
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

- (void)processTick {
    double decay = self.decayFactor;

    os_unfair_lock_lock(&lock_);
    velocityX_ *= decay;
    velocityY_ *= decay;
    double dx = velocityX_;
    double dy = velocityY_;
    os_unfair_lock_unlock(&lock_);

    BOOL belowThreshold = (fabs(dx) < kStopThreshold && fabs(dy) < kStopThreshold);
    if (belowThreshold) {
        [self cancelMomentum];
        return;
    }

    ScrollTickCallback callback = self.onTick;
    if (callback) {
        if ([NSThread isMainThread]) {
            callback(dx, dy);
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(dx, dy);
            });
        }
    }
}

@end
