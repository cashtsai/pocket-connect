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

## M1 新增(登入 + 配對 QR + 發佈)
- **首次啟動引導**:第一次開啟彈出視窗(歡迎 → Apple 登入 → 配對 QR)。用
  `UserDefaults` 的 `pocketConnectOnboarded` 記住,之後直接進選單列;選單「重新設定…」
  可再跑一次。
- **Sign in with Apple(桌面版)**:`ASAuthorizationAppleIDProvider` +
  `ASAuthorizationController`(原生 AppKit),登入後把 session token 存進本機 Keychain
  (`kSecClassGenericPassword`,不同步 iCloud)。
- **配對 QR**:登入後呼叫 `POST /app/v1/pair/new`(bridge bearer + account session),
  出一次性 code,組成 `pocket://pair?scheme=https&host=<host>&code=<code>`(與
  `pocket-pair.py` 同格式),畫成 QR;5 分鐘倒數,過期可重新產生。未登入的選單項顯示
  「請先登入」。
- **發佈**:push tag `v*.*.*` → `.github/workflows/release.yml` 在 macOS runner build
  → `build_dmg.sh` → 上傳 `.dmg` 成 GitHub Release。本機出版本用
  `packaging/cut_release.sh <ver|patch|minor|major>`。

## Sign in with Apple — 正式簽章設定(已就緒)
Bundle id 為 **`com.pocketagent.desktop`**(Team `4F8B93R3SH`)。正式登入需要用真實憑證
+ provisioning profile 簽章,以下已在善彰帳號建好:
- **App ID** `com.pocketagent.desktop`(ASC id `6SUL2W23HK`),已啟用 **Sign in with
  Apple** capability(primary app consent)。
- **Mac Development profile** 「Pocket Agent Desktop Mac Dev」
  (uuid `22403cda-d674-4ba6-8a2b-0e5ea908ce06`),綁本機裝置 + 開發憑證,已裝到
  `~/Library/MobileDevice/Provisioning Profiles/`。
- **憑證**:`Apple Development: Created via API`(本機指紋
  `F0685308…`)。簽章用:
  ```bash
  SIGN_IDENTITY="F0685308E5B7BDADBA007D2D4DF773E117FFDC9D" ./packaging/build_dmg.sh
  ```
  `build_dmg.sh` 會把上述 profile 嵌入 `Contents/embedded.provisionprofile` 並用
  `packaging/PocketConnect.entitlements`(`com.apple.developer.applesignin`)簽。
- **audience**:bridge 的 `APPLE_ID_AUDIENCES` 已含 `com.pocketagent.ios` 與
  `com.pocketagent.desktop`(見 `~/Library/LaunchAgents/ai.studio.hermes-bridge.plist`)。

> ⚠️ 這是 **Development** 簽章(本機/註冊裝置可跑真實 Apple 登入)。對外散佈仍需
> Developer ID + 公證(獨立待辦)。

## 結構
```
mac-app/
├── Package.swift                          # SwiftPM executable(免 Xcode)
├── Sources/PocketConnect/
│   ├── main.swift                         # 選單列 App + supervisor + 選單/QR 視窗
│   ├── Onboarding.swift                   # 首次引導視窗 + 配對 QR 視圖 + 倒數
│   ├── AppleSignIn.swift                  # ASAuthorizationController 原生登入
│   ├── Bridge.swift                       # BRIDGE_TOKEN 讀取 + auth/apple、pair/new client
│   ├── Keychain.swift                     # session token 存取(generic password)
│   └── QR.swift                           # 共用 QR 產生 + 配對 payload
├── packaging/
│   ├── Info.plist                         # LSUIElement、bundle id、版本
│   ├── PocketConnect.entitlements         # Sign in with Apple entitlement
│   ├── build_dmg.sh                       # 組 .app(可帶 SIGN_IDENTITY)→ 產 .dmg
│   └── cut_release.sh                     # bump 版號 → build → tag → push
└── build/                                 # 產物(git 忽略)
```

## 開發 / 打包
```bash
cd mac-app
swift run            # 直接跑(選單列會出現 P 圖示)
./packaging/build_dmg.sh   # 產出 build/Pocket Connect.app 與 .dmg
```

## 下一步(待辦)
- [x] **首次設定 / 引導**:首次啟動引導(M1)已做,`Config` 仍寫死預設值,尚未做設定頁。
- [x] **配對 QR**:已做「配對這台桌機」帳號綁定一次性 code QR(M1)。
- [ ] **Sign in with Apple 正式簽章**:見上方卡點,需 Team ID + entitlement + bridge audience。
- [ ] **Bundling deps**:把 `cloudflared`(必要時連 bridge runtime)打包進 `Contents/Resources`,使用者不用先裝任何東西(腳本內已留註解位置)。
- [ ] **登入自啟**:`SMAppService`(Login Item),讓服務開機常駐。
- [ ] **連上自動開好 Hermes(商業)**:啟動時拉起 personas + 連接器。
- [ ] **簽章 & 公證(Signing & notarization)**:用 Developer ID 憑證簽 + `notarytool` 公證,使用者開啟才不被 Gatekeeper 擋。目前是 ad-hoc 簽(本機可跑,散佈會被擋)。
- [ ] **狀態列圖示**:換成 P logo(`Contents/Resources/AppIcon.icns` + template image)。

## 商業化定位
- OSS:這個桌面 App 的「區網直連 / BYO tunnel」基本款。
- 善字營(商業):託管 relay + 帳號 + 連上自動開好 Hermes + 一鍵安裝。便利性與託管 = 付費價值。
