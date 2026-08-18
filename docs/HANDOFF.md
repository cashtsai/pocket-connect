# Pocket 交接文件（給接手的人）

> 更新：2026-08-18（前次 2026-07-07）。作者：Claude（與 owner 協作）。
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

### ✅ 已完成並上版：v0.2（Developer ID 簽章 + Apple 公證，已發 Release）

`v0.2` 由 GitHub Actions 在乾淨 runner 完成測試、Developer ID 簽章、公證、staple 與
Release 發布，任何 Mac 雙擊 `.dmg` 即可安裝，不會跳「無法確認開發者」。
repo 已於 2026-08 轉為 **公開 + Apache 2.0**（見 `LICENSE` / `PATENTS.md`），所以
GitHub Releases 現在就是可用的公開下載通路。細節見 `M4_DEVELOPER_ID_SIGNING_SPEC.md`。

### ✅ 已完成：M3 執行環境偵測 + bridge bootstrap（2026-08-18）

一台全新的 Mac 現在會在登入前先看到「執行環境」檢查清單，缺什麼講什麼、能自動修的
一鍵修（裝 bridge、寫 LaunchAgent、啟動、驗 `/health`），修不了的給可複製指令 +
說明連結。實作與乾跑佐證見 `M3_ENV_DETECTION_SPEC.md` §7。

### ✅ 早期里程碑：桌面控制台 v0.1
分支 `feat/desktop-control-panel-v0.1`（已 push origin）。內容：品牌化登入頁、控制台（內嵌配對 QR、bridge 來源的裝置清單＋解除、連線精簡、右上登出、右下版權 v0.1、標題列拿掉滿版）、選單收斂（連線/登入兩行狀態＋控制台/登入＋狀態列隱藏＋結束）、登入登出流程（登出關控制台回登入頁、登入成功關登入頁開控制台）、Keychain 修正、網路錯誤防呆、bridge client 加 `/pair/devices`、`/pair/revoke`。

### 🔨 手機端：Pocket iOS 1.0.0（build 148）審核中
送審中，上架後的 App Store 連結是 <https://apps.apple.com/app/id6787644476>。
桌面 app 的「下載手機 App」QR 已經指向這個連結（`Config.downloadURL`）。

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
| 免費 | 半桶水 Hermes 使用者（主力在家） | LAN/tailnet（**已內建**）+ 自動臨時 tunnel（**已內建**） | ✅ |
| 進階 | 有自己網域的人 | 填自己的固定網址（控制台「連線設定」） | ✅ |
| 一鍵版 | 不會架 Hermes 的一般人 | 安裝檔內含 cloudflared（✅）+ bridge payload（程式已就緒，`BUNDLE_BRIDGE=1` 開關預設關，等 owner 拍板） | 🟡 |

**關鍵決策：免費 tier 強制開 iCloud。** Sign in with Apple 已必要、且綁 CloudKit discovery（`permitsCloudKit == .apple`）。臨時 tunnel 網址會變，靠 CloudKit 把新 `hostCandidates` 傳給手機讓它跟上。沒開 iCloud → 擋住引導開，不給用。（所以不用另做非-CloudKit 更新路徑。）

完整清單：`docs/FREE_TIER_CONNECTION_PLAN.md`。

---

## 4. 啟動路徑（activation path）——這是產品的命脈

陌生人從 App Store 裝了手機 App 之後，必須能一路走到「手機連上他自己的 Mac」：

```
裝 Pocket.app → 選單列出現口袋 → 【執行環境檢查】→ Apple 登入 → 配對 QR → 手機掃 → 連上
                                    ↑ M3 新增的一關
```

**「執行環境」那一關是 2026-08-18 補上的，補之前這條路是斷的**：桌面 app 的 Apple 登入
是 POST 到 `http://127.0.0.1:8081/app/v1/auth/apple`，一台沒有 bridge 的 Mac 上這個
請求必然失敗，使用者只會拿到「暫時連不到伺服器，請稍後再試」——完全查不出真正原因。
現在會先把環境攤開來檢查，缺什麼講什麼。狀態機與乾跑佐證見 `M3_ENV_DETECTION_SPEC.md` §7。

連線層（免費自動 tunnel）：`TunnelManager.swift` 跑 `cloudflared tunnel --url
http://127.0.0.1:8081`（quick tunnel，免帳號免網域），解析出 `https://xxx.trycloudflare.com`
後回呼；`effectiveConnectURL = 自訂網址 ?? 自動tunnel網址 ?? 內建fallback`。
**仍未端到端實測**：手機是否真的透過 CloudKit 跟上「桌面重開後變掉的 tunnel 網址」。

### App 不再自己 spawn bridge
`Supervisor` 以前帶著寫死的 `/opt/homebrew/bin/python3` + `~/apps/hermes-openwebui-bridge`
去 spawn bridge——那是**開發機的路徑**，在別人的 Mac 上只會失敗，而且會跟 launchd 搶埠、
app 一關服務就死。2026-08-18 已移除，改由 `BridgeBootstrap` 裝 LaunchAgent（正確做法）。
`Supervisor` 現在只剩「通不通」的探測。選單也因此沒有「啟動/停止服務」那一項了。

