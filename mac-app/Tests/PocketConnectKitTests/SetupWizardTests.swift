import XCTest
@testable import PocketConnectKit

// 首次安裝引導精靈的決策層測試。
//
// 這幾條就是「掃上去馬上用」的保證,壞一條就是使用者配對成功卻看到空殼:
//   • 兩個引擎都沒登入 → QR 必須被擋
//   • 只有 Claude Code 登入 → 放行
//   • bridge 沒跑 → 擋在 ② ,而且**不會**去問引擎(問不準,不能冤枉使用者)
final class SetupWizardTests: XCTestCase {

    private let home = "/Users/tester"
    private var layout: BridgeInstallLayout {
        BridgeInstallLayout.resolve(home: home, environment: [:])
    }

    /// 一台 bridge 已經跑起來、python 也有的機器(① ② 綠)。
    private var healthyProbe: BridgeEnvironmentProbe {
        BridgeEnvironmentProbe(pythonPath: "/opt/homebrew/bin/python3",
                               bridgeSource: .installed("\(home)/bridge"),
                               launchAgentInstalled: true,
                               tokenSource: .pocketLaunchAgent,
                               health: .ok)
    }

    private var lanOnly: ReachabilityReport {
        ReachabilityReport.make(localIPv4: ["192.168.1.20"], bridgePort: 8081, tunnelURL: nil)
    }

    private func plan(bridgeState: BridgeEnvironmentState?,
                      probe: BridgeEnvironmentProbe? = nil,
                      agents: AgentAuthSnapshot?,
                      reach: ReachabilityReport? = nil) -> SetupWizardPlan {
        SetupWizardPlanner.plan(bridgeState: bridgeState,
                                probe: probe ?? healthyProbe,
                                layout: layout,
                                agents: agents,
                                reach: reach ?? lanOnly)
    }

    private func agent(installed: Bool, loggedIn: Bool? = nil, account: String? = nil)
        -> AgentAuthSnapshot.Agent {
        .init(installed: installed, loggedIn: loggedIn, account: account)
    }

    // MARK: - 硬規則:QR 擋放

