#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <UserNotifications/UserNotifications.h>
#import "RazerDevice.hpp"

@interface BatteryMonitorApp : NSObject <NSApplicationDelegate> {
    NSStatusItem* statusItem_;
    RazerDevice* razerDevice_;
    NSTimer* pollTimer_;
    uint8_t lastBatteryLevel_;
    bool notificationShown_;
    dispatch_block_t pendingReconnect_;
    dispatch_queue_t batteryQueue_;
}

- (void)updateBatteryDisplay;
- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging;
- (void)pollBattery:(NSTimer*)timer;
- (void)connectToDevice;
- (void)handleUSBEvent;
- (NSImage*)mouseIconWithColor:(NSColor*)color;
@end

// Static callback for RazerDevice monitoring (must be after @interface)
static void onDeviceChange(void* context) {
    BatteryMonitorApp* app = (__bridge BatteryMonitorApp*)context;
    // Ensure we run on main thread for UI updates
    dispatch_async(dispatch_get_main_queue(), ^{
        [app handleUSBEvent];
    });
}

@implementation BatteryMonitorApp

- (instancetype)init {
    self = [super init];
    if (self) {
        statusItem_ = nil;
        // Create device instance immediately and keep it alive
        razerDevice_ = new RazerDevice();
        pollTimer_ = nil;
        lastBatteryLevel_ = 0;
        notificationShown_ = false;
        pendingReconnect_ = nil;
        batteryQueue_ = dispatch_queue_create("no.ulfsec.battery", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // STEP 1: Create UI FIRST
    NSStatusBar* statusBar = [NSStatusBar systemStatusBar];
    statusItem_ = [statusBar statusItemWithLength:NSVariableStatusItemLength];
    
    NSImage* mouseIcon = [self mouseIconWithColor:[NSColor whiteColor]];
    if (mouseIcon) {
        statusItem_.button.image = mouseIcon;
        statusItem_.button.title = @"...";
        statusItem_.button.imagePosition = NSImageLeft;
    } else {
        statusItem_.button.title = @"🖱️ ...";
    }
    statusItem_.button.toolTip = @"Razer Battery Monitor";
    
    // Create menu
    NSMenu* menu = [[NSMenu alloc] init];
    
    NSMenuItem* refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh" 
                                                         action:@selector(manualRefresh:) 
                                                  keyEquivalent:@"r"];
    [refreshItem setTarget:self];
    [menu addItem:refreshItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit" 
                                                       action:@selector(terminate:) 
                                                keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];
    [menu addItem:quitItem];
    statusItem_.menu = menu;
    
    // STEP 2: Force UI to appear immediately
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    
    // STEP 3: Start IOKit Hotplug Monitoring via RazerDevice
    if (razerDevice_) {
        razerDevice_->startMonitoring(onDeviceChange, (__bridge void*)self);
    }
    
    // STEP 4: Connect to device
    [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:0.5];
}

- (void)handleUSBEvent {
    NSLog(@"USB event detected - refreshing...");

    if (!razerDevice_) {
        return;
    }

    // Cancel any pending connectToDevice retries from performSelector:afterDelay:
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(connectToDevice)
                                               object:nil];

    // Cancel any pending reconnect attempts
    if (pendingReconnect_) {
        dispatch_block_cancel(pendingReconnect_);
        pendingReconnect_ = nil;
    }

    razerDevice_->disconnect();

    // Single managed reconnect sequence with exponential backoff
    __weak __typeof(self) weakSelf = self;
    __block int attempt = 0;
    __block void (^reconnectBlock)(void) = ^{
        __strong __typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->razerDevice_) return;

        if (strongSelf->razerDevice_->connect()) {
            [strongSelf updateBatteryDisplay];
            return;
        }

        attempt++;
        if (attempt < 5) {
            // Exponential backoff: 2s, 4s, 8s, 16s
            double delay = pow(2.0, attempt);
            NSLog(@"Reconnect attempt %d failed, retrying in %.0fs", attempt, delay);

            strongSelf->pendingReconnect_ = reconnectBlock;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                          dispatch_get_main_queue(), strongSelf->pendingReconnect_);
        } else {
            NSLog(@"All reconnect attempts failed after %d tries", attempt);
            // Only show "Not Found" if ALL attempts fail
            NSImage* icon = [strongSelf mouseIconWithColor:[NSColor systemGrayColor]];
            if (icon) {
                strongSelf->statusItem_.button.image = icon;
                strongSelf->statusItem_.button.title = @"Not Found";
            } else {
                strongSelf->statusItem_.button.image = nil;
                strongSelf->statusItem_.button.title = @"🖱️ Not Found";
            }
            strongSelf->pendingReconnect_ = nil;
        }
    };

    // Start first reconnect attempt after 1 second
    pendingReconnect_ = reconnectBlock;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), pendingReconnect_);
}

