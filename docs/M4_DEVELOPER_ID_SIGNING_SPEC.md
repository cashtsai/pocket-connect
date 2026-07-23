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

### 2.2 CI（GitHub Actions）要補的部分

`release.yml` 需要：
- 把 `.p12` + 密碼存進 GitHub repo secrets（`DEVELOPER_ID_P12_BASE64`、`DEVELOPER_ID_P12_PASSWORD`）
- Runner 匯入憑證到暫時 keychain：
  ```yaml
  - name: Import signing cert
    run: |
      echo "$P12_BASE64" | base64 --decode > cert.p12
      security create-keychain -p temp build.keychain
      security import cert.p12 -k build.keychain -P "$P12_PASSWORD" -T /usr/bin/codesign
      security list-keychains -d user -s build.keychain
      security unlock-keychain -p temp build.keychain
  ```
- 公證步驟需要 `APPLE_ID` + App-specific password 或 App Store Connect API key，同樣存 secrets

---

## 3. 驗收標準

| 檢查項 | 通過條件 |
|---|---|
| 全新未註冊 Mac 安裝 | 雙擊 `.dmg` 開啟，Gatekeeper 不擋（或只需一次「打開」確認，無「無法確認開發者」錯誤）|
| `spctl` 檢查 | `spctl -a -vvv /Applications/Pocket.app` 回傳 `accepted`，`source=Notarized Developer ID` |
| Production CloudKit | 簽章含 `iCloud.com.pocketagent`，環境為 `Production` |
| 公開版 Apple 登入 | Web Sign in with Apple 完成後才能驗收；Developer ID 不支援原生登入 |
| CI 自動化 | push tag 後 GitHub Actions 自動出「已公證」的 `.dmg`，不需手動本機跑 |

---

## 4. 分工

| 線 | 工作 |
|---|---|
| 善彰 | Developer ID 憑證與正式 profile 已建立；保管 `.p12` 備份密碼 |
| XCash | `.p12` 已放安全位置（不進 git）；GitHub secrets 待補 |
| Codex | 本機 profile / 簽章 / 公證 / 安裝已完成；CI workflow 待補 secrets 後改造 |
| CC | 公開版 Web Sign in with Apple 流程待實作 |

---

## 5. 尚待完成

- GitHub Actions 尚未放入 Developer ID `.p12`、profile 與公證 API key secrets，因此
  tag release 仍不可視為正式發行來源。
- 公開 DMG 的 Apple 登入需另做 Web Sign in with Apple；目前原生登入只適用
  Development / Mac App Store 軌。
