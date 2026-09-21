# M3 施工規格：環境偵測 + 引導安裝 Hermes 依賴

> 2026-07-01 · XCash 整理，承接 `COMMERCIALIZATION_SPEC.md` 缺口 2。
> 排在 M2 之後開工，不搶 M2 資源。
>
> **2026-08-18 更新：已施工完成。** §3 那個「需與 Codex 確認 bridge LaunchAgent 產生
> 流程是否已有腳本可複用」的 TODO 答案是 **有**——bridge repo 的
> `deploy/install-local-bridge.sh` 就是現成的 per-user 安裝器。實作與原規格的差異、
> 以及實際做出來的東西，見文末 §7「as-built」。原規格內容保留作為對照，不要照著它施工。

---

## 0. 目標

Pocket Connect.app 啟動時，若這台機器還沒裝好 Hermes + bridge，不要讓使用者卡在
「Apple 登入完卻連不上」的死路，而是主動偵測、引導補齊。

---

## 1. 偵測邏輯

首次啟動（或每次啟動時的健康檢查）：

```swift
func checkEnvironmentReady() -> EnvironmentStatus {
    let hasHermes = AccountLinkChecker.resolveBinary("hermes") != nil
    let bridgeHealthy = pingBridgeHealth()  // GET http://127.0.0.1:8081/health, 2s timeout
    if hasHermes && bridgeHealthy { return .ready }
    if !hasHermes { return .missingHermes }
    return .missingBridge   // hermes 裝了但 bridge 沒跑起來
}
```

---

## 2. UI 流程

```
┌───────────────────────────────┐
│  需要先準備好執行環境            │
│                                 │
│  ❌ 沒偵測到 Hermes              │
│                                 │
│  這台 Mac 需要先裝好 Hermes 才能  │
│  執行 Pocket。按下方按鈕自動安裝。 │
│                                 │
│      [ 一鍵安裝 Hermes ]         │
│      [ 我已經裝好了，重新檢查 ]    │
└───────────────────────────────┘
```

- 「一鍵安裝」觸發背景 `Process` 跑 `install_hermes.sh`（見 §3），顯示進度 log（至少顯示
  「安裝中…」spinner，不用逐行顯示終端輸出）
- 裝完自動重新跑一次 `checkEnvironmentReady()`，通過就自動進下一步（Apple 登入或帳號連結）
- 失敗時顯示明確錯誤 + 「查看記錄檔」按鈕（把 log 存到 `~/Library/Logs/Pocket/install.log`）

---

## 3. 安裝腳本 `install_hermes.sh`

```bash
#!/bin/zsh
set -euo pipefail
echo "▸ 安裝 Hermes..."
pip3 install --user hermes-agent
echo "▸ 執行快速設定..."
hermes setup --quick    # 需確認 hermes-agent 是否真的支援 --quick，若無則調整為互動式但給預設值
echo "▸ 產生 bridge LaunchAgent..."
# TODO: 需與 Codex 確認 bridge LaunchAgent 產生流程是否已有腳本可複用
echo "✓ 安裝完成"
```

> ⚠️ 派工前先確認：`hermes-agent` 套件是否真的有 `--quick` 這種非互動安裝模式；若沒有，
> 這支腳本要改成產生一份預設 config 檔案直接寫入，跳過互動精靈。這點在派工描述裡要
> 明講給 Codex，不要讓它假設存在就硬做。

---

## 4. 商業客戶版（跳過 M3，走安裝器）

真正的商業客戶（善字營）不會走這條「使用者自己補環境」的路——他們拿到的機器已經
預先裝好整套。M3 的偵測引導只服務「OSS 自架使用者」這個客群，商業客戶版用獨立的
「Pocket 商業安裝器」`.pkg`（另案，不在 M3 範圍內）。

---

## 5. 驗收標準

| 檢查項 | 通過條件 |
|---|---|
| 全新機器（無 Hermes）冷啟動 | 顯示「需要先準備環境」畫面，不是直接卡死或空白 |
| 一鍵安裝 | 背景跑完後自動偵測通過、自動進下一步 |
| 已裝好環境的機器 | 完全跳過這個畫面，直接進 Apple 登入（不能讓已就緒的使用者被多問一次）|
| 安裝失敗 | 顯示清楚錯誤 + log 路徑，不是無聲失敗 |

---

## 6. 分工

| 線 | 工作 |
|---|---|
| Codex（bridge/installer） | 寫 `install_hermes.sh`，確認 hermes-agent 非互動安裝的真實可行方式 |
| CC（app） | `Onboarding.swift` 加環境偵測畫面 + 呼叫安裝腳本 + 輪詢重新檢查 |
| XCash | 驗收（找一台乾淨的測試環境或新 macOS 使用者帳號模擬）、出 PR |

---

## 7. as-built（2026-08-18 實作紀錄）

### 7.1 §3 TODO 的答案：不用另寫腳本

bridge repo 已經有 **`deploy/install-local-bridge.sh`**，而且它本來就是為這件事寫的
per-user 安裝器：建 venv、`pip install fastapi uvicorn …`、rsync bridge 程式碼、
產生並 `launchctl bootstrap` LaunchAgent、沒有 token 就用 `secrets.token_urlsafe(32)`
生一組。它用的是**自己的一組身分**，跟開發機上 production 的 `ai.studio.hermes-bridge`
完全隔離：

| 項目 | 值 | 覆寫用的環境變數 |
|---|---|---|
| LaunchAgent label | `com.pocketconnect.bridge` | `POCKET_BRIDGE_LABEL` |
| 安裝位置 | `~/Library/Application Support/PocketConnect/bridge/current` | `POCKET_BRIDGE_INSTALL_ROOT` |
| venv | 上者的 `venv/` | `POCKET_BRIDGE_VENV` |
| 埠 | 8081 | `POCKET_BRIDGE_PORT`（app 端） |

