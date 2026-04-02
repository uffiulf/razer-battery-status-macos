#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <UserNotifications/UserNotifications.h>
#import "RazerDevice.hpp"
#import "ScrollInterceptor.hpp"

// Display style options stored in NSUserDefaults
typedef NS_ENUM(NSInteger, DisplayStyle) {
    DisplayStyleIconAndVerticalPercent = 0,  // Mouse icon + stacked "87 / %" (default)
    DisplayStyleIconAndPercent         = 1,  // Mouse icon + "87%"
    DisplayStylePercentOnly            = 2,  // "87%" (no icon)
    DisplayStyleIconOnly               = 3,  // Mouse icon only
};

// Color mode options stored in NSUserDefaults
typedef NS_ENUM(NSInteger, ColorMode) {
    ColorModeColored  = 0,  // 🔴 red ≤20%, 🟡 yellow 21-40%, ⬜ white >40%, 🟢 green charging (default)
    ColorModeWhite    = 1,  // Always white/system default, green only when charging
    ColorModeMinimal  = 2,  // Always white/system default, no special charging color
};

static NSString* const kDisplayStyleKey = @"displayStyle";
static NSString* const kColorModeKey    = @"colorMode";

static NSString* const kScrollMasterKey   = @"scrollMasterEnabled";
static NSString* const kScrollReverseKey  = @"scrollReverseEnabled";
static NSString* const kScrollSpeedKey    = @"scrollSpeedEnabled";
static NSString* const kScrollSpeedFactor = @"scrollSpeedFactor";
static NSString* const kScrollAccelKey    = @"scrollAccelEnabled";
static NSString* const kScrollAccelCurve  = @"scrollAccelCurve";
static NSString* const kScrollSmoothKey   = @"scrollSmoothEnabled";
static NSString* const kScrollDecayFactor = @"scrollDecayFactor";
static NSString* const kScrollBackKey     = @"scrollBackEnabled";

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
    NSMenu* colorModeMenu_;     // Submenu for color mode selection
    ScrollInterceptor* scrollInterceptor_;
    NSMenu* scrollSettingsMenu_;
    NSTimer* accessibilityPollTimer_;
}

- (void)updateBatteryDisplay;
- (void)updateBatteryDisplayWithLevel:(uint8_t)batteryPercent charging:(bool)isCharging;
- (void)setDisconnectedState:(NSString*)statusText;
- (void)menuWillOpen:(NSMenu*)menu;
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
- (ColorMode)currentColorMode;
- (void)setColorMode:(ColorMode)mode;
- (void)colorModeChanged:(id)sender;
- (NSMenu*)buildColorModeMenu;
- (NSMenu*)buildScrollSettingsMenu;
- (void)pushScrollPrefsToInterceptor;
- (void)updateScrollPermissionUI;
- (void)updateStatusBarTooltip;
- (void)openAccessibilitySetup:(id)sender;
- (void)scrollFeatureToggled:(id)sender;
- (void)scrollSpeedSliderChanged:(id)sender;
- (void)scrollAccelSliderChanged:(id)sender;
- (void)scrollDecaySliderChanged:(id)sender;
- (void)checkAccessibilityPermission:(NSTimer*)timer;
- (NSColor*)textColorForBattery:(uint8_t)batteryPercent charging:(bool)isCharging;
@end

// Static callback for RazerDevice monitoring (must be after @interface)
static void onDeviceChange(void* context) {
    BatteryMonitorApp* app = (__bridge BatteryMonitorApp*)context;
    // Ensure we run on main thread for UI updates
    dispatch_async(dispatch_get_main_queue(), ^{
        [app handleUSBEvent];
    });
}

