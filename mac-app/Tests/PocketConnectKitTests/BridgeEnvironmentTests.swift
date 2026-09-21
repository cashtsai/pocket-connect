import XCTest
@testable import PocketConnectKit

// M3 — 環境偵測決策層的單元測試。
//
// 沒辦法真的清空一台 Mac,所以「全新 Mac 的每一種狀況」在這裡用純資料重現:
// 缺 python / 缺 bridge 程式 / plist 不在 / bridge 已經在跑 / 埠被別人占。
// 這些分支決定了使用者第一次打開 Pocket 看到什麼,錯一個就是一條死路。

final class BridgeEnvironmentTests: XCTestCase {

    private let home = "/Users/tester"

    private func layout(_ environment: [String: String] = [:]) -> BridgeInstallLayout {
        BridgeInstallLayout.resolve(home: home, environment: environment)
    }

    // MARK: - 佈局

    func testDefaultLayoutIsPerUserAndNeverTouchesProductionHermes() {
        let l = layout()
        XCTAssertEqual(l.installRoot, "\(home)/Library/Application Support/PocketConnect/bridge/current")
        XCTAssertEqual(l.venvPath, "\(home)/Library/Application Support/PocketConnect/bridge/current/venv")
        XCTAssertEqual(l.label, "com.pocketconnect.bridge")
        XCTAssertEqual(l.launchAgentPath, "\(home)/Library/LaunchAgents/com.pocketconnect.bridge.plist")
        XCTAssertEqual(l.port, 8081)
        XCTAssertEqual(l.healthURL, "http://127.0.0.1:8081/health")
        XCTAssertEqual(l.installLogPath, "\(home)/Library/Logs/Pocket/install.log")
        // 紅線:絕不能算出 production 那顆 LaunchAgent 的 label/路徑。
        XCTAssertFalse(l.label.contains("hermes"))
        XCTAssertFalse(l.launchAgentPath.contains("ai.studio.hermes-bridge"))
    }

    func testLayoutHonoursTempPrefixOverridesForDryRun() {
        let l = layout([
            "POCKET_BRIDGE_INSTALL_ROOT": "/tmp/prefix/bridge",
            "POCKET_BRIDGE_LABEL": "com.example.test",
            "POCKET_LAUNCH_AGENTS_DIR": "/tmp/prefix/agents",
            "POCKET_BRIDGE_PORT": "9999",
            "POCKET_LOG_DIR": "/tmp/prefix/logs",
        ])
        XCTAssertEqual(l.installRoot, "/tmp/prefix/bridge")
        XCTAssertEqual(l.venvPath, "/tmp/prefix/bridge/venv")
        XCTAssertEqual(l.launchAgentPath, "/tmp/prefix/agents/com.example.test.plist")
        // 乾跑時把 LaunchAgents 目錄指到 TEMP prefix,連「既有 Hermes bridge」
        // 這條後備金鑰來源也一起被隔離掉 —— 才能重現「全新 Mac 讀不到金鑰」。
        XCTAssertEqual(l.legacyLaunchAgentPath, "/tmp/prefix/agents/ai.studio.hermes-bridge.plist")
        XCTAssertEqual(l.port, 9999)
        XCTAssertEqual(l.healthURL, "http://127.0.0.1:9999/health")
        XCTAssertEqual(l.installLogPath, "/tmp/prefix/logs/install.log")
    }

    func testCandidateListOverridesAreColonSeparated() {
        let l = layout([
            "POCKET_BRIDGE_PYTHON_CANDIDATES": "/a/python3:/b/python3",
            "POCKET_BRIDGE_SOURCE_CANDIDATES": "/src/one:/src/two",
        ])
        XCTAssertEqual(l.pythonCandidates, ["/a/python3", "/b/python3"])
        XCTAssertEqual(l.bridgeSourceCandidates, ["/src/one", "/src/two"])
    }

    func testBridgeSourcePriorityIsInstalledThenBundledThenCheckout() {
        let l = BridgeInstallLayout.resolve(home: home, environment: [:],
                                            bundledBridgePath: "/Apps/Pocket.app/Contents/Resources/bridge")
        XCTAssertEqual(l.bridgeSourceCandidates, [
            "\(home)/Library/Application Support/PocketConnect/bridge/current",
            "/Apps/Pocket.app/Contents/Resources/bridge",
            "\(home)/apps/hermes-openwebui-bridge",
        ])
    }

    func testInstallerEnvironmentPinsScriptToTheSameLayout() {
        let l = layout(["POCKET_BRIDGE_INSTALL_ROOT": "/tmp/x", "POCKET_BRIDGE_LABEL": "com.example.t"])
        let env = l.installerEnvironment
        XCTAssertEqual(env["POCKET_BRIDGE_INSTALL_ROOT"], "/tmp/x")
        XCTAssertEqual(env["POCKET_BRIDGE_VENV"], "/tmp/x/venv")
        XCTAssertEqual(env["POCKET_BRIDGE_LABEL"], "com.example.t")
    }

