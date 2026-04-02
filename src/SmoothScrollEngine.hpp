#pragma once
#import <Foundation/Foundation.h>

typedef void (^ScrollTickCallback)(double deltaX, double deltaY);

@interface SmoothScrollEngine : NSObject

@property (nonatomic) BOOL    enabled;
@property (nonatomic) double  decayFactor;   // 0.70–0.98, default 0.85
@property (nonatomic, copy) ScrollTickCallback onTick;

- (void)feedDeltaX:(double)dx deltaY:(double)dy;
- (void)cancelMomentum;

@end
