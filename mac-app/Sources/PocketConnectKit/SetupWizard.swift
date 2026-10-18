import Foundation

// 首次安裝引導精靈 —— 六列檢查清單 + 「能不能出 QR」的純決策層。
//
// 為什麼要有這一層(2026-10-11):舊的環境檢查只管到「bridge 活著」就放人去掃 QR。
// 結果使用者在 Claude Code / Codex 根本沒裝、或裝了沒登入的情況下配對成功,手機
// 進 CC 分頁看到的是鎖頭或空白 —— 配對明明「成功」,卻完全不知道為什麼沒東西用。
//
// 所以這裡把「掃上去馬上用」寫成一條硬規則:
//   ④ Claude Code 與 ⑤ Codex **至少一個「裝了且已登入」** 才放行 QR。
//
// 本檔不碰 Process / 網路 / 檔案系統,只吃探測結果吐「該顯示什麼 + 該擋誰」,
// 所以每一種壞法(bridge 沒跑 / 兩個引擎都沒登入 / 只有 CC 登入 / 還在查)都能
// 用單元測試釘死,不必真的清空一台 Mac。實際探測留在 app 端 SetupWizard.swift。

// MARK: - ④⑤ 的資料來源:bridge /app/v1/agents/auth(唯讀)

/// bridge `GET /app/v1/agents/auth` 的回應。
///
/// 為什麼問 bridge 而不是桌面自己 spawn `claude auth status`:**bridge 那個家目錄**
/// 才是手機真正會用到的那份登入(Codex 走隔離 CODEX_HOME)。桌面自己問共用家目錄
/// 會給出假綠燈 —— 看起來登入了,手機那頭還是鎖頭。
public struct AgentAuthSnapshot: Equatable {

    /// 單一引擎的狀態。`loggedIn == nil` = bridge 的 60s 快取還沒探完(不是未登入)。
    public struct Agent: Equatable {
        public var installed: Bool
        public var loggedIn: Bool?
        public var account: String?

        public init(installed: Bool, loggedIn: Bool? = nil, account: String? = nil) {
            self.installed = installed
            self.loggedIn = loggedIn
            self.account = account
        }

        /// 「裝了且已登入」—— 這才算手機掃上去真的有東西可用。
        public var isUsable: Bool { installed && loggedIn == true }
        /// 還在查(bridge 冷啟首探可能 10s+)。
        public var isChecking: Bool { installed && loggedIn == nil }
    }

    public var claude: Agent
    public var codex: Agent

    public init(claude: Agent, codex: Agent) {
        self.claude = claude
        self.codex = codex
    }

