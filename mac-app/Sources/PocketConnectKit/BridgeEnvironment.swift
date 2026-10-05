import Foundation

// M3 — 執行環境偵測 + bridge bootstrap 的「純決策層」。
//
// 這一層完全不碰 Process / 網路 / launchctl,只吃「探測結果」吐「該做什麼」,
// 所以每個分支(缺 python / 缺 bridge / 沒 plist / 已在跑 / port 被占)都能用
// 單元測試釘死,不需要真的清空一台 Mac。實際執行留在 app 端的 BridgeBootstrap.swift。
//
// 路徑/標籤/埠一律對齊 bridge repo 的 `deploy/install-local-bridge.sh`,那支腳本
// 就是 M3_ENV_DETECTION_SPEC.md §3 留的 TODO「bridge LaunchAgent 產生流程是否已有
// 腳本可複用」的答案 —— 有,而且是 per-user 的(裝到使用者家目錄、自己的 label、
// 自己的 token),不會碰到開發機上那個 production 的 ai.studio.hermes-bridge。

// MARK: - 安裝佈局(路徑 / label / port)

/// bridge 的安裝佈局。所有欄位都可用環境變數覆寫 —— 正式環境用不到,
/// 但這讓「假裝一台全新 Mac」的乾跑測試可以把整組路徑指到一個 TEMP prefix。
/// 變數名稱與 `install-local-bridge.sh` 一致,app 與腳本才不會各算各的。
public struct BridgeInstallLayout: Equatable {
    /// bridge 程式碼安裝目的地(launchd 的 WorkingDirectory)。
    public let installRoot: String
    /// bridge 專用 venv(不與使用者其他 python 環境混用)。
    public let venvPath: String
    /// LaunchAgent label。刻意不同於 production 的 `ai.studio.hermes-bridge`。
    public let label: String
    /// LaunchAgent plist 完整路徑。
    public let launchAgentPath: String
    /// 開發機上既有的 Hermes bridge plist(讀金鑰時的後備來源)。
    /// 與 launchAgentPath 同一個目錄,所以乾跑時把目錄指到 TEMP prefix 會一起改掉。
    public let legacyLaunchAgentPath: String
    /// bridge 監聽埠。
    public let port: Int
    /// 安裝記錄檔目錄(M3 spec §2「失敗時顯示明確錯誤 + 查看記錄檔」)。
    public let logDirectory: String
    /// 找 python3 的候選路徑(依序)。
    public let pythonCandidates: [String]
    /// 找 bridge 程式來源的候選目錄(依序)。
    public let bridgeSourceCandidates: [String]

    public static let defaultLabel = "com.pocketconnect.bridge"
    public static let defaultPort = 8081

    public init(installRoot: String, venvPath: String, label: String, launchAgentPath: String,
                legacyLaunchAgentPath: String,
                port: Int, logDirectory: String,
                pythonCandidates: [String], bridgeSourceCandidates: [String]) {
        self.installRoot = installRoot
        self.venvPath = venvPath
        self.label = label
        self.launchAgentPath = launchAgentPath
        self.legacyLaunchAgentPath = legacyLaunchAgentPath
        self.port = port
        self.logDirectory = logDirectory
        self.pythonCandidates = pythonCandidates
        self.bridgeSourceCandidates = bridgeSourceCandidates
    }

    /// 由 home + 環境變數推導佈局。`bundledBridgePath` 是 app bundle 內附帶的
    /// bridge payload(`Pocket.app/Contents/Resources/bridge`),沒有就傳 nil。
    public static func resolve(home: String,
                               environment: [String: String],
                               bundledBridgePath: String? = nil) -> BridgeInstallLayout {
        func env(_ key: String) -> String? {
            guard let v = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return nil }
            return v
        }

        let installRoot = env("POCKET_BRIDGE_INSTALL_ROOT")
            ?? "\(home)/Library/Application Support/PocketConnect/bridge/current"
        let venv = env("POCKET_BRIDGE_VENV") ?? "\(installRoot)/venv"
        let label = env("POCKET_BRIDGE_LABEL") ?? defaultLabel
        let agentsDir = env("POCKET_LAUNCH_AGENTS_DIR") ?? "\(home)/Library/LaunchAgents"
        let port = env("POCKET_BRIDGE_PORT").flatMap(Int.init) ?? defaultPort
        let logDir = env("POCKET_LOG_DIR") ?? "\(home)/Library/Logs/Pocket"

