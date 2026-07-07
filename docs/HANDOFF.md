# Pocket 交接文件（給接手的人）

> 更新：2026-07-07。作者：Claude（與 owner 協作）。
> 一句話：Pocket = 「你自架 Hermes agent 的手機遙控器」。手機當遙控，Mac 當主機，
> 登入/金鑰/資料都留在你的 Mac。目前在做「免費仔零設定就能連」。

---

## 1. 這是什麼、由哪些 repo 組成

| repo | 角色 | 平台 |
|---|---|---|
| `~/apps/pocket-connect` | **桌面主機 app**（menubar「Pocket」）+ 控制台。本文件重點。 | macOS（SwiftPM，非 Xcode） |
| `~/apps/pocketagent` | **手機 app**（iOS/macOS）＋共用套件 PocketDesign/Core。配對、聊天、探測。 | iOS/macOS（Xcode） |
| `~/apps/hermes-openwebui-bridge` | **bridge**（`uvicorn bridge:app :8081`）＋ Hermes。手機↔Mac 的 API。 | Python，launchd 管 |
| `~/apps/pa-hermes` (scarf) | Hermes 管理台（別人的產品，曾試整合後放棄，見下） | macOS/iOS（Xcode） |

桌面 app 簽章：owner 團隊 `4F8B93R3SH`，Development 憑證 `Apple Development: Created via API (7YB9Q2WYSA)`，bundle `com.pocketagent.desktop`。build 指令見 §6。

---

## 2. 目前進度

### ✅ 已完成並上版：桌面控制台 v0.1
分支 `feat/desktop-control-panel-v0.1`（已 push origin）。內容：品牌化登入頁、控制台（內嵌配對 QR、bridge 來源的裝置清單＋解除、連線精簡、右上登出、右下版權 v0.1、標題列拿掉滿版）、選單收斂（連線/登入兩行狀態＋控制台/登入＋狀態列隱藏＋結束）、登入登出流程（登出關控制台回登入頁、登入成功關登入頁開控制台）、Keychain 修正、網路錯誤防呆、bridge client 加 `/pair/devices`、`/pair/revoke`。

### 🔨 進行中（本次）：免費仔零設定連線
分支 `feat/free-tier-auto-tunnel`。**這就是「我在做啥」**。

---

## 3. 連線架構（重要，決定產品形狀）

**拓撲 = A：各自自架。** 每個使用者用自己的 Mac 當主機、自己的連線，資料各留各家。**不走**「大家都連 owner 的 Mac」或「中央 relay」。

手機連線靠 `PocketConnectKit/HostCandidates.swift`，best-first 排序：
```
tailnet(100.x) → LAN(192.168.x/10.x/172.16-31.x) → 公開 tunnel URL
```
手機拿到後自動挑第一條通的**直連**（CloudKit 不轉流量）。

**三層產品：**
| 層 | 給誰 | 連線 | 狀態 |
|---|---|---|---|
| 免費 | 半桶水 Hermes 使用者（主力在家） | LAN/tailnet（**已內建**）+ 自動臨時 tunnel（本次在做） | 進行中 |
| 進階 | 有自己網域的人 | 填自己的固定網址（設定欄位） | 待做 |
| 一鍵版 | 不會架 Hermes 的一般人 | 打包 bridge+Hermes+cloudflared 進安裝檔 + 發放後端 | 未來 |

**關鍵決策：免費 tier 強制開 iCloud。** Sign in with Apple 已必要、且綁 CloudKit discovery（`permitsCloudKit == .apple`）。臨時 tunnel 網址會變，靠 CloudKit 把新 `hostCandidates` 傳給手機讓它跟上。沒開 iCloud → 擋住引導開，不給用。（所以不用另做非-CloudKit 更新路徑。）

完整清單：`docs/FREE_TIER_CONNECTION_PLAN.md`。

---

## 4. 本次做了什麼（免費自動 tunnel 的地基）

