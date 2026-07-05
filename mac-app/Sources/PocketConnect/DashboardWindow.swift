import AppKit
import PocketConnectKit
import SwiftUI

// M2c — tailnet-simple dashboard window (design §5 M2c 驗收 ①-④):
//   ① local bridge alive/latency + external channel (tailnet/LAN/tunnel)
//   ② paired devices + lastConnectedAt (CloudKit Device/PairingInfo)
//   ③ ErrorLog, local+remote mixed, sorted by time, tagged by source device
//   ④ one-click "copy diagnostics" — NSPasteboard only on explicit tap
// When CloudGate is off (no entitlement / no iCloud account) ②③ show
// "iCloud 同步未啟用(原因)" instead of empty/broken sections — ① still works
// since bridge reachability has nothing to do with CloudKit.

// Plain ObservableObject, not an actor — this app is single-threaded AppKit
// (no Swift concurrency elsewhere); every mutation here happens on the main
// run loop already, same convention as CloudSyncController.setStatus.
final class DashboardViewModel: ObservableObject {
    @Published var bridgeReachable = false
    @Published var bridgeLatencyMs: Double?
    @Published var hostCandidates: [String] = []
    @Published var cloudStatusText = "—"
    @Published var cloudEnabled = false
    @Published var snapshot = DashboardSnapshot()
    @Published var lastCopiedAt: Date?

    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
    var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    func refresh() {
        guard let appDelegate else { return }
        cloudStatusText = appDelegate.cloudStatusText
        let cloudSync = appDelegate.cloudSync
        cloudEnabled = cloudSync?.dashboardStore != nil
        hostCandidates = appDelegate.currentDeviceInfo().hostCandidates

        appDelegate.supervisor.probeLatency(appDelegate.cfg.connectURL) { [weak self] ok, ms in
            self?.bridgeReachable = ok
            self?.bridgeLatencyMs = ms
        }

        guard let store = cloudSync?.dashboardStore else {
            snapshot = DashboardSnapshot()
            return
        }
        store.refresh { [weak self] result in
            DispatchQueue.main.async { self?.snapshot = result }
        }
    }

    /// User tapped "複製診斷資訊" — the ONLY place this app touches
    /// NSPasteboard for diagnostics (design §5 M2c 驗收 ③: button-copy is
    /// user-initiated and explicitly allowed; nothing else may auto-copy).
    func copyDiagnostics() {
        let input = DiagnosticsInput(
            appVersion: appVersion, osVersion: osVersion, bridgeReachable: bridgeReachable,
            bridgeLatencyMs: bridgeLatencyMs, hostCandidates: hostCandidates,
            cloudStatusText: cloudStatusText, devices: snapshot.devices,
            pairings: snapshot.pairings, recentErrors: snapshot.errorLogs)
        let text = DiagnosticsReport.build(input)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastCopiedAt = Date()
    }
}

struct DashboardView: View {
    @ObservedObject var model: DashboardViewModel
    private let dateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                connectionSection
                Divider()
                if model.cloudEnabled {
                    pairedDevicesSection
                    Divider()
                    errorLogSection
                } else {
                    Text("iCloud 同步未啟用(\(model.cloudStatusText))")
                        .foregroundStyle(.secondary)
                }
                Divider()
                copySection
            }
            .padding(20)
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 600)
        .onAppear { model.refresh() }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("連線狀況").font(.headline)
            HStack(spacing: 6) {
                Circle()
                    .fill(model.bridgeReachable ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(model.bridgeReachable ? "本機 bridge 存活" : "本機 bridge 無回應")
                if let ms = model.bridgeLatencyMs {
                    Text(String(format: "· %.0fms", ms)).foregroundStyle(.secondary)
                }
            }
            Text("iCloud 發現:\(model.cloudStatusText)").foregroundStyle(.secondary)
            if model.hostCandidates.isEmpty {
                Text("對外通道:(無)").foregroundStyle(.secondary)
            } else {
                Text("對外通道:").foregroundStyle(.secondary)
                ForEach(model.hostCandidates, id: \.self) { candidate in
                    Text("  · \(candidate)").font(.system(.body, design: .monospaced))
                }
            }
        }
    }

    private var pairedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已配對裝置").font(.headline)
            if model.snapshot.pairings.isEmpty {
                Text("(尚無配對紀錄)").foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.pairings) { pairing in
                    HStack {
                        Text(deviceName(pairing.clientDeviceID))
                        Text("· \(pairing.status)").foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeOrDash(pairing.lastConnectedAt)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var errorLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("錯誤紀錄").font(.headline)
            if model.snapshot.errorLogs.isEmpty {
                Text("(無)").foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.errorLogs.prefix(50)) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(entry.level.uppercased())
                                .font(.caption.bold())
                                .foregroundStyle(entry.level == "error" ? .red : .orange)
                            Text(entry.code).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(relativeOrDash(entry.ts)).foregroundStyle(.secondary)
                        }
                        Text("\(entry.message)  — 來源:\(deviceName(entry.deviceID))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var copySection: some View {
        HStack {
            Button("複製診斷資訊") { model.copyDiagnostics() }
            if let at = model.lastCopiedAt {
                Text("已複製 · \(dateFormatter.localizedString(for: at, relativeTo: Date()))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重新整理") { model.refresh() }
        }
    }

    private func deviceName(_ deviceID: String?) -> String {
        guard let deviceID else { return "未知裝置" }
        return model.snapshot.devices.first(where: { $0.deviceID == deviceID })?.name ?? deviceID
    }

    private func relativeOrDash(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

extension AppDelegate {
    @objc func showDashboard() {
        if dashboardWindow == nil {
            let model = DashboardViewModel(appDelegate: self)
            dashboardModel = model
            let hosting = NSHostingController(rootView: DashboardView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Pocket 儀表板"
            win.setContentSize(NSSize(width: 520, height: 600))
            win.center()
            win.delegate = self
            dashboardWindow = win
        }
        dashboardModel?.refresh()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if dashboardRefreshTimer == nil {
            dashboardRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
                [weak self] _ in self?.dashboardModel?.refresh()
            }
        }
    }
}

// Foreground-fetch fallback lifecycle: stop polling once the dashboard window
// closes so an idle Pocket menu-bar app isn't quietly hammering CloudKit.
extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === dashboardWindow else { return }
        dashboardRefreshTimer?.invalidate()
        dashboardRefreshTimer = nil
    }
}
