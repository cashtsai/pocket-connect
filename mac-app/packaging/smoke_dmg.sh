#!/bin/zsh
set -euo pipefail
# smoke_dmg.sh — 出貨前煙霧測試:驗「這顆 DMG 的行為」,不是驗「建置有沒有跑完」。
#
# 思路照 t3code(MIT)scripts/smoke-desktop-app.ts + release-desktop.yml 的
# Launch check 步驟:mount DMG → 從包內把 app 拿出來 → 真的把它跑起來看行為。
# 不引入 playwright —— 這顆 app 有 POCKET_ENV_DOCTOR=1 乾跑出口(main.swift),
# 直接用它當「app 在乾淨機器上跑得起來、而且自己找得到內附 bridge」的行為探針。
# 「管線存在 ≠ 端到端通」:spctl/stapler 擋簽章事故,env doctor 擋 v0.3/v0.4/v0.9
# 那種「包是好的、裡面沒貨」的空包事故。
#
# 用法:
#   ./packaging/smoke_dmg.sh build/dist/Pocket-1.0.1.dmg
# 環境:
#   EXPECT_BRIDGE=0   驗刻意不含 bridge 的建置時用(預設 1:沒 bridge = 失敗)
#
# 與 verify_release.sh 的分工:這支驗**還沒上傳**的那顆(CI 內、發佈前),
# verify_release.sh 驗**使用者真的會下載到**的那顆(發佈後)。兩關都要過。

DMG="${1:?用法: smoke_dmg.sh <dmg>}"
[[ -f "$DMG" ]] || { echo "✗ 找不到 $DMG" >&2; exit 1; }
EXPECT_BRIDGE="${EXPECT_BRIDGE:-1}"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

fail=0
note() { printf '  %s %s\n' "$1" "$2"; }

echo "▸ DMG 簽章與票據"
if spctl -a -t install "$DMG" >/dev/null 2>&1; then
  note "✅" "dmg 簽章通過 spctl"
else
  note "❌" "dmg spctl rejected(沒簽/沒公證)"; fail=1
fi
if xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  note "✅" "dmg 有 staple 票據"
else
  note "❌" "dmg 沒有 staple 票據"; fail=1
fi

# sha256 檔(cut_release.sh 的發行指令引用它;一定要跟 DMG 對得上)
if [[ -f "$DMG.sha256" ]]; then
  if ( cd "$(dirname "$DMG")" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null 2>&1 ); then
    note "✅" "sha256 檔與 DMG 相符"
  else
    note "❌" "sha256 檔與 DMG 不符(staple 之前算的?)"; fail=1
  fi
else
  note "❌" "缺 $DMG.sha256"; fail=1
fi

echo "▸ 掛載並驗 app"
mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
APP=$(find "$MNT" -maxdepth 1 -name '*.app' | head -1)
[[ -n "$APP" ]] || { echo "✗ DMG 裡找不到 .app" >&2; exit 1; }

codesign --verify --deep --strict "$APP" >/dev/null 2>&1 \
  && note "✅" "app 簽章完整(codesign --deep --strict)" \
  || { note "❌" "app 簽章驗證失敗"; fail=1; }
spctl --assess --type execute "$APP" >/dev/null 2>&1 \
  && note "✅" "app 通過 Gatekeeper(spctl execute)" \
  || { note "❌" "app 未通過 Gatekeeper"; fail=1; }
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  note "✅" "app 有 staple 票據(離線也能開)"
else
  note "❌" "app 沒有 staple 票據 —— 離線/受限網路會跳「Apple 無法檢查」"; fail=1
fi

# helper binary 一律要 universal:少一個架構 = 安靜地只對一半使用者壞掉
# (同 verify_release.sh;v0.9.1 實測 cloudflared 只有 arm64 的事故)。
check_universal() {
  # ⚠️ 這支是 zsh:小寫 `path` 跟 $PATH 綁定,拿來當區域變數會把 PATH 清掉、
  # 接下來連 lipo 都找不到(實測踩過)。所以叫 helper_bin。
  local name="$1" helper_bin="$APP/Contents/Resources/$1" archs
  if [[ ! -x "$helper_bin" ]]; then
    note "⚠️ " "沒有內含 $name(ALLOW_NO_* 建置?正式發行不該如此)"
    return
  fi
  archs="$(lipo -archs "$helper_bin" 2>/dev/null || echo unknown)"
  if [[ "$archs" == *x86_64* && "$archs" == *arm64* ]]; then
    note "✅" "$name universal($archs)"
  else
    note "❌" "$name 不是 universal($archs)"; fail=1
  fi
}
BIN="$APP/Contents/MacOS/PocketConnect"
MAIN_ARCHS="$(lipo -archs "$BIN" 2>/dev/null || echo unknown)"
if [[ "$MAIN_ARCHS" == *x86_64* && "$MAIN_ARCHS" == *arm64* ]]; then
  note "✅" "主程式 universal($MAIN_ARCHS)"