@implementation BatteryMonitorApp {
    NSEvent* statusBarClickMonitor_;
}

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
        colorModeMenu_ = nil;
        // Register default preferences
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            kDisplayStyleKey:  @(DisplayStyleIconAndVerticalPercent),
            kColorModeKey:     @(ColorModeColored),
            kScrollMasterKey:   @NO,
            kScrollReverseKey:  @NO,
            kScrollSpeedKey:    @NO,   kScrollSpeedFactor: @2.0,
            kScrollAccelKey:    @NO,   kScrollAccelCurve:  @1.5,
            kScrollSmoothKey:   @NO,   kScrollDecayFactor: @0.85,
            kScrollBackKey:     @NO,
        }];
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    // LOGGFIL: /tmp/RazerBatteryMonitor.log (fungerer også med sudo)
    // freopen("/tmp/RazerBatteryMonitor.log", "a", stderr);  // NSLog skrives til stderr → loggfil
    NSLog(@"========== RazerBatteryMonitor startet ==========");

    // STEP 1: Create UI FIRST
    NSStatusBar* statusBar = [NSStatusBar systemStatusBar];
    statusItem_ = [statusBar statusItemWithLength:NSVariableStatusItemLength];
    
    NSLog(@"Status item created: %@", statusItem_);
    NSLog(@"Status item button: %@", statusItem_.button);
    
    // Set up button with click target for menu
    NSStatusBarButton* button = statusItem_.button;
    button.target = self;
    button.action = @selector(statusItemClicked:);
    
    NSImage* mouseIcon = [self mouseIconCharging:NO];
    if (mouseIcon) {
        button.image = mouseIcon;
        button.title = @"...";
        button.imagePosition = NSImageLeft;
    } else {
        button.title = @"🖱️ ...";
    }
    // Update tooltip to show scroll status
    [self updateStatusBarTooltip];
    NSLog(@"Button configured - image: %@", button.image);
    NSLog(@"Button title: '%@'", button.title);
    NSLog(@"Button imagePosition: %ld", (long)button.imagePosition);

    // Create menu
    NSMenu* menu = [[NSMenu alloc] init];
    NSLog(@"Menu created");
    
    NSMenuItem* versionItem_ = [[NSMenuItem alloc] initWithTitle:@"Version: 1.3.4" action:nil keyEquivalent:@""];
    [menu addItem:versionItem_];
    NSLog(@"Version item added");
    
    statusMenuItem_ = [[NSMenuItem alloc] initWithTitle:@"Starting..." action:nil keyEquivalent:@""];
    [statusMenuItem_ setEnabled:NO];
    [menu addItem:statusMenuItem_];
    NSLog(@"Status menu item added");
    
    [menu addItem:[NSMenuItem separatorItem]];
    NSLog(@"Separator added");
    
    NSMenuItem* refreshItem = [[NSMenuItem alloc] initWithTitle:@"Refresh"
                                                          action:@selector(manualRefresh:)
                                                   keyEquivalent:@"r"];
    [refreshItem setTarget:self];
    [menu addItem:refreshItem];
    NSLog(@"Refresh item added");
    
    // Display Style submenu
    NSMenuItem* displayStyleItem = [[NSMenuItem alloc] initWithTitle:@"Display Style" action:nil keyEquivalent:@""];
    displayStyleMenu_ = [self buildDisplayStyleMenu];
    [displayStyleItem setSubmenu:displayStyleMenu_];
    [menu addItem:displayStyleItem];
    NSLog(@"Display style submenu added");
    
    // Color Mode submenu
    NSMenuItem* colorModeItem = [[NSMenuItem alloc] initWithTitle:@"Color Mode" action:nil keyEquivalent:@""];
    colorModeMenu_ = [self buildColorModeMenu];
    [colorModeItem setSubmenu:colorModeMenu_];
    [menu addItem:colorModeItem];
    NSLog(@"Color mode submenu added");
    
    // Scroll Settings submenu
    NSMenuItem* scrollSettingsItem = [[NSMenuItem alloc] initWithTitle:@"Scroll Settings" action:nil keyEquivalent:@""];
    @try {
        scrollSettingsMenu_ = [self buildScrollSettingsMenu];
        [scrollSettingsItem setSubmenu:scrollSettingsMenu_];
        NSLog(@"Scroll settings submenu built successfully");
    } @catch (NSException* e) {
        NSLog(@"ERROR building scroll menu: %@", e);
        NSMenuItem* errItem = [[NSMenuItem alloc] initWithTitle:@"⚠️ Error loading menu" action:nil keyEquivalent:@""];
        [errItem setEnabled:NO];
        NSMenu* errMenu = [[NSMenu alloc] initWithTitle:@""];
        [errMenu addItem:errItem];
        [scrollSettingsItem setSubmenu:errMenu];
    }
    [menu addItem:scrollSettingsItem];
    NSLog(@"Scroll settings item added");
    
    [menu addItem:[NSMenuItem separatorItem]];
    NSLog(@"Separator added");
    
    NSMenuItem* loginItem = [[NSMenuItem alloc] initWithTitle:@"Open at Login"
                                                        action:@selector(openLoginSettings:)
                                                 keyEquivalent:@""];
    [loginItem setTarget:self];
    [menu addItem:loginItem];
    NSLog(@"Login item added");
    
    [menu addItem:[NSMenuItem separatorItem]];
    NSLog(@"Separator added");
    
    NSMenuItem* quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                        action:@selector(terminate:)
                                                 keyEquivalent:@"q"];
    [quitItem setTarget:NSApp];
    [menu addItem:quitItem];
    NSLog(@"Quit item added");
    statusItem_.menu = menu;
    NSLog(@"Menu assigned to statusItem");
    
    // Verify menu was set correctly
    if (statusItem_.menu) {
        NSLog(@"Menu successfully set: %lu items", (unsigned long)[statusItem_.menu.itemArray count]);
        for (NSMenuItem* item in statusItem_.menu.itemArray) {
            NSLog(@"  Item: '%@' (enabled=%d)", item.title, [item isEnabled]);
        }
    } else {
        NSLog(@"ERROR: Menu is nil after assignment!");
    }
    
    // Additional debug: test menu opening
    NSLog(@"Menu configuration complete - click test ready");

    // STEP 2: Force UI to appear immediately
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    
    // Additional debug: verify status item properties
    NSLog(@"Status item length: %f", [statusItem_ length]);
    NSLog(@"Status item button isHidden: %d", [statusItem_.button isHidden]);
    NSLog(@"Status item button alphaValue: %f", [statusItem_.button alphaValue]);

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


    
    // STEP 6: Set up scroll wheel interception
    scrollInterceptor_ = [[ScrollInterceptor alloc] init];
    [self pushScrollPrefsToInterceptor];
    if ([ScrollInterceptor hasAccessibilityPermission]) {
        NSError* tapError = nil;
        if (![scrollInterceptor_ startWithError:&tapError]) {
            NSLog(@"ScrollInterceptor start failed: %@", tapError);
        } else {
            NSLog(@"ScrollInterceptor started successfully - this should fix menu click issues");
        }
    } else {
        [self updateScrollPermissionUI];
        accessibilityPollTimer_ = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                                    target:self
                                                                  selector:@selector(checkAccessibilityPermission:)
                                                                  userInfo:nil
                                                                   repeats:YES];
    }
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

    // Dispatch connection tasks to background to avoid UI freeze while holding usbMutex_
    __weak BatteryMonitorApp* weakSelf = self;
    dispatch_async(batteryQueue_, ^{
        BatteryMonitorApp* strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // Disconnect stale USB handle
        strongSelf->razerDevice_->disconnect();

        // Try to reconnect once. If it fails, let the 10s poll timer retry.
        bool success = strongSelf->razerDevice_->connect();
        
        dispatch_async(dispatch_get_main_queue(), ^{
            BatteryMonitorApp* strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            if (success) {
                [strongSelf2 updateBatteryDisplay];
            } else {
                [strongSelf2 setDisconnectedState:@"Disconnected"];
            }
        });
    });
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