    public func agent(_ cli: AgentCLI) -> Agent {
        switch cli {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// 至少一個引擎可用 —— QR 放行的唯一條件。
    public var hasUsableAgent: Bool { claude.isUsable || codex.isUsable }
    /// 沒有任何可用引擎,但還有人在查 → 要顯示「檢查中」而不是紅燈。
    public var isStillChecking: Bool { !hasUsableAgent && (claude.isChecking || codex.isChecking) }

    /// 解析 bridge 的 JSON。少欄位一律當「沒有」,不猜。
    public static func parse(_ data: Data) -> AgentAuthSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        func agent(_ key: String) -> Agent {
            let d = root[key] as? [String: Any] ?? [:]
            let account = (d["account"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Agent(installed: d["installed"] as? Bool ?? false,
                         loggedIn: d["logged_in"] as? Bool,
                         account: account)
        }
        guard root["claude"] != nil || root["codex"] != nil else { return nil }
        return AgentAuthSnapshot(claude: agent("claude"), codex: agent("codex"))
    }
}

// MARK: - ③ 對外通道

/// 手機實際能用哪條路連到這台機器。順序即優先度。
public struct ReachabilityReport: Equatable {

    public enum Channel: Equatable {
        /// 同一個 Wi-Fi / 區網直連。
        case lan(String)
        /// Tailscale 私網(100.64.0.0/10)。出門在外也通。
        case tailnet(String)
        /// 公網通道(Cloudflare tunnel / Funnel / 自訂網址),而且實測回得了話。
        case tunnel(String)

        public var address: String {
            switch self {
            case .lan(let a), .tailnet(let a), .tunnel(let a): return a
            }
        }

        /// 離開這個區網還能不能用。
        public var worksAwayFromHome: Bool {
            switch self {
            case .lan: return false
            case .tailnet, .tunnel: return true
            }
        }

        public var displayName: String {
            switch self {
            case .lan: return L10n.t("同網路直連")
            case .tailnet: return L10n.t("Tailscale 私網")
            case .tunnel: return L10n.t("公網通道")
            }
        }
    }

    public var channels: [Channel]
    /// false = 還沒探完(顯示「檢查中」而不是「找不到」)。
    public var checked: Bool

    public init(channels: [Channel], checked: Bool = true) {
        self.channels = channels
        self.checked = checked
    }

    public static let checking = ReachabilityReport(channels: [], checked: false)

    /// 出門在外也通的那條(拿來報給使用者看的「實際可用的那條」)。
    public var remoteChannel: Channel? { channels.first(where: { $0.worksAwayFromHome }) }

    /// 由原始探測資料組出報告 —— 純函式。
    /// - Parameters:
    ///   - localIPv4: 本機 up 且非 loopback 的 IPv4(含 tailnet 的 100.64/10)。
    ///   - bridgePort: bridge 監聽埠,組成手機看得懂的 http://ip:port。
    ///   - tunnelURL: 公網網址;**只有實測連得上時才傳進來**(不然就是在騙人)。
    public static func make(localIPv4: [String], bridgePort: Int, tunnelURL: String?) -> ReachabilityReport {
        var tailnet: [Channel] = []
        var lan: [Channel] = []
        for ip in localIPv4 {
            if HostCandidates.isTailnetIP(ip) {
                tailnet.append(.tailnet("http://\(ip):\(bridgePort)"))
            } else if HostCandidates.isPrivateIP(ip) {
                lan.append(.lan("http://\(ip):\(bridgePort)"))
            }
        }
        var out = tailnet + lan
        if let tunnelURL, !tunnelURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(.tunnel(tunnelURL))
        }
        return ReachabilityReport(channels: out)
    }
}

// MARK: - 六列

public enum SetupWizardStep: String, CaseIterable {
    case python
    case bridge
    case reach
    case claude
    case codex
    case qr

    /// 畫面上的 ①②③④⑤⑥。
    public var number: String {
        ["①", "②", "③", "④", "⑤", "⑥"][Self.allCases.firstIndex(of: self) ?? 0]
    }

    public var title: String {
        switch self {
        case .python: return L10n.t("Python 3.10 以上")
        case .bridge: return L10n.t("Bridge 已安裝並在跑")
        case .reach: return L10n.t("手機怎麼連到這台")
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .qr: return L10n.t("配對 QR")
        }
    }
}

/// 一列紅燈時「可以按的那顆鈕」。文案在這裡,實際怎麼做在 app 端。
public enum SetupWizardAction: Equatable {
    case installBridge
    case startBridge
    case pasteToken
    case installAgent(AgentCLI)
    case loginAgent(AgentCLI)
    case recheck
    case openQR

    public var title: String {
        switch self {
        case .installBridge: return L10n.t("一鍵安裝並啟動")
        case .startBridge: return L10n.t("啟動 Bridge")
        case .pasteToken: return L10n.t("打開連線設定")
        case .installAgent(let cli): return L10n.t("自動安裝 \(cli.displayName)")
        case .loginAgent(let cli): return L10n.t("登入 \(cli.displayName)")
        case .recheck: return L10n.t("重新檢查")
        case .openQR: return L10n.t("好了,拿手機掃這個")
        }
    }
}

public struct SetupWizardRow: Equatable, Identifiable {
    public let step: SetupWizardStep
    public var id: String { step.rawValue }
    public let status: BridgeChecklistItem.Status
    /// 一句話,口語、短、不給技術訊息。
    public let detail: String
    public let action: SetupWizardAction?
    public let helpURL: String?

    public init(step: SetupWizardStep, status: BridgeChecklistItem.Status,
                detail: String, action: SetupWizardAction? = nil, helpURL: String? = nil) {
        self.step = step
        self.status = status
        self.detail = detail
        self.action = action
        self.helpURL = helpURL
    }

    public var title: String { step.title }
    public var number: String { step.number }
}

/// QR 的閘門。`allowsQR == false` 時畫面上不准出現 QR。
public enum QRGate: Equatable {
    /// 放行。
    case ready
    /// ② 還沒綠 —— 連 bridge 都還沒活,根本問不到引擎狀態。
    case waitingBridge
    /// bridge 活著,引擎狀態還在查(bridge 的快取冷啟要幾秒)。
    case checkingAgents
    /// ④⑤ 都不是「裝了且已登入」—— 這時放人掃 QR 就是給他一個空殼。
    case noUsableAgent

    public var allowsQR: Bool { self == .ready }

    /// 擋住時給使用者看的一句話(現在去做什麼)。
    public var message: String {
        switch self {
        case .ready:
            return L10n.t("都好了 —— 拿手機掃下面這個 QR 就能開始用。")
        case .waitingBridge:
            return L10n.t("先把上面的 Bridge 弄好,手機才有東西可以連。")
        case .checkingAgents:
            return L10n.t("正在確認你的 AI 引擎有沒有登入,幾秒就好。")
        case .noUsableAgent:
            return L10n.t("還差一個登入好的 AI 引擎。現在掃上去,手機那頭會是空的 —— 先把上面 Claude Code 或 Codex 其中一個登入完成。")
        }
    }
}

public struct SetupWizardPlan: Equatable {
    public let rows: [SetupWizardRow]
    public let gate: QRGate

    public init(rows: [SetupWizardRow], gate: QRGate) {
        self.rows = rows
        self.gate = gate
    }

    public func row(_ step: SetupWizardStep) -> SetupWizardRow? {
        rows.first(where: { $0.step == step })
    }

    /// 全綠 = 六列都 ok(③ 只有區網時是黃燈,不算全綠,但照樣放行 QR)。
    public var isAllGreen: Bool { rows.allSatisfy { $0.status == .ok } }
}

public enum SetupWizardPlanner {

    /// 六列 + 閘門。順序有意義,見各段註解。
    /// - Parameters:
    ///   - bridgeState: nil = 第一次探測還沒回來。
    ///   - agents: nil = 還沒問到 bridge(bridge 沒活、或請求還在路上)。
    public static func plan(bridgeState: BridgeEnvironmentState?,
                            probe: BridgeEnvironmentProbe,
                            layout: BridgeInstallLayout,
                            agents: AgentAuthSnapshot?,
                            reach: ReachabilityReport) -> SetupWizardPlan {
        var rows: [SetupWizardRow] = []
        rows.append(pythonRow(probe))
        rows.append(bridgeRow(bridgeState, layout: layout))
        rows.append(reachRow(reach))

        // ── 閘門第一關:bridge 沒綠就**不問引擎** ────────────────────────────
        // 引擎狀態只有 bridge 問得準(它知道自己那個家目錄登入了沒)。bridge 沒活
        // 的時候桌面問不到,這時候把 ④⑤ 畫成紅燈是在冤枉使用者 —— 畫「等前面」。
        let bridgeReady = bridgeState?.isReady == true
        guard bridgeReady else {
            rows.append(pendingAgentRow(.claude))
            rows.append(pendingAgentRow(.codex))
            rows.append(qrRow(.waitingBridge))
            return SetupWizardPlan(rows: rows, gate: .waitingBridge)
        }

        // ── ④⑤ 引擎 ───────────────────────────────────────────────────────
        guard let agents else {
            rows.append(pendingAgentRow(.claude))
            rows.append(pendingAgentRow(.codex))
            rows.append(qrRow(.checkingAgents))
            return SetupWizardPlan(rows: rows, gate: .checkingAgents)
        }

        let gate: QRGate = agents.hasUsableAgent
            ? .ready
            : (agents.isStillChecking ? .checkingAgents : .noUsableAgent)

        // 只要已經有一個引擎可用,另一個沒裝/沒登入就只是黃燈(少一個選擇,不是壞掉);
        // 兩個都不可用時,兩列都是紅燈 —— 因為那時候**每一列都是解法**,都要給按鈕。
        let blocking = (gate == .noUsableAgent)
        rows.append(agentRow(.claude, agents.claude, blocking: blocking))
        rows.append(agentRow(.codex, agents.codex, blocking: blocking))
        rows.append(qrRow(gate))
        return SetupWizardPlan(rows: rows, gate: gate)
    }

    // MARK: ① Python

    private static func pythonRow(_ probe: BridgeEnvironmentProbe) -> SetupWizardRow {
        if probe.pythonPath != nil {
            return SetupWizardRow(step: .python, status: .ok, detail: L10n.t("有了,版本夠新。"))
        }
        // 這條 app 代勞不了(不能替使用者裝 Homebrew/Python)→ 給「說明」,
        // 重測交給清單底下那顆唯一的「重新檢查」,不要同一頁三顆一樣的鈕。
        return SetupWizardRow(
            step: .python, status: .blocked,
            detail: L10n.t("這台 Mac 還沒有夠新的 Python(系統內建的那版太舊)。按「說明」照著裝一次,裝好按下面的「重新檢查」。"),
            helpURL: "https://www.python.org/downloads/macos/")
    }

    // MARK: ② Bridge

    private static func bridgeRow(_ state: BridgeEnvironmentState?,
                                  layout: BridgeInstallLayout) -> SetupWizardRow {
        guard let state else {
            return SetupWizardRow(step: .bridge, status: .pending, detail: L10n.t("檢查中…"))
        }
        switch state {
        case .ready:
            return SetupWizardRow(step: .bridge, status: .ok, detail: L10n.t("正在跑,手機連得上。"))
        case .readyButNoToken:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("服務活著,但少了配對用的金鑰。到「連線設定」把金鑰貼上就好。"),
                action: .pasteToken)
        case .installedNotRunning:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("裝好了但沒在跑。按右邊幫你拉起來。"),
                action: .startBridge)
        case .needsInstall:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("還沒裝。按右邊,Pocket 幫你裝好並啟動,你什麼都不用打。"),
                action: .installBridge)
        case .portBusy:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("這台機器上有別的程式占著 Pocket 要用的位置。Pocket 不會去動它 —— 先把那個程式關掉,再按「重新檢查」。"),
                action: .recheck,
                helpURL: "https://github.com/cashtsai/pocket-connect/blob/main/docs/INSTALL_FAQ.md")
        case .missingPython:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("等上面的 Python 裝好,Pocket 才能把 Bridge 裝起來。"),
                helpURL: "https://www.python.org/downloads/macos/")
        case .missingBridgeSource:
            return SetupWizardRow(
                step: .bridge, status: .blocked,
                detail: L10n.t("這個版本的 Pocket 找不到要安裝的內容。重新下載一次最新版再試。"),
                action: .recheck,
                helpURL: "https://github.com/cashtsai/pocket-connect/releases/latest")
        }
    }

    // MARK: ③ 對外通道

    private static func reachRow(_ reach: ReachabilityReport) -> SetupWizardRow {
        guard reach.checked else {
            return SetupWizardRow(step: .reach, status: .pending, detail: L10n.t("檢查中…"))
        }
        if let remote = reach.remoteChannel {
            return SetupWizardRow(
                step: .reach, status: .ok,
                detail: L10n.t("走「\(remote.displayName)」\(pretty(remote.address)) —— 出門在外也連得到。"))
        }
        if let lan = reach.channels.first {
            return SetupWizardRow(
                step: .reach, status: .warning,
                detail: L10n.t("只能在同一個網路用(現在的位址 \(pretty(lan.address)))。出門想連就裝 Tailscale,按右邊看怎麼做。"),
                helpURL: "https://tailscale.com/download/mac")
        }
        return SetupWizardRow(
            step: .reach, status: .warning,
            detail: L10n.t("找不到可以讓手機連進來的網路位址。確認這台 Mac 有連上 Wi-Fi,再按「重新檢查」。"),
            action: .recheck)
    }

    /// 位址給人看的樣子:去掉 scheme 的雜訊,留下「看得懂的那串」。
    private static func pretty(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        if let port = url.port, port != 80, port != 443 { return "\(host):\(port)" }
        return host
    }

    // MARK: ④⑤ 引擎

    /// CLI 回的帳號字串是給工程師看的英文(`Logged in using ChatGPT`…)。
    /// 使用者只該看到「他認得出那是誰」的那部分,其餘英文技術訊息一律不顯示。
    /// 「 · 帳號」或空字串。抽成函式是為了讓上面那句的插值裡不要有巢狀字串
    /// (見 `agentRow` 的註解)。
    static func accountSuffix(_ raw: String?) -> String {
        prettyAccount(raw).map { " · \($0)" } ?? ""
    }

    static func prettyAccount(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        let lower = text.lowercased()
        if lower.contains("api key") { return L10n.t("API 金鑰") }
        if text.contains("@") { return text }           // email(+ 方案)—— 認得出是誰
        if lower.contains("chatgpt") { return L10n.t("ChatGPT 帳號") }
        return nil                                       // 看不懂的就不要給他看
    }

    private static func pendingAgentRow(_ cli: AgentCLI) -> SetupWizardRow {
        SetupWizardRow(step: cli == .claude ? .claude : .codex, status: .pending,
                       detail: L10n.t("等 Bridge 起來才查得到。"))
    }

    private static func agentRow(_ cli: AgentCLI, _ agent: AgentAuthSnapshot.Agent,
                                 blocking: Bool) -> SetupWizardRow {
        let step: SetupWizardStep = (cli == .claude) ? .claude : .codex
        if agent.isUsable {
            return SetupWizardRow(step: step, status: .ok,
                                  // 帳號有值就補「 · 帳號」。**先算出來再插值** ——
                                  // 插值裡放巢狀字串會讓 .strings 的 key 抽不出來
                                  // (抽取器在第一個內層引號就斷掉),而且查表落空
                                  // 時會靜默回退成中文,沒人會發現。
                                  detail: L10n.t("已登入\(accountSuffix(agent.account)) —— 手機上可以直接用。"))
        }
        if agent.isChecking {
            return SetupWizardRow(step: step, status: .pending, detail: L10n.t("確認登入狀態中…"))
        }
        let status: BridgeChecklistItem.Status = blocking ? .blocked : .warning
        if !agent.installed {
            return SetupWizardRow(
                step: step, status: status,
                detail: blocking
                    ? L10n.t("還沒裝。按右邊讓 Pocket 幫你裝,裝完再登入就能用。")
                    : L10n.t("還沒裝 —— 不裝也沒關係,你已經有另一個引擎可以用了。"),
                action: .installAgent(cli),
                helpURL: cli.websiteURL)
        }
        return SetupWizardRow(
            step: step, status: status,
            detail: blocking
                ? L10n.t("裝好了,但還沒登入 —— 手機上會是鎖著的。按右邊登入,授權頁會自己開。")
                : L10n.t("裝好了但沒登入,想多一個引擎可用就按右邊登入。"),
            action: .loginAgent(cli),
            helpURL: cli.websiteURL)
    }

    // MARK: ⑥ QR

    private static func qrRow(_ gate: QRGate) -> SetupWizardRow {
        switch gate {
        case .ready:
            return SetupWizardRow(step: .qr, status: .ok,
                                  detail: L10n.t("一切就緒。按右邊,拿手機掃一下就完成。"),
                                  action: .openQR)
        case .waitingBridge, .checkingAgents:
            return SetupWizardRow(step: .qr, status: .pending, detail: gate.message)
        case .noUsableAgent:
            return SetupWizardRow(step: .qr, status: .blocked, detail: gate.message)
        }
    }
}
