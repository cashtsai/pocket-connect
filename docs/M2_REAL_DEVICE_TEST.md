# M2 帳號連結 — 真機測試步驟（善彰）

> 2026-07-12 · 測 Development-signed `Pocket.app`（含 M2 帳號連結）。
> App：`mac-app/build/Pocket.app`，DMG：`mac-app/build/Pocket-0.1.dmg`（v0.1，
> bundle id `com.pocketagent.desktop`，2026-07-11 18:09 重簽）。

---

## 步驟 0：先驗機器（不過就別往下，會白做）

這是 Development build，**Apple 登入只在 provisioning profile 註冊過的 Mac 才成功**，
而「帳號連結」選單登入後才出現。目前 profile 只註冊 2 台，其中一台開頭 `00006001-…`
應該是善彰的 Mac mini。在**善彰要測的那台 Mac** 上跑：

```bash
ioreg -d2 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}'
```

- 印出 `00006001-001221D42204401E` 或 `93CDF1FD-333C-5C6C-99DB-3BE3E49799E4` → OK，往下。
- 印出別的 → **停**。這台沒註冊，Apple 登入會失敗；要先把它的 UDID 加進 Apple Developer
  的 Devices + 重簽 profile，回報 XCash 處理。

另外確認**官方 CLI 已裝、且在這台的登入 shell PATH 裡**（帳號連結靠它們）：

```bash
which claude && which codex        # 兩個都要印出路徑
claude auth status --json          # 能跑就對
codex login status                 # 能跑就對（訊息會印在 STDERR）
```

CLI 若不在標準位置（`/opt/homebrew/bin`、`/usr/local/bin`、`~/.local/*/bin`），
App 會顯示「找不到 claude/codex CLI」錯誤 —— 那是預期的錯誤畫面，不是 crash。

---

## 步驟 1：把 app 裝到善彰的 Mac

從 build 機把 DMG 傳過去（AirDrop / scp / 隨身碟都行）：

```
mac-app/build/Pocket-0.1.dmg
```

在善彰的 Mac：雙擊 DMG → 把 **Pocket** 拖進 **Applications** 資料夾 → 退出 DMG。

---

## 步驟 2：第一次開啟（過 Gatekeeper）

Development-signed 不是 App Store / 公證版，第一次會被 Gatekeeper 擋。

- 到「應用程式」對 **Pocket** 按右鍵 → **打開** → 對話框再按一次「打開」。
- 若仍被擋：系統設定 → 隱私權與安全性 → 最下方會有「仍要打開 Pocket」→ 點它。

開起來後**看選單列（螢幕右上角）**，會出現 Pocket 的口袋圖示（不是 Dock）。

---

## 步驟 3：Apple 登入

1. 點選單列的 Pocket 圖示 → 這時選單只有「登入」（還沒登入前沒有「帳號連結」）。
2. 點「登入」→ 走 Sign in with Apple → 用善彰的 Apple ID 完成。
3. 成功後再點一次選單列圖示，應該多出「**控制台**」和「**帳號連結…**」兩項。

> 若這步 Apple 登入失敗（轉圈或報錯）→ 幾乎都是步驟 0 的機器沒註冊，回報 XCash。

---

## 步驟 4：開帳號連結視窗

點選單列 → **帳號連結…**（快捷鍵 ⌘L）。跳出「連結你的 AI 帳號」視窗：

- 上方標題 + 說明「憑證由官方 CLI 自己保管，Pocket 不會碰到你的 token」。
- 兩列：**Claude Code** 和 **Codex**，各自獨立。
- 底部「**完成**」按鈕。

**冷啟動自動偵測**：視窗一開就自動查兩邊狀態。善彰這台若本來就登入過 CLI，
會直接顯示「已連結 ✓」+ email/等級 —— 這條路徑（已連結）已在 build 機驗過。

---

## 步驟 5：測「全新 OAuth 連結」流程（本輪要驗的重點）

要驗「從未連結 → 點連結 → 走瀏覽器 → App 偵測到」的完整流程，得先讓 CLI 回到未連結。
**注意：logout 會登出目前工作中的 CLI session**，測完要自己重新登入。

### 5a. Claude
```bash
claude auth logout
```
1. 回 App 視窗，Claude 列點「重新整理／重試」或重開視窗 → 應顯示「未連結」。
2. 點「**連結 Claude Code**」→ 列變「連結中…」+ spinner，自動開瀏覽器到 claude.ai 登入頁。
3. 在瀏覽器完成 OAuth（登入 + 授權）。
4. 回 App，**不用做任何事**，App 每 2 秒輪詢一次，2 分鐘內應自動變「已連結 ✓」，
   顯示 `sendtocash@gmail.com（max）`。

### 5b. Codex
```bash
codex logout
```
1. Codex 列應顯示「未連結」。
2. 點「**連結 Codex**」→「連結中…」→ 自動開瀏覽器到 ChatGPT 登入頁。
3. 瀏覽器完成 OAuth。
4. 回 App，2 分鐘內應自動變「已連結 ✓」（Codex 不顯示 email，只顯示「已登入」）。

---

## 預期結果 & 成功判斷

| 檢查項 | 成功長怎樣 |
|---|---|
| 冷啟動偵測 | 開視窗即顯示兩邊正確的已連結/未連結，不卡在「檢查中…」 |
| Claude 全新連結 | 點連結→開瀏覽器 claude.ai→完成後 2 分鐘內自動顯示「已連結 ✓」+ email +（max） |
| Codex 全新連結 | 點連結→開瀏覽器 ChatGPT→完成後 2 分鐘內自動顯示「已連結 ✓」 |
| 「完成」門檻 | 兩邊都未連結時「完成」是**灰的**（不可點）；任一邊連上就變**可點**（寬鬆版，善彰已拍板）|
| 逾時處理 | 若 2 分鐘沒完成 OAuth → 該列變「逾時，請重試」，spinner 停、可再按，**不會無限轉圈** |
| 找不到 CLI | CLI 沒裝時顯示「找不到 XX CLI，請先安裝」錯誤字，**不 crash、不空白** |
| 不影響既有流程 | Apple 登入 + QR 配對照舊能用，帳號連結是獨立新視窗 |

**整體算成功** = 上表每一列都符合，特別是 5a/5b 的「點連結→瀏覽器→自動偵測到已連結」
兩條全新流程都跑通。

---

## 失敗排查（回報 XCash 時附上）

- **Apple 登入就失敗** → 步驟 0 機器沒註冊，最常見。附上 `ioreg` 印出的 UUID。
- **點「連結」沒開瀏覽器** → 可能 GUI 程序沒 TTY 導致 CLI 內部開瀏覽器方式不同；
  回報後 XCash 改 `startLogin` 走 `open <auth-url>`（規格 §5 已預留這條退路）。
- **瀏覽器完成了但 App 一直「連結中…」到逾時** → 輪詢的 `checkStatus` 沒偵測到；
  附上該台跑 `claude auth status --json` / `codex login status`（含 STDERR）的原始輸出。
- **顯示「找不到 CLI」但明明有裝** → CLI 在非標準路徑且不在登入 shell PATH；
  附上 `which claude`、`which codex` 的輸出。

測完（尤其做過 5a/5b logout）記得重新 `claude auth login --claudeai` /
`codex login` 把工作用的 session 登回來。
