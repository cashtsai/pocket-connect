# Pocket Connect

讓使用者**快速建立連線、不用過多設定**的桌面端：裝在跑 Claude Code / Codex / Hermes
的那台 Mac 上，自動托管 bridge 並對外，手機端零設定連上。

## 組成
- **`mac-app/`** — **選單列 App**（SwiftPM，無 Dock 圖示）。supervise bridge + 對外通道、
  Apple 登入、配對 QR、裝置管理、連線設定。可打包成 `.dmg` 安裝。是主力。
- **`relay/`** — 對外通道參考。用 `cloudflared` 把本機 bridge 對外；MVP 用它驗證直通。
  App 免費模式已內建自動臨時 tunnel，這個目錄是固定網址（進階）的參考。

## 現況（2026-07-23）
- ✅ **桌面 App v0.2**：品牌化控制台、Apple 登入、配對 QR、裝置清單/解除。
- ✅ **免費零設定連線**：桌面自動開 cloudflared 臨時 tunnel、掛掉自動重啟、網址經
  CloudKit 傳手機；免費模式強制開 iCloud。進階可填自己的固定網址。
- ✅ **公開發佈底盤**：`build_dmg.sh` 已能產出內含 cloudflared、Developer ID 簽章、
  Apple 公證與 stapled ticket 的 `.dmg`；Production CloudKit 與公開版 Web Sign in
  with Apple 已部署。
- ✅ **自動 Release**：`v0.2` 已由 GitHub Actions 在乾淨的 macOS runner 完成測試、
  Developer ID 簽章、Apple 公證、staple 與 Release 發布。
  [下載 Pocket-0.2.dmg](https://github.com/cashtsai/pocket-connect/releases/tag/v0.2)
  見 [`docs/M4_DEVELOPER_ID_SIGNING_SPEC.md`](docs/M4_DEVELOPER_ID_SIGNING_SPEC.md)。

## 下載安裝
1. 到 [Releases](https://github.com/cashtsai/pocket-connect/releases) 下載最新的
   `Pocket-<版本>.dmg`（可用附帶的 `.sha256` 核對）。
2. 雙擊 `.dmg` → 把 **Pocket** 拖進 **Applications**。
3. 從 Applications 打開 Pocket → 選單列出現口袋圖示（無 Dock 圖示）。

正式 `.dmg` 已用 **Developer ID 簽章 + Apple 公證（notarized）並 staple**，任何 Mac
雙擊即可安裝，不會出現「無法確認開發者」，也不需要右鍵繞過 Gatekeeper。
完整步驟、免費模式為何要開 iCloud、配對、常見狀況：**[`docs/INSTALL_FAQ.md`](docs/INSTALL_FAQ.md)**。

## 開發 / 打包
```bash
cd mac-app
swift run                          # 直接跑（選單列出現口袋圖示）
./packaging/build_dmg.sh           # 產出 build/dist/Pocket-<版本>.dmg（ad-hoc 簽）
NOTARIZE=1 ./packaging/build_dmg.sh # Developer ID 正式簽章、公證、staple
./packaging/cut_release.sh patch   # bump 版號 → tag → CI 出 Release
```
更多結構與簽章細節見 [`mac-app/README.md`](mac-app/README.md)。

## 定位（與其他專案的關係）
- **OSS**：這個桌面 App 的「區網直連 / BYO tunnel / 自動臨時 tunnel」基本款。
- **善字營（商業）**：託管 relay + 帳號 + 連上自動開好 Hermes + 一鍵安裝。便利性與託管 = 付費價值。
- 連線拓撲走「各自自架」（每人用自己的 Mac 當主機）；免費/進階兩層。