        let pythonCandidates: [String]
        if let override = env("POCKET_BRIDGE_PYTHON_CANDIDATES") {
            pythonCandidates = splitPathList(override)
        } else if let explicit = env("POCKET_BRIDGE_PYTHON") {
            pythonCandidates = [explicit]
        } else {
            // GUI app 的 PATH 沒有 shell profile,不能只信 PATH(同 AgentCLIProbe)。
            // /usr/bin/python3 是 macOS 內建的 Command Line Tools shim —— 沒裝 CLT
            // 時它存在但一跑就跳安裝對話框,所以排在真正的 python 之後。
            pythonCandidates = [
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "\(home)/.local/bin/python3",
                "/usr/bin/python3",
            ]
        }

        let sourceCandidates: [String]
        if let override = env("POCKET_BRIDGE_SOURCE_CANDIDATES") {
            sourceCandidates = splitPathList(override)
        } else if let explicit = env("POCKET_BRIDGE_SOURCE") {
            sourceCandidates = [explicit]
        } else {
            // 順序即優先度:已裝好的 > app 內附帶的 > 本機開發用 checkout。
            var list = [installRoot]
            if let bundled = bundledBridgePath { list.append(bundled) }
            list.append("\(home)/apps/hermes-openwebui-bridge")
            sourceCandidates = list
        }

        return BridgeInstallLayout(
            installRoot: installRoot,
            venvPath: venv,
            label: label,
            launchAgentPath: "\(agentsDir)/\(label).plist",
            legacyLaunchAgentPath: "\(agentsDir)/ai.studio.hermes-bridge.plist",
            port: port,
            logDirectory: logDir,
            pythonCandidates: pythonCandidates,
            bridgeSourceCandidates: sourceCandidates)
    }

    static func splitPathList(_ raw: String) -> [String] {
        raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// 本機 bridge 的 health 端點。
    public var healthURL: String { "http://127.0.0.1:\(port)/health" }

    /// 安裝記錄檔(M3 spec §2)。
    public var installLogPath: String { "\(logDirectory)/install.log" }

    /// 傳給 `install-local-bridge.sh` 的環境變數,確保腳本裝到跟 app 算出來的
    /// 同一組路徑,而且**永遠不會**碰到 production 的 ai.studio.hermes-bridge。
    public var installerEnvironment: [String: String] {
        [
            "POCKET_BRIDGE_INSTALL_ROOT": installRoot,
            "POCKET_BRIDGE_VENV": venvPath,
            "POCKET_BRIDGE_LABEL": label,
        ]
    }
}

// MARK: - 探測結果(純資料)

/// bridge 程式來源。順序即優先度。
public enum BridgeSource: Equatable {
    /// 已經安裝在 installRoot(升級/重裝走這條)。
    case installed(String)
    /// app bundle 內附帶的 payload(全新 Mac 走這條)。
    case bundled(String)
    /// 本機開發用 checkout(開發機走這條)。
    case localCheckout(String)

    public var path: String {
        switch self {
        case .installed(let p), .bundled(let p), .localCheckout(let p): return p
        }
    }

    public var displayName: String {
        switch self {
        case .installed: return "已安裝的 bridge"
        case .bundled: return "Pocket.app 內附的 bridge"
        case .localCheckout: return "本機 bridge 原始碼"
        }
    }
}

public enum BridgeHealth: Equatable {
    case ok
    case unreachable
    case httpError(Int)

    public var isOK: Bool { self == .ok }
}

/// 誰占著這個埠。
public struct PortOccupant: Equatable {
    public let pid: Int32
    public let command: String
    /// `ps -o comm=` 拿到的完整執行檔路徑(拿不到就 nil)。
    public let executablePath: String?

    public init(pid: Int32, command: String, executablePath: String? = nil) {
        self.pid = pid
        self.command = command
        self.executablePath = executablePath
    }

    /// 這個占用者是不是 Pocket 自己裝的 bridge(venv 底下的 python)。
    public func isPocketManaged(venvPath: String) -> Bool {
        guard let exe = executablePath else { return false }
        return exe.hasPrefix(venvPath + "/")
    }
}

