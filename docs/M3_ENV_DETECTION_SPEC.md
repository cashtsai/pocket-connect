# M3 施工規格：環境偵測 + 引導安裝 Hermes 依賴

> 2026-07-01 · XCash 整理，承接 `COMMERCIALIZATION_SPEC.md` 缺口 2。
> 排在 M2 之後開工，不搶 M2 資源。

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
