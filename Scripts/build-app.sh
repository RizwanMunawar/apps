#!/bin/bash
# Packages apps-releases (the shell app; Redact runs inside it) as a real, launchable .app
# bundle. This is required (not optional) for macOS to grant Camera access: TCC will not
# reliably prompt for, or even list, a bare `swift run` process.
#
# Usage: Scripts/build-app.sh [debug|release]   (defaults to debug)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="apps-releases.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/apps-releases" "$APP/Contents/MacOS/apps-releases"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon/Shell/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SPM's auto-generated resource bundle name depends on the toolchain version, so glob for it
# rather than hardcoding <package>_<target>.bundle.
for bundle in "$BIN_PATH"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

codesign --force --deep --sign - "$APP"

echo "Built $APP — launch with: open $APP"