/// BRIDGE_TOKEN 從哪來的(回報用,也讓 UI 能說清楚)。
public enum BridgeTokenSource: String, Equatable {
    /// 使用者在「連線設定」手動貼的。
    case manualOverride
    /// 行程環境變數(開發時 `swift run` 帶進來的)。
    case environment
    /// Pocket 自己裝的 LaunchAgent。
    case pocketLaunchAgent
    /// 開發機上既有的 Hermes bridge LaunchAgent。
    case hermesLaunchAgent

    public var displayName: String {
        switch self {
        case .manualOverride: return "手動貼上"
        case .environment: return "環境變數"
        case .pocketLaunchAgent: return "Pocket 安裝的 bridge"
        case .hermesLaunchAgent: return "既有的 Hermes bridge"
        }
    }
}

/// 一次環境探測的完整結果。純資料,方便測試直接組。
public struct BridgeEnvironmentProbe: Equatable {
    public var pythonPath: String?
    public var bridgeSource: BridgeSource?
    public var launchAgentInstalled: Bool
    public var tokenSource: BridgeTokenSource?
    public var health: BridgeHealth
    public var portOccupant: PortOccupant?

    public init(pythonPath: String? = nil,
                bridgeSource: BridgeSource? = nil,
                launchAgentInstalled: Bool = false,
                tokenSource: BridgeTokenSource? = nil,
                health: BridgeHealth = .unreachable,
                portOccupant: PortOccupant? = nil) {
        self.pythonPath = pythonPath
        self.bridgeSource = bridgeSource
        self.launchAgentInstalled = launchAgentInstalled
        self.tokenSource = tokenSource
        self.health = health
        self.portOccupant = portOccupant
    }
}

// MARK: - 決策

/// 偵測後該做什麼。UI 與 bootstrap 都只看這個。
public enum BridgeEnvironmentState: Equatable {
    /// bridge 活著,金鑰也讀得到 → 可以直接出配對 QR。
    case ready(BridgeTokenSource)
    /// bridge 活著但讀不到金鑰 → 引導手動貼(不是無聲失敗)。
    case readyButNoToken
    /// 我們的 LaunchAgent 在,但服務沒回應 → kickstart 就好,不用重裝。
    case installedNotRunning
    /// 埠被「別人」占著 → 絕不覆蓋,請使用者處理。
    case portBusy(PortOccupant)
    /// 一切就緒,可以裝。
    case needsInstall(BridgeSource)
    /// 沒有 python3 → 使用者要自己補(不能替他裝 Xcode CLT)。
    case missingPython
    /// 找不到 bridge 程式來源 → 這版 app 沒附 payload 也沒本機 checkout。
    case missingBridgeSource

    /// 這個狀態能不能直接進配對流程。
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// 需要使用者本人動手(app 自動化解不掉)的狀態。
    public var needsUserAction: Bool {
        switch self {
        case .missingPython, .missingBridgeSource, .portBusy, .readyButNoToken: return true
        case .ready, .installedNotRunning, .needsInstall: return false
        }
    }
}

public enum BridgeEnvironmentPlanner {

    /// 純決策:探測結果 → 狀態。順序有意義,見各分支註解。
    public static func plan(_ probe: BridgeEnvironmentProbe, layout: BridgeInstallLayout) -> BridgeEnvironmentState {
        // 1. 服務會回 200 就是活的 —— 不管是 Pocket 裝的還是使用者原本就有的
        //    (開發機上 production 的 ai.studio.hermes-bridge 就會走到這裡),
        //    一律不再動它。「別搶 port、別重裝人家的東西」是這裡的第一原則。
        if probe.health.isOK {
            if let source = probe.tokenSource { return .ready(source) }
            return .readyButNoToken
        }

        // 2. 埠上有東西但不回 health,而且不是我們裝的 → 別人的服務,不能覆蓋。
        if let occupant = probe.portOccupant, !occupant.isPocketManaged(venvPath: layout.venvPath) {
            return .portBusy(occupant)
        }

        // 3. 沒有 python3 就什麼都做不了(venv 建不起來)。這條使用者要自己補。
        guard let _ = probe.pythonPath else { return .missingPython }

        // 4. 我們的 plist 已經在了、程式也在 installRoot → 只是沒跑起來,踢一下即可。
        if probe.launchAgentInstalled, case .installed = probe.bridgeSource {
            return .installedNotRunning
        }

        // 5. 有來源就裝。
        if let source = probe.bridgeSource { return .needsInstall(source) }

        // 6. 連 bridge 程式都找不到。
        return .missingBridgeSource
    }
}

// MARK: - 使用者看得到的檢查清單

