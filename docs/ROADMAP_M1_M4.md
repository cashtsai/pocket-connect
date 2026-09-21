# Pocket Connect 施工路線圖（M1–M4）

> 2026-07-01 · XCash 整理。善彰定案：**M2（登入+帳號連結）是目前首要**，要儘快做完、
> 走穩商業化根基；M3/M4 是根基走穩之後的後續強化，不搶 M2 的時間。

---

## 里程碑總覽

| 里程碑 | 名稱 | 內容一句話 | 狀態 |
|---|---|---|---|
| **M1** | 安裝 + Apple 登入 + QR 配對 | 桌面 App 裝起來、Apple ID 登入、QR 配對手機 | ✅ 已完成上線（v0.1.1） |
| **M2** | Claude/Codex 帳號連結 | 官方 CLI OAuth 觸發 + 狀態顯示，免填 API key | ✅ 已完成（控制台「AI 引擎」卡片） |
| **M3** | 環境偵測 + 引導安裝 | 偵測 Hermes/bridge 是否就緒，缺的話引導裝好 | ✅ 已完成（2026-08-18，as-built 見 spec §7） |
| **M4** | Developer ID 簽章 + 公證 | 讓任意 Mac（非開發者本機）都能安裝，不被 Gatekeeper 擋 | ✅ 已完成（v0.2 已公證發行）；唯一還開著的是「全新 Mac 實機驗收」 |

> 2026-08-18：M1–M4 全數施工完成。剩下的不是「還沒寫的程式」，而是兩件需要 owner
> 本人的事：**① 在一台真的乾淨的 Mac 上跑完整條啟動路徑**、**② 拍板要不要把 bridge
> payload 打進 `.dmg`**（`BUNDLE_BRIDGE=1`）。見 `HANDOFF.md` §5。

---

## 為什麼是這個順序

商業化根基 = 「使用者能不能順利登入、綁定好自己的 AI 帳號」。M1+M2 做完，一個使用者
（哪怕只是善彰自己）就能完整跑一次「裝 App → Apple 登入 → 連結 Claude/Codex → QR 配對手機」
全流程，這是**最小可用商業閉環**。

M3（環境偵測引導安裝）跟 M4（讓任意人都能裝）都是「規模化到更多使用者」才需要的強化，
不影響善彰自己或第一批熟悉環境的使用者能不能用——所以排在 M2 後面，不搶當前資源。

---

## M2 詳情

見 `M2_ACCOUNT_LINKING_SPEC.md`（方案 B：官方 CLI OAuth，非 API key 填寫）。已完成：
`AgentCLI.swift` + `AgentConnect.swift`，控制台「AI 引擎」卡片顯示三態並可一鍵連接。
規格 §6 提到「App 內建 CLI 安裝引導」留給 M3——已在 M3 的環境檢查清單裡補上
（未安裝 → warning + 可複製安裝指令 + 官網連結）。

---

## M3 詳情

見 `M3_ENV_DETECTION_SPEC.md`（承接 `COMMERCIALIZATION_SPEC.md` 缺口 2 的內容）。

一句話：App 啟動時偵測 python / bridge 程式 / LaunchAgent / bridge health / 金鑰 /
AI CLI，沒裝好就在登入前先擋一頁檢查清單，能自動修的一鍵修。**實際做出來的東西與原
規格有出入（狀態從三態變七態、安裝腳本沿用 bridge repo 現成的
`deploy/install-local-bridge.sh`），以 spec §7「as-built」為準。**

---

## M4 詳情

見 `M4_DEVELOPER_ID_SIGNING_SPEC.md`（承接 `COMMERCIALIZATION_SPEC.md` 缺口 1 的內容）。

一句話：Developer ID Application 憑證簽章 + 公證，讓 `.dmg` 在任何一台沒註冊過的 Mac
上都能直接雙擊開啟，不被 Gatekeeper 擋。**唯一的阻塞點是善彰要親自去 Apple Developer
網站建立憑證**（帳號層級操作，任何子程序都無法代勞）。

---

## 分工總覽（M2 起）

| 里程碑 | Codex（bridge） | CC（app） | 善彰 |
|---|---|---|---|
| M2 | — （官方 CLI 在本機，不經 bridge） | `AccountLinking.swift` + UI | 驗收時實測一次真實 OAuth |
| M3 | ~~installer script~~（沿用現成的 `deploy/install-local-bridge.sh`，bridge 端無需改動） | ✅ 環境偵測 + bootstrap + UI | 全新 Mac 實機驗收 |
| M4 | CI workflow 改 Developer ID + notarize | build script 加 `--options runtime` | **去 ASC 建 Developer ID Application 憑證（一次性，必須本人）** |