// --- Color Mode Preferences ---

- (ColorMode)currentColorMode {
    return (ColorMode)[[NSUserDefaults standardUserDefaults] integerForKey:kColorModeKey];
}

- (void)setColorMode:(ColorMode)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kColorModeKey];
    for (NSMenuItem* item in colorModeMenu_.itemArray) {
        item.state = (item.tag == mode) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (lastBatteryLevel_ > 0) {
        [self updateBatteryDisplayWithLevel:lastBatteryLevel_ charging:lastChargingState_];
    }
}

- (void)colorModeChanged:(id)sender {
    NSMenuItem* item = (NSMenuItem*)sender;
    [self setColorMode:(ColorMode)item.tag];
}

- (NSMenu*)buildColorModeMenu {
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:@"Color Mode"];
    ColorMode current = [self currentColorMode];

    NSArray* titles = @[
        @"Color coded  (🔴 ≤20%  🟡 21-40%  ⬜ >40%)",
        @"White + green when charging",
        @"Always white",
    ];

    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:titles[i]
                                                      action:@selector(colorModeChanged:)
                                               keyEquivalent:@""];
        item.tag = i;
        item.target = self;
        item.state = (i == current) ? NSControlStateValueOn : NSControlStateValueOff;
        [submenu addItem:item];
    }
    return submenu;
}

