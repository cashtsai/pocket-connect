#!/bin/zsh
set -euo pipefail
# Build Pocket.app and package it into a distributable .dmg installer.
# Usage:  ./packaging/build_dmg.sh
# Output: build/Pocket.app  and  build/dist/Pocket-<ver>.dmg
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
# Optional: bundle helper runtimes so users need nothing pre-installed.
#   BRIDGE_BUNDLE_ROOT=/path/to/hermes-studio-bridge ./packaging/build_dmg.sh
# copies the bridge bundle into Contents/Resources/bridge; PocketConnect can run
# deploy/install-local-bridge.sh from there on first launch or upgrade.
# App icon (denim cowboy-pocket brand icon, pocket_macos_* full-size set from
# the brand repo, built with iconutil) → bundled into Resources so Finder/Dock show it.
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
# M3 環境引導:「一鍵安裝 Hermes」按鈕在背景跑的安裝腳本(spec §3)。
cp packaging/install_hermes.sh "$APPDIR/Contents/Resources/"
cp packaging/LICENSE-LuckiestGuy.txt "$APPDIR/Contents/Resources/" 2>/dev/null || true
BRIDGE_DEFAULT_PROVIDER="${BRIDGE_DEFAULT_PROVIDER:-hermes}"
case "$BRIDGE_DEFAULT_PROVIDER" in
  hermes|openclaw|none) ;;
  *)
    echo "✗ BRIDGE_DEFAULT_PROVIDER 必須是 hermes、openclaw 或 none；目前是 $BRIDGE_DEFAULT_PROVIDER" >&2
    exit 1
    ;;
esac
printf '%s\n' "$BRIDGE_DEFAULT_PROVIDER" > "$APPDIR/Contents/Resources/BridgeDefaultProvider"

# 免費零設定連線用的 cloudflared（自動臨時 tunnel）。有系統版就打包進去，讓使用者
# 不用自己裝；TunnelManager.resolveCloudflaredPath() 會優先找這個打包版。-L 跟隨
# Homebrew 的 symlink 複製真檔。測試 bridge/provider 安裝時可用
# BUNDLE_CLOUDFLARED=0 跳過，避免 helper codesign 擋住本地 DMG 驗證。
BUNDLE_CLOUDFLARED="${BUNDLE_CLOUDFLARED:-1}"
if [[ "$BUNDLE_CLOUDFLARED" == "1" ]]; then
  CLOUDFLARED_PATH="${CLOUDFLARED_PATH:-}"
  [[ -n "$CLOUDFLARED_PATH" ]] && CLOUDFLARED_PATH="${CLOUDFLARED_PATH/#\~/$HOME}"
  for cf in "$CLOUDFLARED_PATH" packaging/cloudflared /opt/homebrew/bin/cloudflared /usr/local/bin/cloudflared; do
    [[ -z "$cf" ]] && continue
    if [[ -x "$cf" ]]; then cp -L "$cf" "$APPDIR/Contents/Resources/cloudflared"; break; fi
  done
fi

BRIDGE_BUNDLE_ROOT="${BRIDGE_BUNDLE_ROOT:-}"
if [[ -n "$BRIDGE_BUNDLE_ROOT" ]]; then
  BRIDGE_BUNDLE_ROOT="${BRIDGE_BUNDLE_ROOT/#\~/$HOME}"
  if [[ ! -x "$BRIDGE_BUNDLE_ROOT/deploy/install-local-bridge.sh" ]]; then
    echo "✗ BRIDGE_BUNDLE_ROOT 缺少 deploy/install-local-bridge.sh：$BRIDGE_BUNDLE_ROOT" >&2
    exit 1
  fi
  echo "▸ bundle local bridge"
  mkdir -p "$APPDIR/Contents/Resources/bridge"
  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    --exclude "bridge.out.log*" \
    --exclude "bridge.err.log*" \
    "$BRIDGE_BUNDLE_ROOT/" "$APPDIR/Contents/Resources/bridge/"
fi

