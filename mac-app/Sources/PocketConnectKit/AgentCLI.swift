import Foundation

// AI 引擎 CLI(Claude Code / Codex)的「一鍵連接」核心邏輯 — 純函式、可單元測試。
// Process 執行、開瀏覽器/終端機都留在 app 端(AgentConnect.swift),這裡只放:
//   • CLI 執行檔探測的路徑推導(GUI app 的 PATH 沒有 shell profile,要自己補常見位置)
//   • `claude auth status` / `codex login status` 輸出的解析
//
// 實測事實(2026-07,本機驗證):
//   • claude auth status → JSON,登入時 {"loggedIn": true, "email": …, "subscriptionType": …},exit 0
//   • codex login status → 登入時 "Logged in using ChatGPT" exit 0;未登入 "Not logged in" exit 1

/// 支援的 AI 引擎。rawValue 即執行檔名稱。
public enum AgentCLI: String, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    public var binaryName: String { rawValue }

    /// 查登入狀態的參數。
    public var statusArguments: [String] {
        switch self {
        case .claude: return ["auth", "status"]
        case .codex: return ["login", "status"]
        }
    }

    /// 啟動登入(OAuth)的參數。
    public var loginArguments: [String] {
        switch self {
        case .claude: return ["auth", "login"]
        case .codex: return ["login"]
        }
    }

    /// v1 不做自動安裝 — 給使用者可複製的安裝指令。
    public var installCommand: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "npm install -g @openai/codex"
        }
    }

    public var websiteURL: String {
        switch self {
        case .claude: return "https://claude.com/claude-code"
        case .codex: return "https://developers.openai.com/codex/cli/"
        }
    }
}

/// 三態:未安裝 / 已安裝未登入 / 已連接(帶帳號描述)。
public enum AgentConnectionState: Equatable {
    case notInstalled
    case notLoggedIn
    case connected(account: String?)
}

public enum AgentCLIProbe {

    /// 探測用的候選目錄:常見安裝位置優先,再補現有 PATH(去重)。
    /// GUI app 從 Finder/Dock 啟動時 PATH 只有 /usr/bin:/bin:/usr/sbin:/sbin,
    /// 不含 shell profile 加的 ~/.local/bin 等,所以不能只信 PATH。
    public static func candidateDirectories(home: String, pathVariable: String?) -> [String] {
        var dirs = [
            home + "/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
        for entry in (pathVariable ?? "").split(separator: ":") {
            let dir = String(entry)
            if !dir.isEmpty, !dirs.contains(dir) { dirs.append(dir) }
        }
        return dirs
    }

    /// 在候選目錄中找可執行檔;`isExecutable` 注入方便測試。
    public static func resolveBinary(named name: String,
                                     home: String,
                                     pathVariable: String?,
                                     isExecutable: (String) -> Bool) -> String? {
        for dir in candidateDirectories(home: home, pathVariable: pathVariable) {
            let full = dir + "/" + name
            if isExecutable(full) { return full }
        }
        return nil
    }

    /// 給 Process 用的 PATH(候選目錄串起來),讓 CLI 內部再叫別的工具也找得到。
    public static func augmentedPATH(home: String, existing: String?) -> String {
        candidateDirectories(home: home, pathVariable: existing).joined(separator: ":")
    }

    /// 解析 status 指令的輸出 → 未登入或已連接。
    /// (未安裝在呼叫端判斷 — 找不到執行檔就不會跑到這裡。)
    public static func parseStatus(for cli: AgentCLI, exitCode: Int32, output: String) -> AgentConnectionState {
        switch cli {
        case .claude: return parseClaudeAuthStatus(exitCode: exitCode, output: output)
        case .codex: return parseCodexLoginStatus(exitCode: exitCode, output: output)
        }
    }

    static func parseClaudeAuthStatus(exitCode: Int32, output: String) -> AgentConnectionState {
        // 預設輸出即 JSON;保守起見取第一個 { 到最後一個 } 之間再解析。
        guard exitCode == 0,
              let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"),
              start < end,
              let data = String(output[start...end]).data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              dict["loggedIn"] as? Bool == true
        else { return .notLoggedIn }

        var parts: [String] = []
        if let email = dict["email"] as? String, !email.isEmpty { parts.append(email) }
        if let plan = dict["subscriptionType"] as? String, !plan.isEmpty { parts.append(plan) }
        return .connected(account: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    static func parseCodexLoginStatus(exitCode: Int32, output: String) -> AgentConnectionState {
        // 登入:"Logged in using ChatGPT" exit 0;未登入:"Not logged in" exit 1。
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        guard exitCode == 0, lower.contains("logged in"), !lower.contains("not logged in")
        else { return .notLoggedIn }
        let firstLine = text.split(separator: "\n").first.map(String.init)
        return .connected(account: firstLine)
    }
}
