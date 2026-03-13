#!/bin/bash
# Build and sign Mac Admin Toolbox.app for the Auto Configurator web tool.
# Bundle ID: cloud.swiftsetup.mac_toolbox
# Signs with: Developer ID Application: CORE PERIPHERALS (PTY) LTD (4WTK96D2J8)
set -e
cd "$(dirname "$0")"

BUNDLE_ID="cloud.swiftsetup.mac_toolbox"
DEVELOPER_ID="Developer ID Application: CORE PERIPHERALS (PTY) LTD (4WTK96D2J8)"
APP_NAME="Mac Admin Toolbox.app"
BIN=".build/release/MacAdminToolbox"

echo "Building Mac Admin Toolbox..."
swift build -c release

test -x "$BIN" || { echo "Build failed: $BIN not found"; exit 1; }

echo "Creating $APP_NAME..."
rm -rf "$APP_NAME"
mkdir -p "$APP_NAME/Contents/MacOS"
mkdir -p "$APP_NAME/Contents/Resources"
cp "$BIN" "$APP_NAME/Contents/MacOS/"

# Copy bundled resources (e.g. IntuneBaseBuild.psm1)
cp -R Resources/ "$APP_NAME/Contents/Resources/" 2>/dev/null || true

# App icon: build AppIcon.icns from Online Toolbox.png
ICON_SRC="Online Toolbox.png"
if [ -f "$ICON_SRC" ] && command -v iconutil >/dev/null 2>&1; then
  echo "Building app icon..."
  ICONSET="AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_SRC" --out "$ICONSET/icon_16x16.png" 2>/dev/null || true
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" 2>/dev/null || true
  sips -z 32 32 "$ICON_SRC" --out "$ICONSET/icon_32x32.png" 2>/dev/null || true
  sips -z 64 64 "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" 2>/dev/null || true
  sips -z 128 128 "$ICON_SRC" --out "$ICONSET/icon_128x128.png" 2>/dev/null || true
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" 2>/dev/null || true
  sips -z 256 256 "$ICON_SRC" --out "$ICONSET/icon_256x256.png" 2>/dev/null || true
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" 2>/dev/null || true
  sips -z 512 512 "$ICON_SRC" --out "$ICONSET/icon_512x512.png" 2>/dev/null || true
  sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
  iconutil -c icns "$ICONSET" -o "$APP_NAME/Contents/Resources/AppIcon.icns" 2>/dev/null || true
  rm -rf "$ICONSET"
fi

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

# Notarize
ZIP_PATH="MacAdminToolbox.zip"
echo "Creating zip for notarization..."
ditto -c -k --keepParent "$APP_NAME" "$ZIP_PATH"

echo "Submitting for notarization..."
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "notarytool" --wait

rm -f "$ZIP_PATH"

echo "Stapling notarization ticket..."
xcrun stapler staple "$APP_NAME"

echo "Re-zipping stapled app..."
ditto -c -k --keepParent "$APP_NAME" "$ZIP_PATH"

echo "Done. Created, signed, notarized, and stapled $APP_NAME (bundle ID: $BUNDLE_ID)."
echo "Grant Full Disk Access to this app in System Settings > Privacy & Security > Full Disk Access so it can read TCC data."
