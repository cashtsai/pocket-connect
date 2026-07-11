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
# Brand assets for the onboarding/login screen — use the FINALIZED assets, never
# a homemade stand-in: the real POCKET wordmark (Luckiest Guy, red) + the Luckiest
# Guy font itself (registered at runtime for the rainbow slogan). Same art the iOS
# login uses. See docs/BRAND_CLOUD_BACKGROUND.md + brand CIS.
cp packaging/pocket-wordmark.png "$APPDIR/Contents/Resources/"
cp packaging/LuckiestGuy-Regular.ttf "$APPDIR/Contents/Resources/"
cp packaging/LICENSE-LuckiestGuy.txt "$APPDIR/Contents/Resources/" 2>/dev/null || true

# 免費零設定連線用的 cloudflared（自動臨時 tunnel）。有系統版就打包進去，讓使用者
# 不用自己裝；TunnelManager.resolveCloudflaredPath() 會優先找這個打包版。-L 跟隨
# Homebrew 的 symlink 複製真檔。codesign --deep 會一併簽它。
for cf in /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared; do
  if [[ -x "$cf" ]]; then cp -L "$cf" "$APPDIR/Contents/Resources/cloudflared"; break; fi
done

# Sign so it launches locally. We attach the Sign in with Apple entitlement here.
#   - SIGN_IDENTITY unset  → ad-hoc (local dev; Apple login won't work, Gatekeeper
#     will warn on other Macs — see README).
#   - SIGN_IDENTITY=<Apple Development sha1/name tied to Team 4F8B93R3SH> → a
#     Development build that can complete real Sign in with Apple on registered
#     Macs. Also embed the matching provisioning profile so the restricted
#     applesignin entitlement is authorized.
# Base entitlements (ad-hoc builds sign with just this — Sign in with Apple).
REQUESTED_SIGN_IDENTITY="${SIGN_IDENTITY:-}"
REQUESTED_PROFILE="${PROFILE:-}"
SCRIPT_OUT="$OUT"
SCRIPT_APPDIR="$APPDIR"
SCRIPT_VER="$VER"
ENTITLEMENTS="packaging/PocketConnect.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # default: ad-hoc "-"

# ── Public-distribution track (Developer ID + notarization) ──────────────────
# Off by default; the whole block below is gated on NOTARIZE=1 so the current
# ad-hoc/Development flows are untouched. Turn it on ONLY once 善彰 has created a
# "Developer ID Application" cert (see docs/M4_DEVELOPER_ID_SIGNING_SPEC.md §1 —
# only the account holder can do that, it can't be automated).
#
# Then:  cp packaging/pocket-release.env.example ~/.pocket-release.env  and fill it
#        NOTARIZE=1 ./packaging/build_dmg.sh
#
# ~/.pocket-release.env (never committed) supplies EITHER of two auth paths
# for notarytool (API key preferred — reuses the same ASC key asc.py already
# uses for TestFlight uploads, no extra Apple-ID app-specific-password needed):
#   SIGN_IDENTITY="Developer ID Application: <name> (4F8B93R3SH)"
#   TEAM_ID="4F8B93R3SH"
#   # Path A (preferred): App Store Connect API key
#   ASC_KEY_ID="..."  ASC_ISSUER_ID="..."  ASC_KEY_PATH="~/.appstoreconnect/private_keys/AuthKey_....p8"
#   # Path B (fallback): Apple ID + app-specific password
#   APPLE_ID="you@apple.id"          APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
NOTARIZE="${NOTARIZE:-0}"
[[ -f "$HOME/.pocket-release.env" ]] && source "$HOME/.pocket-release.env"
OUT="$SCRIPT_OUT"
APPDIR="$SCRIPT_APPDIR"
VER="$SCRIPT_VER"
[[ -n "$REQUESTED_SIGN_IDENTITY" ]] && SIGN_IDENTITY="$REQUESTED_SIGN_IDENTITY"
# ~/.pocket-release.env is a SHARED file across projects (also used by the
# pocketagent iOS release lane, which sets its own PROFILE="Pocket iOS
# AppStore" for a completely different app). If this script's caller didn't
# explicitly pass PROFILE, don't let a same-named var leaked in from sourcing
# that shared file silently hijack the desktop app's provisioning profile —
# reset to empty so the desktop-specific default below (line ~93) applies.
PROFILE="$REQUESTED_PROFILE"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # re-resolve in case the env file set it
TEAM_ID="${TEAM_ID:-4F8B93R3SH}"

