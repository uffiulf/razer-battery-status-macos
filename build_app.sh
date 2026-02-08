#!/bin/bash
# Build script for Razer Battery Monitor macOS Application Bundle
# This creates a standalone .app that can be moved to /Applications

set -e  # Exit on error

APP_NAME="RazerBatteryMonitor"
APP_BUNDLE="${APP_NAME}.app"

echo "=== Building Razer Battery Monitor ==="

# Step 1: Clean and build
echo "Building binary..."
make clean
make

# Step 2: Create app bundle structure
echo "Creating app bundle structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Step 3: Copy binary
echo "Copying binary..."
cp "${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# Step 4: Copy Info.plist
echo "Copying Info.plist..."
cp "Info.plist" "${APP_BUNDLE}/Contents/"

# Step 5: Copy app icon
echo "Copying app icon..."
cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"

# Step 6: Create PkgInfo file (standard for macOS apps)
echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Step 7: Remove extended attributes (resource forks, Finder metadata)
echo "Removing extended attributes..."
xattr -cr "${APP_BUNDLE}"

# Step 8: Sign the app with ad-hoc signature
echo "Signing app bundle..."
codesign --force --deep -s - "${APP_BUNDLE}"

echo ""
echo "=== Build Complete ==="
echo ""
echo "App bundle created: ${APP_BUNDLE}"
echo ""
echo "To install:"
echo "  1. Move ${APP_BUNDLE} to /Applications"
echo "  2. Open it from Applications (first time may require right-click > Open)"
echo "  3. Grant Input Monitoring permission if prompted"
echo ""
echo "To run now (requires sudo for USB access):"
echo "  sudo open ${APP_BUNDLE}"
echo ""
