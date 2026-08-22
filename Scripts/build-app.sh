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

# Which resource bundles this package actually declares right now. SPM leaves bundles from earlier
# builds lying in the bin directory even after the target that produced them is gone, so globbing
# for *.bundle would happily ship a stale one forever.
#
# Deleting them first and letting the build recreate them does not work: with no source changes
# the build is a no-op, nothing is regenerated, and the app ships with no bundle at all — which
# for this package means no CoreML model. So ask the package what it expects and copy exactly
# that, failing loudly if something is missing.
EXPECTED_BUNDLES="$(swift package describe --type json | python3 -c 'import json, sys
package = json.load(sys.stdin)
for target in package.get("targets", []):
    if target.get("resources"):
        print(package["name"] + "_" + target["name"] + ".bundle")')"

APP="apps-releases.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/apps-releases" "$APP/Contents/MacOS/apps-releases"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon/Shell/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for bundle in $EXPECTED_BUNDLES; do
    if [ ! -d "$BIN_PATH/$bundle" ]; then
        echo "error: $bundle is missing from $BIN_PATH; the app would ship without its resources" >&2
        exit 1
    fi
    cp -R "$BIN_PATH/$bundle" "$APP/Contents/Resources/$bundle"
done

codesign --force --deep --sign - "$APP"

echo "Built $APP — launch with: open $APP"