else
  note "❌" "主程式不是 universal($MAIN_ARCHS)"; fail=1
fi
check_universal cloudflared
check_universal frpc

if [[ "$EXPECT_BRIDGE" == "1" ]]; then
  if [[ -f "$APP/Contents/Resources/bridge/bridge.py" ]]; then
    note "✅" "內含 bridge payload($(sed -n 's/^commit=//p' "$APP/Contents/Resources/bridge/BRIDGE_VERSION.txt" 2>/dev/null || echo '版本不明'))"
  else
    note "❌" "**沒有內含 bridge** —— v0.3/v0.4/v0.9 空包事故同款,不要發"; fail=1
  fi
fi

# ── 啟動行為探針 ──────────────────────────────────────────────────────────────
# 先把 app 從唯讀 DMG 複製出來(模擬拖進 Applications),再用 POCKET_ENV_DOCTOR=1
# 乾跑:它會載入全部 framework、跑環境偵測、印 JSON 後自己退出,不開 UI。
# 把 install root / LaunchAgents / port 全指到臨時位置 = 模擬全新的 Mac,
# 也保證**不碰**這台機器上真的在跑的 bridge(production 紅線)。
# 乾淨機器的預期結果是 needsInstall(exit 1),所以 0/1 都算活著;要驗的行為是:
#   1) 印得出合法 JSON(app 跑得起來)
#   2) probe.bridgeSource 是 bundled(…)(app 自己找得到內附 bridge)
echo "▸ 啟動行為探針(POCKET_ENV_DOCTOR)"
RUN_DIR="$TMP/run"; mkdir -p "$RUN_DIR"
cp -R "$APP" "$RUN_DIR/"
RUN_BIN="$RUN_DIR/$(basename "$APP")/Contents/MacOS/PocketConnect"
DOCTOR_OUT="$TMP/doctor.json"

POCKET_ENV_DOCTOR=1 \
POCKET_BRIDGE_INSTALL_ROOT="$TMP/fresh-install-root" \
POCKET_LAUNCH_AGENTS_DIR="$TMP/fresh-agents" \
POCKET_BRIDGE_PORT=58123 \
  "$RUN_BIN" > "$DOCTOR_OUT" 2>"$TMP/doctor.err" &
DOCTOR_PID=$!
# 自帶 watchdog(macOS 沒內建 timeout(1)):最多等 90 秒。
waited=0
while kill -0 "$DOCTOR_PID" 2>/dev/null && (( waited < 90 )); do
  sleep 1; (( waited++ )) || true
done
if kill -0 "$DOCTOR_PID" 2>/dev/null; then
  kill -9 "$DOCTOR_PID" 2>/dev/null || true
  note "❌" "env doctor 90 秒沒退出(app 掛住)"; fail=1
else
  rc=0; wait "$DOCTOR_PID" || rc=$?
  if (( rc > 1 )); then
    note "❌" "app 啟動即死(exit $rc)"; fail=1
    sed 's/^/    /' "$TMP/doctor.err" | head -20 || true
  else
    if BRIDGE_SRC=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("probe",{}).get("bridgeSource") or "")' "$DOCTOR_OUT" 2>/dev/null); then
      note "✅" "app 啟動並印出合法 JSON(exit $rc)"
      if [[ "$EXPECT_BRIDGE" == "1" ]]; then
        if [[ "$BRIDGE_SRC" == bundled\(* ]]; then
          note "✅" "app 自己偵測到內附 bridge:$BRIDGE_SRC"
        else
          note "❌" "app 偵測不到內附 bridge(bridgeSource=${BRIDGE_SRC:-null})—— 乾淨 Mac 會是死路"; fail=1
        fi
      fi
    else
      note "❌" "app 的輸出不是合法 JSON(跑起來但行為不對)"; fail=1
      sed 's/^/    /' "$DOCTOR_OUT" | head -10 || true
    fi
  fi
fi

echo
if (( fail == 0 )); then
  echo "✅ 煙霧測試通過,這顆可以進下一關(發佈後還要 verify_release.sh)。"
else
  echo "❌ 煙霧測試失敗 —— 不要發這顆。" >&2
  exit 1
fi
