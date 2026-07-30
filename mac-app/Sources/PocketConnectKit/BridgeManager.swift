import Foundation

/// PocketConnect-owned layout for installing and maintaining the local bridge.
///
/// The DMG installs PocketConnect.app; the app then uses this layout to install
/// or upgrade the per-user bridge bundle. Keeping the paths here prevents new
/// machines from inheriting production-only `/Users/xcash/...` assumptions.
public struct BridgeInstallLayout: Equatable {
    public static let launchAgentLabel = "com.pocketconnect.bridge"
    public static let legacyLaunchAgentLabel = "ai.studio.hermes-bridge"

    public let homeDirectory: String
    public let applicationSupportRoot: String

    public init(homeDirectory: String,
                applicationSupportRoot: String? = nil) {
        self.homeDirectory = homeDirectory
        self.applicationSupportRoot = applicationSupportRoot
            ?? homeDirectory + "/Library/Application Support/PocketConnect"
    }

    public var bridgeInstallRoot: String {
        applicationSupportRoot + "/bridge/current"
    }

    public var launchAgentPath: String {
        homeDirectory + "/Library/LaunchAgents/" + Self.launchAgentLabel + ".plist"
    }

    public var legacyLaunchAgentPath: String {
        homeDirectory + "/Library/LaunchAgents/" + Self.legacyLaunchAgentLabel + ".plist"
    }

    public var hermesHomeRoot: String {
        homeDirectory + "/apps/hermes-agent/home"
    }

    public var openClawInstallRoot: String {
        homeDirectory + "/apps/openclaw-clean"
    }

    public var openClawConfigFile: String {
        homeDirectory + "/.pocket/openclaw.json"
    }

    public var defaultHealthURL: URL {
        URL(string: "http://127.0.0.1:8081/health")!
    }

    public var hermesBinCandidates: [String] {
        [
            homeDirectory + "/apps/hermes-agent/runtime/venv/bin/hermes",
            homeDirectory + "/apps/hermes-agent/venv/bin/hermes",
            homeDirectory + "/.local/bin/hermes",
        ]
    }

    public func installerEnvironment(bridgeBundleRoot: String,
                                     existingEnvironment: [String: String] = [:]) -> [String: String] {
        var env = existingEnvironment
        env["POCKET_BRIDGE_LABEL"] = Self.launchAgentLabel
        env["POCKET_BRIDGE_INSTALL_ROOT"] = bridgeInstallRoot
        env["HERMES_HOME_ROOT"] = hermesHomeRoot
        env["OPENCLAW_CONFIG_FILE"] = openClawConfigFile
        env["POCKET_PROVIDER"] = env["POCKET_PROVIDER"] ?? "auto"
        env["POCKET_DEFAULT_PROVIDER"] = env["POCKET_DEFAULT_PROVIDER"] ?? "hermes"
        env["POCKET_BRIDGE_BUNDLE_ROOT"] = bridgeBundleRoot
        return env
    }
}

public struct BridgeInstallPlan: Equatable {
    public let installScriptPath: String
    public let environment: [String: String]

    public init(layout: BridgeInstallLayout,
                bridgeBundleRoot: String,
                existingEnvironment: [String: String] = [:]) {
        self.installScriptPath = bridgeBundleRoot + "/deploy/install-local-bridge.sh"
        self.environment = layout.installerEnvironment(
            bridgeBundleRoot: bridgeBundleRoot,
            existingEnvironment: existingEnvironment
        )
    }
}
