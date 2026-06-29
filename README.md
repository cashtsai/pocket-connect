# Pocket Connect

讓使用者**快速建立連線、不用過多設定**的桌面端方案:裝在跑 Claude Code / Codex / Hermes 的那台 Mac 上,自動托管 bridge 並對外,手機端零設定連上。

## 組成
- **`relay/`** — 對外通道。目前用 **Cloudflare Tunnel**(`cloudflared`)把本機 bridge 對外成 `https://pocket.tsai.cash`。見 [`relay/RUNBOOK.md`](relay/RUNBOOK.md)。
- **`mac-app/`** — (規劃中)**Mac 狀態列 App**,supervise bridge + cloudflared、顯示連線狀態/網址、(商業版)連上時自動開好 Hermes。

## 現況(2026-06-29)
- ✅ Cloudflare Tunnel 已建,**CC / Codex / Hermes 三路**從公網實測 200。
- ⏳ 常駐(LaunchAgent 或狀態列 App)、Browser Integrity Check 調整 — 見 RUNBOOK「待處理」。
- ⏳ Mac 狀態列 App 雛形未開始。

## 定位(與其他專案的關係)
- **OSS 框架**(CC+Codex)、**善字營**(商業 = Hermes 整合 + 託管後端)的拆分見 App 端的架構討論。
- 本專案 = 「快速連線」桌面層。MVP 先用 Cloudflare Tunnel **驗證直通**(無帳號);商業版再換成自家託管 relay + 帳號/計費 + 端到端加密。

## 手機端怎麼連
設定 → host = `https://pocket.tsai.cash`,token 用既有 BRIDGE_TOKEN。
