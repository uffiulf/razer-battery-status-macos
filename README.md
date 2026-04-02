# Razer Battery Monitor for macOS

A native macOS menu bar application that displays battery status for supported Razer wireless mice.

![Status: Working](https://img.shields.io/badge/Status-Working-brightgreen)
![Version: 1.3.4](https://img.shields.io/badge/Version-1.3.4-blue)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS-blue)




-------------------------------------------------------------------------------------------------------------------

**📥 [Download Latest Release](https://github.com/uffiulf/razer-battery-status-macos/releases/latest)**

-------------------------------------------------------------------------------------------------------------------




## Features

- 🔋 Real-time battery percentage in menu bar
- ⚡ Charging indicator when USB cable connected (instant detection)
- 🎨 Color-coded battery levels:
  - 🔴 Red: ≤20% (Critical)
  - 🟡 Yellow: 21-40% (Warning)
  - 🟢 Green: 41-100% (Good)
- 🔔 Low battery notifications (< 20%)
- 🔄 Auto-refresh every 30 seconds + USB hotplug detection
- 🔌 Automatic Wired/Wireless mode detection via Product ID
- 🖱️ Hover tooltip shows device name
- 🍎 Native macOS app using Cocoa + IOKit
- 📦 DMG installer with drag-and-drop installation

## 🎛️ New! Custom Scroll Settings (v1.3.4)

Enhance your mouse scrolling experience with customizable scroll features:

| Feature | Description |
|---------|-------------|
| **Reverse Scroll** | Flip scroll direction (natural/touchpad style) |
| **Scroll Speed** | Adjust scroll speed multiplier (1x-10x) |
| **Scroll Acceleration** | Customize acceleration curve for different feel |
| **Smooth Scrolling** | Momentum-based smooth scrolling with inertia |
| **Back Button** | Mouse button 4 triggers Finder back navigation |

### Requirements
- Accessibility permission required (app will guide you through 1-click setup)
- Works with any mouse scroll wheel
- Battery monitoring works without any special permissions

### How to Enable
1. Click the mouse icon in menu bar
2. Go to "Scroll Settings"
3. Click "Enable Scroll Features (1-click setup...)"
4. Follow the simple instructions in System Settings
5. Enable scroll features and customize to your preference!

## Supported Devices

The following Razer wireless mice are supported (wireless and wired/charging modes):

| Mouse Model | Status |
|-------------|--------|
| Razer Viper V2 Pro | ✅ Supported & Tested |
| Razer DeathAdder V3 Pro | ✅ Supported & Tested |
| Razer DeathAdder V2 Pro | ✅ Supported |
| Razer Viper Ultimate | ✅ Supported |
| Razer Basilisk Ultimate | ✅ Supported |
| Razer Naga Pro | ✅ Supported |
| Razer Basilisk V3 Pro | ✅ Supported |
| Razer Cobra Pro | ✅ Supported |
| Razer Naga V2 Pro | ✅ Supported |
| Razer DeathAdder V4 Pro | ✅ Supported |
| Razer Viper V3 Pro | ✅ Supported |
| Razer Mamba Wireless | ✅ Supported |
| Razer Lancehead Wireless | ✅ Supported |
| Razer Orochi V2 | ✅ Supported |
| Razer Naga Epic Chroma | ✅ Supported |
| Razer Mamba | ✅ Supported |
| Razer Lancehead | ✅ Supported |
| Razer Mamba 2012 | ✅ Supported |
| Razer Naga Epic | ✅ Supported |

*Note: While these devices are listed as supported, battery query protocol compatibility may vary. The app will automatically detect and connect to any supported device that is connected.*

---

## Installation

### From DMG (Recommended)
1. **[Download latest release](https://github.com/uffiulf/razer-battery-status-macos/releases/latest)** - Download `RazerBatteryMonitor-Installer.dmg`
2. Open the DMG and drag the app to Applications
3. Right-click the app → "Open" (first time only, to bypass Gatekeeper)
4. Grant Input Monitoring permission if prompted

### From Source
```bash
git clone https://github.com/uffiulf/razer-battery-status-macos.git
cd razer-battery-status-macos
make
sudo ./RazerBatteryMonitor
```

### Build Release DMG
```bash
./create_release.sh
open RazerBatteryMonitor.dmg
```

---

## Usage

| State | Display |
|-------|---------|
| Wireless (battery OK) | `🖱️ 85%` (green) - 41-100% |
| Wireless (battery warning) | `🖱️ 30%` (yellow) - 21-40% |
| Wireless (low battery) | `🖱️ 15%` (red) - ≤20% |
| Charging via USB | `🖱️ 100% ⚡` (green) |
| Device not found | `🖱️ Not Found` |

**Menu options:**
- **Refresh** (⌘R) - Force immediate battery update without restarting
- **Quit** (⌘Q) - Exit the application

---

## How It Works

### Wired vs. Wireless Detection

The Razer Viper V2 Pro uses **different USB Product IDs** depending on connection type:

| Connection | Product ID (PID) | Mode |
|------------|------------------|------|
| USB Cable (Direct) | `0x00A5` (165) | Wired/Charging |
| USB Dongle (Wireless) | `0x00A6` (166) | Wireless |

The app detects which PID is present and automatically sets the charging status accordingly. When connected via cable (PID 0xA5), the ⚡ icon appears instantly.

### Battery Query Protocol

- **Command 0x80**: Get Battery Level (Byte 9 = 0-255 raw value)
- **Command 0x84**: Get Charging Status (Byte 11 = 0x01 if charging)
- **Transaction ID 0x1F**: Wireless protocol (works for Viper V2 Pro)

---

## Technical Details

### Protocol Structure (90 bytes)

```
Byte 0:     Status (0x00 = New Command)
Byte 1:     Transaction ID (0x1F for wireless)
Bytes 2-4:  Reserved
Byte 5:     Data Size (0x02)
Byte 6:     Command Class (0x07 = Power)
Byte 7:     Command ID (0x80 = Get Battery, 0x84 = Get Charging)
Bytes 8-87: Arguments (battery at byte 9, charging at byte 11)
Byte 88:    Checksum (XOR of bytes 2-87)
Byte 89:    Reserved
```

### USB Control Transfer

```
bmRequestType: 0x21 (SET) / 0xA1 (GET)
bRequest:      0x09 (SET_REPORT) / 0x01 (GET_REPORT)
wValue:        0x0300 (Feature Report, ID 0)
wIndex:        0x00 (protocol index for mice)
wLength:       90 bytes
```

### Key Discoveries

| Parameter | Description |
|-----------|-------------|
| PID 0xA5 | Wired mouse (direct USB connection = charging) |
| PID 0xA6 | Wireless dongle |
| Transaction ID 0x1F | Works for Viper V2 Pro (not 0xFF) |
| Valid Status | 0x00, 0x02, or 0x04 (not just 0x00) |
| Battery Byte | Response byte 9 (0-255 scale) |
| Charging Byte | Response byte 11 (0x01 = charging) |

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    main.mm (Objective-C++)              │
│  ┌─────────────────┐  ┌──────────────────────────────┐  │
│  │  NSStatusItem   │  │  NSTimer (30s polling)       │  │
│  │  (Menu Bar UI)  │  │  USB Hotplug Notifications   │  │
│  └────────┬────────┘  └──────────────┬───────────────┘  │
│           │                          │                  │
│           └──────────┬───────────────┘                  │
│                      ▼                                  │
│           ┌──────────────────────┐                      │
│           │    RazerDevice.cpp   │                      │
│           │  - queryBattery()    │                      │
│           │  - queryChargingStatus() │                  │
│           │  - PID-based mode detect │                  │
│           └──────────┬───────────┘                      │
│                      │                                  │
└──────────────────────┼──────────────────────────────────┘
                       ▼
              ┌────────────────┐
              │  IOKit (macOS) │
              │  USB Control   │
              │   Transfers    │
              └────────┬───────┘
                       ▼
              ┌────────────────┐
              │  Razer mouse   │
              │   V2 Pro       │
              │  (Interface 2) │
              └────────────────┘
```

---

## Files

| File | Description |
|------|-------------|
| `src/RazerDevice.cpp` | USB communication via IOKit, PID detection |
| `src/RazerDevice.hpp` | Header with constants and class definition |
| `src/main.mm` | Cocoa UI (NSStatusBar menu bar app) |
| `Info.plist` | macOS app configuration |
| `Makefile` | Build configuration |
| `build_app.sh` | Creates .app bundle |
| `create_release.sh` | Creates styled DMG installer |

---

## System Requirements

### Supported macOS Versions
| Version | Codename | Status |
|---------|----------|--------|
| macOS 15.x | Sequoia | ✅ Tested |
| macOS 14.x | Sonoma | ✅ Supported |
| macOS 13.x | Ventura | ✅ Supported |
| macOS 12.x | Monterey | ✅ Supported |
| macOS 11.x | Big Sur | ✅ Supported |
| macOS 10.15 | Catalina | ✅ Supported |
| macOS 10.14 | Mojave | ⚠️ Minimum |

### Supported Hardware
| Architecture | Status |
|--------------|--------|
| Apple Silicon (M1/M2/M3/M4) | ✅ Native (arm64) |
| Intel (x86_64) | ✅ Native (x86_64) |

**Note:** The DMG contains a **Universal Binary** that runs natively on both architectures.

### Other Requirements
- Xcode Command Line Tools (for building from source)
- Razer Viper V2 Pro mouse
- `create-dmg` (for building DMG): `brew install create-dmg`

---

## Troubleshooting

### "Razer: Not Found"
- Ensure the mouse is connected (wired or via USB receiver)
- Check that no other app is claiming the device

### No menu bar icon
- Run as `.app` bundle, not raw binary
- Check Activity Monitor for running process

### Permission errors
- Grant Input Monitoring permission in System Settings
- First launch may require: right-click → Open

---

## Known Issues

- **Sleep mode detection**: When the mouse enters sleep mode, the app may display 100% battery + charging icon. This is incorrect behavior and will be fixed in a future update.

- **Must run as `.app` bundle**: Running the raw binary directly from Terminal (`./RazerBatteryMonitor`) will cause an `Abort trap: 6` crash. This is because `UNUserNotificationCenter` requires a valid Bundle Identifier, which is only present when the app is launched as a proper `.app` bundle. Always launch via `RazerBatteryMonitor.app` or `open -a RazerBatteryMonitor`.

- **Brief UI freeze on USB connect (0.3s)**: When the mouse is plugged in via cable or wakes from sleep, the menu bar may freeze for ~0.3 seconds. This is caused by `setDeviceMode` sending a USB initialization command with a hardware delay. It only occurs during connect events, not during normal use. A full fix requires a thread-safe state machine (planned for v1.4.0).

- **Notifications may not work when running as root**: If the app is started with `sudo`, `UNUserNotificationCenter` may fail to deliver low battery notifications to the logged-in user. Run the app as a regular user (not root) for reliable notifications.

---

## Recent Updates (2026)

### 🎛️ Custom Scroll Settings (v1.3.4)

Major feature release with customizable scroll wheel behavior:

**New Features:**
- ✅ **Scroll Interceptor**: Full control over mouse scroll wheel events
- ✅ **Smooth Scrolling**: Momentum-based scrolling with configurable inertia (decay factor 0.70-0.98)
- ✅ **Reverse Scroll**: Flip scroll direction for natural/touchpad style
- ✅ **Scroll Speed**: Adjustable speed multiplier (1x-10x)
- ✅ **Scroll Acceleration**: Customizable acceleration curve
- ✅ **Back Button Navigation**: Mouse button 4 triggers Finder back (Cmd+[)
- ✅ **1-Click Setup**: User-friendly dialog guides through Accessibility permission
- ✅ **Professional DMG Installer**: Traditional Mac drag-and-drop installation
- ✅ **Visual Feedback**: Status indicators (⚠️/🖱️/✅) in menu

**Technical Implementation:**
- CGEventTap for scroll wheel interception
- CVDisplayLink/CADisplayLink for smooth 60fps animation
- SmoothScrollEngine with velocity tracking and decay
- Automatic permission detection and UI updates

**Fixes:**
- Fixed menu not showing when clicking status bar icon
- Fixed back button (mouse 4) not working in Finder
- Fixed scroll settings being disabled without Accessibility permission
- Added missing action methods for scroll toggles and sliders

User-configurable display styles and color modes for personalized menu bar appearance:

**New Features:**
- ✅ **Display Style** menu: Choose how battery is shown in menu bar
  - Icon + Percent (stacked) — 87⚡︎ / % — most compact
  - Icon + Percent — 87% horizontally
  - Percent only — 87% without icon
  - Icon only — Mouse icon with color tint (no text)
- ✅ **Color Mode** menu: Select color scheme for battery status
  - Color coded — 🔴 red ≤20%, 🟡 yellow 21-40%, ⬜ white >40%, 🟢 green charging
  - White + green when charging — Most minimal, green only when actively charging
  - Always white — No color indicators (system default)
- ✅ **Smart icon tinting** — In "Icon only" mode, colors now show battery status (no text needed)
- ✅ **NSUserDefaults persistence** — Settings saved across app restarts

**Fixes:**
- Fixed icon disappearing in Icon Only mode when charging
- Fixed charging cable bypassing display style preferences
- Improved macOS 12 compatibility (graceful fallback from bolt symbols)

**Result:** Users can now fully customize how their battery status appears in the menu bar while maintaining the app's clean, native macOS aesthetic.

---

### 🚀 Major Refactoring - Thread Safety & Reliability (v1.3.0)

A comprehensive refactoring was completed to fix 13 bugs and improve reliability:

**Critical Fixes:**
- ✅ **Thread safety**: Added mutex protection for all USB operations
- ✅ **Memory leaks**: Fixed CFMutableDictionary and dispatch_block leaks
- ✅ **UI freezing**: Moved USB operations to background thread (no more menu bar lag)
- ✅ **USB timeouts**: Added 5-second timeout to prevent infinite hangs

**Reliability Improvements:**
- ✅ **Reconnection**: Fixed memory leak in hotplug reconnection logic
- ✅ **Active validation**: isConnected() now validates interface is actually live
- ✅ **Error logging**: Comprehensive logging for diagnostics
- ✅ **Adaptive timing**: USB timing adapts to system load (100ms-500ms)

**Code Quality:**
- ✅ **Modern API**: Updated to UNUserNotification (from deprecated NSUserNotification)
- ✅ **No goto**: Removed unstructured control flow
- ✅ **RAII**: CoreFoundation objects now properly managed

**Result:** Production-ready app with no crashes, hangs, or memory leaks

See [REFACTORING_NOTES.md](REFACTORING_NOTES.md) for detailed technical information.

---

## Changelog

### v1.3.4
- **Custom Scroll Settings**: New feature with 5 scroll customization options
- **Smooth Scrolling**: Momentum-based scrolling with configurable inertia
- **Reverse Scroll**: Flip scroll direction
- **Scroll Speed**: Adjustable speed multiplier (1x-10x)
- **Scroll Acceleration**: Customizable acceleration curve
- **Back Button**: Mouse button 4 triggers Finder back navigation
- **1-Click Setup**: User-friendly Accessibility permission setup
- **Professional DMG Installer**: Traditional Mac drag-and-drop
- **Bug fixes**: Menu click, back button in Finder, permission handling
- **Version bump**: 1.3.4

### v1.3.3
- **Display Style preferences**: 4 user-selectable menu bar styles (Icon+Percent stacked/horizontal, Percent only, Icon only)
- **Color Mode preferences**: 3 user-selectable color schemes (Color coded, White+green, Always white)
- **Icon tinting in Icon Only mode**: Colors show battery status without text
- **Bug fixes**: Icon disappearing in Icon Only mode, charging bypassing display styles
- **Persistence**: All preferences saved via NSUserDefaults
- **Known issues documented**: Abort trap on raw binary, 0.3s UI freeze on USB connect, sudo notification limitation

### v1.2.0
- **PID-based mode detection**: Instant wired/wireless detection using USB Product ID
  - PID 0xA5 = Wired (Charging)
  - PID 0xA6 = Wireless (Dongle)
- **Color-coded battery**: Red (≤20%), Yellow (21-40%), Green (41-100%)
- **Charging status fix**: Correctly reads byte 11 for charging state
- **USB hotplug monitoring**: Detects cable connect/disconnect events

### v1.1.0
- IOKit USB Control Transfers (replaced HIDAPI)
- Driver Mode initialization for wireless devices
- Accepts Status 0x00, 0x02, and 0x04 responses

### v1.0.0
- Initial release with basic battery monitoring

---

## References

- [librazermacos](https://github.com/1kc/librazermacos) - Key protocol reference
- [OpenRazer](https://github.com/openrazer/openrazer) - Linux Razer driver

---

## 🔧 Porting to Other Razer Mice

This guide helps you adapt the app for other Razer wireless mice.

### Step 1: Find Your Mouse's USB IDs

```bash
# On macOS
ioreg -p IOUSB -l | grep -A10 "Razer"

# Look for:
# "idVendor" = 0x1532  (always same for Razer)
# "idProduct" = 0x00XX  (your mouse's PID)
```

**Note:** Many Razer mice have TWO PIDs - one for the wireless dongle and one for direct USB connection.

### Step 2: Modify `src/RazerDevice.hpp`

```cpp
// Change these constants to your mouse's PIDs:
static constexpr uint16_t PRODUCT_ID_DONGLE = 0x00XX;  // Wireless receiver PID
static constexpr uint16_t PRODUCT_ID_WIRED = 0x00YY;   // Wired connection PID
```

### Step 3: Test Transaction IDs

Different mice may require different Transaction IDs. Modify `queryBattery()` in `RazerDevice.cpp`:

```cpp
const uint8_t transIds[] = {0x1F, 0xFF, 0x3F};  // Try all common IDs
```

| Transaction ID | Typical Use |
|----------------|-------------|
| `0x1F` | Newer wireless mice (Viper V2 Pro, DeathAdder V3) |
| `0xFF` | Older wired mice |
| `0x3F` | Some Pro models |

### Step 4: Verify Response Bytes

Enable debug output and check which bytes contain data:

- **Byte 9**: Usually battery level (0-255 raw value)
- **Byte 11**: Usually charging status (0x01 = charging)

If your mouse uses different offsets, adjust in `queryBattery()` and `queryChargingStatus()`.

### Step 5: Known Razer Mouse PIDs

| Mouse | Wireless PID | Wired PID | Status |
|-------|-------------|-----------|--------|
| Viper V2 Pro | 0x00A6 | 0x00A5 | ✅ Tested |
| DeathAdder V3 Pro | 0x00B6 | 0x00B5 | ✅ Tested |
| Basilisk V3 Pro | 0x00AA | 0x00A9 | 🔬 Untested |
| Viper Ultimate | 0x007A | 0x007B | 🔬 Untested |
| Naga V2 Pro | 0x00AD | ? | 🔬 Untested |

*PIDs may vary by region/revision. Always verify with `ioreg` command.*

### Step 6: Submit Your Changes

If you successfully port to another mouse:
1. Fork this repository
2. Add your mouse's PIDs and any protocol differences
3. Submit a Pull Request with your mouse model in the title

---

## Contributing

Pull requests welcome! If you port this to another Razer mouse, please share your findings to help others.