# Sign so it launches locally. Restricted entitlements always come from the
# matching provisioning profile; never add them to a distribution signature by
# hand.
#   - SIGN_IDENTITY unset  → ad-hoc (local dev; Apple login won't work, Gatekeeper
#     will warn on other Macs — see README).
#   - SIGN_IDENTITY=<Apple Development sha1/name tied to Team 4F8B93R3SH> → a
#     Development build that can complete real Sign in with Apple on registered
#     Macs. Also embed the matching provisioning profile so the restricted
#     applesignin entitlement is authorized.
#   - NOTARIZE=1 + Developer ID Application → public distribution. The matching
#     Developer ID profile enables Production CloudKit, but Apple does not allow
#     the native Sign in with Apple entitlement on Developer ID profiles.
REQUESTED_SIGN_IDENTITY="${SIGN_IDENTITY:-}"
REQUESTED_PROFILE="${PROFILE:-}"
REQUESTED_DESKTOP_PROFILE="${DESKTOP_PROFILE:-}"
SCRIPT_OUT="$OUT"
SCRIPT_APPDIR="$APPDIR"
SCRIPT_VER="$VER"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # default: ad-hoc "-"

# ── Public-distribution track (Developer ID + notarization) ──────────────────
# Off by default; the whole block below is gated on NOTARIZE=1 so ad-hoc and
# Development builds are untouched. The release certificate and Developer ID
# profile are documented in docs/M4_DEVELOPER_ID_SIGNING_SPEC.md.
#
# Then:  cp packaging/pocket-release.env.example ~/.pocket-release.env  and fill it
#        NOTARIZE=1 ./packaging/build_dmg.sh
#
# ~/.pocket-release.env (never committed) supplies EITHER of two auth paths
# for notarytool (API key preferred — reuses the same ASC key asc.py already
# uses for TestFlight uploads, no extra Apple-ID app-specific-password needed):
#   SIGN_IDENTITY="Developer ID Application: <name> (4F8B93R3SH)"
#   DESKTOP_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/pocket-desktop-developer-id.provisionprofile"
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
RELEASE_DESKTOP_PROFILE="${DESKTOP_PROFILE:-}"
# ~/.pocket-release.env is a SHARED file across projects (also used by the
# pocketagent iOS release lane, which sets its own PROFILE="Pocket iOS
# AppStore" for a completely different app). If this script's caller didn't
# explicitly pass PROFILE, don't let a same-named var leaked in from sourcing
# that shared file silently hijack the desktop app's provisioning profile.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # re-resolve in case the env file set it
TEAM_ID="${TEAM_ID:-4F8B93R3SH}"

# Embed a matching provisioning profile for every real-signed build. PROFILE on
# the command line wins. DESKTOP_PROFILE is the release-env-safe setting because
# the shared PROFILE variable belongs to the iOS release lane.
DEV_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/bcd619b6-c187-49d5-8e53-085e02a79f79.provisionprofile"
DEVELOPER_ID_PROFILE="$HOME/Library/MobileDevice/Provisioning Profiles/pocket-desktop-developer-id.provisionprofile"
if [[ -n "$REQUESTED_PROFILE" ]]; then
  PROFILE="$REQUESTED_PROFILE"
elif [[ -n "$REQUESTED_DESKTOP_PROFILE" ]]; then
  PROFILE="$REQUESTED_DESKTOP_PROFILE"
elif [[ "$NOTARIZE" == "1" ]]; then
  PROFILE="${RELEASE_DESKTOP_PROFILE:-$DEVELOPER_ID_PROFILE}"
else
  PROFILE="$DEV_PROFILE"
fi
PROFILE="${PROFILE/#\~/$HOME}"