---

## 5. 接下來要做

已完成（原本列在這裡的）：iCloud 強制（`CloudGate` + `startPairing()` 的
`CKContainer.accountStatus` 檢查）、進階「連線設定」UI、打包 cloudflared 進 `.app`。

**還沒做完的，按重要性：**

1. 🔴 **真・全新 Mac 驗收**（owner 本人做，任何子程序代勞不了）。拿一台沒參與過開發的
   Mac 或開一個全新 macOS 使用者帳號：裝 `.dmg` → 走完「執行環境 → Apple 登入 →
   配對 QR → 手機掃」。M3 的每個分支都用 `POCKET_ENV_DOCTOR` 對 TEMP prefix 乾跑過了，
   但**真的裝一次 bridge**（建 venv、pip、寫 plist、launchctl）沒有在乾淨機器上跑過。
2. 🔴 **拍板要不要把 bridge payload 打進 `.dmg`**（`BUNDLE_BRIDGE=1`）。不打的話，
   陌生人的 Mac 上「Bridge 程式」那條會是 blocked，他得自己弄一份 bridge 程式碼。
   打的話要確認授權與體積（見 `M3_ENV_DETECTION_SPEC.md` §7.4）。
3. 🟡 **端到端測試**：桌面開臨時 tunnel → 手機掃 QR 配對 → 桌面重開（網址變）→
   確認手機經 CloudKit 跟上、還連得到。若 CloudKit 傳遞不穩，再想辦法。
4. 🟡 測試矩陣：在家/出門 × 有無 Tailscale × 有無自訂網址。
5. 🟡 手機 App 上架後，確認 `Config.downloadURL`（App Store 連結）掃得到、導得對。

---

## 6. 怎麼 build / 安裝 / 測

```bash
cd ~/apps/pocket-connect/mac-app
# 編譯 + 測試
swift build -c release && swift test
# 打包 + Development 簽章（Apple 登入要它）+ 出 dmg（產物在 build/dist/）
SIGN_IDENTITY="F0685308E5B7BDADBA007D2D4DF773E117FFDC9D" ./packaging/build_dmg.sh
# 正式公開版（Developer ID + 公證 + staple）
NOTARIZE=1 ./packaging/build_dmg.sh
# 要讓全新 Mac 能一鍵裝 bridge，才加這個（預設關，見 M3 spec §7.4）
BUNDLE_BRIDGE=1 NOTARIZE=1 ./packaging/build_dmg.sh
# 乾淨安裝（規矩：殺光舊實例、只留 /Applications 一個 bundle）
pkill -x PocketConnect; rm -rf /Applications/Pocket.app
ditto build/Pocket.app /Applications/Pocket.app && rm -rf build/Pocket.app
open -a /Applications/Pocket.app
```
bridge 由 launchd 管。**開發機**上跑的是 production 的 `ai.studio.hermes-bridge`
（埠 8081）；**Pocket 自己裝的**是另一顆 `com.pocketconnect.bridge`，兩者不共用
label、安裝位置與金鑰。App 偵測到 8081 已經有健康的 bridge 就直接沿用、不重裝、不搶埠。

環境偵測要 debug 的話（只印 JSON、不開 UI）：
```bash
POCKET_ENV_DOCTOR=1 .build/arm64-apple-macosx/release/PocketConnect | jq .
```

---

## 7. 未 commit / 在飛的東西（別搞丟）

- ~~**bridge 配對碼 10 分鐘**未 commit~~ → **已解決，這條作廢**。
  2026-08-18 查證：`_PAIR_CODE_TTL = 600.0` 已經在 bridge `main` 上（隨 commit
  `66b40fc` 一起進去，該檔目前位置是 `bridge.py:154`），工作樹乾淨、沒有在飛的改動。
  當時擔心的「混著別人的 PTY 終端 WIP」那批也一併合併掉了。**不要再照舊版本這條去
  手動 commit 那一行**，會變成重複改動。
- **scarf 整合（放棄的岔路）**：`pa-hermes` 有未 commit 的 Pocket 整合改動（team/bundle 改成 owner 的 + Pocket 分頁）。決定「不塞進 scarf、改做進自家 app」，原作留著、暫不處理。
- **手機預設頭像**：`pocketagent` 的 `avatar-persona-0..3` 改成平底置中方形 + `StudioBrand.swift` 四 persona 環色，**未 commit**。

---

## 8. Owner 偏好 / 溝通

- 回覆用**中文**、少夾英文術語。
- 裝新版**一定乾淨移除舊版 + 殺光舊實例**（免得多實例搞混測試）。
- 識別資產（POCKET wordmark、Luckiest Guy 字）**一律用定案原檔，不自製**。資產位置：wordmark `pocketagent/.../pocket-wordmark.imageset`、字 `pocketagent/.../Fonts/LuckiestGuy-Regular.ttf`。