- (void)manualRefresh:(id)sender {
    (void)sender;
    [self handleUSBEvent];
}

- (void)connectToDevice {
    // Try to connect
    if (!razerDevice_->connect()) {
        NSImage* icon = [self mouseIconWithColor:[NSColor systemGrayColor]];
        if (icon) {
            statusItem_.button.image = icon;
            statusItem_.button.title = @"Not Found";
        } else {
            statusItem_.button.image = nil;
            statusItem_.button.title = @"🖱️ Not Found";
        }
        NSLog(@"Failed to connect to Razer Viper V2 Pro");

        // Retry in 10 seconds if initial connection fails
        [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:10.0];
        return;
    }

    // Initial battery query
    [self updateBatteryDisplay];

    // Set up polling timer (30 seconds)
    // We still keep this as a fallback for battery % changes over time
    if (!pollTimer_) {
        pollTimer_ = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                       target:self
                                                     selector:@selector(pollBattery:)
                                                     userInfo:nil
                                                      repeats:YES];
    }
}

- (void)updateBatteryDisplay {
    if (razerDevice_ == nil) {
        NSLog(@"ERROR: razerDevice_ is nil");
        NSImage* icon = [self mouseIconWithColor:[NSColor whiteColor]];
        if (icon) {
            statusItem_.button.image = icon;
            statusItem_.button.title = @"...";
        } else {
            statusItem_.button.image = nil;
            statusItem_.button.title = @"🖱️ ...";
        }
        return;
    }

    if (!razerDevice_->isConnected()) {
        // Clean up stale state before reconnecting (resets isDongle_ etc.)
        razerDevice_->disconnect();
        NSLog(@"Device not connected, attempting reconnect...");
        if (!razerDevice_->connect()) {
            NSLog(@"ERROR: Failed to reconnect to device");
            NSImage* icon = [self mouseIconWithColor:[NSColor systemGrayColor]];
            if (icon) {
                statusItem_.button.image = icon;
                statusItem_.button.title = @"Disconnected";
            } else {
                statusItem_.button.image = nil;
                statusItem_.button.title = @"🖱️ Disconnected";
            }
            return;
        }
        NSLog(@"Successfully reconnected to Razer device");
    }
    
    uint8_t batteryPercent = 0;
    if (razerDevice_->queryBattery(batteryPercent)) {
        bool isCharging = false;
        razerDevice_->queryChargingStatus(isCharging);
        [self updateBatteryDisplayWithLevel:batteryPercent charging:isCharging];
    } else {
        // If query fails, show cached value with (?) indicator to avoid flickering
        NSLog(@"ERROR: Battery query failed");
        NSString* errorText;
        NSString* errorTextWithEmoji;
        NSColor* errorColor = [NSColor systemGrayColor];
        if (lastBatteryLevel_ > 0) {
            NSLog(@"WARNING: Using cached battery level: %d%%", lastBatteryLevel_);
            errorText = [NSString stringWithFormat:@"%d%% (?)", lastBatteryLevel_];
            errorTextWithEmoji = [NSString stringWithFormat:@"🖱️ %d%% (?)", lastBatteryLevel_];
        } else {
            errorText = @"Error";
            errorTextWithEmoji = @"🖱️ Error";
        }

        NSImage* icon = [self mouseIconWithColor:errorColor];
        if (icon) {
            statusItem_.button.image = icon;
            statusItem_.button.title = errorText;
        } else {
            statusItem_.button.image = nil;
            statusItem_.button.title = errorTextWithEmoji;
        }

        NSString* finalTitle = icon ? errorText : errorTextWithEmoji;
        NSDictionary* attrs = @{
            NSForegroundColorAttributeName: errorColor,
            NSFontAttributeName: [NSFont menuBarFontOfSize:0]
        };
        statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:finalTitle attributes:attrs];
    }
}

- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging {
    lastBatteryLevel_ = batteryPercent;

    // Format title text (battery percentage + charging indicator)
    NSString* titleText;
    NSString* titleTextWithEmoji;
    if (isCharging) {
        titleText = [NSString stringWithFormat:@"%d%% ⚡", batteryPercent];
        titleTextWithEmoji = [NSString stringWithFormat:@"🖱️ %d%% ⚡", batteryPercent];
    } else {
        titleText = [NSString stringWithFormat:@"%d%%", batteryPercent];
        titleTextWithEmoji = [NSString stringWithFormat:@"🖱️ %d%%", batteryPercent];
    }

    // Color based on battery level (for both icon and text)
    NSColor* displayColor;
    if (batteryPercent <= 20) {
        displayColor = [NSColor systemRedColor];      // Critical: Red (0-20%)
    } else if (batteryPercent <= 40) {
        displayColor = [NSColor systemYellowColor];   // Warning: Yellow (21-40%)
    } else {
        displayColor = [NSColor systemGreenColor];    // Good: Green (41-100%)
    }

    // Set icon (SF Symbol or emoji fallback)
    NSImage* icon = [self mouseIconWithColor:displayColor];
    if (icon) {
        statusItem_.button.image = icon;
        statusItem_.button.title = titleText;
    } else {
        statusItem_.button.image = nil;
        statusItem_.button.title = titleTextWithEmoji;
    }

    // Apply colored text
    NSString* finalTitle = icon ? titleText : titleTextWithEmoji;
    NSDictionary* attrs = @{
        NSForegroundColorAttributeName: displayColor,
        NSFontAttributeName: [NSFont menuBarFontOfSize:0]
    };
    statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:finalTitle attributes:attrs];

    // Low battery notification
    if (batteryPercent < 20 && batteryPercent > 0 && !notificationShown_ && !isCharging) {
        [self showLowBatteryNotification:batteryPercent];
        notificationShown_ = true;
    } else if (batteryPercent >= 20 || isCharging) {
        notificationShown_ = false;
    }
}

- (void)pollBattery:(NSTimer*)timer {
    (void)timer;
    // Run battery query on background thread to avoid UI freezing
    dispatch_async(batteryQueue_, ^{
        if (!razerDevice_ || !razerDevice_->isConnected()) return;

        uint8_t batteryPercent = 0;
        bool success = razerDevice_->queryBattery(batteryPercent);
        bool isCharging = false;
        if (success) {
            razerDevice_->queryChargingStatus(isCharging);
        }

        // Update UI on main thread with already-queried results
        if (success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateBatteryDisplayWithLevel:batteryPercent charging:isCharging];
            });
        }
    });
}

- (NSImage*)mouseIconWithColor:(NSColor*)color {
    (void)color;  // Color parameter reserved for future use
    
    // Try SF Symbol first (macOS 11+)
    if (@available(macOS 11.0, *)) {
        NSImage* icon = [NSImage imageWithSystemSymbolName:@"computermouse.fill" 
                               accessibilityDescription:@"Mouse"];
        if (icon) {
            // Return as template so it adapts to menu bar appearance
            [icon setTemplate:YES];
            return icon;
        }
    }
    
    // Fallback: return nil (text-only display will be used)
    return nil;
}

- (void)showLowBatteryNotification:(uint8_t)batteryPercent {
    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    // Request authorization (if not already granted)
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError* error) {
        if (error) {
            NSLog(@"ERROR: Failed to request notification authorization: %@", error);
            return;
        }

        if (!granted) {
            NSLog(@"WARNING: User denied notification authorization");
            return;
        }

        // Create notification content
        UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
        content.title = @"Razer Viper V2 Pro - Low Battery";
        content.body = [NSString stringWithFormat:@"Battery level is %d%%. Please charge your mouse.", batteryPercent];
        content.sound = [UNNotificationSound defaultSound];

        // Create notification request (deliver immediately)
        UNNotificationRequest* request = [UNNotificationRequest requestWithIdentifier:@"LowBatteryNotification"
                                                                              content:content
                                                                              trigger:nil];

        // Schedule notification
        [center addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error) {
                NSLog(@"ERROR: Failed to schedule notification: %@", error);
            } else {
                NSLog(@"Low battery notification scheduled");
            }
        }];
    }];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    if (pendingReconnect_) {
        dispatch_block_cancel(pendingReconnect_);
        pendingReconnect_ = nil;
    }
    if (pollTimer_) {
        [pollTimer_ invalidate];
        pollTimer_ = nil;
    }
    if (razerDevice_) {
        razerDevice_->stopMonitoring();
        razerDevice_->disconnect();
        delete razerDevice_;
        razerDevice_ = nullptr;
    }
}

@end

int main(int argc, const char* argv[]) {
    (void)argc;
    (void)argv;
    
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        
        BatteryMonitorApp* delegate = [[BatteryMonitorApp alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
