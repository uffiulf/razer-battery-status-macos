# Razer Battery Monitor v1.3.4

## Release Date: April 2, 2026

## What's New in This Version

### 🎯 Key Features Added

1. **Custom Scroll Settings** - Full control over your mouse scroll wheel
   - Reverse scroll direction
   - Adjustable scroll speed
   - Acceleration curves
   - Smooth scrolling with momentum/inertia
   - Back button navigation (mouse button 4)

2. **1-Click Setup** - Enable scroll features with ease
   - User-friendly dialog with step-by-step instructions
   - Direct link to System Settings
   - Automatic activation when permission granted

3. **Professional DMG Installer** - Easy distribution
   - Traditional Mac "drag & drop" installation
   - Ready for easy user installation

### 🐛 Bug Fixes

- Fixed menu not showing when clicking status bar icon
- Fixed back button (mouse 4) not working in Finder
- Fixed scroll settings being disabled/grayed out
- Added missing action methods for scroll toggles and sliders

### 📋 Requirements

- macOS (tested on recent versions)
- Razer mouse with USB-C connection
- Accessibility permission required for scroll features

### 📥 Installation

1. Download RazerBatteryMonitor-Installer.dmg
2. Open the DMG file
3. Drag RazerBatteryMonitor.app to Applications folder
4. Open from Applications (first time: right-click → Open)
5. For scroll features: Click "Enable Scroll Features" and follow instructions

### 📝 Notes

- **Running with sudo**: When the app runs with sudo (root), accessibility permission checks may show incorrect status because macOS permissions are per-user. This is a macOS limitation - the app still works correctly, but the tooltip may show "Scroll Features Disabled" even when permission is granted. Running without sudo (or as a LaunchDaemon) avoids this issue.
- Scroll features require Accessibility permission in System Settings
- Battery monitoring works without any special permissions

---

**Download:** RazerBatteryMonitor-Installer.dmg