- (NSColor*)textColorForBattery:(uint8_t)batteryPercent charging:(bool)isCharging {
    switch ([self currentColorMode]) {
        case ColorModeColored:
            if (isCharging)          return [NSColor systemGreenColor];
            if (batteryPercent <= 20) return [NSColor systemRedColor];
            if (batteryPercent <= 40) return [NSColor systemYellowColor];
            return [NSColor controlTextColor];

        case ColorModeWhite:
            if (isCharging) return [NSColor systemGreenColor];
            return [NSColor controlTextColor];

        case ColorModeMinimal:
            return [NSColor controlTextColor];
    }
    return [NSColor controlTextColor];
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

    // 1. Determine the color based on user's chosen color mode
    NSColor* textColor = [self textColorForBattery:batteryPercent charging:isCharging];

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
    if (scrollInterceptor_) {
        [scrollInterceptor_ stop];
        scrollInterceptor_ = nil;
    }
    if (accessibilityPollTimer_) {
        [accessibilityPollTimer_ invalidate];
        accessibilityPollTimer_ = nil;
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

#pragma mark - Scroll Settings

- (NSMenu*)buildScrollSettingsMenu {
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:@"Scroll Settings"];
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    BOOL masterOn = [ud boolForKey:kScrollMasterKey];
    BOOL hasPermission = [ScrollInterceptor hasAccessibilityPermission];
    
    // Update title to show status
    if (!hasPermission) {
        submenu.title = @"Scroll Settings ⚠️ Needs Permission";
    } else if (!masterOn) {
        submenu.title = @"Scroll Settings 🖱️ Off";
    } else {
        submenu.title = @"Scroll Settings ✅ Enabled";
    }

    // Permission warning
    NSMenuItem* permItem = [[NSMenuItem alloc] initWithTitle:@"⚠ Enable Scroll Features (1-click setup…)"
                                                      action:@selector(openAccessibilitySetup:)
                                               keyEquivalent:@""];
    permItem.target = self;
    permItem.tag = 999; // Tag for easy lookup
    permItem.hidden = [ScrollInterceptor hasAccessibilityPermission];
    [submenu addItem:permItem];
    if (!permItem.hidden) [submenu addItem:[NSMenuItem separatorItem]];

    // 0. Master Switch
    NSMenuItem* masterItem = [[NSMenuItem alloc] initWithTitle:@"Enable Scroll Features"
                                                        action:@selector(scrollFeatureToggled:)
                                                 keyEquivalent:@""];
    masterItem.target = self;
    masterItem.tag = 10;
    masterItem.state = masterOn ? NSControlStateValueOn : NSControlStateValueOff;
    [submenu addItem:masterItem];
    [submenu addItem:[NSMenuItem separatorItem]];

    // 1. Reverse Scroll (no slider needed)
    NSMenuItem* reverseItem = [[NSMenuItem alloc] initWithTitle:@"Reverse Scroll"
                                                         action:@selector(scrollFeatureToggled:)
                                                  keyEquivalent:@""];
    reverseItem.target = self;
    reverseItem.tag = 0;
    reverseItem.state = [ud boolForKey:kScrollReverseKey] ? NSControlStateValueOn : NSControlStateValueOff;
    reverseItem.enabled = masterOn;
    [submenu addItem:reverseItem];
    [submenu addItem:[NSMenuItem separatorItem]];

    // 2. Scroll Speed — show slider only if enabled
    NSMenuItem* speedItem = [[NSMenuItem alloc] initWithTitle:@"Scroll Speed"
                                                       action:@selector(scrollFeatureToggled:)
                                                keyEquivalent:@""];
    speedItem.target = self;
    speedItem.tag = 1;
    BOOL speedOn = [ud boolForKey:kScrollSpeedKey];
    speedItem.state = speedOn ? NSControlStateValueOn : NSControlStateValueOff;
    speedItem.enabled = masterOn;
    [submenu addItem:speedItem];

    if (speedOn && masterOn) {
        NSMenuItem* speedSliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        speedSliderItem.view = [self sliderViewWithLabel:@"Speed"
                                                  value:[ud doubleForKey:kScrollSpeedFactor]
                                                    min:1.0 max:10.0
                                                 action:@selector(scrollSpeedSliderChanged:)
                                                    tag:1];
        [submenu addItem:speedSliderItem];
    }
    [submenu addItem:[NSMenuItem separatorItem]];

    // 3. Scroll Acceleration — show slider only if enabled
    NSMenuItem* accelItem = [[NSMenuItem alloc] initWithTitle:@"Scroll Acceleration"
                                                       action:@selector(scrollFeatureToggled:)
                                                keyEquivalent:@""];
    accelItem.target = self;
    accelItem.tag = 2;
    BOOL accelOn = [ud boolForKey:kScrollAccelKey];
    accelItem.state = accelOn ? NSControlStateValueOn : NSControlStateValueOff;
    accelItem.enabled = masterOn;
    [submenu addItem:accelItem];

    if (accelOn && masterOn) {
        NSMenuItem* accelSliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        accelSliderItem.view = [self sliderViewWithLabel:@"Curve"
                                                  value:[ud doubleForKey:kScrollAccelCurve]
                                                    min:1.0 max:3.0
                                                 action:@selector(scrollAccelSliderChanged:)
                                                    tag:2];
        [submenu addItem:accelSliderItem];
    }
    [submenu addItem:[NSMenuItem separatorItem]];

    // 4. Smooth Scrolling — show slider only if enabled
    NSMenuItem* smoothItem = [[NSMenuItem alloc] initWithTitle:@"Smooth Scrolling"
                                                        action:@selector(scrollFeatureToggled:)
                                                 keyEquivalent:@""];
    smoothItem.target = self;
    smoothItem.tag = 3;
    BOOL smoothOn = [ud boolForKey:kScrollSmoothKey];
    smoothItem.state = smoothOn ? NSControlStateValueOn : NSControlStateValueOff;
    smoothItem.enabled = masterOn;
    [submenu addItem:smoothItem];

    if (smoothOn && masterOn) {
        NSMenuItem* decaySliderItem = [[NSMenuItem alloc] initWithTitle:@"" action:nil keyEquivalent:@""];
        decaySliderItem.view = [self sliderViewWithLabel:@"Inertia"
                                                  value:[ud doubleForKey:kScrollDecayFactor]
                                                    min:0.70 max:0.98
                                                 action:@selector(scrollDecaySliderChanged:)
                                                    tag:3];
        [submenu addItem:decaySliderItem];
    }
    [submenu addItem:[NSMenuItem separatorItem]];

    // 5. Back Button Navigation (no slider needed)
    NSMenuItem* backItem = [[NSMenuItem alloc] initWithTitle:@"Back Button Navigation"
                                                      action:@selector(scrollFeatureToggled:)
                                               keyEquivalent:@""];
    backItem.target = self;
    backItem.tag = 4;
    backItem.state = [ud boolForKey:kScrollBackKey] ? NSControlStateValueOn : NSControlStateValueOff;
    backItem.enabled = masterOn;
    [submenu addItem:backItem];

    return submenu;
}

- (NSView*)sliderViewWithLabel:(NSString*)label
                         value:(double)value min:(double)min max:(double)max
                        action:(SEL)action tag:(NSInteger)tag {
    CGFloat width = 230.0;
    CGFloat height = 26.0;
    NSView* container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

    NSTextField* lbl = [NSTextField labelWithString:label];
    lbl.frame = NSMakeRect(18, 5, 55, 16);
    lbl.font = [NSFont systemFontOfSize:11.0];
    [container addSubview:lbl];

    NSSlider* slider = [[NSSlider alloc] initWithFrame:NSMakeRect(75, 4, 110, 18)];
    slider.minValue = min;
    slider.maxValue = max;
    slider.doubleValue = value;
    slider.continuous = YES;
    slider.target = self;
    slider.action = action;
    slider.tag = tag;
    [container addSubview:slider];

    NSString* fmt = ((max - min) < 1.0) ? @"%.2f" : @"%.1f";
    NSTextField* valLbl = [NSTextField labelWithString:[NSString stringWithFormat:fmt, value]];
    valLbl.frame = NSMakeRect(190, 5, 35, 16);
    valLbl.font = [NSFont systemFontOfSize:11.0];
    valLbl.tag = tag + 100;
    [container addSubview:valLbl];

    return container;
}

- (void)pushScrollPrefsToInterceptor {
    if (!scrollInterceptor_) return;
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    
    BOOL masterOn = [ud boolForKey:kScrollMasterKey];
    scrollInterceptor_.masterEnabled       = masterOn;
    
    scrollInterceptor_.reverseEnabled      = [ud boolForKey:kScrollReverseKey];
    scrollInterceptor_.speedEnabled        = [ud boolForKey:kScrollSpeedKey];
    scrollInterceptor_.speedFactor         = [ud doubleForKey:kScrollSpeedFactor];
    scrollInterceptor_.accelerationEnabled = [ud boolForKey:kScrollAccelKey];
    scrollInterceptor_.accelerationCurve   = [ud doubleForKey:kScrollAccelCurve];
    scrollInterceptor_.smoothEnabled       = [ud boolForKey:kScrollSmoothKey];
    scrollInterceptor_.smoothDecayFactor   = [ud doubleForKey:kScrollDecayFactor];
    scrollInterceptor_.backButtonEnabled   = [ud boolForKey:kScrollBackKey];
}

- (void)updateScrollPermissionUI {
    for (NSMenuItem* item in statusItem_.menu.itemArray) {
        if ([item.title isEqualToString:@"Scroll Settings"]) {
            NSMenuItem* permItem = [item.submenu itemWithTag:999];
            if (permItem) {
                permItem.hidden = [ScrollInterceptor hasAccessibilityPermission];
            }
            break;
        }
    }
}

- (void)openAccessibilitySetup:(id)sender {
    (void)sender;
    
    // Show clear instructions to user
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Enable Scroll Features in 1 Click";
    alert.informativeText = @"To enable scroll customization, Razer Battery Monitor needs Accessibility access.\n\nClick OK below to open System Settings, then:\n1. Scroll down to 'Privacy & Security'\n2. Click 'Accessibility'\n3. Toggle 'Razer Battery Monitor' ON\n4. Close System Settings\n\nScroll features will work immediately!";
    alert.alertStyle = NSAlertStyleInformational;
    
    [alert addButtonWithTitle:@"OK, Open Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    
    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        [ScrollInterceptor requestAccessibilityPermission];
    }
}

- (void)checkAccessibilityPermission:(NSTimer*)timer {
    (void)timer;
    if (![ScrollInterceptor hasAccessibilityPermission]) return;
    [accessibilityPollTimer_ invalidate];
    accessibilityPollTimer_ = nil;
    NSError* tapError = nil;
    if (![scrollInterceptor_ startWithError:&tapError]) {
        NSLog(@"ScrollInterceptor start failed after permission grant: %@", tapError);
    }
[self updateScrollPermissionUI];
}

- (void)scrollSpeedSliderChanged:(id)sender {
    NSSlider* slider = (NSSlider*)sender;
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:slider.doubleValue forKey:kScrollSpeedFactor];
    [ud synchronize];
    [self pushScrollPrefsToInterceptor];
    
    // Update value label
    NSView* superview = slider.superview;
    for (NSView* subview in superview.subviews) {
        if ([subview isKindOfClass:[NSTextField class]] && subview.tag == 101) {
            NSTextField* label = (NSTextField*)subview;
            NSString* fmt = ((slider.maxValue - slider.minValue) < 1.0) ? @"%.2f" : @"%.1f";
            label.stringValue = [NSString stringWithFormat:fmt, slider.doubleValue];
            break;
        }
    }
}

