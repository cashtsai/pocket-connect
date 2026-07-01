# M2 施工規格：Claude / Codex 帳號連結（官方 OAuth，非 API key）

> 2026-07-01 · XCash 整理。善彰決策：**方案 B**——桌面 App 內走官方 CLI 的瀏覽器 OAuth 登入，
> 不做「填 API key」那條路。前提成立：每使用者一台自己的 Mac mini，Claude Code / Codex
> 官方 CLI 本來就已裝在這台機器上，OAuth 憑證由官方 CLI 自己管理與加密儲存，Pocket
> 不需要自己碰 token 明文、不需要另建 Keychain 同步機制。

---

## 0. 為什麼這樣做（架構決策）

官方 CLI 已經提供完整、可程式化探測的 OAuth 登入機制：

```bash
$ claude auth status --json
{
  "loggedIn": true,
  "authMethod": "claude.ai",
  "apiProvider": "firstParty",
  "email": "sendtocash@gmail.com",
  "orgId": "...",
  "orgName": "...",
  "subscriptionType": "max"
}

$ codex login status
Logged in using ChatGPT
```

登入指令（會開瀏覽器走 OAuth，完成後回寫本機憑證檔）：

```bash
claude auth login --claudeai     # 開瀏覽器走 claude.ai OAuth
codex login                      # 開瀏覽器走 ChatGPT OAuth（無子指令＝觸發登入）
```

憑證實際落地：
- Claude Code → `~/.claude/.credentials.json`（官方 CLI 自己管理，600 權限）
- Codex → `~/.codex/auth.json`（官方 CLI 自己管理）

**Pocket Connect 完全不需要自己存這些 token**，只需要：
1. 呼叫官方 CLI 觸發登入
2. 輪詢官方 CLI 的 status 指令確認完成
3. 把「已連結／未連結 + 帳號 email/訂閱等級」顯示在 UI，並回報一個布林狀態給 bridge 存
   （bridge 只存「這個 apple_user_id 底下這台機器的 Claude/Codex 是否已連結」，不存 token 本身）

這與既有 `ACCOUNT_CROSS_DEVICE_ARCH.md` 的「每使用者一台自己的 Mac mini，憑證留在本機」
原則完全一致，甚至更乾淨——因為官方 CLI 已經處理掉最麻煩的部分（OAuth flow、token 刷新、
安全儲存），Pocket 只是「觸發 + 顯示狀態」的殼。

---

## 1. UI 流程

新增一個畫面（Apple 登入成功後、QR 配對之前，或選單列常駐選項「帳號連結」）：

```
┌─────────────────────────────┐
│  連結你的 AI 帳號              │
│                               │
│  Claude Code    [已連結 ✓]    │
│  sendtocash@gmail.com (Max)   │
│  [ 重新連結 ]                  │
│                               │
│  Codex          [未連結]      │
│  [ 連結 Codex ]                │
│                               │
│         [ 繼續 → QR 配對 ]     │
└─────────────────────────────┘
```

- 「連結」按鈕觸發背景 Process 執行對應 CLI 登入指令，同時顯示 spinner
- 登入指令會自己開瀏覽器（`open` 系統呼叫或 CLI 內部處理），使用者在瀏覽器完成 OAuth 後
  回到 App，App 端每 2 秒輪詢一次 status 指令直到 `loggedIn: true` 或逾時（建議 120 秒）
- 逾時或使用者取消 → 顯示「連結失敗，可重試」，不要卡死 spinner
- 兩邊都可獨立連結，不互相阻塞；「繼續 → QR 配對」按鈕在至少一邊已連結時才可點
  （或善彰若希望兩邊都必連才能繼續，另外拍板——**先做成「至少一邊即可繼續」，較寬鬆**）

---

## 2. 技術實作（CC 線，pocket-connect repo）

新檔案 `mac-app/Sources/PocketConnect/AccountLinking.swift`：

