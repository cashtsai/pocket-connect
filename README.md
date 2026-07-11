# Pocket Connect

讓使用者**快速建立連線、不用過多設定**的桌面端：裝在跑 Claude Code / Codex / Hermes
的那台 Mac 上，自動托管 bridge 並對外，手機端零設定連上。

## 組成
- **`mac-app/`** — **選單列 App**（SwiftPM，無 Dock 圖示）。supervise bridge + 對外通道、
  Apple 登入、配對 QR、裝置管理、連線設定。可打包成 `.dmg` 安裝。是主力。
- **`relay/`** — 對外通道參考。用 `cloudflared` 把本機 bridge 對外；MVP 用它驗證直通。
  App 免費模式已內建自動臨時 tunnel，這個目錄是固定網址（進階）的參考。

## 現況（2026-07-07）
- ✅ **桌面 App v0.1**：品牌化控制台、Apple 登入、配對 QR、裝置清單/解除。
- ✅ **免費零設定連線**：桌面自動開 cloudflared 臨時 tunnel、掛掉自動重啟、網址經
  CloudKit 傳手機；免費模式強制開 iCloud。進階可填自己的固定網址。
- ✅ **打包**：`build_dmg.sh` 出簽章 `.dmg`（含打包 cloudflared）；`cut_release.sh` +
  GitHub Actions 出 Release。
- ⏳ **公開發佈**：Developer ID 簽章 + 公證（現為 Development 簽章；別台 Mac 需右鍵→打開）。
  見 [`docs/M4_DEVELOPER_ID_SIGNING_SPEC.md`](docs/M4_DEVELOPER_ID_SIGNING_SPEC.md)。

## 安裝
下載 `.dmg` → 拖進 Applications → 打開（第一次右鍵→打開繞 Gatekeeper）→ 選單列出現口袋圖示。
完整步驟、免費模式為何要開 iCloud、配對、常見狀況：**[`docs/INSTALL_FAQ.md`](docs/INSTALL_FAQ.md)**。

## 開發 / 打包
```bash
cd mac-app
swift run                          # 直接跑（選單列出現口袋圖示）
./packaging/build_dmg.sh           # 產出 build/Pocket-<版本>.dmg（ad-hoc 簽）
./packaging/cut_release.sh patch   # bump 版號 → tag → CI 出 Release
```
更多結構與簽章細節見 [`mac-app/README.md`](mac-app/README.md)。

## 定位（與其他專案的關係）
- **OSS**：這個桌面 App 的「區網直連 / BYO tunnel / 自動臨時 tunnel」基本款。
- **善字營（商業）**：託管 relay + 帳號 + 連上自動開好 Hermes + 一鍵安裝。便利性與託管 = 付費價值。
- 連線拓撲走「各自自架」（每人用自己的 Mac 當主機）；免費/進階兩層。
