#!/usr/bin/env bash
# verify_release.sh — 驗「使用者真的會下載到的那顆」,不是本機那顆。
#
# 為什麼需要這支(2026-10-18 一星風險排查):
#   線上的 v0.5.1 實測結果是
#     spctl -a -t install <dmg>  → rejected, no usable signature
#     stapler validate <app>     → does not have a ticket stapled
#   但 app 本身是 accepted / Notarized Developer ID,而且帶 hardened runtime
#   —— 當時確實走了 NOTARIZE=1,**只是上傳到 release 的那顆不是 staple 過的
#   那顆**。本機驗沒用,要驗下載回來的。
#
#   後果:沒票據的公證 app 在**離線或公司網路擋掉 Apple 公證服務**時會跳
#   「無法打開,因為 Apple 無法檢查是否含有惡意軟體」。有網路的人不會遇到,
#   所以本機測試永遠測不出來。
#
# 用法:
#   mac-app/packaging/verify_release.sh            # 驗 releases/latest
#   mac-app/packaging/verify_release.sh v0.6.0     # 驗指定 tag
set -euo pipefail

REPO="cashtsai/pocket-connect"
TAG="${1:-latest}"
TMP="$(mktemp -d)"
cleanup() { hdiutil detach "$TMP/mnt" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

API="https://api.github.com/repos/$REPO/releases/$([[ "$TAG" == latest ]] && echo latest || echo "tags/$TAG")"
URL=$(curl -fsSL "$API" | python3 -c 'import json,sys;print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"].endswith(".dmg")))')
echo "▸ 下載 $URL"
DMG="$TMP/$(basename "$URL")"
curl -fsSL -o "$DMG" "$URL"

fail=0
note() { printf '  %s %s\n' "$1" "$2"; }

echo "▸ DMG 本身"
if spctl -a -vv -t install "$DMG" 2>&1 | grep -q accepted; then
  note "✅" "spctl accepted"
else
  note "❌" "spctl rejected —— DMG 沒簽/沒公證"
  fail=1
fi

echo "▸ 掛載並驗 app"
mkdir -p "$TMP/mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$TMP/mnt" "$DMG" >/dev/null
APP=$(find "$TMP/mnt" -maxdepth 1 -name '*.app' | head -1)
[[ -n "$APP" ]] || { echo "  ❌ DMG 裡找不到 .app"; exit 1; }

if spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID"; then
  note "✅" "app 已公證(線上查驗)"
else
  note "❌" "app 未通過 Gatekeeper"; fail=1
fi

if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  note "✅" "app 票據已 staple(離線也能開)"
else
  note "❌" "app 沒有 staple 票據 —— 離線/受限網路會跳「Apple 無法檢查」"; fail=1
fi

# bridge payload:沒有它,乾淨 Mac 裝完就是死路(release.yml 記載的 v0.3/v0.4 事故)
if [[ -d "$APP/Contents/Resources/bridge" ]]; then
  note "✅" "內含 bridge payload"
else
  note "❌" "**沒有內含 bridge** —— 乾淨 Mac 會卡在「找不到 bridge 原始碼」死路"; fail=1
fi

if [[ -x "$APP/Contents/Resources/cloudflared" ]]; then
  note "✅" "內含 cloudflared"
else
  note "⚠️ " "沒有內含 cloudflared —— 對外通道會整個靜默不啟動"
fi

# frpc:付費中繼的客戶端。架構要**擋**不是印 —— 只有單一架構的話,另一半使用者
# 的 bridge 會 spawn 失敗,而那端只記一行 log,使用者看到的是「遠端連線就是不通」,
# 沒人查得到為什麼。這種「安靜地只對一半的人壞掉」比整個壞掉更難抓。
FRPC="$APP/Contents/Resources/frpc"
if [[ -x "$FRPC" ]]; then
  FRPC_ARCHS="$(lipo -archs "$FRPC" 2>/dev/null || echo unknown)"
  if [[ "$FRPC_ARCHS" == *x86_64* && "$FRPC_ARCHS" == *arm64* ]]; then
    note "✅" "內含 frpc(universal:$FRPC_ARCHS)"
  else
    note "❌" "frpc 不是 universal($FRPC_ARCHS)—— 另一半使用者的中繼會靜默失敗"; fail=1
  fi
else
  note "⚠️ " "沒有內含 frpc —— 付費中繼功能會整個靜默不存在"
fi

BIN=$(find "$APP/Contents/MacOS" -maxdepth 1 -type f -perm -111 | head -1)
note "ℹ️ " "架構:$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
echo
if [[ $fail -eq 0 ]]; then echo "✅ 這顆可以發。"; else echo "❌ 有問題,**不要公告**。"; exit 1; fi
