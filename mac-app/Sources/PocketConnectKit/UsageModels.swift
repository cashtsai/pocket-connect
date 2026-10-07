import Foundation

// Wire models for the bridge's GET /app/v1/usage (Codex + Claude Code local
// quota snapshot; bridge reads session/status files only, no cloud API).
// Every branch of the contract can be absent and the UI must degrade instead
// of crashing:
//   • codex.available=false / claude.available=false — provider missing.
//   • claude.official_synced=false — five_hour/seven_day are null and only
//     raw token_usage counts exist (statusLine hook not installed). Those
//     counts must NEVER be dressed up as an official percentage.
//   • a single window can be null even when official_synced=true (expired).
// Parsed from JSONSerialization dictionaries (same style as BridgeClient)
// so unknown/missing fields never throw.

/// One rate-limit window (Codex primary 5h, Claude five_hour/seven_day).
public struct UsageWindow: Equatable {
    public let usedPercent: Double
    public let remainingPercent: Double
    public let resetAt: Date?

    public init(usedPercent: Double, remainingPercent: Double, resetAt: Date?) {
        self.usedPercent = usedPercent
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any],
              let used = UsageSnapshot.number(dict["used_percent"]) else { return nil }
        usedPercent = used
        remainingPercent = UsageSnapshot.number(dict["remaining_percent"]) ?? max(0, 100 - used)
        resetAt = UsageSnapshot.isoDate(dict["reset_at"])
    }
}

public struct CodexUsage: Equatable {
    public let available: Bool
    /// Primary (5h) window — nil when unavailable.
    public let window: UsageWindow?

    public init(available: Bool, window: UsageWindow?) {
        self.available = available
        self.window = window
    }

    init(json: [String: Any]) {
        available = (json["available"] as? Bool) ?? false
        // The codex block is flat: used_percent/reset_at sit at the top level.
        window = available ? UsageWindow(json: json) : nil
    }
}

/// Raw local token totals — the only data when official_synced=false.
public struct ClaudeTokenUsage: Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadInputTokens: Int
    public let cacheCreationInputTokens: Int

    public init(inputTokens: Int, outputTokens: Int,
                cacheReadInputTokens: Int, cacheCreationInputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    init?(json: Any?) {
        guard let dict = json as? [String: Any] else { return nil }
        inputTokens = UsageSnapshot.int(dict["input_tokens"])
        outputTokens = UsageSnapshot.int(dict["output_tokens"])
        cacheReadInputTokens = UsageSnapshot.int(dict["cache_read_input_tokens"])
        cacheCreationInputTokens = UsageSnapshot.int(dict["cache_creation_input_tokens"])
    }
}

public struct ClaudeUsage: Equatable {
    public let available: Bool
    /// true only when the official statusLine hook produced fresh rate_limits.
    public let officialSynced: Bool
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let tokenUsage: ClaudeTokenUsage?
    public let accountLabel: String?

    public init(available: Bool, officialSynced: Bool, fiveHour: UsageWindow?,
                sevenDay: UsageWindow?, tokenUsage: ClaudeTokenUsage?, accountLabel: String?) {
        self.available = available
        self.officialSynced = officialSynced
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.tokenUsage = tokenUsage
        self.accountLabel = accountLabel
    }

    init(json: [String: Any]) {
        available = (json["available"] as? Bool) ?? false
        officialSynced = (json["official_synced"] as? Bool) ?? false
        fiveHour = UsageWindow(json: json["five_hour"])
        sevenDay = UsageWindow(json: json["seven_day"])
        tokenUsage = ClaudeTokenUsage(json: json["token_usage"])
        accountLabel = json["account_label"] as? String
    }
}

public struct UsageSnapshot: Equatable {
    public let codex: CodexUsage?
    public let claude: ClaudeUsage?

    public init(codex: CodexUsage?, claude: ClaudeUsage?) {
        self.codex = codex
        self.claude = claude
    }

    public init(json: [String: Any]) {
        codex = (json["codex"] as? [String: Any]).map(CodexUsage.init(json:))
        claude = (json["claude"] as? [String: Any]).map(ClaudeUsage.init(json:))
    }

    // MARK: - Tolerant scalar helpers

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int(_ value: Any?) -> Int {
        number(value).map { Int($0) } ?? 0
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func isoDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return iso.date(from: s) ?? isoFractional.date(from: s)
    }
}