所以原規格 §3 那支 `install_hermes.sh` **不寫了**；`hermes-agent --quick` 那個疑問也
連帶消失（Pocket 這條路預設 `POCKET_PROVIDER=none`，只裝 bridge 本體，AI 引擎交給
使用者自己用官方 CLI 裝，清單上有明確項目）。

### 7.2 實際做出來的東西

| 檔案 | 內容 |
|---|---|
| `mac-app/Sources/PocketConnectKit/BridgeEnvironment.swift` | **純決策層**：佈局推導、探測資料結構、`BridgeEnvironmentPlanner.plan()`、檢查清單產生、lsof/ps/plist 解析。零副作用，全部有單元測試。 |
| `mac-app/Sources/PocketConnect/BridgeBootstrap.swift` | **執行層**：找 python / 找 bridge 來源 / 打 `/health` / `lsof` 查佔埠 / 跑安裝腳本 / `launchctl kickstart` / 輪詢健康 / 寫 `~/Library/Logs/Pocket/install.log`。 |
| `mac-app/Sources/PocketConnect/EnvironmentSetup.swift` | **UI**：`BridgeEnvironmentModel` + `EnvironmentSetupView`。同一份 view 用在首次啟動的把關頁與控制台的常駐卡片。 |
| `mac-app/Tests/…/BridgeEnvironmentTests.swift` | 決策層的單元測試（每個分支 + 檢查清單 + 解析器）。 |

### 7.3 狀態機（取代原規格 §1 的三態）

原規格只有 `ready / missingHermes / missingBridge` 三態，不夠用——真實世界至少有七種：

| 狀態 | 條件 | app 怎麼做 |
|---|---|---|
| `ready(來源)` | `/health` 200 + 讀得到金鑰 | 直接放行去登入/配對 |
| `readyButNoToken` | `/health` 200、沒金鑰 | 金鑰那條標 **blocked**，引導到「連線設定」貼上 |
| `installedNotRunning` | 我們的 plist 在、程式在，服務沒回應 | 「啟動 Bridge」→ `launchctl kickstart` |
| `portBusy(占用者)` | 埠上有別人的程式且不回 health | **不覆蓋**，秀出 PID/程式名 + `lsof` 指令 |
| `needsInstall(來源)` | 有 python + 有 bridge 來源 | 「一鍵安裝並啟動」→ 跑 `install-local-bridge.sh` |
| `missingPython` | 候選路徑都找不到 python3 | blocked + `xcode-select --install` 可複製指令 |
| `missingBridgeSource` | app 沒內附 payload、本機也沒 checkout | blocked + 說明連結 |

**第一原則：`/health` 回 200 就一律沿用，不重裝也不搶埠。** 開發機上 8081 跑的是
production 的 `ai.studio.hermes-bridge`，這條規則保證 Pocket 不會去動它。

### 7.4 bridge 程式來源的優先序

1. 已安裝的 `installRoot`（升級/重裝）
2. **app 內附的 payload** `Pocket.app/Contents/Resources/bridge`（全新 Mac 的正路）
3. 本機開發用 checkout `~/apps/hermes-openwebui-bridge`（開發機）

②要靠 `BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh` 打包進去，**預設關閉**——要不要把
bridge 一起發出去是發行決策（授權、體積、secrets 稽核），需要 owner 拍板。沒開的話，
全新 Mac 會在清單上看到「找不到 Bridge 程式」這條 blocked 項目 + 說明連結，
**不是無聲失敗**。

### 7.5 乾跑驗證（沒辦法真的清空一台 Mac）

`POCKET_ENV_DOCTOR=1` 讓 app 只跑偵測、印 JSON 就結束。把 `POCKET_BRIDGE_INSTALL_ROOT`
/ `POCKET_LAUNCH_AGENTS_DIR` / `POCKET_LOG_DIR` / `POCKET_BRIDGE_PORT` /
`POCKET_BRIDGE_PYTHON_CANDIDATES` / `POCKET_BRIDGE_SOURCE_CANDIDATES` 指到一個 TEMP
prefix，就能在現有機器上重現全新 Mac 的每一個分支：

```bash
POCKET_ENV_DOCTOR=1 \
POCKET_BRIDGE_INSTALL_ROOT=/tmp/fresh/install \
POCKET_LAUNCH_AGENTS_DIR=/tmp/fresh/agents \
POCKET_BRIDGE_PYTHON_CANDIDATES=/tmp/fresh/nonexistent/python3 \
POCKET_BRIDGE_PORT=18081 \
  .build/arm64-apple-macosx/release/PocketConnect | jq .state
# → "missingPython"
```

exit code：0 = ready，1 = 還沒就緒。

### 7.6 原規格 §5 驗收表對照

| 檢查項 | 結果 |
|---|---|
| 全新機器冷啟動顯示「需要先準備環境」 | ✅ 登入頁前先擋一頁檢查清單；乾跑分支 ①②③ 有佐證 |
| 一鍵安裝跑完自動偵測通過、自動進下一步 | ✅ 安裝→輪詢 `/health`→就緒即自動回登入頁（真機安裝待 owner 在乾淨 Mac 驗） |
| 已就緒的機器完全跳過這畫面 | ✅ 乾跑分支 ⑥（8081 已有健康 bridge）→ `ready`，直接進登入 |
| 安裝失敗顯示清楚錯誤 + log 路徑 | ✅ 錯誤訊息帶 `~/Library/Logs/Pocket/install.log`，並有「查看記錄檔」按鈕 |
