# M4 施工規格：Developer ID 簽章 + 公證

> 2026-07-01 · XCash 整理，承接 `COMMERCIALIZATION_SPEC.md` 缺口 1。
> 排在 M2、M3 之後，是「讓任意一台 Mac（非開發者本機）都能安裝」的最後一哩路。

---

## 0. 目標

目前 `.dmg` 是用 `Apple Development` 憑證簽的（Team `4F8B93R3SH`），只在善彰的開發者
機器上能正常執行 Sign in with Apple、且會被其他 Mac 的 Gatekeeper 擋下（「無法確認開發者」）。
要讓任意 Mac 都能直接雙擊安裝、正常運作，需要換成 **Developer ID Application** 憑證
並完成 **公證（notarization）**。

---

## 1. 阻塞點：需要善彰本人操作（無法代勞）

Apple 的帳號安全設計要求 Developer ID Application 憑證只能由帳號持有人在
App Store Connect / developer.apple.com 網站親自建立與下載 `.p12`。這一步任何
子程序、XCash、CC、Codex 都不能代替善彰完成。

**善彰需要做的事**（一次性）：
1. 登入 https://developer.apple.com/account/resources/certificates/list
2. 建立新憑證 → 選 **Developer ID Application**
3. 依網站指示產生 CSR（可用 `Keychain Access.app` → 憑證輔助程式 → 從憑證授權機構要求憑證）
4. 下載憑證，雙擊安裝進 Keychain
5. 匯出 `.p12`（含私鑰），設一組密碼，交給 XCash 存進安全位置（不進 git）

---

## 2. 完成後的技術實作（Codex/CC 線，善彰給憑證後才能做）

### 2.1 本機簽章 + 公證流程

```bash
# packaging/build_dmg.sh 要加的部分
SIGN_IDENTITY="Developer ID Application: 蔡嘉祥 (4F8B93R3SH)"   # 憑證建立後才知道確切名稱

codesign --force --deep --options runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APPDIR"

# 公證（需要 App-specific password 或 API key，存在 ~/.pocket-release.env）
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" --team-id "4F8B93R3SH" \
  --password "$APP_SPECIFIC_PASSWORD" --wait

xcrun stapler staple "$DMG"
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
| Sign in with Apple 正常運作 | 換一台機器，Apple 登入正常拿到 identityToken |
| CI 自動化 | push tag 後 GitHub Actions 自動出「已公證」的 `.dmg`，不需手動本機跑 |

---

## 4. 分工

| 線 | 工作 |
|---|---|
| 善彰 | **建立 Developer ID Application 憑證 + 匯出 `.p12`（唯一無法代勞的步驟）** |
| XCash | 拿到 `.p12` 後安全存放（不進 git），設定 GitHub secrets，驗收 |
| Codex | CI workflow 改造（匯入憑證 + 公證步驟） |
| CC | `build_dmg.sh` 加 `--options runtime` + 公證 hook（若需要本機測試） |

---

## 5. 這輪先不做的事

M4 目前**不排入立即工作**——善彰已定案 M2（帳號連結）是首要。M4 待 M2/M3 完成、
且善彰有空親自去 ASC 建憑證時再啟動，不佔用現在的開發資源。
