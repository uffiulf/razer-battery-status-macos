#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <UserNotifications/UserNotifications.h>
#import "RazerDevice.hpp"

@interface BatteryMonitorApp : NSObject <NSApplicationDelegate> {
    NSStatusItem* statusItem_;
    NSMenuItem* statusMenuItem_;
    RazerDevice* razerDevice_;
    NSTimer* pollTimer_;
    uint8_t lastBatteryLevel_;
    bool notificationShown_;
    dispatch_queue_t batteryQueue_;
}

- (void)updateBatteryDisplay;
- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging;
- (void)setDisconnectedState:(NSString*)statusText;
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

    statusMenuItem_ = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    [statusMenuItem_ setEnabled:NO];
    [menu addItem:statusMenuItem_];

    [menu addItem:[NSMenuItem separatorItem]];

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

- (void)setDisconnectedState:(NSString*)statusText {
    // Show only icon (no text) in menu bar to save space
    NSImage* icon = [self mouseIconWithColor:[NSColor systemGrayColor]];
    if (icon) {
        statusItem_.button.image = icon;
    }
    statusItem_.button.title = @"";
    statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
    statusMenuItem_.title = statusText;
}

- (void)handleUSBEvent {
    NSLog(@"USB event detected - refreshing...");

    if (!razerDevice_) {
        return;
    }

    // Cancel any pending connectToDevice retries
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(connectToDevice)
                                               object:nil];

    // Disconnect stale USB handle
    razerDevice_->disconnect();

    // Try to reconnect once. If it fails, let the 10s poll timer retry.
    if (razerDevice_->connect()) {
        [self updateBatteryDisplay];
    } else {
        [self setDisconnectedState:@"Disconnected"];
    }
}

- (void)manualRefresh:(id)sender {
    (void)sender;
    [self handleUSBEvent];
}

- (void)connectToDevice {
    // Try to connect
    if (!razerDevice_->connect()) {
        [self setDisconnectedState:@"No Razer mouse found"];
        NSLog(@"Failed to connect to Razer device");

        // Retry in 10 seconds if initial connection fails
        [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:10.0];
        return;
    }

    // Initial battery query
    [self updateBatteryDisplay];

    // Set up polling timer (30 seconds)
    // We still keep this as a fallback for battery % changes over time
    if (!pollTimer_) {
        pollTimer_ = [NSTimer scheduledTimerWithTimeInterval:10.0
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
            [self setDisconnectedState:@"Disconnected"];
            return;
        }
        NSLog(@"Successfully reconnected to Razer device");
    }
    
    uint8_t batteryPercent = 0;
    if (razerDevice_->queryBattery(batteryPercent)) {
        bool isCharging = false;
        razerDevice_->queryChargingStatus(isCharging);
        // Fallback: if wired PID is present in IOKit, mouse is charging via cable
        if (!isCharging && razerDevice_->isWiredDevicePresent()) {
            isCharging = true;
        }
        [self updateBatteryDisplayWithLevel:batteryPercent charging:isCharging];
    } else {
        // Battery query failed - check cable and use cached value
        NSLog(@"ERROR: Battery query failed");
        bool isCharging = razerDevice_->isWiredDevicePresent();
        if (lastBatteryLevel_ > 0) {
            NSLog(@"WARNING: Using cached battery level: %d%%", lastBatteryLevel_);
            [self updateBatteryDisplayWithLevel:lastBatteryLevel_ charging:isCharging];
        } else {
            [self setDisconnectedState:@"Battery query failed"];
        }
    }
}

- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging {
    lastBatteryLevel_ = batteryPercent;

    // Format menu bar text
    NSString* titleText;
    if (isCharging) {
        titleText = [NSString stringWithFormat:@"%d%% ⚡", batteryPercent];
    } else {
        titleText = [NSString stringWithFormat:@"%d%%", batteryPercent];
    }

    // Color based on battery level
    NSColor* displayColor;
    if (batteryPercent <= 20) {
        displayColor = [NSColor systemRedColor];
    } else if (batteryPercent <= 40) {
        displayColor = [NSColor systemYellowColor];
    } else {
        displayColor = [NSColor systemGreenColor];
    }

    // Set icon and text in menu bar
    NSImage* icon = [self mouseIconWithColor:displayColor];
    if (icon) {
        statusItem_.button.image = icon;
    }
    NSDictionary* attrs = @{
        NSForegroundColorAttributeName: displayColor,
        NSFontAttributeName: [NSFont menuBarFontOfSize:0]
    };
    statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:titleText attributes:attrs];

    // Update dropdown menu status line
    NSString* mode = isCharging ? @"Charging via USB-C" : @"Wireless";
    statusMenuItem_.title = [NSString stringWithFormat:@"Razer Viper V2 Pro — %@ — %d%%", mode, batteryPercent];

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
        if (!razerDevice_) return;

        // Detect disconnection (fallback when IOKit notifications don't fire)
        if (!razerDevice_->isConnected()) {
            razerDevice_->disconnect();
            NSLog(@"Poll detected disconnect, attempting reconnect...");

            bool reconnected = razerDevice_->connect();
            if (reconnected) {
                uint8_t batteryPercent = 0;
                bool success = razerDevice_->queryBattery(batteryPercent);
                bool isCharging = false;
                if (success) {
                    razerDevice_->queryChargingStatus(isCharging);
                    // Fallback: if wired PID is present in IOKit, mouse is charging via cable
                    if (!isCharging && razerDevice_->isWiredDevicePresent()) {
                        isCharging = true;
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (success) {
                        NSLog(@"Reconnected and got battery: %d%%", batteryPercent);
                        [self updateBatteryDisplayWithLevel:batteryPercent charging:isCharging];
                    } else {
                        [self updateBatteryDisplay];
                    }
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setDisconnectedState:@"Disconnected"];
                });
            }
            return;
        }

        uint8_t batteryPercent = 0;
        bool success = razerDevice_->queryBattery(batteryPercent);
        bool isCharging = false;
        if (success) {
            razerDevice_->queryChargingStatus(isCharging);
        }
        // Always check cable presence (works even when battery query fails)
        if (!isCharging && razerDevice_->isWiredDevicePresent()) {
            isCharging = true;
        }

        // Update UI on main thread
        uint8_t displayLevel = success ? batteryPercent : lastBatteryLevel_;
        bool hasLevel = success || (lastBatteryLevel_ > 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasLevel) {
                [self updateBatteryDisplayWithLevel:displayLevel charging:isCharging];
            }
        });
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
