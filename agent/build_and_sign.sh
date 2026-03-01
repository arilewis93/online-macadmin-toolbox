#!/bin/bash
# Build and sign Mac Admin Toolbox.app for the Auto Configurator web tool.
# Bundle ID: cloud.swiftsetup.mac_toolbox
# Signs with: Developer ID Application: CORE PERIPHERALS (PTY) LTD (4WTK96D2J8)
set -e
cd "$(dirname "$0")"

BUNDLE_ID="cloud.swiftsetup.mac_toolbox"
DEVELOPER_ID="Developer ID Application: CORE PERIPHERALS (PTY) LTD (4WTK96D2J8)"
APP_NAME="Mac Admin Toolbox.app"
BIN=".build/release/AutoConfigAgent"

echo "Building Mac Admin Toolbox..."
swift build -c release

test -x "$BIN" || { echo "Build failed: $BIN not found"; exit 1; }

echo "Creating $APP_NAME..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
cp "$BIN" "$APP_NAME/Contents/MacOS/"

# Copy Info.plist (with URL scheme etc.) and set bundle ID for signing
PLIST="$APP_NAME/Contents/Info.plist"
if [ ! -f "Info.plist" ]; then
  echo "Error: Info.plist not found in $(pwd)"
  exit 1
fi
cp "Info.plist" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"

echo "Signing with $DEVELOPER_ID..."
codesign --force --deep -s "$DEVELOPER_ID" --options runtime "$APP_NAME"

echo "Done. Created and signed $APP_NAME (bundle ID: $BUNDLE_ID)."
echo "Grant Full Disk Access to this app in System Settings > Privacy & Security > Full Disk Access so it can read TCC data."