/// 一條檢查項。凡是 app 自動化不了的,一律變成一條 blocked/warning 的項目 +
/// 可複製指令或說明連結 —— 絕不無聲失敗(M3 spec §5 驗收表最後一列)。
public struct BridgeChecklistItem: Equatable, Identifiable {
    public enum Status: Equatable {
        case ok
        case warning   // 不擋配對,但功能會少
        case blocked   // 擋住配對
        case pending   // 還在檢查
    }

    public let id: String
    public let title: String
    public let detail: String
    public let status: Status
    /// 「怎麼修」的說明連結。
    public let fixItURL: String?
    /// 「怎麼修」的可複製指令。
    public let fixItCommand: String?

    public init(id: String, title: String, detail: String, status: Status,
                fixItURL: String? = nil, fixItCommand: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.fixItURL = fixItURL
        self.fixItCommand = fixItCommand
    }
}

public enum BridgeChecklist {

    /// 由狀態 + 探測結果組出使用者看得懂的清單。
    /// `agentStates` 是 Claude Code / Codex 的偵測結果(可空),用來把「你得自己裝
    /// Claude Code」變成一條明確的項目,而不是等使用者配對完才發現沒引擎可用。
    public static func build(state: BridgeEnvironmentState,
                             probe: BridgeEnvironmentProbe,
                             layout: BridgeInstallLayout,
                             agentStates: [(cli: AgentCLI, state: AgentConnectionState)] = []) -> [BridgeChecklistItem] {
        var items: [BridgeChecklistItem] = []

        // ── Python ──────────────────────────────────────────────────────────
        if let python = probe.pythonPath {
            items.append(.init(id: "python", title: "Python 3.10+",
                               detail: python, status: .ok))
        } else {
            // 2026-10-05 文案修正:舊版教 `xcode-select --install`,但 CLT 給的
            // python3 是 3.9 —— bridge 用的 3.10+ 語法會直接 SyntaxError,照舊
            // 文案走完還是死路。正確路徑是 Homebrew 或 python.org 的新版。
            items.append(.init(
                id: "python", title: "Python 3.10+",
                detail: "找不到 Python 3.10 以上版本(系統內建的 3.9 跑不動 bridge)。用 Homebrew 裝一行搞定,或去 python.org 下載安裝器。",
                status: .blocked,
                fixItURL: "https://www.python.org/downloads/macos/",
                fixItCommand: "brew install python"))
        }

        // ── bridge 程式來源 ──────────────────────────────────────────────────
        if let source = probe.bridgeSource {
            items.append(.init(id: "source", title: "Bridge 程式",
                               detail: "\(source.displayName) · \(source.path)", status: .ok))
        } else {
            items.append(.init(
                id: "source", title: "Bridge 程式",
                detail: "這個版本的 Pocket 沒有內附 bridge,本機也找不到 bridge 原始碼。請照說明取得後再重新檢查。",
                status: .blocked,
                fixItURL: "https://github.com/cashtsai/pocket-connect/blob/main/docs/INSTALL_FAQ.md"))
        }

        // ── LaunchAgent ─────────────────────────────────────────────────────
        items.append(.init(
            id: "launchagent", title: "背景服務(LaunchAgent)",
            detail: probe.launchAgentInstalled
                ? layout.launchAgentPath
                : "尚未建立 —— 按「一鍵安裝」會自動寫入並啟動。",
            status: probe.launchAgentInstalled ? .ok : .warning))

        // ── 服務健康 ────────────────────────────────────────────────────────
        switch state {
        case .ready, .readyButNoToken:
            items.append(.init(id: "health", title: "Bridge 服務",
                               detail: "已在 \(layout.healthURL) 回應", status: .ok))
        case .portBusy(let occupant):
            items.append(.init(
                id: "health", title: "Bridge 服務",
                detail: "埠 \(layout.port) 已被其他程式占用(\(occupant.command),PID \(occupant.pid)),而且它不是 Pocket 裝的。Pocket 不會覆蓋它 —— 請先停掉那個程式,或改用其他埠。",
                status: .blocked,
                fixItCommand: "lsof -nP -iTCP:\(layout.port) -sTCP:LISTEN"))
        case .installedNotRunning:
            items.append(.init(
                id: "health", title: "Bridge 服務",
                detail: "已安裝但沒在跑 —— 按「啟動」會重新拉起來。", status: .warning,
                fixItCommand: "launchctl kickstart -k gui/$(id -u)/\(layout.label)"))
        case .needsInstall, .missingPython, .missingBridgeSource:
            items.append(.init(id: "health", title: "Bridge 服務",
                               detail: "尚未安裝", status: .warning))
        }

        // ── 金鑰 ────────────────────────────────────────────────────────────
        if let source = probe.tokenSource {
            items.append(.init(id: "token", title: "BRIDGE_TOKEN",
                               detail: "已讀到(來源:\(source.displayName))", status: .ok))
        } else {
            // bridge 已經活著卻沒有金鑰 = 配對一定失敗(pair/new 需要 bearer),
            // 所以是 blocked 不是 warning。還沒裝好時金鑰本來就還沒產生,那才是 warning。
            items.append(.init(
                id: "token", title: "BRIDGE_TOKEN",
                detail: probe.health.isOK
                    ? "服務活著但讀不到金鑰,配對會失敗。請到「連線設定」把 BRIDGE_TOKEN 貼上。"
                    : "讀不到金鑰。安裝完會自動產生;若你用自己的 bridge,請到「連線設定」手動貼上。",
                status: probe.health.isOK ? .blocked : .warning))
        }

        // ── AI 引擎(使用者必須自己裝/登入,app 代勞不了)──────────────────────
        for (cli, agentState) in agentStates {
            switch agentState {
            case .connected(let account):
                items.append(.init(id: "agent-\(cli.rawValue)", title: cli.displayName,
                                   detail: account ?? "已連接", status: .ok))
            case .notLoggedIn:
                items.append(.init(
                    id: "agent-\(cli.rawValue)", title: cli.displayName,
                    detail: "已安裝但尚未登入 —— 到控制台「AI 引擎」按「連接」完成授權。",
                    status: .warning, fixItURL: cli.websiteURL))
            case .notInstalled:
                items.append(.init(
                    id: "agent-\(cli.rawValue)", title: cli.displayName,
                    detail: "尚未安裝。Pocket 不會替你安裝 AI CLI —— 請自行用下面這行指令裝好。",
                    status: .warning,
                    fixItURL: cli.websiteURL, fixItCommand: cli.installCommand))
            }
        }

        return items
    }
}

