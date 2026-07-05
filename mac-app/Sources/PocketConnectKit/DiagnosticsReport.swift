import Foundation

// One-click "copy diagnostics" text block (design §5 M2c 驗收 ③): version,
// connection status, paired devices, a config excerpt, and recent errors.
// User-initiated only — the app never auto-copies; the button handler is the
// one and only caller of NSPasteboard for this data (see DashboardView).
//
// Red line: the config JSON section must never leak anything token-shaped
// either (design §3.3). Every upstream value going into a CKRecord already
// passes TokenRedLine, but DiagnosticsRedLine.scrub is a second, independent
// pass over the assembled TEXT — defense in depth for a value that leaves the
// app via the clipboard.

public struct DiagnosticsInput {
    public var appVersion: String
    public var osVersion: String
    public var bridgeReachable: Bool
    public var bridgeLatencyMs: Double?
    public var hostCandidates: [String]
    public var cloudStatusText: String
    public var devices: [DeviceSummary]
    public var pairings: [PairingSummary]
    public var recentErrors: [ErrorLogEntry]
    /// Best-effort config excerpt. Empty until M2b (ConfigSnapshot roaming)
    /// ships — the section still renders so the text block's shape is stable.
    public var configJSON: [String: String]

    public init(appVersion: String, osVersion: String, bridgeReachable: Bool,
               bridgeLatencyMs: Double? = nil, hostCandidates: [String] = [],
               cloudStatusText: String, devices: [DeviceSummary] = [],
               pairings: [PairingSummary] = [], recentErrors: [ErrorLogEntry] = [],
               configJSON: [String: String] = [:]) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.bridgeReachable = bridgeReachable
        self.bridgeLatencyMs = bridgeLatencyMs
        self.hostCandidates = hostCandidates
        self.cloudStatusText = cloudStatusText
        self.devices = devices
        self.pairings = pairings
        self.recentErrors = recentErrors
        self.configJSON = configJSON
    }
}

public enum DiagnosticsReport {
    /// Most recent errors included in the text block — enough to be useful
    /// without turning the pasted text into an unreadable wall.
    public static let maxErrorLines = 20

    public static func build(_ input: DiagnosticsInput, now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("Pocket 診斷報告 — \(iso.string(from: now))")
        lines.append("版本:\(input.appVersion)（\(input.osVersion)）")
        lines.append("")
        lines.append("[連線]")
        let latency = input.bridgeLatencyMs.map { String(format: "，延遲 %.0fms", $0) } ?? ""
        lines.append("  本機 bridge:\(input.bridgeReachable ? "存活" : "無回應")\(latency)")
        lines.append("  對外通道:" + (input.hostCandidates.isEmpty ? "（無）" : input.hostCandidates.joined(separator: "、")))
        lines.append("  iCloud 發現:\(input.cloudStatusText)")
        lines.append("")
        lines.append("[已配對裝置]")
        if input.pairings.isEmpty {
            lines.append("  （無）")
        } else {
            for p in input.pairings {
                let name = input.devices.first(where: { $0.deviceID == p.clientDeviceID })?.name
                    ?? p.clientDeviceID ?? "未知裝置"
                let last = p.lastConnectedAt.map { iso.string(from: $0) } ?? "—"
                lines.append("  · \(name)（\(p.status)）最後連線:\(last)")
            }
        }
        lines.append("")
        lines.append("[組態節錄]")
        if input.configJSON.isEmpty {
            lines.append("  （無 — 組態漫遊尚未上線）")
        } else {
            for key in input.configJSON.keys.sorted() {
                lines.append("  \(key) = \(input.configJSON[key] ?? "")")
            }
        }
        lines.append("")
        lines.append("[最近錯誤（最多 \(maxErrorLines) 筆）]")
        if input.recentErrors.isEmpty {
            lines.append("  （無）")
        } else {
            for e in input.recentErrors.prefix(maxErrorLines) {
                let ts = iso.string(from: e.ts)
                let source = e.deviceID.map { deviceLabel($0, in: input.devices) } ?? "未知裝置"
                lines.append("  [\(ts)] \(e.level) \(e.code) — \(e.message)（來源:\(source)）")
            }
        }
        return DiagnosticsRedLine.scrub(lines.joined(separator: "\n"))
    }

    private static func deviceLabel(_ deviceID: String, in devices: [DeviceSummary]) -> String {
        devices.first(where: { $0.deviceID == deviceID })?.name ?? deviceID
    }
}

// Second, independent red-line pass over the assembled clipboard TEXT (design
// §3.3). Should never trigger given upstream CKRecord-level TokenRedLine
// checks — this only guards against a future call site that builds
// DiagnosticsInput from a source that skipped that check.
public enum DiagnosticsRedLine {
    public static func scrub(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                line.lowercased().contains("token") ? "  [已濾除:此行含 token 字樣]" : String(line)
            }
            .joined(separator: "\n")
    }
}
