#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <UserNotifications/UserNotifications.h>
#import "RazerDevice.hpp"

// Display style options stored in NSUserDefaults
typedef NS_ENUM(NSInteger, DisplayStyle) {
    DisplayStyleIconAndVerticalPercent = 0,  // Mouse icon + stacked "87 / %" (default)
    DisplayStyleIconAndPercent         = 1,  // Mouse icon + "87%"
    DisplayStylePercentOnly            = 2,  // "87%" (no icon)
    DisplayStyleIconOnly               = 3,  // Mouse icon only
};

static NSString* const kDisplayStyleKey = @"displayStyle";

@interface BatteryMonitorApp : NSObject <NSApplicationDelegate> {
    NSStatusItem* statusItem_;
    NSMenuItem* statusMenuItem_;
    RazerDevice* razerDevice_;
    NSTimer* pollTimer_;
    uint8_t lastBatteryLevel_;
    bool lastChargingState_;
    bool notificationShown_;
    dispatch_queue_t batteryQueue_;
    int notChargingCount_;  // Debounce: antall påfølgende "ikke lader"-svar fra firmware
    NSMenu* displayStyleMenu_;  // Submenu for display style selection
}

- (void)updateBatteryDisplay;
- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging;
- (void)setDisconnectedState:(NSString*)statusText;
- (void)pollBattery:(NSTimer*)timer;
- (void)connectToDevice;
- (void)handleUSBEvent;
- (NSImage*)mouseIconCharging:(BOOL)charging;
- (void)showLowBatteryNotification:(uint8_t)batteryPercent deviceName:(NSString*)name;
- (void)manualRefresh:(id)sender;
- (void)schedulePollWithInterval:(NSTimeInterval)interval;
- (NSTimeInterval)pollIntervalForBattery:(uint8_t)battery charging:(bool)charging;
- (DisplayStyle)currentDisplayStyle;
- (void)setDisplayStyle:(DisplayStyle)style;
- (void)displayStyleChanged:(id)sender;
- (NSMenu*)buildDisplayStyleMenu;
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
        lastChargingState_ = false;
        notificationShown_ = false;
        batteryQueue_ = dispatch_queue_create("no.ulfsec.battery", DISPATCH_QUEUE_SERIAL);
        notChargingCount_ = 0;
        displayStyleMenu_ = nil;
        // Register default display style
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kDisplayStyleKey: @(DisplayStyleIconAndVerticalPercent)
        }];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // LOGGFIL: /tmp/RazerBatteryMonitor.log (fungerer også med sudo)
    freopen("/tmp/RazerBatteryMonitor.log", "a", stderr);  // NSLog skrives til stderr → loggfil
    NSLog(@"========== RazerBatteryMonitor startet ==========");

    // STEP 1: Create UI FIRST
    NSStatusBar* statusBar = [NSStatusBar systemStatusBar];
    statusItem_ = [statusBar statusItemWithLength:NSVariableStatusItemLength];

    NSImage* mouseIcon = [self mouseIconCharging:NO];
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

    NSMenuItem* versionItem_ = [[NSMenuItem alloc] initWithTitle:@"Version: 1.3.2" action:nil keyEquivalent:@""];
    [menu addItem:versionItem_];

    statusMenuItem_ = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    [statusMenuItem_ setEnabled:NO];
    [menu addItem:statusMenuItem_];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh"
                                                         action:@selector(manualRefresh:)
                                                  keyEquivalent:@"r"];
    [refreshItem setTarget:self];
    [menu addItem:refreshItem];

    // Display Style submenu
    NSMenuItem* displayStyleItem = [[NSMenuItem alloc] initWithTitle:@"Display Style" action:nil keyEquivalent:@""];
    displayStyleMenu_ = [self buildDisplayStyleMenu];
    [displayStyleItem setSubmenu:displayStyleMenu_];
    [menu addItem:displayStyleItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* loginItem = [[NSMenuItem alloc] initWithTitle:@"Open at Login"
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
    NSImage* icon = [self mouseIconCharging:NO];
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

- (NSTimeInterval)pollIntervalForBattery:(uint8_t)battery charging:(bool)charging {
    if (charging)           return 3.0;   // Lader → sjekk ofte (se når fulladet)
    if (battery <= 20 && battery > 0) return 10.0;  // Lav batteri
    return 10.0;                          // Normal
}

- (void)schedulePollWithInterval:(NSTimeInterval)interval {
    if (pollTimer_) {
        [pollTimer_ invalidate];
        pollTimer_ = nil;
    }
    pollTimer_ = [NSTimer scheduledTimerWithTimeInterval:interval
                                                   target:self
                                                 selector:@selector(pollBattery:)
                                                 userInfo:nil
                                                  repeats:NO];
}

- (void)openLoginSettings:(id)sender {
    (void)sender;
    // URL to open Login Items in System Settings (macOS 13+)
    NSURL* url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

// --- Display Style Preferences ---

- (DisplayStyle)currentDisplayStyle {
    return (DisplayStyle)[[NSUserDefaults standardUserDefaults] integerForKey:kDisplayStyleKey];
}

- (void)setDisplayStyle:(DisplayStyle)style {
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:kDisplayStyleKey];
    // Update checkmarks in submenu
    for (NSMenuItem* item in displayStyleMenu_.itemArray) {
        item.state = (item.tag == style) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    // Refresh display immediately with current cached values
    if (lastBatteryLevel_ > 0) {
        [self updateBatteryDisplayWithLevel:lastBatteryLevel_ charging:lastChargingState_];
    }
}

- (void)displayStyleChanged:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    [self setDisplayStyle:(DisplayStyle)item.tag];
}

- (NSMenu*)buildDisplayStyleMenu {
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:@"Display Style"];
    DisplayStyle current = [self currentDisplayStyle];

    NSDictionary* options = @{
        @(DisplayStyleIconAndVerticalPercent): @"Icon + Percent (stacked)",
        @(DisplayStyleIconAndPercent):         @"Icon + Percent",
        @(DisplayStylePercentOnly):            @"Percent only",
        @(DisplayStyleIconOnly):               @"Icon only",
    };
    NSArray* order = @[
        @(DisplayStyleIconAndVerticalPercent),
        @(DisplayStyleIconAndPercent),
        @(DisplayStylePercentOnly),
        @(DisplayStyleIconOnly),
    ];

    for (NSNumber* styleNum in order) {
        DisplayStyle style = (DisplayStyle)styleNum.integerValue;
        NSString* title = options[styleNum];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                                                      action:@selector(displayStyleChanged:)
                                               keyEquivalent:@""];
        item.tag = style;
        item.target = self;
        item.state = (style == current) ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
    return submenu;
}

- (void)connectToDevice {
    // Try to connect
    if (!razerDevice_->connect()) {
        // Sjekk om feilen skyldes manglende rettigheter
        if (razerDevice_->needsPrivileges()) {
            [self setDisconnectedState:@"⚠️ Trenger admin"];
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"Administrator-tilgang kreves";
            alert.informativeText =
                @"Razer Battery Monitor trenger administrator-rettigheter for å lese USB-enheter.\n\n"
                @"Kjør appen slik fra Terminal:\n"
                @"sudo open -a \"RazerBatteryMonitor\"\n\n"
                @"Eller installer som en systemtjeneste (LaunchDaemon) for automatisk oppstart.";
            alert.alertStyle = NSAlertStyleWarning;
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
            return;  // Ikke prøv igjen – krever brukerhandling
        }
        [self setDisconnectedState:@"Ingen Razer mus funnet"];
        NSLog(@"Failed to connect to Razer device");

        // Retry in 10 seconds if initial connection fails
        [self performSelector:@selector(connectToDevice) withObject:nil afterDelay:10.0];
        return;
    }

    // Initial battery query
    [self updateBatteryDisplay];

    // Start smart polling (one-shot timer som reschedulerer seg selv)
    if (!pollTimer_) {
        [self schedulePollWithInterval:5.0];  // Første poll raskt
    }
}

- (void)updateBatteryDisplay {
    if (razerDevice_ == nil) {
        NSLog(@"ERROR: razerDevice_ is nil");
        NSImage* icon = [self mouseIconCharging:NO];
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
            // Battery unknown but cable detected — route through display style so Icon Only etc. works
            NSLog(@"WARNING: Battery unknown, cable detected — showing charging state");
            [self updateBatteryDisplayWithLevel:0 charging:true];
        } else {
            [self setDisconnectedState:@"Battery query failed"];
        }
    }
}

- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging {
    lastBatteryLevel_ = batteryPercent;
    lastChargingState_ = isCharging;

    // 1. Determine the color
    NSColor* textColor;
    if (isCharging) {
        textColor = [NSColor systemGreenColor];
    } else if (batteryPercent <= 30) {
        textColor = [NSColor systemRedColor];
    } else if (batteryPercent <= 50) {
        textColor = [NSColor systemYellowColor];
    } else {
        textColor = [NSColor controlTextColor];
    }

    // Charging suffix symbol
    NSString* chargeSuffix = @"";
    if (isCharging && batteryPercent < 100) chargeSuffix = @"⚡︎";
    else if (isCharging && batteryPercent >= 100) chargeSuffix = @"🔌";

    DisplayStyle style = [self currentDisplayStyle];
    NSImage* icon = [self mouseIconCharging:isCharging];

    // 2. Apply display style
    switch (style) {

        case DisplayStyleIconAndVerticalPercent: {
            // Stacked: "87⚡︎" on top, "%" below — compact vertical layout
            NSString* textStr = [NSString stringWithFormat:@"%d%@\n%%", batteryPercent, chargeSuffix];
            NSMutableParagraphStyle* pStyle = [[NSMutableParagraphStyle alloc] init];
            pStyle.alignment = NSTextAlignmentCenter;
            pStyle.lineSpacing = -4.0;
            pStyle.maximumLineHeight = 8.0;
            pStyle.lineHeightMultiple = 0.8;
            NSDictionary* attrs = @{
                NSForegroundColorAttributeName: textColor,
                NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightMedium],
                NSParagraphStyleAttributeName: pStyle,
                NSBaselineOffsetAttributeName: @(-3.5)
            };
            statusItem_.button.contentTintColor = nil;
            statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:textStr attributes:attrs];
            if (icon) {
                statusItem_.button.image = icon;
                statusItem_.button.imagePosition = NSImageLeft;
            } else {
                statusItem_.button.image = nil;
            }
            break;
        }

        case DisplayStyleIconAndPercent: {
            // Horizontal: icon + "87%" side by side
            NSString* textStr = [NSString stringWithFormat:@"%d%%%@", batteryPercent, chargeSuffix];
            NSDictionary* attrs = @{
                NSForegroundColorAttributeName: textColor,
                NSFontAttributeName: [NSFont menuBarFontOfSize:0]
            };
            statusItem_.button.contentTintColor = nil;
            statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:textStr attributes:attrs];
            if (icon) {
                statusItem_.button.image = icon;
                statusItem_.button.imagePosition = NSImageLeft;
            } else {
                statusItem_.button.image = nil;
            }
            break;
        }

        case DisplayStylePercentOnly: {
            // Just "87%" — no icon
            NSString* textStr = [NSString stringWithFormat:@"%d%%%@", batteryPercent, chargeSuffix];
            NSDictionary* attrs = @{
                NSForegroundColorAttributeName: textColor,
                NSFontAttributeName: [NSFont menuBarFontOfSize:0]
            };
            statusItem_.button.contentTintColor = nil;
            statusItem_.button.image = nil;
            statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:textStr attributes:attrs];
            break;
        }

        case DisplayStyleIconOnly: {
            // Just the mouse icon — no text
            // Use color tint to indicate charging/battery level since there's no text
            statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
            statusItem_.button.title = @"";
            NSImage* displayIcon = icon ?: [self mouseIconCharging:NO];
            if (displayIcon) {
                statusItem_.button.image = displayIcon;
                statusItem_.button.imagePosition = NSImageOnly;
                // Tint the icon to show status: green=charging, red=low, yellow=medium, nil=normal
                statusItem_.button.contentTintColor = textColor == [NSColor controlTextColor] ? nil : textColor;
            } else {
                // Last resort: show plain text percentage
                NSDictionary* attrs = @{ NSForegroundColorAttributeName: textColor,
                                         NSFontAttributeName: [NSFont menuBarFontOfSize:0] };
                NSString* fallbackStr = [NSString stringWithFormat:@"%d%%%@", batteryPercent, chargeSuffix];
                statusItem_.button.image = nil;
                statusItem_.button.contentTintColor = nil;
                statusItem_.button.attributedTitle = [[NSAttributedString alloc] initWithString:fallbackStr attributes:attrs];
            }
            break;
        }
    }

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
    if ([deviceName length] == 0 || [deviceName isEqualToString:@"Unknown Razer Mouse"]) {
        deviceName = @"Razer Mouse";
    }
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
    pollTimer_ = nil;  // One-shot timer har fyrt, nullstill referansen

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
                    // Rescheduler med smart intervall etter reconnect
                    NSTimeInterval next = [self pollIntervalForBattery:(success ? batteryPercent : lastBatteryLevel_) charging:isCharging];
                    [self schedulePollWithInterval:next];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setDisconnectedState:@"Disconnected"];
                    [self schedulePollWithInterval:10.0];  // Prøv igjen om 10 sek
                });
            }
            return;
        }

        uint8_t batteryPercent = 0;
        bool success = razerDevice_->queryBattery(batteryPercent);
        bool isCharging = false;

        // BUG FIX: Alltid spør om ladestatus, uavhengig av om battery-query lyktes
        // Uten dette: hvis battery-query feiler → isCharging=false → ladeikon forsvinner
        razerDevice_->queryChargingStatus(isCharging);

        // Fallback: kabel til Mac (PID 0xA5 synlig i IOKit)
        if (!isCharging && razerDevice_->isWiredDevicePresent()) {
            isCharging = true;
        }

        // DEBOUNCE: Razer firmware rapporterer sporadisk charging=0 midt i lading.
        // Krev 3 påfølgende "ikke lader"-svar før vi faktisk bytter ikon.
        if (isCharging) {
            notChargingCount_ = 0;
        } else {
            notChargingCount_++;
            if (notChargingCount_ < 3) {
                isCharging = true;  // Hold ladeikon inntil vi er sikre
            }
        }

        // Bruk cachet verdi hvis battery-query feilet
        uint8_t displayLevel = (success && batteryPercent > 0) ? batteryPercent : lastBatteryLevel_;
        bool hasLevel = (success && batteryPercent > 0) || (lastBatteryLevel_ > 0);

        NSLog(@"[POLL] battery=%d%% (success=%d cached=%d%%) charging=%d notChargingCount=%d interval=%.0fs",
              batteryPercent, success, lastBatteryLevel_, isCharging, notChargingCount_,
              [self pollIntervalForBattery:displayLevel charging:isCharging]);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (hasLevel) {
                [self updateBatteryDisplayWithLevel:displayLevel charging:isCharging];
            }
            // Rescheduler med smart intervall basert på nåværende tilstand
            NSTimeInterval next = [self pollIntervalForBattery:displayLevel charging:isCharging];
            [self schedulePollWithInterval:next];
        });
    });
}

- (NSImage*)mouseIconCharging:(BOOL)charging {
    // Try SF Symbol first (macOS 11+)
    if (@available(macOS 11.0, *)) {
        // computermouse.and.bolt.fill requires macOS 13+, fall back gracefully
        NSString* symbolName = charging ? @"computermouse.and.bolt.fill" : @"computermouse.fill";
        NSImage* icon = [NSImage imageWithSystemSymbolName:symbolName
                               accessibilityDescription:charging ? @"Mouse charging" : @"Mouse"];
        if (!icon && charging) {
            // Bolt symbol unavailable (macOS < 13) — use plain mouse icon instead
            icon = [NSImage imageWithSystemSymbolName:@"computermouse.fill"
                           accessibilityDescription:@"Mouse"];
        }
        if (icon) {
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
