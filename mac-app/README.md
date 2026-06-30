# Pocket Connect (macOS menu-bar app)

裝在跑 Claude Code / Codex / Hermes 的那台 Mac 上,讓手機**零設定連線**。
設計成**可打包成安裝檔**的結構,方便未來商業化推廣。

## 使用者流程(目標)
**下載 `.dmg` → 拖進 Applications → 開啟 → 選單列出現圖示 → 顯示「下載 App QR」→ 手機掃碼裝 App → 收工。**

## 現在做到哪
雛形(v0.1,可編譯可打包):
- 選單列 App(AppKit agent,`LSUIElement`,無 Dock 圖示)
- 狀態列:`P●`(已連線)/`P○`(離線),每 8 秒探測 `pocket.tsai.cash` 可達性
- 選單:**複製連線網址**、**顯示下載 App QR**(CoreImage 產生)、**啟動/停止服務**、結束
- **服務 supervise**:啟動/停止本機 `bridge`(uvicorn)+ `cloudflared`(pocket tunnel)
- **打包**:`packaging/build_dmg.sh` → `Pocket Connect.app` + `PocketConnect-<ver>.dmg`

## 結構
```
mac-app/
├── Package.swift                     # SwiftPM executable(免 Xcode)
├── Sources/PocketConnect/main.swift  # 選單列 App + supervisor + QR
├── packaging/
│   ├── Info.plist                    # LSUIElement、bundle id、版本
│   └── build_dmg.sh                  # 組 .app → 產 .dmg
└── build/                            # 產物(git 忽略)
```

## 開發 / 打包
```bash
cd mac-app
swift run            # 直接跑(選單列會出現 P 圖示)
./packaging/build_dmg.sh   # 產出 build/Pocket Connect.app 與 .dmg
```

## 下一步(待辦)
- [ ] **首次設定**:把 `Config`(connect URL / 下載連結 / 服務指令)改成首次啟動的設定頁,而非寫死。
- [ ] **Bundling deps**:把 `cloudflared`(必要時連 bridge runtime)打包進 `Contents/Resources`,使用者不用先裝任何東西(腳本內已留註解位置)。
- [ ] **登入自啟**:`SMAppService`(Login Item),讓服務開機常駐。
- [ ] **配對 QR(P2)**:除了「下載 App」QR,再加一個「連線」QR(host+token),手機掃了自動帶入設定。
- [ ] **連上自動開好 Hermes(商業)**:啟動時拉起 personas + 連接器。
- [ ] **簽章 & 公證(Signing & notarization)**:用 Developer ID 憑證簽 + `notarytool` 公證,使用者開啟才不被 Gatekeeper 擋。目前是 ad-hoc 簽(本機可跑,散佈會被擋)。
- [ ] **狀態列圖示**:換成 P logo(`Contents/Resources/AppIcon.icns` + template image)。

## 商業化定位
- OSS:這個桌面 App 的「區網直連 / BYO tunnel」基本款。
- 善字營(商業):託管 relay + 帳號 + 連上自動開好 Hermes + 一鍵安裝。便利性與託管 = 付費價值。