    func testBothAgentsLoggedOutBlocksQR() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: false),
                                               codex: agent(installed: true, loggedIn: false)))
        XCTAssertEqual(p.gate, .noUsableAgent)
        XCTAssertFalse(p.gate.allowsQR, "兩個引擎都沒登入還放人掃 QR = 手機那頭是空殼")
        // 兩列都要是紅燈 + 都要給得出可按的動作(紅燈不准只有一句話)。
        for step in [SetupWizardStep.claude, .codex] {
            let row = p.row(step)
            XCTAssertEqual(row?.status, .blocked, "\(step) 應該是紅燈")
            XCTAssertEqual(row?.action, .loginAgent(step == .claude ? .claude : .codex))
        }
        XCTAssertEqual(p.row(.qr)?.status, .blocked)
        XCTAssertNil(p.row(.qr)?.action, "擋住時不准出現「拿手機掃」的鈕")
    }

    func testBothAgentsMissingBlocksQRAndOffersInstall() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: false, loggedIn: nil),
                                               codex: agent(installed: false, loggedIn: nil)))
        XCTAssertEqual(p.gate, .noUsableAgent, "沒裝就不是「檢查中」—— 不會有人幫你裝完")
        XCTAssertFalse(p.gate.allowsQR)
        XCTAssertEqual(p.row(.claude)?.action, .installAgent(.claude))
        XCTAssertEqual(p.row(.codex)?.action, .installAgent(.codex))
    }

    func testOnlyClaudeLoggedInAllowsQR() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(
                        claude: agent(installed: true, loggedIn: true, account: "cash@tsai.cash · max"),
                        codex: agent(installed: false, loggedIn: nil)))
        XCTAssertEqual(p.gate, .ready)
        XCTAssertTrue(p.gate.allowsQR, "一個引擎登入好就夠用了")
        XCTAssertEqual(p.row(.claude)?.status, .ok)
        XCTAssertTrue(p.row(.claude)?.detail.contains("cash@tsai.cash") == true)
        // Codex 沒裝只是「少一個選擇」→ 黃燈,不是紅燈。
        XCTAssertEqual(p.row(.codex)?.status, .warning)
        XCTAssertEqual(p.row(.qr)?.status, .ok)
        XCTAssertEqual(p.row(.qr)?.action, .openQR)
    }

    func testEnglishCLIAccountStringsAreNotShownRaw() {
        // codex 回的是 "Logged in using ChatGPT" —— 使用者不該看到這串英文。
        XCTAssertEqual(SetupWizardPlanner.prettyAccount("Logged in using ChatGPT"), "ChatGPT 帳號")
        XCTAssertEqual(SetupWizardPlanner.prettyAccount("Logged in using an API key"), "API 金鑰")
        XCTAssertEqual(SetupWizardPlanner.prettyAccount("cash@tsai.cash · max"), "cash@tsai.cash · max")
        XCTAssertNil(SetupWizardPlanner.prettyAccount("some unexpected cli chatter"))
        XCTAssertNil(SetupWizardPlanner.prettyAccount("   "))

        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: true),
                                               codex: agent(installed: true, loggedIn: true,
                                                            account: "Logged in using ChatGPT")))
        XCTAssertFalse(p.row(.codex)?.detail.contains("Logged in") == true)
        XCTAssertTrue(p.row(.codex)?.detail.contains("ChatGPT 帳號") == true)
    }

    func testOnlyCodexLoggedInAlsoAllowsQR() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: false),
                                               codex: agent(installed: true, loggedIn: true)))
        XCTAssertTrue(p.gate.allowsQR)
        XCTAssertEqual(p.row(.claude)?.status, .warning)
        XCTAssertEqual(p.row(.codex)?.status, .ok)
    }

    func testAgentStillCheckingIsPendingNotBlocked() {
        // bridge 冷啟時 logged_in = null(還在探)。這時候畫紅燈會嚇到使用者。
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: nil),
                                               codex: agent(installed: false, loggedIn: nil)))
        XCTAssertEqual(p.gate, .checkingAgents)
        XCTAssertFalse(p.gate.allowsQR, "還不確定有沒有引擎可用 → 先別放 QR")
        XCTAssertEqual(p.row(.claude)?.status, .pending)
        XCTAssertEqual(p.row(.qr)?.status, .pending)
    }

    // MARK: - bridge 沒跑 → 擋在前面,不問引擎

    func testBridgeNotRunningBlocksBeforeAskingAgents() {
        for state in [BridgeEnvironmentState.needsInstall(.bundled("/x")),
                      .installedNotRunning,
                      .readyButNoToken,
                      .missingPython,
                      .missingBridgeSource,
                      .portBusy(PortOccupant(pid: 42, command: "node"))] {
            // 故意餵一組「兩個引擎都登入好」的資料 —— 就算有,也不該被採信/顯示。
            let p = plan(bridgeState: state,
                         agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: true),
                                                   codex: agent(installed: true, loggedIn: true)))
            XCTAssertEqual(p.gate, .waitingBridge, "\(state):bridge 沒就緒就該擋在 ②")
            XCTAssertFalse(p.gate.allowsQR)
            XCTAssertEqual(p.row(.claude)?.status, .pending, "\(state):bridge 沒活時問不準,要畫「等前面」")
            XCTAssertEqual(p.row(.codex)?.status, .pending)
            XCTAssertNil(p.row(.claude)?.action, "\(state):還沒問到就不該叫使用者去登入")
            XCTAssertEqual(p.row(.qr)?.status, .pending)
        }
    }

    func testFirstProbeNotBackYetIsAllPendingNotRed() {
        let p = plan(bridgeState: nil, probe: BridgeEnvironmentProbe(),
                     agents: nil, reach: .checking)
        XCTAssertEqual(p.gate, .waitingBridge)
        XCTAssertEqual(p.row(.bridge)?.status, .pending)
        XCTAssertEqual(p.row(.reach)?.status, .pending)
    }

    func testBridgeReadyButAgentsNotFetchedYetIsChecking() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil)
        XCTAssertEqual(p.gate, .checkingAgents)
        XCTAssertFalse(p.gate.allowsQR)
    }

    // MARK: - 六列齊全 + 每個紅燈都有動作

    func testAlwaysSixRowsInFixedOrder() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: true),
                                               codex: agent(installed: true, loggedIn: true)))
        XCTAssertEqual(p.rows.map(\.step), [.python, .bridge, .reach, .claude, .codex, .qr])
        XCTAssertEqual(p.rows.map(\.number), ["①", "②", "③", "④", "⑤", "⑥"])
    }

    func testEveryBlockedRowHasSomethingToPress() {
        // 掃一遍各種壞法,任何一列紅燈都必須有動作或說明連結可按。
        struct Case {
            var state: BridgeEnvironmentState?
            var probe: BridgeEnvironmentProbe?
            var agents: AgentAuthSnapshot?
        }
        let cases: [Case] = [
            Case(state: .needsInstall(.bundled("/x")), probe: BridgeEnvironmentProbe(pythonPath: "/p")),
            Case(state: .missingPython, probe: BridgeEnvironmentProbe()),
            Case(state: .portBusy(PortOccupant(pid: 1, command: "node")),
                 probe: BridgeEnvironmentProbe(pythonPath: "/p")),
            Case(state: .installedNotRunning, probe: BridgeEnvironmentProbe(pythonPath: "/p")),
            Case(state: .readyButNoToken, probe: BridgeEnvironmentProbe(pythonPath: "/p", health: .ok)),
            Case(state: .missingBridgeSource, probe: BridgeEnvironmentProbe(pythonPath: "/p")),
            Case(state: .ready(.pocketLaunchAgent),
                 agents: AgentAuthSnapshot(claude: .init(installed: false), codex: .init(installed: false))),
            Case(state: .ready(.pocketLaunchAgent),
                 agents: AgentAuthSnapshot(claude: .init(installed: true, loggedIn: false),
                                           codex: .init(installed: true, loggedIn: false))),
        ]

        for (state, probe, agents) in cases.map({ ($0.state, $0.probe ?? healthyProbe, $0.agents) }) {
            let p = plan(bridgeState: state, probe: probe, agents: agents)
            for row in p.rows where row.status == .blocked {
                // ⑥ 是結果不是原因 —— 它的「怎麼辦」寫在 detail,解法鈕在上面那幾列。
                if row.step == .qr {
                    XCTAssertFalse(row.detail.isEmpty)
                    continue
                }
                XCTAssertTrue(row.action != nil || row.helpURL != nil,
                              "\(String(describing: state)) 的 \(row.step) 是紅燈卻沒有任何可按的東西")
            }
        }
    }

    func testNoUserFacingTextLeaksTechnicalNoise() {
        // 文案紅線:不給使用者看 traceback / exit code / 英文技術訊息。
        let noise = ["Traceback", "exit code", "errno", "stderr", "launchctl", "lsof",
                     "127.0.0.1", "LaunchAgent", "plist", "BRIDGE_TOKEN", "HTTP"]
        let states: [BridgeEnvironmentState] = [
            .ready(.pocketLaunchAgent), .readyButNoToken, .installedNotRunning,
            .needsInstall(.bundled("/x")), .portBusy(PortOccupant(pid: 1, command: "node")),
            .missingPython, .missingBridgeSource,
        ]
        for state in states {
            let p = plan(bridgeState: state, probe: BridgeEnvironmentProbe(health: .ok), agents: nil)
            for row in p.rows {
                for word in noise {
                    XCTAssertFalse(row.detail.localizedCaseInsensitiveContains(word),
                                   "\(row.step) 的文案出現技術雜訊「\(word)」:\(row.detail)")
                }
            }
        }
    }

    // MARK: - ③ 對外通道

    func testTailnetAddressIsReportedAsRemoteCapable() {
        let reach = ReachabilityReport.make(localIPv4: ["192.168.1.20", "100.101.102.103"],
                                            bridgePort: 8081, tunnelURL: nil)
        // 優先序:tailnet 在 LAN 前面。
        XCTAssertEqual(reach.channels.first, .tailnet("http://100.101.102.103:8081"))
        let row = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil, reach: reach).row(.reach)
        XCTAssertEqual(row?.status, .ok)
        XCTAssertTrue(row?.detail.contains("100.101.102.103:8081") == true, "要給人看得到的實際位址")
    }

    func testTunnelCountsAsRemoteCapable() {
        let reach = ReachabilityReport.make(localIPv4: ["192.168.1.20"], bridgePort: 8081,
                                            tunnelURL: "https://abc.trycloudflare.com")
        XCTAssertEqual(reach.remoteChannel, .tunnel("https://abc.trycloudflare.com"))
        let row = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil, reach: reach).row(.reach)
        XCTAssertEqual(row?.status, .ok)
        XCTAssertTrue(row?.detail.contains("abc.trycloudflare.com") == true)
    }

    /// 免費臨時通道「能用」,但**位址會變** —— 精靈必須在配對當下就講。
    ///
    /// 不講的代價是把問題延後到最糟的時刻:使用者人在外面、手機在手上、
    /// 連不上、而且不知道為什麼。這是免費層唯一真的會卡住人的情境。
    func testEphemeralTunnelWarnsThatTheAddressChanges() {
        let reach = ReachabilityReport.make(localIPv4: ["192.168.1.20"], bridgePort: 8081,
                                            tunnelURL: "https://abc.trycloudflare.com")
        let row = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil, reach: reach).row(.reach)
        XCTAssertTrue(row?.detail.contains("會換") == true, "必須講明網址會變")
        XCTAssertTrue(row?.detail.contains("Tailscale") == true, "必須給出一勞永逸的那條路")
        XCTAssertEqual(row?.helpURL, "https://tailscale.com/download/mac")
    }

    /// 反過來:固定位址(使用者自填)**不該**出現那段警告 —— 它不會變。
    func testFixedAddressDoesNotWarn() {
        let reach = ReachabilityReport.make(localIPv4: ["192.168.1.20"], bridgePort: 8081,
                                            tunnelURL: "https://pocket.example.com")
        let row = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil, reach: reach).row(.reach)
        XCTAssertFalse(row?.detail.contains("會換") == true, "固定位址不會變,不該嚇人")
        XCTAssertTrue(row?.detail.contains("不會變") == true)
    }

    func testLanOnlyIsHonestWarningAndNeverBlocksQR() {
        let p = plan(bridgeState: .ready(.pocketLaunchAgent),
                     agents: AgentAuthSnapshot(claude: agent(installed: true, loggedIn: true),
                                               codex: agent(installed: false)),
                     reach: lanOnly)
        XCTAssertEqual(p.row(.reach)?.status, .warning)
        XCTAssertTrue(p.row(.reach)?.detail.contains("只能在同一個網路") == true)
        XCTAssertTrue(p.gate.allowsQR, "只有區網照樣能配對,不該擋 QR")
    }

    func testNoAddressAtAllOffersRecheck() {
        let reach = ReachabilityReport.make(localIPv4: [], bridgePort: 8081, tunnelURL: nil)
        let row = plan(bridgeState: .ready(.pocketLaunchAgent), agents: nil, reach: reach).row(.reach)
        XCTAssertEqual(row?.status, .warning)
        XCTAssertEqual(row?.action, .recheck)
    }

    func testPublicIPsAreNotAdvertisedAsLan() {
        let reach = ReachabilityReport.make(localIPv4: ["8.8.8.8"], bridgePort: 8081, tunnelURL: nil)
        XCTAssertTrue(reach.channels.isEmpty, "公網 IP 不是私網候選,不能當成同網路直連")
    }

    // MARK: - ④⑤ JSON 解析(bridge /app/v1/agents/auth)

    func testParseAgentAuthHappyPath() throws {
        let json = """
        {"claude":{"installed":true,"logged_in":true,"account":"cash@tsai.cash · max"},
         "codex":{"installed":true,"logged_in":false,"account":null}}
        """
        let snap = try XCTUnwrap(AgentAuthSnapshot.parse(Data(json.utf8)))
        XCTAssertTrue(snap.claude.isUsable)
        XCTAssertEqual(snap.claude.account, "cash@tsai.cash · max")
        XCTAssertFalse(snap.codex.isUsable)
        XCTAssertNil(snap.codex.account)
        XCTAssertTrue(snap.hasUsableAgent)
    }

    func testParseAgentAuthCheckingShape() throws {
        // bridge 冷啟:logged_in 是 null + checking:true。
        let json = """
        {"claude":{"installed":true,"logged_in":null,"account":null},
         "codex":{"installed":true,"logged_in":null,"account":null},"checking":true}
        """
        let snap = try XCTUnwrap(AgentAuthSnapshot.parse(Data(json.utf8)))
        XCTAssertNil(snap.claude.loggedIn)
        XCTAssertTrue(snap.isStillChecking)
        XCTAssertFalse(snap.hasUsableAgent)
    }

    func testParseAgentAuthRejectsGarbage() {
        XCTAssertNil(AgentAuthSnapshot.parse(Data("not json".utf8)))
        XCTAssertNil(AgentAuthSnapshot.parse(Data("{}".utf8)), "空物件不能當成「兩個都沒裝」")
        XCTAssertNil(AgentAuthSnapshot.parse(Data("[]".utf8)))
    }

    func testParseAgentAuthMissingFieldsDefaultToNotInstalled() throws {
        let snap = try XCTUnwrap(AgentAuthSnapshot.parse(Data("{\"claude\":{}}".utf8)))
        XCTAssertFalse(snap.claude.installed)
        XCTAssertFalse(snap.codex.installed)
        XCTAssertFalse(snap.hasUsableAgent)
        XCTAssertFalse(snap.isStillChecking, "沒裝就不是檢查中")
    }
}