檔案 `mac-app/Sources/PocketConnect/`：
- **`TunnelManager.swift`（新）**：跑 `cloudflared tunnel --url http://127.0.0.1:8081`（quick tunnel，免帳號免網域），從輸出解析出 `https://xxx.trycloudflare.com`，變更時回呼。已實測會產生網址、regex 抓得到。
- **`main.swift`**：加 `effectiveConnectURL = 自訂網址 ?? 自動tunnel網址 ?? 內建fallback`；`bridge` 改成 URL 變更時重建；啟動時「沒設自訂網址」就自動開 tunnel；結束時收掉。
- 把原本寫死 `cfg.connectURL` 的 5 處全部路由到 `effectiveConnectURL`（`main.swift` bridge/poll、`CloudDiscovery.swift` hostCandidates、`DashboardWindow.swift` 連線探測 x2）。

**狀態**：編譯過、tunnel 機制單獨驗過。**尚未端到端實測**（手機是否透過 CloudKit 跟上變動網址）。**尚未 live 安裝**（會把 owner 的連線從 pocket.tsai.cash 切成臨時 tunnel，怕打斷 owner 現有配對，故留給 owner 自己決定何時測裝）。

---

## 5. 接下來要做（照 FREE_TIER_CONNECTION_PLAN.md）

1. **iCloud 強制**：免費路徑用 `CKContainer.accountStatus` 偵測，沒開 iCloud → 擋配對、引導開。
2. **端到端測試**：桌面開臨時 tunnel → 手機掃 QR 配對 → 桌面重開（網址變）→ 確認手機經 CloudKit 跟上、還連得到。若 CloudKit 傳遞不穩，再想辦法。
3. **進階「連線設定」UI**：控制台加一個欄位「你的 Pocket 網址」+ 金鑰自動偵測 + 測試連線（填了就走進階、不開 tunnel）。存 UserDefaults key `pocketCustomConnectURL`（程式已讀這個 key）。
4. **打包 cloudflared** 進 `.app`（免費仔機器多半沒裝）；`build_dmg.sh` 複製進 Resources；`TunnelManager.resolveCloudflaredPath()` 已會優先找打包版。
5. 測試矩陣：在家/出門 × 有無 Tailscale × 有無自訂網址。

---

## 6. 怎麼 build / 安裝 / 測

```bash
cd ~/apps/pocket-connect/mac-app
# 編譯
swift build -c release
# 打包 + Development 簽章（Apple 登入要它）+ 出 dmg
SIGN_IDENTITY="F0685308E5B7BDADBA007D2D4DF773E117FFDC9D" ./packaging/build_dmg.sh
# 乾淨安裝（規矩：殺光舊實例、只留 /Applications 一個 bundle）
pkill -x PocketConnect; rm -rf /Applications/Pocket.app
ditto build/Pocket.app /Applications/Pocket.app && rm -rf build/Pocket.app
open -a /Applications/Pocket.app
```
bridge 由 launchd 管：`launchctl kickstart -k gui/$(id -u)/ai.studio.hermes-bridge` 可重啟。

---

## 7. 未 commit / 在飛的東西（別搞丟）

- **bridge 配對碼 10 分鐘**：`hermes-openwebui-bridge/bridge.py` 第 89 行 `_PAIR_CODE_TTL = 600.0`（原 300）。**已生效跑著但未 commit**——那份 bridge.py 混著別人的 PTY 終端 WIP（~197 行），要跟那份一起 commit 那一行，別掃到別人的。
- **scarf 整合（放棄的岔路）**：`pa-hermes` 有未 commit 的 Pocket 整合改動（team/bundle 改成 owner 的 + Pocket 分頁）。決定「不塞進 scarf、改做進自家 app」，原作留著、暫不處理。
- **手機預設頭像**：`pocketagent` 的 `avatar-persona-0..3` 改成平底置中方形 + `StudioBrand.swift` 四 persona 環色，**未 commit**。

---

## 8. Owner 偏好 / 溝通

- 回覆用**中文**、少夾英文術語。
- 裝新版**一定乾淨移除舊版 + 殺光舊實例**（免得多實例搞混測試）。
- 識別資產（POCKET wordmark、Luckiest Guy 字）**一律用定案原檔，不自製**。資產位置：wordmark `pocketagent/.../pocket-wordmark.imageset`、字 `pocketagent/.../Fonts/LuckiestGuy-Regular.ttf`。
