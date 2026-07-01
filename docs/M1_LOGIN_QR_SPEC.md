# Pocket Connect M1 — 安裝 → 登入 → QR 串接

## 背景
- Repo: `~/apps/pocket-connect`(已推上 `git@github.com:cashtsai/pocket-connect.git`,private)
- 現況:`mac-app/` 是 SwiftPM 選單列 App 雛形(v0.1),已可 `swift build -c release` +
  `packaging/build_dmg.sh` 產出 `.dmg`,但只有「supervise bridge/tunnel + 顯示下載App QR」
  功能,沒有登入、沒有配對邏輯。
- 後端已就緒,今天剛合併上 production bridge(`~/apps/hermes-openwebui-bridge`,main
  分支,已重啟生效):
  - `POST /app/v1/auth/apple` — 驗 Apple identityToken,upsert 使用者,回
    `{user, session:{token, expires_at}}`
  - `GET /app/v1/account` — 帶 `X-Pocket-Account-Session: <token>`,回使用者+已配對裝置
  - `POST /app/v1/pair/new` — 帶 bridge bearer token + 上面的 account session,回
    `{code, ttl, account_bound}`(一次性配對碼,5 分鐘有效,絕不回傳裸 token)
  - `POST /app/v1/pair/claim` — 手機端用 code 換自己的 device token
  - 規格文件:`~/apps/hermes-openwebui-bridge/docs/APP_BRIDGE_CONTRACT.md`
    (`### POST /app/v1/auth/apple` 到 `### POST /app/v1/devices/{id}/revoke` 這幾節)
- 手機端(pocketagent repo)已經有一樣的 Apple Sign In + Keychain 流程可以參考:
  `Scarf iOS/Studio/StudioOnboarding.swift`、`Scarf iOS/Studio/StudioAccount.swift`。
  桌面端的登入語意要跟手機端一致(同一個 Apple ID 登入 → 同一個 apple_user_id)。

## 目標(M1 三件事)
### 1. 安裝檔分發(GitHub Releases)
- 在 `pocket-connect` repo 加 `.github/workflows/release.yml`:
  - 觸發:push tag `v*.*.*`
  - macOS runner(`macos-14` 或最新可用),`swift build -c release` →
    跑既有 `mac-app/packaging/build_dmg.sh` → 產出 `PocketConnect-<ver>.dmg`
  - 用 `gh release create` 或 `softprops/action-gh-release` 把 dmg 上傳成該 tag 的
    release asset
  - ad-hoc codesign 現況先保留(不做 Developer ID 簽章/公證,README 已註記這是待辦,
    不要在這次範圍內動)
- 補一個本機也能跑的手動 release 腳本(`mac-app/packaging/cut_release.sh` 或類似),
  方便善彰或 XCash 之後手動出版本:bump `Info.plist` 版號 → build → tag → push tag。

### 2. 安裝完成 = 首次啟動引導(first-run onboarding)
- 目前 App 一啟動就直接進選單列常駐畫面。改成:
  - 偵測是否為首次啟動(用 `UserDefaults` 記一個 flag,例如 `pocketConnectOnboarded`)
  - 首次啟動彈出一個小型視窗(可用現有 `NSWindow` 手法,不必上 SwiftUI),流程:
    1. 歡迎畫面,簡短說明「這台 Mac 會當你的 Pocket 執行主機」
    2. 「使用 Apple 登入」按鈕(見下一節)
    3. 登入成功後直接進「顯示配對 QR」畫面(見下一節),不要讓使用者自己再點選單找
  - 完成一次後,之後啟動直接進選單列(現有行為),不再彈引導視窗,除非使用者從選單
    手動選「重新設定」

### 3. 登入設計(Sign in with Apple,桌面版)
- AppKit/macOS 沒有 SwiftUI 的 `SignInWithAppleButton`,要用
  `ASAuthorizationAppleIDProvider` + `ASAuthorizationController`(`AuthenticationServices`
  framework),走原生 `NSViewController`/`NSWindow` 呈現。
