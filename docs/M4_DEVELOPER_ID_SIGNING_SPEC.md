# M4 施工規格：Developer ID 簽章 + 公證

> 2026-07-23 · Developer ID + Production CloudKit 本機發行、Apple Web auth broker
> 部署與正式安裝均已完成。

---

## 0. 目標

公開 `.dmg` 使用 **Developer ID Application** 憑證與 **公證（notarization）**，讓
Gatekeeper 在任意 Mac 接受安裝。若使用 CloudKit，還必須嵌入 MAC_APP_DIRECT 類型的
Developer ID provisioning profile；Pocket 的正式 profile 名稱為 `Pocket Desktop DevID`。

注意：[Apple 的 macOS capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-macos)
不允許 Developer ID profile 使用原生
Sign in with Apple entitlement。公開 `.dmg` 可用 Production CloudKit，但 Apple 登入
必須改走 Web Sign in with Apple；原生登入只能保留在 Development / Mac App Store 軌。

---

## 1. 簽章材料（已完成）

Developer ID Application 憑證、私鑰與 `Pocket Desktop DevID` profile 已建立。正式
profile 綁定 Team `4F8B93R3SH`、App ID `com.pocketagent.desktop`、Production
CloudKit container `iCloud.com.pocketagent`，並設定 `ProvisionsAllDevices=true`。

**已完成的建立步驟**（保留作為換證紀錄）：
1. 登入 https://developer.apple.com/account/resources/certificates/list
2. 建立新憑證 → 選 **Developer ID Application**
3. 依網站指示產生 CSR（可用 `Keychain Access.app` → 憑證輔助程式 → 從憑證授權機構要求憑證）
4. 下載憑證，雙擊安裝進 Keychain
5. 匯出 `.p12`（含私鑰），設一組密碼，交給 XCash 存進安全位置（不進 git）

---

## 2. 已完成的技術實作

### 2.1 本機簽章 + 公證流程

`packaging/build_dmg.sh` 在 `NOTARIZE=1` 時會：

1. 驗證 profile App ID 為 `4F8B93R3SH.com.pocketagent.desktop`，且
   `ProvisionsAllDevices=true`。
2. 從 profile 派生 Production CloudKit / Keychain entitlements，將 wildcard 轉為
   Pocket 的具體識別值，不加入 `get-task-allow` 或未授權的 Apple 登入 entitlement。
3. 對 App 與內嵌 `cloudflared` 套用 Developer ID、hardened runtime 與 timestamp。
4. 用 `notarytool` 提交 DMG，通過後 staple，並以 `codesign` / `spctl` 驗收。

本機正式建置指令：

```bash
cd mac-app
NOTARIZE=1 ./packaging/build_dmg.sh
```

### 2.2 CI（GitHub Actions）

`.github/workflows/release.yml` 已改為正式發行軌：

1. 在 Apple Silicon `macos-15` runner 驗證 tag 與 `Info.plist` 版本一致。
2. 執行完整 Swift 測試並安裝要內嵌的 `cloudflared`。
3. 從 GitHub Secrets 把 Developer ID `.p12` 匯入一次性 keychain。
4. 嵌入 Developer ID profile，執行 hardened-runtime 簽章、公證與 staple。
5. 以 `codesign`、`spctl`、`stapler validate` 驗收。
6. GitHub Release 同時發布 DMG 與 SHA-256。

Repo Settings → Secrets and variables → Actions 必須設定：

| Secret | 內容 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID Application `.p12` 的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 該 `.p12` 的匯出密碼 |
| `DEVELOPER_ID_PROFILE_BASE64` | `Pocket Desktop DevID` profile 的 base64 |
| `APPLE_NOTARY_KEY_P8_BASE64` | App Store Connect / notarytool API key `.p8` 的 base64 |
| `APPLE_NOTARY_KEY_ID` | 公證 API key ID |
| `APPLE_NOTARY_ISSUER_ID` | 公證 API issuer ID |

以上 secrets 只用於建置與公證。Web Sign in with Apple 的私鑰屬於 Bridge
runtime，不能放進 DMG，也不要與發行憑證混用。

### 2.3 公開版 Web Sign in with Apple

程式碼已完成：

- Developer ID 簽章沒有 `com.apple.developer.applesignin` 時，Pocket 自動改開系統瀏覽器。
- 固定網域 `pocket.tsai.cash` 的 auth broker 建立 10 分鐘單次流程，使用 `state`
  防 CSRF、`nonce` 防重放，並限制每個來源的建立頻率。
- Apple callback 不回傳 token；broker 先用專用 client secret 向 Apple 交換並驗證
  authorization code，再讓 Pocket 以 `flow_id` + `poll_secret` 一次性取回 Apple
  identity proof。
- Pocket 把 proof 交給自己的 `127.0.0.1` Bridge 驗簽並建立本機 account session；
  callback 不會把公開使用者寫進 CashCamp 的帳號資料庫。
- Development / Mac App Store 簽章仍保留原生 `ASAuthorizationController`。

