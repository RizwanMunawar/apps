#!/bin/bash
# Packages LiveBlur as a real, launchable .app bundle. This is required (not optional) for macOS
# to grant Camera access: TCC will not reliably prompt for, or even list, a bare `swift run` process.
#
# Usage: Scripts/build-app.sh [debug|release]   (defaults to debug)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="LiveBlur.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/LiveBlur" "$APP/Contents/MacOS/LiveBlur"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -d "$BIN_PATH/LiveBlur_LiveBlur.bundle" ]; then
    cp -R "$BIN_PATH/LiveBlur_LiveBlur.bundle" "$APP/Contents/Resources/LiveBlur_LiveBlur.bundle"
fi

codesign --force --deep --sign - "$APP"

echo "Built $APP — launch with: open $APP"
