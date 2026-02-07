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
- (NSImage*)mouseIcon;
- (void)showLowBatteryNotification:(uint8_t)batteryPercent deviceName:(NSString*)name;
- (void)manualRefresh:(id)sender;
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
    
    NSImage* mouseIcon = [self mouseIcon];
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

    NSMenuItem* loginItem = [[NSMenuItem alloc] initWithTitle:@"Start at Login..."
                                                       action:@selector(openLoginSettings:)
                                                keyEquivalent:@""];
    [loginItem setTarget:self];
    [menu addItem:loginItem];

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
    
    // STEP 4: Register for sleep/wake notifications
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(systemWillSleep:)
        name:NSWorkspaceWillSleepNotification object:nil];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserver:self selector:@selector(systemDidWake:)
        name:NSWorkspaceDidWakeNotification object:nil];

    // STEP 5: Connect to device
    [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:0.5];
}

- (void)setDisconnectedState:(NSString*)statusText {
    // Show only icon (no text) in menu bar to save space
    NSImage* icon = [self mouseIcon];
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

- (void)openLoginSettings:(id)sender {
    (void)sender;
    // URL to open Login Items in System Settings (macOS 13+)
    NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"];
    [[NSWorkspace sharedWorkspace] openURL:url];
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
        NSImage* icon = [self mouseIcon];
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
        } else if (isCharging) {
            // New logic: Show ONLY the lightning bolt icon in green when battery is unknown
            NSImage* icon = [self mouseIcon]; // Color ignored here
            if (icon) {
                [icon setTemplate:YES]; // Ensure template mode for tinting
                statusItem_.button.image = icon;
                statusItem_.button.contentTintColor = nil; // Use system color for icon
            }
            statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:@"⚡" attributes:@{
                NSForegroundColorAttributeName: [NSColor systemGreenColor],
                NSFontAttributeName: [NSFont menuBarFontOfSize:0]
            }];
            NSString* deviceName = [NSString stringWithUTF8String:razerDevice_->deviceName().c_str()];
            statusMenuItem_.title = [NSString stringWithFormat:@"%@ — Charging via USB-C", deviceName];
        } else {
            [self setDisconnectedState:@"Battery query failed"];
        }
    }
}

- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging {
    lastBatteryLevel_ = batteryPercent;

    // Format menu bar text
    NSString* titleText;
    if (isCharging && batteryPercent >= 100) {
        titleText = [NSString stringWithFormat:@"%d%% 🔌", batteryPercent];
    } else if (isCharging) {
        titleText = [NSString stringWithFormat:@"%d%% ⚡", batteryPercent];
    } else {
        titleText = [NSString stringWithFormat:@"%d%%", batteryPercent];
    }

    // Design choice: Text color based on status, Icon remains system default
    NSColor* textColor;
    if (isCharging) {
        textColor = [NSColor systemGreenColor];
    } else if (batteryPercent <= 20) {
        textColor = [NSColor systemRedColor];
    } else if (batteryPercent <= 30) {
        textColor = [NSColor systemYellowColor];
    } else {
        textColor = [NSColor controlTextColor]; // Standard white/black
    }

    // Set icon (Always template mode, no manual tinting)
    NSImage* icon = [self mouseIcon];
    if (icon) {
        [icon setTemplate:YES];
        statusItem_.button.image = icon;
        statusItem_.button.contentTintColor = nil; // Clear any previous tint
    }
    
    NSDictionary* attrs = @{
        NSForegroundColorAttributeName: textColor,
        NSFontAttributeName: [NSFont menuBarFontOfSize:0]
    };
    statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:titleText attributes:attrs];

    // Update dropdown menu status line
    NSString* mode;
    if (isCharging && batteryPercent >= 100) {
        mode = @"Fully charged";
    } else if (isCharging) {
        mode = @"Charging via USB-C";
    } else {
        mode = @"Wireless";
    }
    
    NSString* deviceName = [NSString stringWithUTF8String:razerDevice_->deviceName().c_str()];
    statusMenuItem_.title = [NSString stringWithFormat:@"%@ — %@ — %d%%", deviceName, mode, batteryPercent];

    // Low battery notification (only when not charging)
    if (batteryPercent < 20 && batteryPercent > 0 && !notificationShown_ && !isCharging) {
        [self showLowBatteryNotification:batteryPercent deviceName:deviceName];
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

- (NSImage*)mouseIcon {
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

- (void)showLowBatteryNotification:(uint8_t)batteryPercent deviceName:(NSString*)name {
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
        content.title = [NSString stringWithFormat:@"%@ - Low Battery", name];
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

- (void)systemWillSleep:(NSNotification*)notification {
    (void)notification;
    NSLog(@"System going to sleep, pausing poll timer");
    if (pollTimer_) {
        [pollTimer_ invalidate];
        pollTimer_ = nil;
    }
    if (razerDevice_) {
        razerDevice_->disconnect();
    }
}

- (void)systemDidWake:(NSNotification*)notification {
    (void)notification;
    NSLog(@"System woke up, reconnecting...");
    // Give USB subsystem time to re-enumerate devices after wake
    [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:2.0];
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
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