- 拿到 `ASAuthorizationAppleIDCredential` 後:
  - 取 `credential.user`(= apple_user_id)、`credential.identityToken`(Data → utf8
    String)、`credential.fullName`(僅首次登入會有)
  - `POST` 到 bridge:`https://pocket.tsai.cash/app/v1/auth/apple`(正式環境走公網
    tunnel host,不要寫死 127.0.0.1;host 目前來自 `Config.connectURL`,可以複用)
    body: `{"apple_user_id": ..., "identityToken": ..., "display_name": ..., "email": ...}`
  - 收到 `session.token` 後存進本機 Keychain(桌面端用一般
    `kSecClassGenericPassword`即可,不需要 `kSecAttrSynchronizable`;桌面本來就是
    憑證的家,不用跨機同步這份 session token)
  - 登入失敗(非 200)要在畫面上顯示簡短錯誤,不要 silently fail

### 4. QR 串接(桌面出碼 → 手機掃描配對)
- 登入成功後,呼叫 `POST /app/v1/pair/new`,headers 需要兩個:
  - `Authorization: Bearer <BRIDGE_TOKEN>`(桌面本地讀 LaunchAgent plist 或環境變數,
    參考現有 `hermes-openwebui-bridge/pocket-pair.py` 的 `read_token()` 寫法邏輯,
    port 到 Swift)
  - `X-Pocket-Account-Session: <上一步拿到的 session token>`
- 拿到 `{code, ttl}` 後,組出跟現有 `pocket-pair.py` 一致的 QR payload 格式:
  `pocket://pair?scheme=https&host=<funnel-host>&code=<code>`
- 用現有 `qr(_:size:)`(CoreImage QR 產生,main.swift 裡已經有)畫出這個 QR,取代/整合
  現有「顯示下載 App QR」那個選單項——變成兩張 QR 都要有:
  1. 「下載 App」QR(現有,不變)
  2. 「配對這台桌機」QR(新的,登入後才會出現在選單,沒登入則顯示「請先登入」)
- 5 分鐘倒數:code 過期後 QR 要失效並提示「已過期,重新產生」(可以簡單做:視窗顯示
  剩餘秒數,歸零後按鈕變「重新產生配對碼」)

## 明確不做(out of scope,不要順手做)
- Developer ID 簽章 / notarization(README 已列為獨立待辦)
- 把 cloudflared / bridge runtime 打包進 `.app`(README 已列為獨立待辦「Bundling deps」)
- 登入自啟(`SMAppService` login item)
- iOS App(`pocketagent` repo)本身的任何修改 —— 這次只動 `pocket-connect`

## 驗收標準
1. `swift build -c release` 過、`packaging/build_dmg.sh` 能出 `.dmg`
2. 本機跑起來:選單列圖示存在,首次啟動彈出引導視窗
3. 「使用 Apple 登入」可以完成一次真實登入(善彰的 Apple ID),bridge 端
   `/app/v1/account` 能查到這個 apple_user_id 已建立
4. 登入後選單能顯示「配對這台桌機」QR,QR payload 格式跟 `pocket-pair.py` 一致
5. commit 到獨立 branch(例如 `feature/desktop-login-qr`),push 上
   `github.com:cashtsai/pocket-connect`,不要直接推 main
6. 完工回報要列:改了哪些檔案、swift build/QR 實測結果、有沒有卡在需要善彰提供的
   東西(例如 Apple Developer Team ID / entitlements 需要善彰的開發者帳號設定)

## 已知可能的坑
- Sign in with Apple 在 macOS App 需要正確的 entitlements
  (`com.apple.developer.applesignin`)+ 對應的 provisioning/signing,ad-hoc 簽名
  可能無法完整測試真實登入(Apple 有時候要求正式 Team ID)。如果卡在這裡,回報清楚
  「需要善彰的 Apple Developer Team ID 才能繼續」,不要用假資料硬過關。
- bridge 目前掛在 `cashtsai/hermes-studio-bridge`(private repo,repo 名跟資料夾
  `hermes-openwebui-bridge` 不同,不要搞混)。
- 正式環境 host 是 `https://pocket.tsai.cash`(Cloudflare Tunnel),不是
  `cashcamp-1.tail905550.ts.net`(那是 `pocket-pair.py` 裡的 Tailscale Funnel 舊值,
  桌面 App 要用 Cloudflare tunnel 這個當預設,因為手機不裝 Tailscale 也要能連)。
