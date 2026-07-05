#!/bin/zsh
set -euo pipefail
# Build Pocket.app and package it into a distributable .dmg installer.
# Usage:  ./packaging/build_dmg.sh
# Output: build/Pocket.app  and  build/Pocket-<ver>.dmg
cd "$(dirname "$0")/.."   # mac-app/

APP="Pocket"
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
# App icon (denim cowboy-pocket brand icon, pocket_macos_* full-size set from
# the sun repo, built with iconutil) → bundled into Resources so Finder/Dock show it.
cp packaging/AppIcon.icns "$APPDIR/Contents/Resources/"
# Menu bar glyph: monochrome pocket-outline template mark (menubar_36 from the
# same brand set), not a system-font placeholder. isTemplate=true in code
# handles the light/dark recoloring; this is just the source art.
cp packaging/MenuBarIcon.png "$APPDIR/Contents/Resources/"
# v005 dual-state menu bar (statusbar_on/off_36 from pocket-brand 3c0b221):
# connected = on, offline = off; MenuBarIcon.png stays as legacy fallback.
cp packaging/MenuBarIconOn.png "$APPDIR/Contents/Resources/"
cp packaging/MenuBarIconOff.png "$APPDIR/Contents/Resources/"

# Sign so it launches locally. We attach the Sign in with Apple entitlement here.
#   - SIGN_IDENTITY unset  → ad-hoc (local dev; Apple login won't work, Gatekeeper
#     will warn on other Macs — see README).
#   - SIGN_IDENTITY=<Apple Development sha1/name tied to Team 4F8B93R3SH> → a
#     Development build that can complete real Sign in with Apple on registered
#     Macs. Also embed the matching provisioning profile so the restricted
#     applesignin entitlement is authorized.
# Base entitlements (ad-hoc builds sign with just this — Sign in with Apple).
ENTITLEMENTS="packaging/PocketConnect.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # default: ad-hoc "-"

# Embed the provisioning profile (real-signed builds only). Point PROFILE at a
# .provisionprofile, or leave the default to auto-pick the installed
# "Pocket Agent Desktop Mac Dev" profile by its known UUID.
PROFILE="${PROFILE:-$HOME/Library/MobileDevice/Provisioning Profiles/bcd619b6-c187-49d5-8e53-085e02a79f79.provisionprofile}"
SIGN_ENTITLEMENTS="$ENTITLEMENTS"
if [[ "$SIGN_IDENTITY" != "-" && -f "$PROFILE" ]]; then
  echo "▸ embed provisioning profile: $(basename "$PROFILE")"
  cp "$PROFILE" "$APPDIR/Contents/embedded.provisionprofile"
  # A provisioned app must be signed with the profile's full entitlement set
  # (application-identifier, team-identifier, keychain-access-groups, applesignin)
  # or amfid refuses to launch it (Launchd job spawn failed / error 163). Derive
  # them straight from the profile and add get-task-allow for a Development build.
  DERIVED="$OUT/derived.entitlements"
  security cms -D -i "$PROFILE" > "$OUT/profile.plist"
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$OUT/profile.plist" > "$DERIVED"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$DERIVED" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :com.apple.security.get-task-allow true' "$DERIVED"
  SIGN_ENTITLEMENTS="$DERIVED"
  echo "  entitlements: derived from profile (+ get-task-allow)"
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "  ⚠ 找不到 provisioning profile ($PROFILE) — Sign in with Apple 可能無法運作"
fi

echo "▸ codesign (identity: $SIGN_IDENTITY)"
codesign --force --deep \
  --entitlements "$SIGN_ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APPDIR" \
  || echo "  (codesign failed — ad-hoc build may still run locally)"

echo "▸ create .dmg"
DMG="$OUT/Pocket-$VER.dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
hdiutil create -volname "Pocket" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ done:"
echo "  app: $APPDIR"
echo "  dmg: $DMG"
