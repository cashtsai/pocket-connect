# Pocket Connect — Relay RUNBOOK(Cloudflare Tunnel)

讓手機 App 從任何網路(4G/外網)零設定連到本機 bridge(CC / Codex / Hermes 三路),
不需 Tailscale、不需 VPS。relay = Cloudflare Tunnel(`cloudflared` 跑在本機)。

## 現況(已建好,2026-06-29)
- 網域:`tsai.cash`(Cloudflare 管理)
- 對外網址:**`https://pocket.tsai.cash`** → 本機 `http://127.0.0.1:8081`(bridge)
- 專屬 tunnel:`pocket`(id `614ad2a9-661f-42fe-a15f-6eefeac723fc`),**與既有 `fed-console-studio` tunnel 完全隔離**,不影響 console/fliper。
- 三路已實測 200:`/ccsessions`、`/codexsessions`、`/sessions`、`/app/v2/agents`。

## 手機 App 怎麼用
設定 → 連線 host 改為 `https://pocket.tsai.cash`,token 用原本那組(bridge BRIDGE_TOKEN)。完成。

---

## 當初的建立步驟(可重現)
```bash
# 1) 建專屬 tunnel
cloudflared tunnel create pocket

# 2) 設定檔 ~/.cloudflared/pocket.yml(見 pocket.yml.example;tunnel id 換成你的)
#    ingress: pocket.tsai.cash → http://127.0.0.1:8081

# 3) 路由 DNS(在 Cloudflare 自動加 CNAME)
cloudflared tunnel route dns pocket pocket.tsai.cash

# 4) 啟動
cloudflared tunnel --config ~/.cloudflared/pocket.yml run pocket
```

## 啟停 / 反悔
```bash
# 停止:殺掉該 cloudflared 行程(只殺 pocket 那支,別動 fed-console-studio)
pkill -f "pocket.yml run pocket"

# 完全移除(反悔):刪 tunnel + DNS 自行到 Cloudflare 後台刪 pocket.tsai.cash CNAME
cloudflared tunnel delete pocket
rm ~/.cloudflared/pocket.yml ~/.cloudflared/614ad2a9-*.json
```

---

## ⚠️ 兩個待處理

### 1. 常駐(persistence)
目前 tunnel 是手動 `nohup` 起的,**Mac 睡眠/重開或行程被收掉就斷**。正式要常駐,二選一:
- **LaunchAgent**(`~/Library/LaunchAgents/ai.pocket.tunnel.plist`,`RunAtLoad`+`KeepAlive`)— 需要你同意安裝常駐。
- **Mac 狀態列 App**(`../mac-app/`,規劃中)supervise bridge + cloudflared,最終取代手動。

### 2. Cloudflare Browser Integrity Check(error 1010)
測試時 bot UA 會被擋(1010)。一般 client(App 的 URLSession 有正常 User-Agent)會過,但建議:
- 在 Cloudflare → `pocket.tsai.cash` 關閉 **Browser Integrity Check**,或加一條 WAF skip,避免 API 請求偶發被擋。
- App 端確保送出正常 `User-Agent`。

---

## 之後升級路線
- 用 **Cloudflare Access / mTLS** 或維持 bridge token 做鑑權(目前靠 bridge BRIDGE_TOKEN)。
- 商業版(善字營):relay 改為自己的託管後端 + 帳號 + 計費 + 端到端加密;此 Cloudflare 方案先驗證直通。