// MARK: - lsof / ps 輸出解析(純函式)

public enum PortProbeParser {

    /// 解析 `lsof -nP -iTCP:<port> -sTCP:LISTEN -F pcn` 的輸出。
    /// 格式是每行一個欄位,首字母是欄位名:p=pid、c=command、n=name。
    /// 取第一個「同時有 pid 與 command」的行程。
    public static func parseLsof(_ output: String) -> PortOccupant? {
        var pid: Int32?
        var command: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            switch marker {
            case "p":
                // 新的行程區塊開始 —— 前一個沒湊齊就丟掉。
                pid = Int32(value)
                command = nil
            case "c":
                command = value
            default:
                break
            }
            if let p = pid, let c = command, !c.isEmpty {
                return PortOccupant(pid: p, command: c)
            }
        }
        return nil
    }

    /// 解析 `ps -p <pid> -o comm=` 的輸出(單行完整執行檔路徑)。
    public static func parsePSComm(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - LaunchAgent plist 讀取(純函式)

public enum BridgeTokenReader {

    /// 依序要找的 LaunchAgent plist:先看 Pocket 自己裝的,再看開發機上既有的
    /// Hermes bridge。回傳 (路徑, 來源標記)。
    public static func candidatePlists(layout: BridgeInstallLayout)
        -> [(path: String, source: BridgeTokenSource)] {
        [
            (layout.launchAgentPath, .pocketLaunchAgent),
            (layout.legacyLaunchAgentPath, .hermesLaunchAgent),
        ]
    }

    /// 從 LaunchAgent plist 的位元組取出 `EnvironmentVariables.BRIDGE_TOKEN`。
    public static func parse(plistData data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let envVars = plist["EnvironmentVariables"] as? [String: Any],
              let token = envVars["BRIDGE_TOKEN"] as? String
        else { return nil }
        return sanitize(token)
    }

    /// 空白、佔位字串一律視為「沒有金鑰」,免得拿佔位符去打 API 換一個看不懂的 401。
    public static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        let lower = t.lowercased()
        for placeholder in ["change-me", "replace_with_bridge_token", "changeme"] where lower.hasPrefix(placeholder) {
            return nil
        }
        return t
    }
}