SIGN_ENTITLEMENTS=""
# Development and Developer ID builds both embed a profile when they claim
# restricted capabilities. Only Development receives get-task-allow.
if [[ "$SIGN_IDENTITY" != "-" && -f "$PROFILE" ]]; then
  echo "▸ embed provisioning profile: $(basename "$PROFILE")"
  cp "$PROFILE" "$APPDIR/Contents/embedded.provisionprofile"
  DERIVED="$OUT/derived.entitlements"
  PROFILE_PLIST="$OUT/profile.plist"
  security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
  PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")
  PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")
  EXPECTED_APP_ID="${TEAM_ID}.com.pocketagent.desktop"
  if [[ "$PROFILE_APP_ID" != "$EXPECTED_APP_ID" ]]; then
    echo "✗ provisioning profile App ID 不符：$PROFILE_APP_ID（預期 $EXPECTED_APP_ID）" >&2
    exit 1
  fi

  PROVISIONS_ALL_DEVICES=$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || true)
  if [[ "$NOTARIZE" == "1" && "$PROVISIONS_ALL_DEVICES" != "true" ]]; then
    echo "✗ NOTARIZE=1 必須使用 Developer ID provisioning profile；目前是：$PROFILE_NAME" >&2
    exit 1
  fi
  if [[ "$NOTARIZE" == "1" ]]; then
    PROFILE_CLOUD_CONTAINER=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers:0' "$PROFILE_PLIST" 2>/dev/null || true)
    PROFILE_CLOUD_ENV=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$PROFILE_PLIST" 2>/dev/null || true)
    if [[ "$PROFILE_CLOUD_CONTAINER" != "iCloud.com.pocketagent" || "$PROFILE_CLOUD_ENV" != "Production" ]]; then
      echo "✗ Developer ID profile 缺少 iCloud.com.pocketagent / Production CloudKit 授權" >&2
      exit 1
    fi
  fi

  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$PROFILE_PLIST" > "$DERIVED"
  if [[ "$NOTARIZE" != "1" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$DERIVED" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c 'Set :com.apple.security.get-task-allow true' "$DERIVED"
  fi

  # A provisioning profile hands CloudKit entitlements back in wildcard forms
  # that CKContainer rejects at launch with CKException("malformed entitlements"):
  #   · icloud-services arrives as the string "*" — must be an array of strings
  #     (["CloudKit"]).
  #   · a Development profile returns [Production, Development] for the container
  #     environment — its signed entitlement must be the single string Development.
  #     A Developer ID profile already returns the single string Production.
  # Coerce both, or the app SIGABRTs during applicationDidFinishLaunching.
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-services' "$DERIVED" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-services' "$DERIVED"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.icloud-services array' "$DERIVED"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.developer.icloud-services:0 string CloudKit' "$DERIVED"
  fi
  if [[ "$NOTARIZE" != "1" ]] && /usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$DERIVED" >/dev/null 2>&1; then
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
  if [[ "$NOTARIZE" == "1" ]]; then
    echo "  profile: $PROFILE_NAME (Developer ID, Production CloudKit)"
    echo "  注意：Apple 不允許 Developer ID profile 使用原生 Sign in with Apple entitlement"
  else
    echo "  profile: $PROFILE_NAME (Development + get-task-allow)"
  fi
elif [[ "$SIGN_IDENTITY" != "-" ]]; then
  echo "✗ 找不到 provisioning profile：$PROFILE" >&2
  echo "  請安裝對應 profile，或用 PROFILE / DESKTOP_PROFILE 指定路徑。" >&2
  exit 1
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
  codesign "${CODESIGN_OPTS[@]}" --sign "$SIGN_IDENTITY" "$APPDIR/Contents/Resources/cloudflared"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  echo "▸ codesign (identity: $SIGN_IDENTITY, hardened runtime)"
else
  echo "▸ codesign (identity: $SIGN_IDENTITY)"
fi
if [[ -n "$SIGN_ENTITLEMENTS" ]]; then
  codesign "${CODESIGN_OPTS[@]}" \
    --entitlements "$SIGN_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$APPDIR"
else
  codesign "${CODESIGN_OPTS[@]}" \
    --sign "$SIGN_IDENTITY" "$APPDIR"
fi
codesign --verify --deep --strict --verbose=2 "$APPDIR"

echo "▸ create .dmg"
DIST="$OUT/dist"; mkdir -p "$DIST"   # 發行產物統一落 build/dist/
DMG="$DIST/Pocket-$VER.dmg"
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
