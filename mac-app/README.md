# Pocket (macOS menu-bar app)

裝在跑 Claude Code / Codex / Hermes 的那台 Mac 上,讓手機**零設定連線**。
設計成**可打包成安裝檔**的結構,方便未來商業化推廣。

## 使用者流程(目標)
**下載 `.dmg` → 拖進 Applications → 開啟 → 選單列出現圖示 → 顯示「下載 App QR」→ 手機掃碼裝 App → 收工。**

## 現在做到哪
正式底盤(v0.2,可編譯、簽章、公證與安裝):
- 選單列 App(AppKit agent,`LSUIElement`,無 Dock 圖示)
- 狀態列:品牌「P」圖示(紅底白 P 的 template 版,自動適應淺/深色),每 8 秒探測 `pocket.tsai.cash` 可達性,連線狀態顯示在滑鼠停留的 tooltip(`Pocket — ● 已連線 / ○ 離線`)
- 選單:連線/登入狀態、**執行環境**警示、控制台、帳號連結、**下載手機 App QR**(CoreImage 產生)、狀態列隱藏、結束
- **服務 supervise**:啟動/停止本機 `bridge`(uvicorn)+ `cloudflared`(pocket tunnel)
- **打包**:`packaging/build_dmg.sh` → `Pocket.app` + `Pocket-<ver>.dmg`

## M1 新增(登入 + 配對 QR + 發佈)
- **首次啟動引導**:第一次開啟彈出視窗(歡迎 → Apple 登入 → 配對 QR)。用
  `UserDefaults` 的 `pocketConnectOnboarded` 記住,之後直接進選單列;選單「重新設定…」
  可再跑一次。
- **Sign in with Apple(桌面版)**:Development / Mac App Store 簽章使用
  `ASAuthorizationController`；Developer ID 公開版自動改走瀏覽器 Web Sign in with
  Apple。兩條路徑登入後都只把 account session 存進本機 Keychain
  (`kSecClassGenericPassword`,不同步 iCloud)。
- **配對 QR**:登入後呼叫 `POST /app/v1/pair/new`(bridge bearer + account session),
  出一次性 code,組成 `pocket://pair?scheme=https&host=<host>&code=<code>`(與
  `pocket-pair.py` 同格式),畫成 QR;5 分鐘倒數,過期可重新產生。未登入的選單項顯示
  「請先登入」。
- **發佈**:push tag `v*.*.*` → `.github/workflows/release.yml` 在 ARM64 macOS
  runner 測試、Developer ID 簽章、公證、staple、Gatekeeper 驗收，再上傳 `.dmg`
  與 SHA-256 到 GitHub Release。本機出版本用
  `packaging/cut_release.sh <ver|patch|minor|major>`。

## Sign in with Apple — Development 簽章設定
Bundle id 為 **`com.pocketagent.desktop`**(Team `4F8B93R3SH`)。正式登入需要用真實憑證
+ provisioning profile 簽章,以下已在善彰帳號建好:
- **App ID** `com.pocketagent.desktop`(ASC id `6SUL2W23HK`),已啟用 **Sign in with
  Apple** capability(primary app consent)。
- **Mac Development profile** 「Pocket Agent Desktop Mac Dev」,綁本機裝置 + 開發憑證,已裝到
  `~/Library/MobileDevice/Provisioning Profiles/`。
- **憑證**:`Apple Development: Created via API`(本機指紋
  `F0685308…`)。簽章用:
  ```bash
  SIGN_IDENTITY="F0685308E5B7BDADBA007D2D4DF773E117FFDC9D" ./packaging/build_dmg.sh
  ```
  `build_dmg.sh` 會把上述 profile 嵌入 `Contents/embedded.provisionprofile`，並直接從
  profile 派生 Apple 核准的 entitlements。
- **audience**:bridge 的 `APPLE_ID_AUDIENCES` 已含 `com.pocketagent.ios` 與
  `com.pocketagent.desktop`(見 `~/Library/LaunchAgents/ai.studio.hermes-bridge.plist`)。

> Development 簽章可在註冊裝置跑原生 Apple 登入。對外 `.dmg` 使用 Developer ID
> + 公證，並以 Developer ID profile 啟用 Production CloudKit；依 Apple 的 macOS
> capability matrix，Developer ID 不支援原生 Sign in with Apple entitlement。Pocket
> 會依目前簽章的 entitlement 自動切到 Web Sign in with Apple；原生路徑留給
> Development / Mac App Store。

## 結構
```
mac-app/
├── Package.swift                          # SwiftPM executable(免 Xcode)
├── Sources/PocketConnect/
│   ├── main.swift                         # 選單列 App + supervisor + 選單/QR 視窗
│   ├── Onboarding.swift                   # 首次引導視窗 + 配對 QR 視圖 + 倒數
│   ├── AppleSignIn.swift                  # ASAuthorizationController 原生登入
│   ├── WebAppleSignIn.swift               # Developer ID 瀏覽器登入 + 本機安全輪詢
│   ├── Bridge.swift                       # BRIDGE_TOKEN 讀取 + Apple auth、pair/new client
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
- [x] **公開版 Apple 登入底盤**:Developer ID 自動走瀏覽器 callback + 本機輪詢；
  Apple Portal Services ID / key、固定網域 broker 與 Bridge runtime secrets 已部署，
  真人 Apple Account 的 callback、一次性 proof、Bridge 驗簽與 account session
  建立已完成端到端驗收。
- [x] **Bundling cloudflared**:`build_dmg.sh` 會把 Homebrew 的實體 binary 打包進
  `Contents/Resources` 並一起簽章。
- [ ] **Bundling bridge runtime**:全新使用者仍需要 bridge runtime 安裝／啟動方案。
- [ ] **登入自啟**:`SMAppService`(Login Item),讓服務開機常駐。
- [ ] **連上自動開好 Hermes(商業)**:啟動時拉起 personas + 連接器。
- [x] **簽章 & 公證(Signing & notarization)**:Developer ID 憑證 + 正式 CloudKit
  provisioning profile + `notarytool` 公證流程已接通。
- [x] **狀態列圖示**:已使用品牌 template image，App 亦包含 `AppIcon.icns`。

## 商業化定位
- OSS:這個桌面 App 的「區網直連 / BYO tunnel」基本款。
- 善字營(商業):託管 relay + 帳號 + 連上自動開好 Hermes + 一鍵安裝。便利性與託管 = 付費價值。
