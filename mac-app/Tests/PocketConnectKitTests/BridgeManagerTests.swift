import XCTest
@testable import PocketConnectKit

final class BridgeManagerTests: XCTestCase {

    func testLayoutUsesPocketConnectOwnedLaunchAgentAndAppSupport() {
        let layout = BridgeInstallLayout(homeDirectory: "/Users/rakutai")

        XCTAssertEqual(layout.bridgeInstallRoot,
                       "/Users/rakutai/Library/Application Support/PocketConnect/bridge/current")
        XCTAssertEqual(layout.launchAgentPath,
                       "/Users/rakutai/Library/LaunchAgents/com.pocketconnect.bridge.plist")
        XCTAssertEqual(layout.legacyLaunchAgentPath,
                       "/Users/rakutai/Library/LaunchAgents/ai.studio.hermes-bridge.plist")
        XCTAssertEqual(layout.defaultHealthURL.absoluteString,
                       "http://127.0.0.1:8081/health")
    }

    func testLayoutDoesNotBakeInProductionUser() {
        let layout = BridgeInstallLayout(homeDirectory: "/Users/fresh")

        XCTAssertFalse(layout.bridgeInstallRoot.contains("/Users/xcash"))
        XCTAssertFalse(layout.hermesHomeRoot.contains("/Users/xcash"))
        XCTAssertFalse(layout.openClawConfigFile.contains("/Users/xcash"))
        XCTAssertTrue(layout.hermesBinCandidates.allSatisfy { $0.hasPrefix("/Users/fresh/") })
    }

    func testInstallerPlanInjectsRuntimePaths() {
        let layout = BridgeInstallLayout(homeDirectory: "/Users/fresh")
        let plan = BridgeInstallPlan(
            layout: layout,
            bridgeBundleRoot: "/Applications/Pocket.app/Contents/Resources/bridge"
        )

        XCTAssertEqual(plan.installScriptPath,
                       "/Applications/Pocket.app/Contents/Resources/bridge/deploy/install-local-bridge.sh")
        XCTAssertEqual(plan.environment["POCKET_BRIDGE_LABEL"], "com.pocketconnect.bridge")
        XCTAssertEqual(plan.environment["POCKET_BRIDGE_INSTALL_ROOT"],
                       "/Users/fresh/Library/Application Support/PocketConnect/bridge/current")
        XCTAssertEqual(plan.environment["HERMES_HOME_ROOT"],
                       "/Users/fresh/apps/hermes-agent/home")
        XCTAssertEqual(plan.environment["OPENCLAW_CONFIG_FILE"],
                       "/Users/fresh/.pocket/openclaw.json")
        XCTAssertEqual(plan.environment["POCKET_PROVIDER"], "auto")
        XCTAssertEqual(plan.environment["POCKET_DEFAULT_PROVIDER"], "hermes")
    }

    func testInstallerPlanCanOverrideProviderChoice() {
        let layout = BridgeInstallLayout(homeDirectory: "/Users/fresh")
        let plan = BridgeInstallPlan(
            layout: layout,
            bridgeBundleRoot: "/tmp/bridge",
            existingEnvironment: [
                "POCKET_PROVIDER": "openclaw",
                "POCKET_DEFAULT_PROVIDER": "openclaw",
            ]
        )

        XCTAssertEqual(plan.environment["POCKET_PROVIDER"], "openclaw")
        XCTAssertEqual(plan.environment["POCKET_DEFAULT_PROVIDER"], "openclaw")
    }
}
