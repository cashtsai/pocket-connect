#!/bin/zsh
set -euo pipefail
# Build Pocket Connect.app and package it into a distributable .dmg installer.
# Usage:  ./packaging/build_dmg.sh
# Output: build/Pocket Connect.app  and  build/PocketConnect-<ver>.dmg
cd "$(dirname "$0")/.."   # mac-app/

APP="Pocket Connect"
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" packaging/Info.plist 2>/dev/null || echo 0.1.0)
OUT=build
APPDIR="$OUT/$APP.app"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "▸ swift build (release)"
swift build -c release
BIN=$(swift build -c release --show-bin-path)/PocketConnect

echo "▸ assemble $APP.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
cp "$BIN" "$APPDIR/Contents/MacOS/PocketConnect"
cp packaging/Info.plist "$APPDIR/Contents/Info.plist"
# Optional: bundle the helper binaries so users need nothing pre-installed.
#   cp "$(command -v cloudflared)" "$APPDIR/Contents/Resources/cloudflared"
#   (bridge runtime would be bundled here too — see README "Bundling deps")
# Optional: app icon → cp packaging/AppIcon.icns "$APPDIR/Contents/Resources/"

# Ad-hoc sign so it launches locally. For real distribution use a Developer ID
# cert + notarization (see README "Signing & notarization").
codesign --force --deep --sign - "$APPDIR" 2>/dev/null || echo "  (codesign skipped)"

echo "▸ create .dmg"
DMG="$OUT/PocketConnect-$VER.dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ done:"
echo "  app: $APPDIR"
echo "  dmg: $DMG"
