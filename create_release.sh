#!/bin/bash
# Release script for Razer Battery Monitor
# Creates a professional DMG disk image with styled installer

set -e  # Exit on error

APP_NAME="RazerBatteryMonitor"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
VERSION="1.3.5"

echo "=========================================="
echo "  Razer Battery Monitor - Release Build"
echo "  Version: ${VERSION}"
echo "=========================================="
echo ""

# Check for create-dmg
if ! command -v create-dmg &> /dev/null; then
    echo "ERROR: 'create-dmg' is not installed."
    echo ""
    echo "Please install it with:"
    echo "  brew install create-dmg"
    echo ""
    exit 1
fi

# Step 1: Clean and build
echo "[1/5] Building fresh binary..."
make clean
make

# Step 2: Create app bundle structure
echo "[2/5] Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Step 3: Copy files
echo "[3/5] Copying files..."
cp "${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp "Info.plist" "${APP_BUNDLE}/Contents/"
cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
echo "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Kopier app-ikon
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
    echo "App icon added."
fi

# Step 4: Sign the app
echo "[4/5] Signing app bundle (ad-hoc)..."
xattr -cr "${APP_BUNDLE}"
codesign --force --deep -s - "${APP_BUNDLE}"

# Step 5: Create styled DMG
echo "[5/5] Creating styled DMG installer..."
rm -f "${DMG_NAME}"

create-dmg \
    --volname "Razer Battery Monitor Installer" \
    --window-pos 200 120 \
    --window-size 800 400 \
    --icon-size 100 \
    --icon "${APP_BUNDLE}" 200 190 \
    --hide-extension "${APP_BUNDLE}" \
    --app-drop-link 600 185 \
    "${DMG_NAME}" \
    "${APP_BUNDLE}"

echo ""
echo "=========================================="
echo "  Release Build Complete!"
echo "=========================================="
echo ""
echo "Output files:"
echo "  - ${APP_BUNDLE} (Application)"
echo "  - ${DMG_NAME} (Disk Image)"
echo ""
echo "To install:"
echo "  1. Open ${DMG_NAME}"
echo "  2. Drag the app icon to the Applications folder"
echo "  3. Eject the disk image"
echo "  4. Open from Applications (right-click > Open first time)"
echo ""
echo "Note: The app requires Input Monitoring permission"
echo "for USB device access."
echo ""