# Embed the provisioning profile (real-signed builds only). Point PROFILE at a
# .provisionprofile, or leave the default to auto-pick the installed
# "Pocket Agent Desktop Mac Dev" profile by its known UUID.
PROFILE="${PROFILE:-$HOME/Library/MobileDevice/Provisioning Profiles/bcd619b6-c187-49d5-8e53-085e02a79f79.provisionprofile}"
SIGN_ENTITLEMENTS=""
# Development builds embed a provisioning profile + derive get-task-allow entitlements.
# The Developer ID / notarization path (NOTARIZE=1) must NOT: notarized apps ship with
# a hardened runtime and no get-task-allow, and Developer ID needs no embedded profile.
if [[ "$NOTARIZE" != "1" && "$SIGN_IDENTITY" != "-" && -f "$PROFILE" ]]; then
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
  # A provisioning profile hands CloudKit entitlements back in wildcard forms
  # that CKContainer rejects at launch with CKException("malformed entitlements"):
  #   · icloud-services arrives as the string "*" — must be an array of strings
  #     (["CloudKit"]).
  #   · icloud-container-environment arrives as an array [Production, Development]
  #     — must be a single string; a Development-signed build wants "Development".
  # Coerce both, or the app SIGABRTs during applicationDidFinishLaunching.
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' "$DERIVED" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-services' "$DERIVED"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.icloud-services array' "$DERIVED"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.icloud-services:0 string CloudKit' "$DERIVED"
  fi
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$DERIVED" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-container-environment' "$DERIVED"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.icloud-container-environment string Development' "$DERIVED"
  fi
  # Profiles may grant wildcard groups, but the app signature must carry
  # concrete values. Leaving `4F8B93R3SH.*` in the signed entitlements makes
  # macOS report "invalid entitlements blob" and ignore them, which breaks the
  # Keychain access-group lookup used by Keychain.swift.
  if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups' "$DERIVED" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Delete :keychain-access-groups' "$DERIVED"
  fi
  /usr/libexec/PlistBuddy -c 'Add :keychain-access-groups array' "$DERIVED"
  /usr/libexec/PlistBuddy -c "Add :keychain-access-groups:0 string ${TEAM_ID}.com.pocketagent.desktop" "$DERIVED"
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.ubiquity-kvstore-identifier' "$DERIVED" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.ubiquity-kvstore-identifier ${TEAM_ID}.com.pocketagent.desktop" "$DERIVED"
  fi
  SIGN_ENTITLEMENTS="$DERIVED"
  echo "  entitlements: derived from profile (+ get-task-allow, CloudKit-coerced)"
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "  ⚠ 找不到 provisioning profile ($PROFILE) — Sign in with Apple 可能無法運作"
  SIGN_ENTITLEMENTS="$ENTITLEMENTS"
fi

# Hardened runtime is REQUIRED for notarization; only add it on the Developer ID
# path (it conflicts with the Development build's get-task-allow entitlement).
CODESIGN_OPTS=(--force --generate-entitlement-der)
[[ "$NOTARIZE" == "1" ]] && CODESIGN_OPTS+=(--options runtime --timestamp)

