# Pocket Connect

[English](README.md) · **繁體中文**

[Pocket](https://pocket.shan.house) 的桌面端。裝在你 agent 本來就在跑的那台 Mac 上
—— Claude Code、Codex、Hermes 人格 —— 手機掃一張 QR 就配對完成。零手打網址、
零貼 token。

它負責托管本機 bridge、開一條對外通道讓你人在外面也連得回來,並發出配對 QR。

## 這裡有什麼

| | |
|---|---|
| **`mac-app/`** | 選單列 App(SwiftPM,無 Dock 圖示)。環境檢查與一鍵安裝 bridge、Apple 登入、配對 QR、裝置清單、連線設定。可打包成已簽章的 `.dmg`。這是主體。 |
| **`relay/`** | 想用自己的固定網址取代內建臨時通道時的參考資料。選配。 |

## 安裝

1. 從 [Releases](https://github.com/cashtsai/pocket-connect/releases) 下載最新的
   `Pocket-<版本>.dmg`(想核對的話附有 `.sha256`)。
2. 打開它,把 **Pocket** 拖進 **Applications**。
3. 啟動 —— 選單列會出現一個口袋圖示。**沒有** Dock 圖示。

發行版都是 **Developer ID 簽章 + Apple 公證 + staple 票據,而且 app 與磁碟映像
兩者都有**,所以任何 Mac 都裝得起來,包含離線、或公司網路擋掉 Apple 公證服務的情況。

> v0.8.0 之前**只有磁碟映像帶票據**,所以 app 本身在沒有網路時第一次啟動仍可能被
> Gatekeeper 擋下。已修;`packaging/build_dmg.sh` 現在只要少任何一張票據就拒絕完成。

**另外你要自己準備**,Pocket 不會替你裝:

- **Python 3.10 以上** —— macOS 內建的是 3.9,跑不動 bridge。`brew install python`。
- **Claude Code 與/或 Codex**,裝好並登入。Pocket 只讀它們的登入狀態,
  **從不碰它們的憑證**。

完整流程、免費模式為什麼要開 iCloud、配對、常見狀況:
**[`docs/INSTALL_FAQ.md`](docs/INSTALL_FAQ.md)**。
手機 App 本身的問題在[官網的常見問題](https://pocket.shan.house/#faq)。

## 連線方式

手機要連到你的 Mac,兩條路:

- **免費、零設定** —— 桌面端自動開一條 Cloudflare 臨時通道,掉了會自己重開。
  網址每次重開都會變,所以重啟之後要重掃一張 QR。
- **你自己的固定網址** —— 在「連線設定」填 Tailscale 位址或你自己的反向代理。
  網址永遠不變,而且免費模式那個 iCloud 要求也不再適用。

另外 bridge 自己還有一個**免登入的配對頁** —— 安裝器會在輸出的最後印出完整連結。
那條路不需要 Apple 登入、也不需要 iCloud,是最短的配對方式。

## 開發

```bash
cd mac-app
swift build && swift test
swift run                            # 選單列出現圖示

./packaging/build_dmg.sh             # ad-hoc 簽章,本機測試用
NOTARIZE=1 BUNDLE_BRIDGE=1 ./packaging/build_dmg.sh   # 正式那顆
```

**發版是本機做的,不是 CI**:

```bash
./packaging/cut_release.sh minor     # 升版號、tag、推送 —— 跑完會告訴你還剩什麼
gh release create "vX.Y.Z" build/dist/Pocket-X.Y.Z.dmg build/dist/Pocket-X.Y.Z.dmg.sha256 ...
./packaging/verify_release.sh vX.Y.Z # 驗使用者真的會下載到的那顆
```

CI 永不碰 release 資產,只跑測試與確認 DMG 組得起來。理由寫在
`.github/workflows/release.yml`:CI 連不到私有的 bridge repo,它建的 DMG 裡**沒有
bridge**,而且曾兩次跟本機正貨搶著掛上 `releases/latest`。

**上傳完一定要跑 `verify_release.sh`。** 它會下載已發布的資產,檢查簽章、公證、
兩張 staple 票據與內含的 payload —— **本機那顆過了,不能證明上傳的那顆也過**。

結構與簽章細節:[`mac-app/README.md`](mac-app/README.md)。

## 授權

**Apache License 2.0**(見 [`LICENSE`](LICENSE))—— 永久、免權利金、含明確專利授權。
自由 fork、修改、商用;只請保留授權與著作權標示。

專利部分另附一份 Tesla 式的善意承諾(見 [`PATENTS.md`](PATENTS.md)):**只要你善意
使用,我們不會對你發動專利訴訟。** 品牌不在範圍內 —— *Pocket* 字標與口袋 icon 仍是
我們的。程式碼隨你拿,別掛我們的名字。

> **關於註解**:識別字、API 與文件是英文,但原始碼裡的**解釋性註解是繁體中文**。
> 它們記的是一次次具體事故而不是重述程式碼,所以沒有被清掉。如果有哪一段擋住你,
> 開 issue 問 —— 單段翻譯隨時歡迎。
