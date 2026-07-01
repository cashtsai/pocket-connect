# Pocket Connect 商業化施工規格

> 2026-07-01 · XCash 整理。目標：讓「裝 Hermes → 裝桌面 App → 掃碼配對」對消費者是**真的**可行，不是開發者原型。

---

## 0. 現況基線（今天做到哪）

- ✅ Sign in with Apple 在**開發者本機**簽章下可正確啟動、可觸發登入面板（bundle id `com.pocketagent.desktop`）
- ✅ bridge `/pair/new` `/pair/claim` 骨架存在（一次性碼、per-device token）
- ❌ 簽章綁死在善彰的 ASC 帳號 + 這台機器的 Provisioning Profile，別人裝了會被 Gatekeeper 擋
- ❌ App 不含 bridge/cloudflared，使用者要自己先裝好整套 Hermes 環境
- ❌ bridge 沒有 `/app/v1/auth/apple` 正式端點，identityToken 沒有驗證、沒有 `apple_user_id` 帳號表
- ❌ 沒人真的用手機掃過 QR 走完配對

---

## 1. Hermes 使用者到底要怎麼用這個工具？（先想清楚兩種客群）

### 客群 A：技術使用者 / OSS 自架（現有 `hermes setup` 使用者）
```
1. 使用者自己 pip/pipx install hermes-agent，跑 `hermes setup` 走完精靈（模型、平台、terminal）
2. 另外下載 Pocket Connect.dmg，拖進 Applications，打開
3. 選單列出現圖示，Apple 登入 → 綁定這台機器的 bridge
4. 手機裝 Pocket App，掃碼配對
```
這條路 Pocket Connect **不需要打包 Hermes 本體**，只需要偵測「這台機器有沒有裝 Hermes + bridge」，沒有的話引導去跑 `hermes setup` 或給一鍵安裝腳本。**這是 OSS 版該做的最小整合**。

### 客群 B：善字營商業客戶（真正的「一鍵」體驗，你的核心商業模式）
```
1. 客戶收到/購買一台已預先灌好 Hermes + bridge + Pocket Connect 的 Mac mini（或你出一支「Pocket 商業安裝器」幫他們裝好整套）
2. 開機 → 選單列圖示已在 → 點 Apple 登入
3. 手機下載 Pocket App，掃碼配對
4. 完成，Hermes 在背景常駐運作
```
這條路才是你原本設想的「消費者只要裝桌面 App、配對完就好」——但前提是**背後的 Hermes/bridge 是你事先幫他裝好、或用商業安裝器一次裝完**，不是消費者自己去 `pip install`。

### 建議：現階段先把 A 做完整，B 用「商業安裝器」包一層
不用把 Hermes 本體塞進 Pocket Connect.app（會讓 app 肥大、且 Hermes 更新要跟著重新打包，維護成本高）。改成：
- Pocket Connect.app 啟動時偵測 `hermes` command + bridge 是否已配置好
- 沒有的話彈出「需要先安裝 Hermes」引導視窗，一鍵跑背景腳本（`pip install hermes-agent && hermes setup --quick` 之類，或你們自己包的 installer pkg）
- 裝完之後才進入 Apple 登入 / QR 配對流程

這樣 App 保持輕量，商業客戶感受到的仍然是「一鍵」，因為引導視窗把安裝過程包起來了。

---

## 2. 三個缺口的施工規格

### 缺口 1：Developer ID 簽章 + 公證（讓任意 Mac 能裝）

| 項目 | 內容 |
|---|---|
| 需要 | 善彰的 Apple Developer Program 帳號要有 **Developer ID Application** 憑證（不同於現在用的 Development 憑證）|
| 產出 | `codesign --sign "Developer ID Application: XXX (TEAMID)"` 簽出的 `.app`，再用 `xcrun notarytool submit` 送 Apple 公證，通過後 `xcrun stapler staple` 把公證票據釘進 `.app`/`.dmg` |
| 影響檔案 | `packaging/build_dmg.sh`（加 `--options runtime` hardened runtime + notarize 步驟）、CI workflow `release.yml`（GitHub Actions runner 需要匯入 Developer ID 憑證到 keychain，走 secrets） |
| 阻塞點 | 需要善彰在 ASC 網站手動建立 Developer ID Application 憑證並下載 `.p12`，這步是帳號層級操作，**必須善彰本人做**，子程序/XCash 不能代勞（帳號憑證下載頁需要人親自登入） |
| 驗收 | 用另一台**沒註冊過**的 Mac（或全新使用者帳號）安裝 `.dmg`，Gatekeeper 不擋、雙擊直接開 |
| 負責 | Codex（改 build script + CI）／善彰（建憑證，一次性） |

### 缺口 2：偵測/引導安裝 Hermes 依賴（不打包本體）

