# Session Relay: xw-pocketconn-m3envdetect-20260712

> 更新時間：2026-07-12 · 承接 20260711-5450（環境偵測 + 引導安裝，commit 2e9ff82）

## 本輪完成

- **善彰拍板第 1 點並已執行**：`hermes-studio-bridge` 已開源（GitHub repo
  `cashtsai/hermes-studio-bridge` 由 PRIVATE 翻 PUBLIC，2026-07-12）。
  - 開源前已掃過：tracked 檔案與全部 207 個 commit 的 diff 歷史都沒有金鑰本體
    （.env / .p8 從未進過 git；`docs/HANDOFF_CREDENTIALS.md` 只記金鑰位置與
    Key ID，設計上就不含 key）。
  - OSS 名字採 `hermes-studio-bridge`（品牌中性問題隨拍板一併解決）。
- **`install_hermes.sh` 補 git clone 步驟**：`$BRIDGE_DIR/bridge.py` 不存在時
  自動 `git clone --depth 1 https://github.com/cashtsai/hermes-studio-bridge.git`
  （可用 `POCKET_BRIDGE_REPO` 覆寫來源）。防呆：
  - 全新機器 git 只是 CLT stub → 先檢查 `xcode-select -p`，缺 CLT 時給明確
    指令（`xcode-select --install`）而不是跳 GUI 視窗卡死背景 Process。
  - `$BRIDGE_DIR` 已存在且非空但缺 bridge.py → 明確報錯不覆蓋。
  - 已驗證：zsh 語法檢查通過；以無憑證環境匿名 https clone 成功、含 bridge.py。

## 待善彰斟酌（開源後的內部文件曝光）

repo 公開後這些「非金鑰但屬內部」的內容也跟著公開（且在 git 歷史裡，翻回
private 也已曝光過）：
- `docs/HANDOFF_CREDENTIALS.md`：Apple Team ID、兩把 .p8 的 Key ID、bundle ID、
  App Store App ID、本機憑證路徑。Key ID 沒有 .p8 本體不可利用，Team ID/bundle
  ID 本來就能從上架 app 抽出，風險低但觀感可議。
- `docs/HANDOFF.md`：cashcamp 主機名、Tailscale 內網 IP（100.67.0.12，tailnet
  外不可達）、四個 persona 的 home 配置。
- `CLAUDE.md`：內部操作紅線與 2026-07-10 事故記錄。
如要清理：從 tip 移除只是眼不見為淨（歷史還在），徹底清要 rewrite history +
force push，需另行拍板。

## 殘餘風險（沿前輪）

- 環境檢查只掛在 onboarding 入口；已完成 onboarding 後 Hermes 被移除的情境
  不會觸發引導（spec §1 寫「首次啟動或每次啟動」，取最小實作）。
- repo 目前沒有 LICENSE 檔——嚴格說「公開 ≠ 開源授權」，別人 clone 得到但
  法律上無授權。要補的話選個 license（MIT/Apache-2.0）commit 進 bridge repo
  main（依該 repo CLAUDE.md 鐵則需明確指示才能動 main）。

## 下一步建議

1. 找乾淨 macOS 使用者帳號跑真實冷啟動驗收（spec §5 驗收第 1、2 項，XCash
   線，spec §6）——現在 bridge 可自動 clone，「全新機器全自動裝到能配對」
   應可全程走通。
2. 拍板 bridge repo 是否補 LICENSE、是否清理上述內部文件。
3. 驗收過後把 feat/m3-env-detection 出 PR。
