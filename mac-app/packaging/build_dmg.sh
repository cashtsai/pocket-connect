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

# Sign so it launches locally. We attach the Sign in with Apple entitlement here.
#   - SIGN_IDENTITY unset  → ad-hoc (local dev; Apple login won't fully work,
#     Gatekeeper will warn on other Macs — see README).
#   - SIGN_IDENTITY="Developer ID Application: …" (or an Apple Dev cert tied to
#     the Team ID) → a build that can actually complete Sign in with Apple.
ENTITLEMENTS="packaging/PocketConnect.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # default: ad-hoc "-"
echo "▸ codesign (identity: $SIGN_IDENTITY)"
codesign --force --deep \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APPDIR" 2>/dev/null \
  || echo "  (codesign skipped or failed — ad-hoc build may still run locally)"

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