- (void)scrollAccelSliderChanged:(id)sender {
    NSSlider* slider = (NSSlider*)sender;
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:slider.doubleValue forKey:kScrollAccelCurve];
    [ud synchronize];
    [self pushScrollPrefsToInterceptor];
    
    // Update value label
    NSView* superview = slider.superview;
    for (NSView* subview in superview.subviews) {
        if ([subview isKindOfClass:[NSTextField class]] && subview.tag == 102) {
            NSTextField* label = (NSTextField*)subview;
            NSString* fmt = ((slider.maxValue - slider.minValue) < 1.0) ? @"%.2f" : @"%.1f";
            label.stringValue = [NSString stringWithFormat:fmt, slider.doubleValue];
            break;
        }
    }
}

- (void)scrollDecaySliderChanged:(id)sender {
    NSSlider* slider = (NSSlider*)sender;
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    [ud setDouble:slider.doubleValue forKey:kScrollDecayFactor];
    [ud synchronize];
    [self pushScrollPrefsToInterceptor];
    
    // Update value label
    NSView* superview = slider.superview;
    for (NSView* subview in superview.subviews) {
        if ([subview isKindOfClass:[NSTextField class]] && subview.tag == 103) {
            NSTextField* label = (NSTextField*)subview;
            NSString* fmt = ((slider.maxValue - slider.minValue) < 1.0) ? @"%.2f" : @"%.1f";
            label.stringValue = [NSString stringWithFormat:fmt, slider.doubleValue];
            break;
        }
    }
}

