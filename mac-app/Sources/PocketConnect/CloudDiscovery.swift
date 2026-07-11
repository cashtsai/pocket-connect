import AppKit
import PocketConnectKit

// M2a — mac side of the Apple ID pairing discovery layer.
// Registers this desktop as a Device record in the user's private CloudKit DB
// and answers PairingInvite requests coming from the phone (design §4.1/§4.2).
// Everything here is best-effort: when the build isn't entitled / no iCloud
// account is signed in, CloudGate keeps the whole layer silently off and the
// QR pairing path is unaffected.

extension AppDelegate {
    // MARK: - Bring-up (called from applicationDidFinishLaunching)

    func setupCloudSync() {
        let controller = CloudSyncController(
            deviceInfoProvider: { [weak self] in
                self?.currentDeviceInfo() ?? Self.fallbackDeviceInfo()
            },
            approvalHandler: { [weak self] invite, respond in
                guard let self else { return respond(false) }
                self.promptPairingApproval(invite, respond: respond)
            },
            codeIssuer: { [weak self] completion in
                guard let self else {
                    return completion(.failure(BridgeError(message: "app 已結束")))
                }
                self.issuePairingCode(completion: completion)
            })
        controller.onStatusChange = { [weak self] status in
            self?.cloudStatusText = Self.describe(status)
            self?.rebuildMenu()
        }
        // Dashboard window (M2c) refreshes on silent push too, not just on
        // open/timer — design §5 M2c 驗收 ② wants a 2-minute-ish turnaround.
        controller.onDashboardShouldRefresh = { [weak self] in
            self?.dashboardModel?.refresh()
        }
        cloudSync = controller
        controller.startIfAvailable()
        // Silent push registration — only meaningful on entitled builds; on
        // ad-hoc builds registration fails and we just live on the 30 s poll.
        if case .disabled = controller.status {} else {
            NSApp.registerForRemoteNotifications()
        }
    }

    static func describe(_ status: CloudSyncController.Status) -> String {
        switch status {
        case .idle: return "—"
        case .disabled(let why): return "停用(\(why))"
        case .starting: return "啟動中…"
        case .active: return "同步中"
        case .error(let why): return "錯誤:\(why)"
        }
    }

    // MARK: - NSApplicationDelegate push plumbing

    func application(_ application: NSApplication,
                     didReceiveRemoteNotification userInfo: [String: Any]) {
        cloudSync?.handleRemoteNotification()
    }

    func application(_ application: NSApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on non-entitled builds — polling covers us.
    }

    // MARK: - Device identity

    private static let deviceIDKey = "pocketDeviceID"
    private static let fingerprintKey = "pocketBridgeFingerprint"

    /// Stable per-install device ID — the CloudKit Device recordName.
    static func stableDeviceID() -> String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: deviceIDKey), !existing.isEmpty { return existing }
        let fresh = UUID().uuidString
        d.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    /// Stable random fingerprint published with the Device record. The phone
    /// compares it against what the bridge reports once the bridge exposes the
    /// same value (open item — bridge endpoint lands with the iOS half).
    static func stableBridgeFingerprint() -> String {
        let d = UserDefaults.standard
        if let existing = d.string(forKey: fingerprintKey), !existing.isEmpty { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        d.set(fresh, forKey: fingerprintKey)
        return fresh
    }

    func currentDeviceInfo() -> DeviceInfo {
        DeviceInfo(
            deviceID: Self.stableDeviceID(),
            name: Host.current().localizedName ?? "Mac",
            hostCandidates: HostCandidates.gather(bridgePort: cfg.bridgePort,
                                                  tunnelURL: effectiveConnectURL),
            bridgeFingerprint: Self.stableBridgeFingerprint(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    static func fallbackDeviceInfo() -> DeviceInfo {
        DeviceInfo(deviceID: stableDeviceID(), name: "Mac", hostCandidates: [],
                   bridgeFingerprint: nil, appVersion: "dev",
                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }

    // MARK: - Human confirmation (anti-silent-pairing, design §4.2)

    private func promptPairingApproval(_ invite: PairingInvite,
                                       respond: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "手機請求配對這台 Mac"
            alert.informativeText =
                "有一台使用你 Apple ID 的手機請求配對這台桌機。\n" +
                "允許後,該手機會在 5 分鐘內完成配對。\n若不是你本人操作,請拒絕。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "允許配對")
            alert.addButton(withTitle: "拒絕")
            NSApp.activate(ignoringOtherApps: true)
            respond(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    // MARK: - oneTimeCode minting (same /app/v1/pair/new as the QR path)

    private func issuePairingCode(
        completion: @escaping (Result<(code: String, ttlSeconds: Int), Error>) -> Void) {
        guard let session = Keychain.loadSessionToken() else {
            return completion(.failure(BridgeError(message: "尚未登入 Apple 帳號")))
        }
        guard let bearer = BridgeToken.read() else {
            return completion(.failure(BridgeError(message: "找不到 BRIDGE_TOKEN")))
        }
        bridge.pairNew(bridgeToken: bearer, sessionToken: session) { result in
            completion(result.map { (code: $0.code, ttlSeconds: $0.ttl) })
        }
    }
}