    // MARK: - 決策:每一個分支

    /// 分支 ①:bridge 活著 + 讀得到金鑰 → 直接可以出配對 QR。
    func testReadyWhenHealthyAndTokenPresent() {
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/opt/homebrew/bin/python3",
            bridgeSource: .installed("/root"),
            launchAgentInstalled: true,
            tokenSource: .pocketLaunchAgent,
            health: .ok)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()),
                       .ready(.pocketLaunchAgent))
        XCTAssertTrue(BridgeEnvironmentPlanner.plan(probe, layout: layout()).isReady)
    }

    /// 開發機情境:8081 上跑的是既有的 Hermes bridge。健康就沿用,
    /// **絕不**因為「我們的 plist 不在」就跑去重裝、搶埠。
    func testExistingHermesBridgeIsAdoptedNotReinstalled() {
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/opt/homebrew/bin/python3",
            bridgeSource: .localCheckout("\(home)/apps/hermes-openwebui-bridge"),
            launchAgentInstalled: false,          // 沒有 com.pocketconnect.bridge.plist
            tokenSource: .hermesLaunchAgent,
            health: .ok)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()),
                       .ready(.hermesLaunchAgent))
    }

    /// 分支 ②:服務活著但沒金鑰 → 要明講,不能靜靜地讓配對失敗。
    func testReadyButNoTokenWhenHealthyWithoutToken() {
        let probe = BridgeEnvironmentProbe(health: .ok)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .readyButNoToken)
        XCTAssertTrue(BridgeEnvironmentPlanner.plan(probe, layout: layout()).needsUserAction)
    }

    /// 分支 ③:埠上有別人的程式(不回 health)→ 絕不覆蓋。
    func testPortBusyByForeignProcess() {
        let occupant = PortOccupant(pid: 4242, command: "node",
                                    executablePath: "/opt/homebrew/bin/node")
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/opt/homebrew/bin/python3",
            bridgeSource: .installed("/root"),
            launchAgentInstalled: true,
            health: .unreachable,
            portOccupant: occupant)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .portBusy(occupant))
    }

    /// 埠上是**我們自己**的 venv python,只是還沒回應(剛啟動/卡住)→
    /// 不是 portBusy,而是「已安裝但沒跑起來」,踢一下就好。
    func testOurOwnStalledBridgeIsNotTreatedAsPortBusy() {
        let l = layout()
        let occupant = PortOccupant(pid: 99, command: "Python",
                                    executablePath: l.venvPath + "/bin/python3.12")
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/opt/homebrew/bin/python3",
            bridgeSource: .installed(l.installRoot),
            launchAgentInstalled: true,
            health: .unreachable,
            portOccupant: occupant)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: l), .installedNotRunning)
    }

    /// 埠上是別的服務且回了非 200(例如某個 web app)→ 一樣算被占用。
    func testHTTPErrorFromForeignServiceIsPortBusy() {
        let occupant = PortOccupant(pid: 7, command: "nginx", executablePath: "/usr/sbin/nginx")
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/opt/homebrew/bin/python3",
            bridgeSource: .installed("/root"),
            health: .httpError(404),
            portOccupant: occupant)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .portBusy(occupant))
    }

    /// 分支 ④:沒 python3 → app 代勞不了,要使用者自己裝。
    func testMissingPythonBlocksEverything() {
        let probe = BridgeEnvironmentProbe(
            pythonPath: nil,
            bridgeSource: .bundled("/Apps/Pocket.app/Contents/Resources/bridge"),
            health: .unreachable)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .missingPython)
        XCTAssertTrue(BridgeEnvironmentPlanner.plan(probe, layout: layout()).needsUserAction)
    }

    /// 分支 ⑤:plist 在、程式也在 installRoot,只是沒跑 → kickstart。
    func testInstalledButNotRunning() {
        let l = layout()
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/usr/bin/python3",
            bridgeSource: .installed(l.installRoot),
            launchAgentInstalled: true,
            health: .unreachable)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: l), .installedNotRunning)
    }

    /// plist 不在,但 app 內附了 bridge → 全新 Mac 的正路:一鍵安裝。
    func testFreshMacWithBundledBridgeNeedsInstall() {
        let source = BridgeSource.bundled("/Apps/Pocket.app/Contents/Resources/bridge")
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/usr/bin/python3",
            bridgeSource: source,
            launchAgentInstalled: false,
            health: .unreachable)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .needsInstall(source))
    }

    /// 程式已經 rsync 進 installRoot 但 plist 被使用者砍了 → 重跑安裝腳本補回來。
    func testInstalledSourceWithoutLaunchAgentReinstalls() {
        let l = layout()
        let source = BridgeSource.installed(l.installRoot)
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/usr/bin/python3",
            bridgeSource: source,
            launchAgentInstalled: false,
            health: .unreachable)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: l), .needsInstall(source))
    }

    /// 分支 ⑥:連 bridge 程式都找不到(app 沒內附、本機也沒 checkout)。
    func testMissingBridgeSource() {
        let probe = BridgeEnvironmentProbe(
            pythonPath: "/usr/bin/python3",
            bridgeSource: nil,
            launchAgentInstalled: false,
            health: .unreachable)
        XCTAssertEqual(BridgeEnvironmentPlanner.plan(probe, layout: layout()), .missingBridgeSource)
        XCTAssertTrue(BridgeEnvironmentPlanner.plan(probe, layout: layout()).needsUserAction)
    }

    // MARK: - 檢查清單:自動化不了的一定要有出路

    func testMissingPythonChecklistOffersAFixItCommand() throws {
        let probe = BridgeEnvironmentProbe(pythonPath: nil, bridgeSource: nil, health: .unreachable)
        let items = BridgeChecklist.build(state: .missingPython, probe: probe, layout: layout())
        let python = try XCTUnwrap(items.first { $0.id == "python" })
        XCTAssertEqual(python.status, .blocked)
        XCTAssertEqual(python.fixItCommand, "xcode-select --install")
        XCTAssertNotNil(python.fixItURL)
    }

    func testPortBusyChecklistNamesTheOccupantAndHowToLookItUp() {
        let occupant = PortOccupant(pid: 4242, command: "node", executablePath: "/opt/homebrew/bin/node")
        let probe = BridgeEnvironmentProbe(pythonPath: "/usr/bin/python3",
                                           bridgeSource: .installed("/root"),
                                           health: .unreachable, portOccupant: occupant)
        let items = BridgeChecklist.build(state: .portBusy(occupant), probe: probe, layout: layout())
        let health = items.first { $0.id == "health" }
        XCTAssertEqual(health?.status, .blocked)
        XCTAssertTrue(health?.detail.contains("4242") == true)
        XCTAssertTrue(health?.detail.contains("node") == true)
        XCTAssertEqual(health?.fixItCommand, "lsof -nP -iTCP:8081 -sTCP:LISTEN")
    }

    /// 使用者必須自己裝 Claude Code —— 這件事一定要變成清單上一條有安裝指令的項目,
    /// 不能等他配對完才發現手機那頭沒有引擎可用。
    func testUninstalledAgentBecomesAnExplicitChecklistItem() {
        let probe = BridgeEnvironmentProbe(pythonPath: "/usr/bin/python3",
                                           bridgeSource: .installed("/root"),
                                           tokenSource: .pocketLaunchAgent, health: .ok)
        let items = BridgeChecklist.build(
            state: .ready(.pocketLaunchAgent), probe: probe, layout: layout(),
            agentStates: [(.claude, .notInstalled), (.codex, .connected(account: "cash@example.com"))])
        let claude = items.first { $0.id == "agent-claude" }
        XCTAssertEqual(claude?.status, .warning)
        XCTAssertEqual(claude?.fixItCommand, AgentCLI.claude.installCommand)
        XCTAssertEqual(claude?.fixItURL, AgentCLI.claude.websiteURL)
        let codex = items.first { $0.id == "agent-codex" }
        XCTAssertEqual(codex?.status, .ok)
        XCTAssertEqual(codex?.detail, "cash@example.com")
    }

    func testReadyChecklistHasNoBlockedItems() {
        let probe = BridgeEnvironmentProbe(pythonPath: "/usr/bin/python3",
                                           bridgeSource: .installed("/root"),
                                           launchAgentInstalled: true,
                                           tokenSource: .pocketLaunchAgent, health: .ok)
        let items = BridgeChecklist.build(state: .ready(.pocketLaunchAgent), probe: probe, layout: layout())
        XCTAssertFalse(items.contains { $0.status == .blocked })
        XCTAssertTrue(items.contains { $0.id == "token" && $0.status == .ok })
    }

    /// 服務活著但沒金鑰 → 金鑰那條要是 blocked(不是 warning),因為配對真的會失敗
    /// (`/app/v1/pair/new` 要 bearer)。乾跑案例 ⑦ 抓到過這個:原本寫成 warning,
    /// 使用者會看到一片「黃燈」卻在按下配對時才失敗。
    func testHealthyWithoutTokenBlocksOnTheTokenRow() {
        let probe = BridgeEnvironmentProbe(pythonPath: "/usr/bin/python3",
                                           bridgeSource: .installed("/root"),
                                           launchAgentInstalled: true, health: .ok)
        let items = BridgeChecklist.build(state: .readyButNoToken, probe: probe, layout: layout())
        XCTAssertEqual(items.first { $0.id == "token" }?.status, .blocked)
    }

    /// 反過來:還沒安裝時沒有金鑰是正常的,那是 warning 不是 blocked
    /// —— 不然全新 Mac 一開就看到兩顆紅燈,使用者會以為壞掉了。
    func testNotYetInstalledTokenRowIsOnlyAWarning() {
        let probe = BridgeEnvironmentProbe(pythonPath: "/usr/bin/python3",
                                           bridgeSource: .bundled("/payload"),
                                           launchAgentInstalled: false, health: .unreachable)
        let items = BridgeChecklist.build(state: .needsInstall(.bundled("/payload")),
                                          probe: probe, layout: layout())
        XCTAssertEqual(items.first { $0.id == "token" }?.status, .warning)
        XCTAssertFalse(items.contains { $0.status == .blocked })
    }

    // MARK: - lsof / ps 解析

    func testParseLsofPickerFirstListeningProcess() {
        // 實測 `lsof -nP -iTCP:8081 -sTCP:LISTEN -F pcn` 的輸出格式。
        let output = """
        p50326
        cPython
        f12
        n*:8081
        """
        XCTAssertEqual(PortProbeParser.parseLsof(output),
                       PortOccupant(pid: 50326, command: "Python"))
    }

    func testParseLsofEmptyOutputMeansNobodyIsListening() {
        XCTAssertNil(PortProbeParser.parseLsof(""))
        XCTAssertNil(PortProbeParser.parseLsof("\n\n"))
    }

    func testParseLsofIgnoresPidWithoutCommand() {
        XCTAssertNil(PortProbeParser.parseLsof("p123\nf5\nn*:8081"))
    }

    func testParsePSComm() {
        XCTAssertEqual(
            PortProbeParser.parsePSComm("  /opt/homebrew/Cellar/python@3.12/bin/Python \n"),
            "/opt/homebrew/Cellar/python@3.12/bin/Python")
        XCTAssertNil(PortProbeParser.parsePSComm("   \n"))
    }

    func testPocketManagedDetectionUsesTheVenvPrefix() {
        let l = layout()
        XCTAssertTrue(PortOccupant(pid: 1, command: "Python",
                                   executablePath: l.venvPath + "/bin/python3")
            .isPocketManaged(venvPath: l.venvPath))
        XCTAssertFalse(PortOccupant(pid: 1, command: "Python",
                                    executablePath: "/opt/homebrew/bin/python3")
            .isPocketManaged(venvPath: l.venvPath))
        // 拿不到執行檔路徑時保守處理:當成別人的,不去覆蓋。
        XCTAssertFalse(PortOccupant(pid: 1, command: "Python").isPocketManaged(venvPath: l.venvPath))
    }

    // MARK: - 金鑰讀取

    func testTokenCandidateOrderPrefersPocketOwnLaunchAgent() {
        let l = layout()
        let candidates = BridgeTokenReader.candidatePlists(layout: l)
        XCTAssertEqual(candidates.map(\.source), [.pocketLaunchAgent, .hermesLaunchAgent])
        XCTAssertEqual(candidates[0].path, l.launchAgentPath)
        XCTAssertEqual(candidates[1].path, "\(home)/Library/LaunchAgents/ai.studio.hermes-bridge.plist")
        XCTAssertEqual(candidates[1].path, l.legacyLaunchAgentPath)
    }

    func testParsePlistExtractsBridgeToken() throws {
        let plist: [String: Any] = ["EnvironmentVariables": ["BRIDGE_TOKEN": "studio-abc123"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        XCTAssertEqual(BridgeTokenReader.parse(plistData: data), "studio-abc123")
    }

    func testParsePlistWithoutTokenReturnsNil() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.example"], format: .xml, options: 0)
        XCTAssertNil(BridgeTokenReader.parse(plistData: data))
        XCTAssertNil(BridgeTokenReader.parse(plistData: Data("not a plist".utf8)))
    }

    func testSanitizeRejectsPlaceholders() {
        XCTAssertNil(BridgeTokenReader.sanitize(""))
        XCTAssertNil(BridgeTokenReader.sanitize("   "))
        XCTAssertNil(BridgeTokenReader.sanitize("CHANGE-ME"))
        XCTAssertNil(BridgeTokenReader.sanitize("REPLACE_WITH_BRIDGE_TOKEN"))
        XCTAssertEqual(BridgeTokenReader.sanitize("  real-token  "), "real-token")
    }
}
