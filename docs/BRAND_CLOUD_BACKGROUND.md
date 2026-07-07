# Pocket 雲朵背景 — 品牌規格（含 logo 頁特規）

奶油底（#FFF2D6）+ 淡雲圖樣是 Pocket 的招牌背景（見 iOS 登入頁）。跨平台（iOS / 桌面 / web）一致，凡用到都照本規格。

## 兩種變體

| 變體 | 用在哪 | 雲朵 |
|---|---|---|
| **完整版（原本）** | 一般頁面（配對頁、內容頁…） | 全部雲照畫 |
| **logo 頁特規** | 有 logo/wordmark 的頁（登入 / 歡迎 / 啟動頁） | **移除 logo 正下方／會壓到 logo 的那些雲** |

## logo 頁特規規則

1. 為 logo（wordmark + 副標）保留一塊「淨空區」＝ **wordmark∪副標的範圍，並向下延伸一段**（桌面用 44pt）。
2. **任何與淨空區相交的雲一律不畫** — 確保 logo 正下方乾淨、清晰。
3. 排版上 **logo 不得壓到任何雲**（logo 與雲不重疊）。
4. 這是**特規、只給 logo 頁**；其他頁面一律用完整版，不要沿用淨空區。

## 實作參考（桌面 pocket-connect）

`mac-app/Sources/PocketConnect/Onboarding.swift`：
- `BrandBackgroundView.logoSafeZone: NSRect?` — 設了就跳過相交的雲（logo 頁），`nil` ＝完整版（其他頁）。
- 登入/歡迎頁 `buildWelcome()` 依 wordmark∪副標算出淨空區並下延 44pt；配對頁 `showPairing()` 設回 `nil`。

## 佈達

其他 Pocket 端（iOS app、web landing、任何啟動/登入頁）若用到雲背景，**logo 頁一律套特規**（移除 logo 正下方的雲、logo 不壓雲），其餘頁面用完整版。新做頁面請對齊本檔。