- (void)scrollFeatureToggled:(id)sender {
    NSMenuItem* menuItem = (NSMenuItem*)sender;
    NSInteger tag = menuItem.tag;
    
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    
    // Toggle the state first
    if (menuItem.state == NSControlStateValueOn) {
        menuItem.state = NSControlStateValueOff;
    } else {
        menuItem.state = NSControlStateValueOn;
    }
    
    switch (tag) {
        case 10: // Master switch
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollMasterKey];
            break;
        case 0: // Reverse scroll
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollReverseKey];
            break;
        case 1: // Scroll speed
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollSpeedKey];
            break;
        case 2: // Scroll acceleration
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollAccelKey];
            break;
        case 3: // Smooth scrolling
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollSmoothKey];
            break;
        case 4: // Back button
            [ud setBool:menuItem.state == NSControlStateValueOn forKey:kScrollBackKey];
            break;
        default:
            break;
    }
    
    // Save preferences and update interceptor
    [ud synchronize];
    [self pushScrollPrefsToInterceptor];
    
    NSLog(@"Scroll feature %ld toggled: %d", (long)tag, menuItem.state == NSControlStateValueOn);
}

- (void)menuWillOpen:(NSMenu*)menu {
    (void)menu;
    // Called when menu is about to open - can be used for dynamic updates
}

- (void)openAccessibilitySettings:(id)sender {
    (void)sender;
    // Legacy method - redirect to new setup method
    [self openAccessibilitySetup:sender];
}

- (void)statusItemClicked:(id)sender {
    (void)sender;
    NSLog(@"Status item clicked");
    // Menu should show automatically when status item is clicked
    // If it doesn't, we can force it by sending a mouse down event
    [statusItem_.button performClick:sender];
}

- (void)updateStatusBarTooltip {
    NSString* baseTooltip = @"Razer Battery Monitor";
    
    if (![ScrollInterceptor hasAccessibilityPermission]) {
        // Add scroll status to tooltip when permissions are missing
        NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
        BOOL masterOn = [ud boolForKey:kScrollMasterKey];
        
        if (masterOn) {
            statusItem_.button.toolTip = [NSString stringWithFormat:@"%@ ⚠️ Scroll Features Disabled (Enable Accessibility)", baseTooltip];
        } else {
            statusItem_.button.toolTip = [NSString stringWithFormat:@"%@ 🖱️ Scroll Features Off", baseTooltip];
        }
    } else {
        statusItem_.button.toolTip = baseTooltip;
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
