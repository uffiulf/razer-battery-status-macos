# Razer Battery Monitor v1.3.5

## Release Date
April 6, 2026

## Overview
Critical performance and stability fixes addressing system-wide microstuttering caused by high-frequency mouse polling and event tap interactions. This release eliminates the lag reported when using high-polling-rate Razer mice on Apple Silicon Macs.

## Major Fixes

### 🔴 Critical: Eliminated System Microstuttering
- **Problem**: Event tap callback processing combined with high-polling-rate mice (1000Hz) was overwhelming macOS WindowServer, causing system-wide UI stuttering
- **Fix**: Implemented sophisticated event tap timeout throttling — re-enable is now rate-limited to max once per second, preventing feedback loops with WindowServer
- **Impact**: Users with high-polling-rate Razer mice will experience smooth, lag-free UI

### 🔴 Critical: USB I/O No Longer Blocks Main Thread
- **Problem**: Battery queries, connection/disconnection, and device updates were executed synchronously on the main thread, freezing the UI during USB operations (up to 2+ seconds)
- **Fix**: Refactored all USB operations (`connectToDevice`, `updateBatteryDisplay`, `handleUSBEvent`) to execute asynchronously on dedicated `batteryQueue_` serial dispatch queue
- **Impact**: UI remains responsive during device initialization and battery queries

### 🟡 Memory Leak Fix: CVDisplayLink
- **Problem**: Under deallocation, `SmoothScrollEngine` leaked `CVDisplayLinkRef` because ARC zero-fills weak references before `dealloc` runs, preventing cleanup via weak-self pattern
- **Fix**: Explicit cleanup in `dealloc` without weak-self indirection, ensuring `CVDisplayLinkRelease` is always called
- **Impact**: Smooth scrolling mode no longer leaks graphics resources

### 🟡 Thread Safety Improvements
- **Problem**: ScrollInterceptor state variables (`isRunning_`, `lastEventSeen_`, `lastTapReenableTime_`) were accessed from multiple threads (event tap callback, health check timer, main thread) without synchronization
- **Fix**: Converted critical state variables to `std::atomic<>` with appropriate memory ordering
- **Impact**: Eliminates potential data races and undefined behavior under high event load

### 🟢 UX Improvements
- **Low Battery Poll Interval**: Reduced from 10s to 3s — low battery state is detected faster
- **Scroll Settings Menu**: Now rebuilds dynamically when master switch is toggled, properly updating enabled/disabled states of feature items
- **Back Button**: Simplified Finder navigation support, removed System Settings injection (Cmd+[ doesn't work there anyway)
- **Health Check**: Replaced idle-time-based tap dead detection with `CGEventTapIsEnabled()` query, eliminating false positives

### 🟢 Code Quality
- Fixed missing closing brace in `applicationDidFinishLaunching:` (linting issue)
- Removed duplicate `CFBundleIconFile` key from Info.plist
- Removed complex auto-restart logic in favor of simple re-enable mechanism

## Technical Changes

### ScrollInterceptor.mm
- Switched to `std::atomic<bool>` and `std::atomic<double>` for thread-safe state
- Implemented event tap timeout throttling with 1-second cooldown
- Simplified health check to use `CGEventTapIsEnabled()` 
- Back button now uses session-level event posting for better Finder compatibility

### SmoothScrollEngine.mm
- Fixed CVDisplayLink leak by explicit cleanup in `dealloc`
- Proper handling of weak-self pattern during object destruction

### main.mm
- Refactored `connectToDevice()` to execute on background queue
- Refactored `updateBatteryDisplay()` to execute USB operations on background queue
- Refactored `handleUSBEvent()` USB I/O to background queue
- All main thread operations now cached and dispatched back with proper weak-self pattern
- Dynamic menu rebuild on scroll feature toggle

### Info.plist
- Removed duplicate `CFBundleIconFile` declaration

## Testing Recommendations

1. **Lag Test**: Open Terminal + multiple Finder windows, move them around. Previously: microstuttering when mouse connected. Now: smooth motion.

2. **Battery Query**: Plug/unplug mouse via USB. Battery status updates smoothly on main thread without UI freeze.

3. **Scroll Features**: 
   - Toggle master switch in menu — enabled/disabled state of sub-items updates correctly
   - Enable smooth scrolling — no dropped events
   - Back button in Finder — works correctly (disabled in System Settings per design)

4. **Memory**: Activity Monitor → search "RazerBatteryMonitor"
   - CPU: ~0% when idle
   - Memory: 30-50 MB
   - No growth over time (CVDisplayLink leak fixed)

5. **Logs**: Verify no errors in console:
   ```bash
   log show --predicate 'process == "RazerBatteryMonitor"' --last 5m
   ```

## Known Limitations

- Back button navigation disabled in System Settings (Cmd+[ is not a valid action there)
- Requires elevated privileges (sudo) for USB access
- Accessibility permission required for scroll features

## Installation

1. Download `RazerBatteryMonitor.dmg`
2. Mount the DMG
3. Drag `RazerBatteryMonitor.app` to `/Applications`
4. Eject the DMG
5. Launch from Applications (right-click > Open on first run)
6. Grant Input Monitoring permission when prompted

## Compatibility

- macOS 12+ (Monterey and later)
- Apple Silicon (arm64) and Intel (x86_64) universal binary
- Razer wireless mice with battery reporting support

## Special Thanks

Thanks to all users who reported the stuttering issue. This release directly addresses the root cause: event tap callback chaining combined with high-frequency mouse polling overwhelming the graphics subsystem.
