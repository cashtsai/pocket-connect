import CloudKit
import Foundation

// Orchestrates the whole mac-side discovery layer (design §4.1):
//   gate (kill switch → entitlement → CKAccountStatus)
//   → ensure PocketZone
//   → Device upsert + 15 min heartbeat
//   → zone-wide silent-push subscription + 30 s invite polling.
// Every failure degrades silently: the rest of the app never depends on this.

public final class CloudSyncController {
    public enum Status: Equatable {
        case idle
        case disabled(String)   // gate failed — reason for the UI line
        case starting
        case active
        case error(String)
    }

    public static let subscriptionID = "pocket-zone-silent-push"
    private static let changeTokenDefaultsKey = "pocketZoneChangeToken"
    public static let heartbeatInterval: TimeInterval = 15 * 60
    public static let invitePollInterval: TimeInterval = 30

    public private(set) var status: Status = .idle {
        didSet { if oldValue != status { onStatusChange?(status) } }
    }
    /// Always invoked on the main thread.
    public var onStatusChange: ((Status) -> Void)?
    /// Fired when a silent push lands (design §5 M2c 驗收 ②) — the dashboard
    /// window (if open) should re-run DashboardStore.refresh(). Best-effort;
    /// nobody needs to be listening.
    public var onDashboardShouldRefresh: (() -> Void)?

    private let deviceInfoProvider: () -> DeviceInfo
    private let approvalHandler: PairingInviteMonitor.ApprovalHandler
    private let codeIssuer: PairingInviteMonitor.CodeIssuer
    /// Injectable for tests; nil → real CKContainer private database.
    private let databaseOverride: CloudDatabase?

    private var registrar: DeviceRegistrar?
    private var monitor: PairingInviteMonitor?
    private var heartbeat: Timer?
    private var accountObserver: NSObjectProtocol?
    private var errorLogWriter: ErrorLogWriter?
    /// Non-nil once the sync layer is active — the dashboard window reads
    /// through this (design §5 M2c 驗收 ①②).
    public private(set) var dashboardStore: DashboardStore?

    public init(deviceInfoProvider: @escaping () -> DeviceInfo,
                approvalHandler: @escaping PairingInviteMonitor.ApprovalHandler,
                codeIssuer: @escaping PairingInviteMonitor.CodeIssuer,
                database: CloudDatabase? = nil) {
        self.deviceInfoProvider = deviceInfoProvider
        self.approvalHandler = approvalHandler
        self.codeIssuer = codeIssuer
        self.databaseOverride = database
    }

    // MARK: - Lifecycle

    /// Run the gate and, if it passes, bring the sync layer up.
    /// Safe to call repeatedly (e.g. on CKAccountChanged).
    public func startIfAvailable() {
        stopTimers()
        if let reason = CloudGate.staticDisableReason() {
            setStatus(.disabled(reason))
            return
        }
        setStatus(.starting)
        observeAccountChanges()

        if let db = databaseOverride {
            begin(db)
            return
        }
        let container = CKContainer(identifier: CloudSchema.containerID)
        container.accountStatus { [weak self] accountStatus, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard accountStatus == .available else {
                    let why = error.map { "\($0.localizedDescription)" } ?? "iCloud 帳號不可用(\(accountStatus.rawValue))"
                    self.setStatus(.disabled(why))
                    return
                }
                self.begin(container.privateCloudDatabase)
            }
        }
    }

    public func stop() {
        stopTimers()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        accountObserver = nil
        setStatus(.idle)
    }

    /// Wire the app delegate's silent-push callback here.
    public func handleRemoteNotification() {
        monitor?.pokePoll()
        onDashboardShouldRefresh?()
    }

    /// Best-effort ErrorLog append (design §3.1/§4.4/§5 M2c 驗收 ②④). A no-op
    /// while the sync layer isn't active — errors before/without iCloud just
    /// stay local (NSLog), which every call site already does alongside this.
    public func logError(level: ErrorLevel, code: String, message: String,
                         context: [String: String] = [:]) {
        errorLogWriter?.append(level: level, code: code, message: message, context: context)
    }

    // MARK: - Bring-up

    private func begin(_ db: CloudDatabase) {
        let info = deviceInfoProvider()
        db.saveZone(CKRecordZone(zoneID: CloudSchema.zoneID)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result {
                    self.setStatus(.error("建立 PocketZone 失敗:\(error.localizedDescription)"))
                    return
                }
                self.activate(db, hostDeviceID: info.deviceID)
            }
        }
    }

    private func activate(_ db: CloudDatabase, hostDeviceID: String) {
        let errorLogWriter = ErrorLogWriter(database: db, deviceID: hostDeviceID)
        self.errorLogWriter = errorLogWriter
        self.dashboardStore = DashboardStore(database: db)

        let registrar = DeviceRegistrar(database: db, infoProvider: deviceInfoProvider)
        self.registrar = registrar
        registrar.upsert { result in
            if case .failure(let error) = result {
                NSLog("PocketCloud: device upsert failed: %@", "\(error)")
                errorLogWriter.append(level: .error, code: "device_upsert_failed",
                                      message: "\(error)")
            }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                         repeats: true) { [weak self] _ in
            self?.registrar?.upsert { _ in }
        }

        // Zone-wide silent push; duplicates are fine (same subscriptionID
        // upserts server-side), and failure just means we live on polling.
        let sub = CKRecordZoneSubscription(zoneID: CloudSchema.zoneID,
                                           subscriptionID: Self.subscriptionID)
        let noteInfo = CKSubscription.NotificationInfo()
        noteInfo.shouldSendContentAvailable = true
        sub.notificationInfo = noteInfo
        db.saveSubscription(sub) { result in
            if case .failure(let error) = result {
                NSLog("PocketCloud: subscription save failed (polling still active): %@", "\(error)")
                errorLogWriter.append(level: .warning, code: "subscription_save_failed",
                                      message: "\(error)")
            }
        }

        let monitor = PairingInviteMonitor(
            database: db,
            hostDeviceID: hostDeviceID,
            approvalHandler: approvalHandler,
            codeIssuer: codeIssuer,
            loadChangeToken: { UserDefaults.standard.data(forKey: Self.changeTokenDefaultsKey) },
            saveChangeToken: { token in
                if let token {
                    UserDefaults.standard.set(token, forKey: Self.changeTokenDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: Self.changeTokenDefaultsKey)
                }
            },
            errorLogger: { [weak errorLogWriter] level, code, message in
                errorLogWriter?.append(level: level, code: code, message: message)
            })
        self.monitor = monitor
        monitor.start(pollInterval: Self.invitePollInterval)

        setStatus(.active)
    }

    // MARK: - Helpers

    private func observeAccountChanges() {
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            self?.startIfAvailable()
        }
    }

    private func stopTimers() {
        heartbeat?.invalidate()
        heartbeat = nil
        monitor?.stop()
        monitor = nil
        registrar = nil
        errorLogWriter = nil
        dashboardStore = nil
    }

    private func setStatus(_ s: Status) {
        if Thread.isMainThread {
            status = s
        } else {
            DispatchQueue.main.async { self.status = s }
        }
    }
}
