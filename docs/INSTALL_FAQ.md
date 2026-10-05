# Pocket 桌面版 — 安裝 FAQ

> 裝在**跑 Claude Code / Codex / Hermes 的那台 Mac** 上。它會托管 bridge、自動對外，
> 讓你的手機零設定連上。這份 FAQ 涵蓋安裝、第一次設定、連線、常見狀況。

---

## 安裝

### 1. 下載並安裝
1. 下載 `Pocket-<版本>.dmg`。
2. 雙擊打開，把 **Pocket** 拖進 **Applications**。
3. 到「應用程式」打開 Pocket，選單列（螢幕右上）會出現一個口袋圖示。

### 2.「無法確認開發者 / 來自未識別的開發者」怎麼辦？
**正式版不會有這個問題。** 從 [Releases](https://github.com/cashtsai/pocket-connect/releases)
下載的 `.dmg` 已經用 Apple 的 **Developer ID 憑證簽章 + 公證（notarized）並 staple**，
任何 Mac 雙擊即可安裝。

如果你拿到的是自己 build 的 ad-hoc 版本，Gatekeeper 第一次會擋，繞法是
**在 Finder 裡對 Pocket 按右鍵（或 Control-點一下）→ 打開 → 再按一次「打開」**，
只需做這一次。

### 需求
- macOS 13（Ventura）以上，Apple Silicon。
- **Python 3.10 以上**（Pocket 用它跑 bridge）。⚠️ macOS 內建的 3.9 **跑不動** —— 用 Homebrew 裝：`brew install python`，或到 [python.org](https://www.python.org/downloads/macos/) 下載安裝器。
- 免費（零設定）模式需要這台 Mac **已登入 iCloud**（原因見下）。
- 想在手機上用 AI，這台 Mac 要自己裝好 **Claude Code** 或 **Codex** CLI 並登入
  （Pocket 不會替你安裝，但控制台會列出來、附上安裝指令）。

### 2.5 手機端 App
到 App Store 下載 **Pocket**：<https://apps.apple.com/app/id6787644476>
（桌面選單列 →「下載手機 App…」也會給你一張可以直接掃的 QR。）

---

## 第一次設定

### 3. 執行環境檢查（第一關）
第一次打開，Pocket 會先檢查這台 Mac 的執行環境，列出一張清單：

| 項目 | 說明 |
|---|---|
| Python 3.10+ | 沒有(或只有系統內建 3.9)會提示 `brew install python`；裝完重按「重新檢查」 |
| Bridge 程式 | 手機連進來的那個小服務 |
| 背景服務（LaunchAgent） | 讓 bridge 開機自動跑 |
| Bridge 服務 | 有沒有在回應 |
| BRIDGE_TOKEN | 桌面跟 bridge 之間的金鑰（安裝時自動產生） |
| Claude Code / Codex | 你的 AI 引擎，要自己裝＋登入 |

- 綠勾 = 好了；黃三角 = 還缺但不擋你；紅叉 = 一定要處理。
- 能自動裝的按 **「一鍵安裝並啟動」** 就好，Pocket 會建好環境、寫好背景服務、
  啟動並確認它有回應。裝好了會自動往下走。
- 裝不起來時會顯示錯誤，並可按 **「查看記錄檔」** 打開
  `~/Library/Logs/Pocket/install.log`。**不會默默失敗。**

> 如果這台 Mac 本來就已經跑著自己的 bridge（埠 8081 有回應），Pocket 會直接沿用它，
> 不會重裝、也不會搶那個埠。這一關會整排綠勾直接跳過。

### 3.5 登入
環境過關後：**用 Apple 登入**。登入後會直接出現「配對這台桌機」的 QR。
（登入 session 存在本機鑰匙圈，不上傳。）

### 4. 免費模式為什麼一定要開 iCloud？
免費模式下，Pocket 會在你出門、離開家用網路時，自動開一條**臨時對外通道**
（cloudflared quick tunnel）。這條通道的網址**每次桌面重開都會變**，Pocket 靠
**iCloud（CloudKit）** 把最新網址推給你手機，手機才自動跟得上。

所以：**沒開 iCloud → 配對會被擋，並提示你去開。**
開法：系統設定 → 你的 Apple ID → iCloud → 登入/開啟。

> 已經填了自己的**固定網址**（進階模式，見第 7 題）就不受此限——網址不會變，不需要 iCloud 這條傳遞管道。

### 5. 找不到金鑰（BRIDGE_TOKEN）？
Pocket 依序找：控制台手動貼的 → 環境變數 → **Pocket 自己裝的** bridge 的 LaunchAgent
（`com.pocketconnect.bridge`）→ 你原本就有的 Hermes bridge（`ai.studio.hermes-bridge`）。

用「一鍵安裝」裝的話金鑰會自動產生，不用管。若你接的是自己的 bridge，
控制台「連線設定」有一個 **貼上 BRIDGE_TOKEN** 欄位，把金鑰貼進去、儲存即可。

---

## 連線

### 6. 手機怎麼連上？
1. 桌面 Pocket 控制台按「配對新裝置」→ 出現 QR（10 分鐘有效）。登入完成時也會自動出一張。
2. 手機 App 掃這個 QR，自動完成配對。
3. 配對成功後，控制台的裝置清單會出現你的手機。

### 7. 免費自動通道 vs 自己的固定網址
控制台「連線設定」有一個網址欄位：

| 你的做法 | 行為 |
|---|---|
| **留空**（免費/預設） | 桌面自動開臨時 tunnel，出門也連得到；網址會變，靠 iCloud 傳給手機。 |
| **填自己的固定網址**（進階） | 例如 `https://pocket.tsai.cash`。覆蓋自動 tunnel，網址不變，不需要 iCloud。 |

填了固定網址可按「測試連線」確認通不通（綠燈=通）。

### 8. 在家 / 出門會用哪條線？
- **在家**：優先走區域網路（LAN）直連，最穩。
- **出門**：走自動臨時 tunnel（或你填的固定網址）。
- 手機端會自動挑通得到的那條，你不用手動切。

---

## 常見狀況

### 9. 對外通道掛了會怎樣？
Pocket 會**自動重啟**臨時 tunnel（偵測到非預期結束後幾秒內重開），並把新網址經 iCloud 更新給手機。你通常不用管。

### 10. 桌面重開後手機連不到？
- 確認這台 Mac 有登入 iCloud（免費模式必要）。
- 確認手機也登入**同一個 Apple ID** 且開了 iCloud。
- 在家的話，確認手機和這台 Mac 在同一個 Wi-Fi。
- 還是不行 → 重新配對一次（第 6 題）。

### 11. 怎麼把服務停掉？
bridge 是由系統的 launchd 管的背景服務，**結束 Pocket 不會把它關掉**（這是刻意的：
你關掉桌面視窗，手機還是連得到）。真的要停：

```bash
launchctl bootout gui/$(id -u)/com.pocketconnect.bridge
```

選單列口袋圖示 →「結束」只會關掉 Pocket 本身與它開的臨時 tunnel。

### 12. 怎麼解除安裝？
1. 選單列 →「結束」。
2. 停掉並移除背景服務：
   ```bash
   launchctl bootout gui/$(id -u)/com.pocketconnect.bridge
   rm -f ~/Library/LaunchAgents/com.pocketconnect.bridge.plist
   rm -rf ~/Library/Application\ Support/PocketConnect
   ```
3. 把 `/Applications/Pocket.app` 丟垃圾桶。
4.（可選）清 `~/Library/Logs/Pocket` 與鑰匙圈裡的 `com.pocketagent.desktop` 項目。

---

## 進階：自己出安裝包

- 出一份本機安裝包：`cd mac-app && ./packaging/build_dmg.sh` → `build/dist/Pocket-<版本>.dmg`。
- 出正式版本（bump 版號→tag→CI 上傳 Release）：`./packaging/cut_release.sh patch`。
- **公開發佈（Developer ID + 公證）**：見 `docs/M4_DEVELOPER_ID_SIGNING_SPEC.md` 與
  `mac-app/packaging/pocket-release.env.example`；備好憑證後 `NOTARIZE=1 ./packaging/build_dmg.sh`。
- **把 bridge 一起打包進去**（讓全新的 Mac 不用自己找 bridge 程式）：
  `BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh`，預設關閉，說明見
  `docs/M3_ENV_DETECTION_SPEC.md` §7.4。