| 項目 | 內容 |
|---|---|
| 首次啟動邏輯 | `Onboarding.swift` 加一個「環境檢查」步驟：`which hermes`、`curl 127.0.0.1:8081/health`（bridge 是否已跑），兩者都通過才進登入流程 |
| 缺失時 | 顯示「需要先安裝 Hermes」畫面，按鈕觸發背景腳本（用 `Process` 呼叫一支 `install_hermes.sh`，裡面跑 `pip install --user hermes-agent` + `hermes setup --quick` + 產生 bridge LaunchAgent） |
| 商業客戶版 | 提供獨立「Pocket 商業安裝器」`.pkg`，postinstall script 直接把 Hermes + bridge + Pocket Connect 一次裝好、開機自啟；Pocket Connect.app 只需認得「已經裝好」不用再引導 |
| 阻塞點 | 需要先定案 Hermes 本體的**授權/計費模型**（客戶用自己的 CC/Codex API key，還是善字營代管）——這決定 installer 要不要順便帶 API key 輸入頁 |
| 驗收 | 全新機器（無 Hermes）跑一次引導，全自動裝完到能登入配對 |
| 負責 | Codex（installer script）／CC（Onboarding.swift 環境檢查 UI）／XCash（統籌+定案授權模型後給規格） |

### 缺口 3：後端帳號表 + Apple identityToken 驗證

規格已經在 `~/apps/pocketagent/docs/ACCOUNT_CROSS_DEVICE_ARCH.md` §2、§7 定案，具體要做：

```sql
-- bridge 這邊新增（SQLite，state.db 或獨立 accounts.db）
CREATE TABLE users (
  apple_user_id TEXT PRIMARY KEY,
  email TEXT,
  display_name TEXT,
  created_at REAL,
  last_seen_at REAL
);
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  apple_user_id TEXT NOT NULL REFERENCES users(apple_user_id),
  device_token TEXT NOT NULL,
  platform TEXT,       -- ios | macos
  label TEXT,
  paired_at REAL,
  revoked INTEGER DEFAULT 0
);
```

| 端點 | 作用 | 驗證 |
|---|---|---|
| `POST /app/v1/auth/apple` | 收 `identityToken`(JWT) + `apple_user_id`，驗證後 upsert `users` | 用 Apple 公鑰 (`https://appleid.apple.com/auth/keys`) 驗簽，確認 token 真偽，避免偽造 apple_user_id |
| `GET /app/v1/account` | 回目前登入者 + 名下裝置列表 | 需要有效 session token |
| `POST /app/v1/pair/new`(既有) | 升級成「綁到 apple_user_id」而非裸 device token | — |
| `POST /app/v1/pair/claim`(既有) | 同上，claim 後寫入該 apple_user_id 底下 | — |

| 阻塞點 | 無（純後端邏輯，資源都在你自己機器上） |
| 驗收 | 兩台裝置（桌機+手機模擬）用同一 Apple ID 登入 → 後端回同一個 apple_user_id → 配對關係正確落地在 devices 表 |
| 負責 | Codex（bridge 端點 + JWT 驗證 + 資料表）｜XCash 驗收 |

---

## 3. 建議施工順序（風險最低到最高）

1. **缺口 3（後端帳號表）**——純程式碼、無帳號依賴，可以先做，不擋善彰
2. **缺口 2（偵測/引導安裝）**——次要，先把「已裝好 Hermes 情境」下的登入+配對走通，再補引導 UI
3. **缺口 1（Developer ID 簽章+公證）**——**最後做**，因為需要善彰去 ASC 網站建立新憑證（一次性但必須本人操作），且這步做完才真正具備「發布給任意人」的資格

---

## 4. 善彰想自己實測，但可能無法乾淨重裝 Hermes 的因應

不需要真的重裝 Hermes 本體來測試「消費者體驗」，用這個方式即可乾淨模擬：

- **手機端**：用你自己的 iPhone 裝 Pocket App，這步跟 Hermes 有沒有重裝無關，直接可以測「掃碼配對」
- **桌面端「假裝是新使用者」**：不用砍掉現有 Hermes，改用**另一個 macOS 使用者帳號**（系統設定 → 新增使用者）登入後在該帳號下裝 Pocket Connect.dmg，這樣 App 的 `UserDefaults`/Keychain 都是全新的，等同模擬「這台機器第一次裝」的首次引導體驗，且不影響你现在跑的 Hermes/bridge（bridge 是系統層 LaunchAgent，任何使用者帳號都連得到 `127.0.0.1:8081`）
- 這樣你可以先驗證「登入 → QR → 手機配對」全流程，不用等 installer/公證那兩塊做完

---

## 5. 分工總覽

| 線 | 這輪要做 |
|---|---|
| Codex（bridge） | 缺口 3 帳號表+端點（可立即開工）→ 缺口 2 installer script |
| CC（app） | 缺口 2 環境偵測 UI → 缺口 1 build script 改 Developer ID + notarize 流程配合 |
| 善彰 | 缺口 1：去 ASC 網站建立 Developer ID Application 憑證（一次性，我無法代勞）|
| XCash | 統籌驗收、定案 installer 授權模型、出 PR |
