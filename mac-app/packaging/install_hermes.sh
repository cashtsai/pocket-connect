#!/bin/zsh
# Pocket — M3 OSS 自架環境一鍵安裝（docs/M3_ENV_DETECTION_SPEC.md §3）。
# 由 Pocket.app「一鍵安裝 Hermes」按鈕以背景 Process 執行,stdout/stderr 由 app
# 收進 ~/Library/Logs/Pocket/install.log;也可以手動在終端機執行。
#
# 與 spec §3 範本的差異（都是 spec 要求派工前先驗證的點,依實測調整）:
#   · hermes-agent(PyPI)要求 Python >=3.11,<3.14;macOS 內建 python3 只有 3.9,
#     所以先掃可用的 3.11–3.13,找不到就明確報錯請使用者先 brew 裝。
#   · Homebrew Python 受 PEP 668(externally-managed)限制,`pip install --user`
#     會直接報錯 → 改用專用 venv(~/.local/share/pocket/hermes-venv)+ symlink
#     到 ~/.local/bin/hermes,app 的環境偵測掃得到。
#   · `hermes setup --quick` 依 --help 只作用於「既有安裝」;全新安裝的非互動
#     模式是 `--non-interactive`(預設值/環境變數)。已有 ~/.hermes/config.yaml
#     的機器整段跳過,不動現有設定。
#   · bridge LaunchAgent 的 label/路徑沿用 ai.studio.hermes-bridge —— app 的
#     BridgeToken.read() 綁定這個 plist 路徑。已存在的 plist 一律保留不覆寫。
#   · bridge 原始碼已開源(github.com/cashtsai/hermes-studio-bridge,2026-07-12
#     善彰拍板);本機沒有時自動 git clone,可用 POCKET_BRIDGE_REPO 覆寫來源。
set -euo pipefail

BRIDGE_DIR="${POCKET_BRIDGE_DIR:-$HOME/apps/hermes-openwebui-bridge}"
BRIDGE_REPO="${POCKET_BRIDGE_REPO:-https://github.com/cashtsai/hermes-studio-bridge.git}"
LABEL="ai.studio.hermes-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PORT="${POCKET_BRIDGE_PORT:-8081}"
VENV="$HOME/.local/share/pocket/hermes-venv"

fail() { echo "✗ $1" >&2; exit 1; }
healthy() { curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }

echo "▸ 尋找 Python 3.11–3.13..."
PY=""
for c in python3.13 python3.12 python3.11 python3; do
  for d in "" /opt/homebrew/bin/ /usr/local/bin/; do
    p="$d$c"
    if command -v "$p" >/dev/null 2>&1 \
       && "$p" -c 'import sys; raise SystemExit(0 if (3,11) <= sys.version_info[:2] < (3,14) else 1)' 2>/dev/null; then
      PY="$(command -v "$p")"
      break 2
    fi
  done
done
[ -n "$PY" ] || fail "找不到 Python 3.11–3.13（hermes-agent 的需求）。請先安裝,例如:brew install python@3.12"
echo "  使用 $PY"

if command -v hermes >/dev/null 2>&1; then
  HERMES="$(command -v hermes)"
  echo "▸ 已安裝 Hermes（$HERMES）,跳過安裝"
else
  echo "▸ 安裝 Hermes 到 $VENV ..."
  mkdir -p "${VENV:h}"
  [ -x "$VENV/bin/pip" ] || "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade --quiet hermes-agent uvicorn fastapi
  [ -x "$VENV/bin/hermes" ] || fail "pip 裝完但找不到 $VENV/bin/hermes"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$VENV/bin/hermes" "$HOME/.local/bin/hermes"
  HERMES="$HOME/.local/bin/hermes"
  echo "  已連結 $HERMES"
fi

if [ -f "$HOME/.hermes/config.yaml" ]; then
  echo "▸ 已有 ~/.hermes/config.yaml,跳過 hermes setup（不動現有設定）"
else
  echo "▸ 執行快速設定（hermes setup --non-interactive）..."
  "$HERMES" setup --non-interactive
fi

echo "▸ 設定 bridge LaunchAgent..."
if healthy; then
  echo "  bridge 已在 $PORT 埠回應 /health,不動現有服務"
  echo "✓ 安裝完成"
  exit 0
fi

if [ -f "$PLIST" ]; then
  echo "  已存在 $PLIST,保留現有設定"
else
  if [ ! -f "$BRIDGE_DIR/bridge.py" ]; then
    if [ -d "$BRIDGE_DIR" ] && [ -n "$(ls -A "$BRIDGE_DIR" 2>/dev/null)" ]; then
      fail "$BRIDGE_DIR 已存在但缺 bridge.py,不敢覆蓋。請清空該目錄讓腳本重新 clone,或以 POCKET_BRIDGE_DIR 指定正確位置。"
    fi
    # 全新機器的 git 是 CLT stub,直接呼叫會跳 GUI 安裝視窗且失敗,先擋下來。
    xcode-select -p >/dev/null 2>&1 \
      || fail "git 需要 Xcode Command Line Tools。請先在終端機執行 xcode-select --install,裝完再按「重新檢查」。"
    echo "▸ 取得 bridge 原始碼（$BRIDGE_REPO）..."
    git clone --depth 1 "$BRIDGE_REPO" "$BRIDGE_DIR" \
      || fail "git clone $BRIDGE_REPO 失敗,詳見上方輸出。"
  fi
  BRIDGE_PY="$PY"
  [ -x "$VENV/bin/python" ] && BRIDGE_PY="$VENV/bin/python"
  "$BRIDGE_PY" -c 'import uvicorn, fastapi' 2>/dev/null \
    || "$BRIDGE_PY" -m pip install --quiet uvicorn fastapi 2>/dev/null \
    || fail "$BRIDGE_PY 缺 uvicorn/fastapi 且無法安裝（externally-managed?）。請改用 venv Python。"
  TOKEN="pocket-$(openssl rand -hex 24)"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BRIDGE_PY</string>
        <string>-m</string>
        <string>uvicorn</string>
        <string>bridge:app</string>
        <string>--host</string>
        <string>127.0.0.1</string>
        <string>--port</string>
        <string>$PORT</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$BRIDGE_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$VENV/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>BRIDGE_TOKEN</key>
        <string>$TOKEN</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$BRIDGE_DIR/bridge.out.log</string>
    <key>StandardErrorPath</key>
    <string>$BRIDGE_DIR/bridge.err.log</string>
</dict>
</plist>
EOF
  echo "  已產生 $PLIST"
fi

echo "▸ 載入 bridge..."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "▸ 等待 bridge 回應 /health ..."
for i in {1..20}; do
  if healthy; then
    echo "✓ 安裝完成"
    exit 0
  fi
  sleep 1
done
fail "bridge 已載入但 /health 在 20 秒內沒有回應,詳見 $BRIDGE_DIR/bridge.err.log"
