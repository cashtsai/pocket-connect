# M4 施工規格：Developer ID 簽章 + 公證

> 2026-07-23 · Developer ID + Production CloudKit 本機發行流程已完成並驗收。

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

Apple Developer Portal 還需完成：

- Services ID：`com.pocketagent.web`
- Domain：`pocket.tsai.cash`
- Return URL：`https://pocket.tsai.cash/app/v1/auth/apple/web/callback`
- 建立 Sign in with Apple private key，綁定 primary App ID
  `com.pocketagent.desktop`

---

## 3. 驗收標準

| 檢查項 | 通過條件 |
|---|---|
| 全新未註冊 Mac 安裝 | 雙擊 `.dmg` 開啟，Gatekeeper 不擋（或只需一次「打開」確認，無「無法確認開發者」錯誤）|
| `spctl` 檢查 | `spctl -a -vvv /Applications/Pocket.app` 回傳 `accepted`，`source=Notarized Developer ID` |
| Production CloudKit | 簽章含 `iCloud.com.pocketagent`，環境為 `Production` |
| 公開版 Apple 登入 | Portal 與 Bridge secrets 設定後，瀏覽器完成登入並由 Pocket 取回 session |
| CI 自動化 | push tag 後 GitHub Actions 自動出「已公證」的 `.dmg`，不需手動本機跑 |

---

## 4. 分工

| 線 | 工作 |
|---|---|
| 善彰 | Developer ID 憑證與正式 profile 已建立；保管 `.p12` 備份密碼 |
| XCash | `.p12` 已放安全位置（不進 git）；完成 Apple Portal 登入 / 2FA |
| Codex | 本機簽章、公證、Web 登入程式與 CI workflow 已完成；待補 secrets 與正式驗收 |

---

## 5. 尚待完成

- GitHub Actions 尚未放入 Developer ID `.p12`、profile 與公證 API key secrets，因此
  tag release 仍不可視為正式發行來源。
- Apple Portal 尚未建立 Services ID / Return URL / Sign in with Apple key，Bridge
  runtime 環境也尚未注入該 key。
- 完成以上設定後，才進行公開 DMG 端到端登入與全新 Mac 安裝驗收。
