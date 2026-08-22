#!/bin/bash
# Builds a release Redact.app and wraps it in a distributable, ad-hoc signed .dmg installer
# with a drag-to-Applications layout. Output: Redact.dmg in the repo root.
set -euo pipefail
cd "$(dirname "$0")/.."

./Scripts/build-app.sh release

APP="Redact.app"
VOLNAME="Redact"
DMG="Redact.dmg"
STAGING="$(mktemp -d)"

trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "Built $DMG"
