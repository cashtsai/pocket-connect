# 免費連線（零設定）實作清單

> 目標：**免費仔 = 登入 → 掃 QR → 直接用**，不用自己的網域/tunnel。
> 進階使用者才填自己的固定網址。受眾多是「半桶水 Hermes 使用者」，主力情境是在家用。

---

## 0. 現況：已內建的部分（不用重做）

`PocketConnectKit/HostCandidates.swift` 已經會蒐集連線路徑，**best-first 排序**：

```
tailnet(100.x) → LAN(192.168.x / 10.x / 172.16-31.x) → 公開 tunnel URL
```

手機拿到這串後會**自動挑第一條通的直連**（CloudKit 不轉流量）。所以：

| 情境 | 免費仔現在 | 靠什麼 |
|---|---|---|
| 在家 / 同一個 wifi | ✅ 已能用 | LAN 自動探測（已內建） |
| 有裝 Tailscale | ✅ 已能用 | tailnet 自動探測（已內建） |
| 出門 + 沒 Tailscale | ❌ 缺 | 需要公開 tunnel |

**唯一缺口 = 出門且沒 Tailscale 的公開 tunnel。**

---

## 1. 要做：免費自動臨時 tunnel

免費版在使用者**沒設自己的網址**時，桌面自動開一條 **cloudflared 臨時 tunnel**（`trycloudflare.com`，免帳號、免網域），塞進上面的候選清單當「出門備援」。

- [ ] **打包 cloudflared** 進 `.app`（免費仔機器上不一定有）。約 ~30MB。放 `Contents/Resources/cloudflared`，`build_dmg.sh` 複製進去。
- [ ] **桌面自動跑 quick tunnel**：`cloudflared tunnel --url http://127.0.0.1:8081`，從 stderr 解析出 `https://<random>.trycloudflare.com`。
- [ ] **監看 process**：掛了自動重開；app 結束時收掉。
- [ ] 這條只在「沒設自己網址」時啟用（進階使用者填了固定網址就不開）。

## 2. 要做：un-hardcode 連線網址

- [ ] `Config.connectURL` 從寫死 `pocket.tsai.cash` → 改成動態：**使用者自訂網址 > 自動 quick tunnel URL > 空**。存 `UserDefaults`。
- [ ] 配對 QR（`pocketPairingPayload`）、`authApple`、`pairNew`、`listDevices`、`revoke`、`HostCandidates.gather(tunnelURL:)` 全部改用這個動態值。
- [ ] 控制台「連線狀況」顯示目前用的是哪條（自動 tunnel / 自訂 / 區網）。

## 3. 要處理：臨時網址會變

quick tunnel 每次重開網址會換。對策（擇一或並用）：

- [x] **靠探測兜底（決策 2026-07-07）**：桌面把最新 `hostCandidates`（含新 tunnel URL + LAN）經 **CloudKit discovery** 同步給手機，手機自動跟上。
      **免費 tier 強制要求開 iCloud**：Sign in with Apple 已是必要，且 app 的 CloudKit discovery 就綁 Apple 登入模式（`permitsCloudKit == .apple`）——所以免費仔**沒開 iCloud 就擋住 / 引導他去開，不給用**（「不開不要用，不然還叫免費仔嗎」）。這樣新 tunnel URL 一定經 CloudKit 傳到手機，**不用再做非-CloudKit 更新路徑**。
- [ ] 要做：免費路徑上偵測 iCloud 帳號狀態，未開 → 擋住配對並引導開啟（`CKContainer.accountStatus`）。
- [ ] **在家以 LAN 為主**：LAN IP 相對穩定，tunnel 只當出門備援，降低「網址變」的衝擊。
- [ ] 驗收：桌面重開後，手機（在家 LAN / 出門 tunnel）都還連得到。

## 4. 要做：進階「連線設定」UI（控制台內）

前面設計過的樣子——**一個欄位為主**：

```
連線設定
  你的 Pocket 網址   [ https://your-bridge.example.com ]
  手機用這個網址連到你這台 Mac 的 Hermes。
  金鑰　● 已自動讀到（來自 Hermes 設定）      // 讀不到才冒出貼 token 欄位
            [ 測試連線 ]   [ 儲存 ]
```

- [ ] 填了 → 覆蓋自動 tunnel（進階路）。空 → 走免費自動 tunnel。
- [ ] 「測試連線」：probe 該網址，通綠燈 / 不通紅字，防呆。
- [ ] 金鑰維持自動從 `ai.studio.hermes-bridge.plist` 讀；讀不到才顯示手動貼欄位。

## 5. 分層總表（產品）

| 層 | 給誰 | 連線 | 狀態 |
|---|---|---|---|
| **免費** | 半桶水 Hermes 使用者 | LAN/tailnet（內建）+ 自動臨時 tunnel（本清單） | 部分已內建 |
| **進階** | 自己有網域的人 | 填自己的固定網址 | §4 |
| **一鍵版** | 不會架 Hermes 的一般人（未來） | 打包 bridge+Hermes+cloudflared 進安裝檔 + 發放後端 | 之後 |

## 6. 決策點（動工前確認）

- [ ] cloudflared **打包進 app** vs 偵測系統已裝？（免費仔多半沒裝 → 傾向打包）
- [ ] quick tunnel 的**可靠度/速率限制**可接受嗎？（Cloudflare 免費服務、非正式 SLA；個人用通常 OK）
- [x] ~~CloudKit discovery 傳 hostCandidates 給手機？~~ **已決策**：免費 tier 強制開 iCloud（見 §3），CloudKit 就是傳遞管道，不另做備援。

## 7. 建議做的順序

1. §1 打包 cloudflared + 桌面自動跑 quick tunnel + 解析 URL
2. §2 un-hardcode connectURL（自動 tunnel 為預設）
3. §3 驗證手機探測（含桌面重開後 URL 變）→ 決定要不要補非-CloudKit 更新路徑
4. §4 進階「連線設定」UI
5. §5 測試矩陣：在家 / 出門 × 有無 Tailscale × 有無自訂網址

---

_關聯記憶：pocket-connection-topology（拓撲 A 決策）、pocket-desktop-app。_
