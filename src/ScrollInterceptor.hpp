#pragma once
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

@interface ScrollInterceptor : NSObject

@property (nonatomic) BOOL   masterEnabled;

@property (nonatomic) BOOL   reverseEnabled;
@property (nonatomic) BOOL   speedEnabled;
@property (nonatomic) double speedFactor;          // 1.0–5.0
@property (nonatomic) BOOL   accelerationEnabled;
@property (nonatomic) double accelerationCurve;   // 1.0–3.0
@property (nonatomic) BOOL   smoothEnabled;
@property (nonatomic) double smoothDecayFactor;   // 0.70–0.98
@property (nonatomic) BOOL   backButtonEnabled;

- (BOOL)startWithError:(NSError **)error;
- (void)stop;
- (BOOL)isRunning;

+ (BOOL)hasAccessibilityPermission;
+ (void)requestAccessibilityPermission;

@end
