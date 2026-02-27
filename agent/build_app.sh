#!/bin/bash
# Build AutoConfigAgent.app for the Auto Configurator web tool.
# Requires: Xcode Command Line Tools (swift, swiftc)
set -e
cd "$(dirname "$0")"
echo "Building AutoConfigAgent..."
swift build -c release
BIN=".build/release/AutoConfigAgent"
test -x "$BIN" || { echo "Build failed: $BIN not found"; exit 1; }
APP="AutoConfigAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/Info.plist"
echo "Created $APP"
echo "Grant Full Disk Access to this app in System Settings > Privacy & Security > Full Disk Access so it can read TCC data."