```swift
import Foundation

enum LinkStatus: Equatable {
    case unknown, checking, linked(email: String?, plan: String?), unlinked, linking, error(String)
}

enum AIProvider {
    case claude, codex

    var statusCommand: [String] {
        switch self {
        case .claude: return ["auth", "status", "--json"]
        case .codex:  return ["login", "status"]
        }
    }
    var loginCommand: [String] {
        switch self {
        case .claude: return ["auth", "login", "--claudeai"]
        case .codex:  return ["login"]
        }
    }
    var binaryName: String { self == .claude ? "claude" : "codex" }
}

final class AccountLinkChecker {
    /// 找官方 CLI 執行檔的絕對路徑（不能假設在 PATH 裡，桌面 App 的
    /// 環境變數跟終端機不同，GUI App 啟動時通常拿不到使用者 shell 的 PATH）。
    /// 依序嘗試： `which <bin>`（若在終端機啟動能用）→ 常見安裝位置。
    static func resolveBinary(_ name: String) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/node-v24.14.1-darwin-arm64/bin/\(name)",  // 目前實測路徑
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // fallback: 用 login shell 跑 `which`，才吃得到使用者 shell profile 裡的 PATH
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    /// 執行 status 指令，回傳解析後的狀態（不阻塞主執行緒——呼叫端自行丟到背景 queue）。
    static func checkStatus(_ provider: AIProvider) -> LinkStatus {
        guard let bin = resolveBinary(provider.binaryName) else {
            return .error("找不到 \(provider.binaryName) CLI，請先安裝")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = provider.statusCommand
        let outPipe = Pipe(); p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return .error("執行失敗: \(error.localizedDescription)") }
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""

        switch provider {
        case .claude:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool else { return .unlinked }
            if !loggedIn { return .unlinked }
            return .linked(email: json["email"] as? String,
                            plan: json["subscriptionType"] as? String)
        case .codex:
            // codex login status 目前無 --json，純文字："Logged in using ChatGPT" / "Not logged in"
            if text.lowercased().contains("logged in") { return .linked(email: nil, plan: nil) }
            return .unlinked
        }
    }

    /// 觸發登入（會開瀏覽器）。呼叫端要在背景 queue 呼叫，並且呼叫後開始輪詢 checkStatus。
    static func startLogin(_ provider: AIProvider) throws {
        guard let bin = resolveBinary(provider.binaryName) else {
            throw NSError(domain: "AccountLinking", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "找不到 \(provider.binaryName)"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = provider.loginCommand
        // 不等待完成——這個指令會開瀏覽器並可能長時間 hang 到使用者完成 OAuth。
        // fire-and-forget，靠輪詢 checkStatus 偵測完成。
        try p.run()
    }
}
```

輪詢輔助（在 Onboarding 或帳號畫面的 controller 裡）：

```swift
func pollUntilLinked(_ provider: AIProvider, timeout: TimeInterval = 120,
                      onUpdate: @escaping (LinkStatus) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func tick() {
        DispatchQueue.global().async {
            let status = AccountLinkChecker.checkStatus(provider)
            DispatchQueue.main.async { onUpdate(status) }
            if case .linked = status { return }          // done
            if Date() >= deadline {
                DispatchQueue.main.async { onUpdate(.error("逾時，請重試")) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: tick)
        }
    }
    tick()
}
```

---

## 3. Bridge 端要不要記錄「已連結」狀態？

**M2 最小可用：不用。** Claude/Codex 的登入狀態是「這台機器」的狀態（官方 CLI 憑證檔在本機），
跟 Apple 帳號、跨裝置配對是兩件事——手機不需要知道桌機的 Claude/Codex 是否連結，那是桌機
自己執行 Hermes/CC/Codex 時才需要的憑證，不經過 bridge 中繼。

若未來善彰要在手機 App 上看到「這台桌機的 Claude/Codex 連結狀態」（例如多桌機管理情境），
再加 `GET /app/v1/account` 回傳裡的 `desktop_capabilities` 欄位，由桌機定期 POST 自己的
status 上去。**這輪不做，先確認 UI + 本機偵測即可用。**

---

## 4. 驗收標準

| 檢查項 | 通過條件 |
|---|---|
| 冷啟動偵測 | App 開啟時自動跑一次兩邊 `checkStatus`，UI 正確顯示已連結/未連結 |
| Claude 連結流程 | 點「連結」→ 開瀏覽器 claude.ai 登入頁 → 完成後 App 輪詢偵測到 `loggedIn:true` 並顯示 email + 訂閱等級，2 分鐘內完成 |
| Codex 連結流程 | 點「連結」→ 開瀏覽器 ChatGPT 登入頁 → 完成後 App 輪詢偵測到已登入 |
| 已連結情境 | 這台機器已經 `claude auth login` / `codex login` 過（善彰目前機器就是這狀態），App 開啟直接顯示已連結，不需重新走一次 OAuth |
| 找不到 CLI | 若 `which claude`/`which codex` 都失敗，顯示明確錯誤「找不到 XX CLI，請先安裝」而非 crash 或空白 |
| 逾時處理 | 120 秒內未偵測到登入完成 → 顯示可重試的錯誤狀態，不會無限轉圈 |
| 不影響既有流程 | Apple 登入 + QR 配對既有流程不受影響，這是新增的獨立畫面/步驟 |

---

## 5. 分工

| 線 | 工作 |
|---|---|
| CC（app，pocket-connect repo） | `AccountLinking.swift` 新檔 + 帳號連結畫面 UI + 接進 Onboarding 流程（Apple 登入成功後或選單列新增選項） |
| XCash | 驗收（實測跑一次真實 OAuth flow，確認 email/訂閱等級正確顯示）、出 PR |
| 善彰 | 若要「兩邊都必連才能配對」這種更嚴格規則，另行拍板（目前先做寬鬆版：至少一邊即可繼續）|

---

## 6. 已知限制 / 之後再做

- 目前只偵測「已登入」，不處理「登出」按鈕（若要加，`claude auth logout` / `codex logout`，risk 低可之後補）
- 多使用者/多 Mac 情境下的「哪台桌機的 Claude/Codex 連結」跨裝置可見性，見 §3，本輪不做
- 沒有做「App 內建 CLI 安裝引導」——若 `which` 都找不到，先只顯示錯誤訊息，引導安裝腳本併入
  `COMMERCIALIZATION_SPEC.md` 缺口 2 的 Hermes 依賴偵測一起做，不在本輪重複實作