if [[ -x "$APPDIR/Contents/Resources/cloudflared" ]]; then
  echo "▸ codesign helper cloudflared"
  # Must use the same CODESIGN_OPTS as the main app (incl. --options runtime on
  # the notarize path) — notarytool rejects the whole archive if ANY embedded
  # executable lacks the hardened runtime, even if the app itself has it.
  codesign "${CODESIGN_OPTS[@]}" --sign "$SIGN_IDENTITY" "$APPDIR/Contents/Resources/cloudflared" \
    || echo "  (helper codesign failed — continuing; app may still run if helper is already signed)"
fi

echo "▸ codesign (identity: $SIGN_IDENTITY${NOTARIZE:+, hardened runtime})"
if [[ -n "$SIGN_ENTITLEMENTS" ]]; then
  codesign "${CODESIGN_OPTS[@]}" \
    --entitlements "$SIGN_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APPDIR" \
    || echo "  (codesign failed — app may not pass verification)"
else
  codesign "${CODESIGN_OPTS[@]}" \
    --sign "$SIGN_IDENTITY" "$APPDIR" \
    || echo "  (codesign failed — app may not pass verification)"
fi

echo "▸ create .dmg"
DMG="$OUT/Pocket-$VER.dmg"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APPDIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
hdiutil create -volname "Pocket" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ── Notarization (public-distribution track) ─────────────────────────────────
# Submit the .dmg to Apple and staple the ticket so any Mac's Gatekeeper accepts
# a double-click with no "unidentified developer" prompt. Gated on NOTARIZE=1.
if [[ "$NOTARIZE" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "✗ NOTARIZE=1 但 SIGN_IDENTITY 還是 ad-hoc(-)。要用 Developer ID Application 憑證。" >&2
    echo "  在 ~/.pocket-release.env 設 SIGN_IDENTITY，並提供 ASC_KEY_ID/ASC_ISSUER_ID/ASC_KEY_PATH" >&2
    echo "  （或 APPLE_ID/APP_SPECIFIC_PASSWORD 作為備援）。" >&2
    exit 1
  fi
  # Path A (preferred): App Store Connect API key — same key asc.py already
  # uses for TestFlight uploads, no separate Apple-ID app-specific password.
  # Path B (fallback): Apple ID + app-specific password.
  NOTARY_AUTH=()
  if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
    KEY_PATH_EXPANDED="${ASC_KEY_PATH/#\~/$HOME}"
    if [[ ! -f "$KEY_PATH_EXPANDED" ]]; then
      echo "✗ ASC_KEY_PATH 指的檔案不存在：$KEY_PATH_EXPANDED" >&2
      exit 1
    fi
    echo "▸ notarytool 認證方式：App Store Connect API key ($ASC_KEY_ID)"
    NOTARY_AUTH=(--key "$KEY_PATH_EXPANDED" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
  elif [[ -n "${APPLE_ID:-}" && -n "${APP_SPECIFIC_PASSWORD:-}" ]]; then
    echo "▸ notarytool 認證方式：Apple ID + App 專用密碼"
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_SPECIFIC_PASSWORD")
  else
    echo "✗ 缺公證認證資訊（放 ~/.pocket-release.env）。二選一：" >&2
    echo "  A) ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH（建議，沿用既有 ASC API key）" >&2
    echo "  B) APPLE_ID / APP_SPECIFIC_PASSWORD（https://account.apple.com → 登入與安全 → App 專用密碼）" >&2
    exit 1
  fi
  echo "▸ notarytool submit（送 Apple 公證，通常幾分鐘）"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait
  echo "▸ stapler staple"
  xcrun stapler staple "$DMG"
  echo "▸ 驗收：spctl 應回 accepted / source=Notarized Developer ID"
  spctl -a -vvv "$APPDIR" 2>&1 || true
fi

echo "✓ done:"
echo "  app: $APPDIR"
echo "  dmg: $DMG"
if [[ "$NOTARIZE" != "1" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "  ⚠ ad-hoc 簽章 — 別台 Mac 會被 Gatekeeper 擋，需右鍵→打開（見 docs/INSTALL_FAQ.md）。"
fi