Apple Developer Portal 已於 2026-07-23 完成：

- Services ID：`com.pocketagent.web`
- Domain：`pocket.tsai.cash`
- Return URL：`https://pocket.tsai.cash/app/v1/auth/apple/web/callback`
- Primary App ID：`com.pocketagent.desktop`
- Sign in with Apple key：`Pocket Web Sign In`，Key ID `QD9D22NS7C`
- 本機 key：`~/.pocket-release-secrets/apple-signin/AuthKey_QD9D22NS7C.p8`
  （目錄 `0700`、檔案 `0600`，不進 git）

### 2.4 2026-07-23 正式部署紀錄

- Bridge `main` 已部署並推送至 GitHub（merge head `f26c002`）；production LaunchAgent
  已注入 Services ID、return URL、Team ID、Key ID 與 mode-600 `.p8` 路徑。
- Pocket 公開版已透過 PR
  [#12](https://github.com/cashtsai/pocket-connect/pull/12) 與
  [#13](https://github.com/cashtsai/pocket-connect/pull/13) 合併至 `main`
  （release merge head `f0ca5ca`）。
- `NOTARIZE=1 ./packaging/build_dmg.sh` 完成；Apple notarization submission ID：
  `b9cd7e3e-3dc9-4e74-a03b-19b01a88a0ba`，狀態 `Accepted`。
- 產物：`mac-app/build/Pocket-0.2.dmg`。`codesign --verify --deep --strict`、
  `spctl -a -vvv` 與 `xcrun stapler validate` 均通過；Gatekeeper 顯示
  `source=Notarized Developer ID`。
- 正式 entitlement 為 `iCloud.com.pocketagent` / `Production`，Keychain group 為
  `4F8B93R3SH.com.pocketagent.desktop`，且不含 Developer ID 不支援的
  `com.apple.developer.applesignin`。
- 新版已安裝至 `/Applications/Pocket.app`；替換前版本保留於
  `/Applications/Pocket.app.pre-web-apple-20260723-103441`。
- 安裝前後 11 個 tmux 工作 session 數量與名稱不變；只重啟 Pocket 並清除它遺留的
  3 個舊 `cloudflared` helper。
- 真人 Apple Account Web 登入已完成：Apple callback 成功，broker 一次性 proof
  由本機 Bridge 驗簽，成功建立並驗證 `account` session；暫存 token 隨即刪除。
- GitHub Actions 六個 release secrets 已建立。CI 專用 Developer ID P12 位於
  `~/.pocket-release-secrets/developerid-application-ci.p12`（`0600`），隨機密碼只存
  macOS Keychain；以臨時 keychain 模擬 runner 匯入成功。
- `v0.2` workflow
  [run 29981075083](https://github.com/cashtsai/pocket-connect/actions/runs/29981075083)
  在 2 分 12 秒內完成測試、簽章、公證、staple、Gatekeeper 驗收與
  [GitHub Release](https://github.com/cashtsai/pocket-connect/releases/tag/v0.2)。
  發布 DMG SHA-256：
  `751375a494fb74c04acc586b291601397b74e93d54be7a5d5f17c382f0f85c0a`。
- 從 GitHub Release 重新下載的 DMG 已獨立通過 checksum、`stapler validate`、
  `codesign --verify --deep --strict`、`spctl` 與 Production CloudKit entitlement
  驗收。

---

## 3. 驗收標準

| 檢查項 | 通過條件 |
|---|---|
| 全新未註冊 Mac 安裝 | 雙擊 `.dmg` 開啟，Gatekeeper 不擋（或只需一次「打開」確認，無「無法確認開發者」錯誤）|
| `spctl` 檢查 | `spctl -a -vvv /Applications/Pocket.app` 回傳 `accepted`，`source=Notarized Developer ID` |
| Production CloudKit | 簽章含 `iCloud.com.pocketagent`，環境為 `Production` |
| 公開版 Apple 登入 | Bridge runtime 設定後，瀏覽器完成登入並由 Pocket 取回本機 session |
| CI 自動化 | push tag 後 GitHub Actions 自動出「已公證」的 `.dmg`，不需手動本機跑 |

---

## 4. 分工

| 線 | 工作 |
|---|---|
| 善彰 | Developer ID 憑證與正式 profile 已建立；保管 `.p12` 備份密碼 |
| XCash | `.p12` 與 SIWA `.p8` 已放安全位置（不進 git） |
| Codex | Portal、程式、Bridge production、真人 Apple 登入、GitHub CI 公證發行與成品回下載驗收均已完成 |

---

## 5. 後續驗收與發布通路

- 再以另一台全新、未註冊開發裝置的 Mac 重跑一次安裝驗收，確認沒有本機歷史狀態
  影響首次啟動。
- `cashtsai/pocket-connect` 目前是 private repository，因此 v0.2 Release 只對 repo
  成員可下載。要提供一般使用者直接下載，應另設公開的 release-only repo 或正式下載站；
  不需要公開原始碼或把簽章 secrets 搬到公開 repo。
