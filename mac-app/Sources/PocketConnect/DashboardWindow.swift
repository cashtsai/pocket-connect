import AppKit
import CloudKit
import PocketConnectKit
import SwiftUI

// Pocket 控制台 — 品牌化 + 以 bridge 為資料源的裝置管理 + 內嵌配對 QR。
//
//   • 風格化：奶油底 + 淡瑪利歐雲 + 紅 POCKET wordmark。
//   • 已配對裝置讀 bridge `/pair/devices`（只需 BRIDGE_TOKEN），可解除。
//   • 配對新裝置：直接在控制台內產生 QR（不另開視窗），並輪詢 `/pair/devices`
//     偵測手機掃描成功後自動收起。
//   • 「服務開關」已移除：bridge 由 launchd 管理，app 不是真正的啟動者，
//     那顆按鈕只會誤導/搶 port。診斷/重新整理也移除（列表 30 秒自動更新）。

// MARK: - SwiftUI 品牌色
private enum Brand {
    static func c(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let red = c(0xEE2D2A)
    static let cream = c(0xFFF2D6)
    static let ink = c(0x17171A)
    static let espresso = c(0x2A1D18)
    static let green = c(0x43B14A)
}

// MARK: - 奶油底 + 淡雲背景
private struct PocketSky: View {
    var body: some View {
        Canvas { ctx, size in
            let line = Brand.espresso.opacity(0.07)
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            let tileW: CGFloat = 300, tileH: CGFloat = 220
            var y: CGFloat = 0
            while y < size.height + tileH {
                var x: CGFloat = 0
                while x < size.width + tileW {
                    ctx.stroke(Self.cloud.applying(.init(translationX: x, y: y)), with: .color(line), style: stroke)
                    let small = CGAffineTransform(scaleX: 0.62, y: 0.62)
                        .concatenating(.init(translationX: x + 180, y: y + 150))
                    ctx.stroke(Self.cloud.applying(small), with: .color(line), style: stroke)
                    x += tileW
                }
                y += tileH
            }
        }
        .background(Brand.cream)
        .allowsHitTesting(false)
    }
    static let cloud: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 40, y: 96))
        p.addCurve(to: CGPoint(x: 36, y: 70), control1: CGPoint(x: 22, y: 96), control2: CGPoint(x: 18, y: 74))
        p.addCurve(to: CGPoint(x: 70, y: 62), control1: CGPoint(x: 33, y: 50), control2: CGPoint(x: 62, y: 44))
        p.addCurve(to: CGPoint(x: 104, y: 68), control1: CGPoint(x: 76, y: 46), control2: CGPoint(x: 104, y: 48))
        p.addCurve(to: CGPoint(x: 108, y: 90), control1: CGPoint(x: 124, y: 64), control2: CGPoint(x: 126, y: 86))
        p.addLine(to: CGPoint(x: 108, y: 96))
        p.closeSubpath()
        return p
    }()
}

// MARK: - View model
final class DashboardViewModel: ObservableObject {
    @Published var bridgeReachable = false
    @Published var bridgeLatencyMs: Double?
    @Published var connectHost = ""
    @Published var cloudStatusText = "—"
    // 連線設定（進階）
    @Published var customURLField = ""
    @Published var usingCustomURL = false
    @Published var tokenDetected = false
    @Published var isTesting = false
    @Published var testResult: String?
    @Published var tokenField = ""
    @Published var devices: [BridgeClient.PairedDevice] = []
    @Published var isLoadingDevices = false
    @Published var devicesError: String?
    @Published var pendingRevokeID: String?

    // 內嵌配對狀態
    @Published var pairingVisible = false
    @Published var qrImage: NSImage?
    @Published var pairingStatus = ""
    @Published var pairingExpired = false

    private weak var appDelegate: AppDelegate?
    private var pairCoordinator: PairingCoordinator?
    private var pairPollTimer: Timer?
    private var pairKnownIDs: Set<String> = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.customURLField = appDelegate.customConnectURL ?? ""   // 一次性載入，別在 refresh 蓋掉使用者打字
    }

    func refresh() {
        guard let appDelegate else { return }
        cloudStatusText = appDelegate.cloudStatusText
        connectHost = URL(string: appDelegate.effectiveConnectURL)?.host ?? appDelegate.effectiveConnectURL
        usingCustomURL = appDelegate.customConnectURL != nil
        tokenDetected = BridgeToken.read() != nil
        appDelegate.supervisor.probeLatency(appDelegate.effectiveConnectURL) { [weak self] ok, ms in
            self?.bridgeReachable = ok
            self?.bridgeLatencyMs = ms
        }
        loadDevices()
    }

    func loadDevices() {
        guard let appDelegate else { return }
        isLoadingDevices = true
        devicesError = nil
        appDelegate.bridge.listDevices { [weak self] result in
            guard let self else { return }
            self.isLoadingDevices = false
            switch result {
            case .success(let list):
                self.devices = list.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            case .failure(let error):
                self.devicesError = error.localizedDescription
            }
        }
    }

    func revoke(_ id: String) {
        appDelegate?.bridge.revoke(id: id) { [weak self] _ in self?.loadDevices() }
    }

    /// 登出並重新設定（清除登入 + 重跑首次設定）。
    func resetOnboarding() { appDelegate?.resetOnboarding() }

    // MARK: 連線設定（進階）

    func testConnection() {
        guard let appDelegate else { return }
        let target = customURLField.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = target.isEmpty ? appDelegate.effectiveConnectURL : target
        isTesting = true
        testResult = nil
        appDelegate.supervisor.probeLatency(url) { [weak self] ok, ms in
            self?.isTesting = false
            self?.testResult = ok ? String(format: "● 連得到 · %.0fms", ms ?? 0) : "✗ 連不到，檢查網址"
        }
    }

    func saveConnection() {
        appDelegate?.setCustomConnectURL(customURLField)
        if !tokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BridgeToken.setOverride(tokenField)
            tokenField = ""
        }
        testResult = "已儲存"
        refresh()
    }

    // MARK: 內嵌配對

    func startPairing() {
        guard let appDelegate else { return }
        pairingVisible = true
        pairingExpired = false
        qrImage = nil
        guard Keychain.loadSessionToken() != nil else { pairingStatus = "請先登入"; return }
        pairingStatus = "檢查中…"
        // 免費模式（自動臨時 tunnel）網址會變，靠 CloudKit 同步給手機 → 必須開 iCloud。
        // 有自訂固定網址（進階）就不需要（網址不變）。
        if appDelegate.customConnectURL == nil {
            if let reason = CloudGate.staticDisableReason() {
                if appDelegate.autoTunnelURL != nil {
                    // A signed CloudKit build can keep the phone updated after
                    // a tunnel URL churn. For the first QR, the payload already
                    // carries the current tunnel host, so local/dev builds may
                    // still mint a usable pairing QR.
                    mintPairingCode()
                } else {
                    waitForTunnelThenMint(cloudGateReason: reason)
                }
                return
            }
            CKContainer.default().accountStatus { [weak self] status, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if status == .available {
                        self.mintPairingCode()
                    } else {
                        self.pairingStatus = "免費模式要先開啟 iCloud（系統設定 → 你的 Apple ID → iCloud）才能配對；\n或到下方「連線設定」填你自己的固定網址。"
                    }
                }
            }
        } else {
            mintPairingCode()
        }
    }

    private func waitForTunnelThenMint(cloudGateReason reason: String, attempt: Int = 0) {
        guard let appDelegate else { return }
        if let url = appDelegate.autoTunnelURL ?? appDelegate.tunnelManager.currentURL {
            appDelegate.autoTunnelURL = url
            appDelegate.onConnectURLChanged()
            mintPairingCode()
            return
        }

        appDelegate.tunnelManager.start()
        pairingStatus = "正在等待臨時連線網址…"
        guard attempt < 20 else {
            pairingStatus = "等不到臨時連線網址。\n請稍後再按一次，或到下方「連線設定」填固定網址，或改用具備 iCloud entitlement 的簽章版本。（目前\(reason)）"
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pairingVisible, self.qrImage == nil else { return }
            self.waitForTunnelThenMint(cloudGateReason: reason, attempt: attempt + 1)
        }
    }

    private func mintPairingCode() {
        guard let appDelegate else { return }
        pairingStatus = "產生配對碼中…"
        pairKnownIDs = Set(devices.map(\.id))
        let coord = PairingCoordinator(client: appDelegate.bridge,
                                       sessionProvider: { Keychain.loadSessionToken() })
        pairCoordinator = coord
        coord.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .needLogin: self.pairingStatus = "請先登入"
            case .loading:   self.pairingStatus = "產生配對碼中…"
            case .active(let img, let secs):
                self.qrImage = img
                self.pairingStatus = "用手機掃描配對 · 剩 \(secs / 60):\(String(format: "%02d", secs % 60))"
                self.pairingExpired = false
                self.ensurePairPoll()
            case .expired:
                self.pairingExpired = true; self.pairingStatus = "配對碼已過期"; self.stopPairPoll()
            case .error(let m):
                self.pairingStatus = "錯誤:\(m)"; self.stopPairPoll()
            }
        }
        coord.refresh()
    }

    func stopPairing() {
        pairCoordinator?.stop(); pairCoordinator = nil
        stopPairPoll()
        pairingVisible = false; qrImage = nil; pairingExpired = false
    }

    /// 輪詢 /pair/devices，出現新裝置就是手機掃成功 → 顯示成功、更新清單、收起 QR。
    private func ensurePairPoll() {
        guard pairPollTimer == nil else { return }
        pairPollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let appDelegate = self.appDelegate else { return }
            appDelegate.bridge.listDevices { [weak self] result in
                guard let self, case .success(let list) = result else { return }
                guard list.contains(where: { !self.pairKnownIDs.contains($0.id) }) else { return }
                self.devices = list.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
                self.pairingStatus = "配對成功 ✓"
                self.stopPairPoll()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.stopPairing() }
            }
        }
    }
    private func stopPairPoll() { pairPollTimer?.invalidate(); pairPollTimer = nil }
}

// MARK: - View
struct DashboardView: View {
    @ObservedObject var model: DashboardViewModel
    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    var body: some View {
        ZStack {
            PocketSky().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wordmarkHeader
                    card { pairingSection }
                    card { connectionSection }
                    card { connectionSettingsSection }
                    card { devicesSection }
                }
                .padding(.horizontal, 20)
                .padding(.top, 34)     // 避開視窗左上紅綠燈（滿版標題列）
                .padding(.bottom, 28)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("Pocket v\(Self.appVersion) · © 2026 Shan Corps Co. Ltd.")
                .font(.system(size: 10))
                .foregroundStyle(Brand.espresso.opacity(0.4))
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 520, idealHeight: 640)
        .onAppear { model.refresh() }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    private var wordmarkHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            if let img = Self.wordmark {
                Image(nsImage: img).resizable().scaledToFit().frame(height: 30)
            } else {
                Text("POCKET").font(.system(size: 26, weight: .black)).foregroundStyle(Brand.red)
            }
            Spacer()
            Button { model.resetOnboarding() } label: {
                Label("登出並重新設定", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.borderless).foregroundStyle(Brand.red).controlSize(.small)
        }
        .padding(.bottom, 2)
    }

    private static var wordmark: NSImage? {
        Bundle.main.url(forResource: "pocket-wordmark", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    // MARK: 配對與設定（內嵌 QR + 登出）

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("配對與設定")
            if model.pairingVisible {
                VStack(spacing: 8) {
                    if let qr = model.qrImage {
                        Image(nsImage: qr).resizable().interpolation(.none)
                            .frame(width: 220, height: 220)
                    } else {
                        ProgressView().frame(width: 220, height: 220)
                    }
                    Text(model.pairingStatus).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if model.pairingExpired {
                            Button("重新產生") { model.startPairing() }.buttonStyle(.borderedProminent).tint(Brand.red)
                        }
                        Button("關閉") { model.stopPairing() }.buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button { model.startPairing() } label: {
                    Label("配對新裝置", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent).tint(Brand.red)
            }
        }
    }

    // MARK: 連線狀況

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("連線狀況")
            HStack(spacing: 6) {
                Circle().fill(model.bridgeReachable ? Brand.green : Brand.red).frame(width: 8, height: 8)
                Text(model.bridgeReachable ? "已連線" : "未連線").foregroundStyle(Brand.ink)
                if let ms = model.bridgeLatencyMs {
                    Text(String(format: "· %.0fms", ms)).foregroundStyle(.secondary)
                }
            }
            if !model.connectHost.isEmpty {
                Text(model.connectHost).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 連線設定（進階）

    private var connectionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("連線設定")
            Text("你的 Pocket 網址（留空 = 用免費自動連線）")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://your-bridge.example.com", text: $model.customURLField)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Circle().fill(model.tokenDetected ? Brand.green : Brand.red).frame(width: 7, height: 7)
                Text(model.tokenDetected ? "金鑰已自動讀到（來自 Hermes 設定）" : "找不到金鑰 — 手動貼上或檢查 Hermes 設定")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.tokenDetected {
                SecureField("貼上 BRIDGE_TOKEN", text: $model.tokenField)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button("測試連線") { model.testConnection() }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isTesting)
                Button("儲存") { model.saveConnection() }
                    .buttonStyle(.borderedProminent).tint(Brand.red).controlSize(.small)
                if model.isTesting { ProgressView().controlSize(.small) }
                if let r = model.testResult {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 已配對裝置

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("已配對裝置")
                if model.isLoadingDevices { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let err = model.devicesError, model.devices.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange)
            } else if model.devices.isEmpty {
                Text("尚無配對裝置 — 用上面「配對新裝置」讓手機掃 QR。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: device.platform)).foregroundStyle(Brand.red).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).foregroundStyle(Brand.ink)
                            Text(subtitle(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.pendingRevokeID = device.id } label: {
                            Text("解除").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
        .confirmationDialog(
            "解除這台裝置的配對？",
            isPresented: Binding(get: { model.pendingRevokeID != nil },
                                 set: { if !$0 { model.pendingRevokeID = nil } }),
            actions: {
                Button("解除配對", role: .destructive) {
                    if let id = model.pendingRevokeID { model.revoke(id) }
                    model.pendingRevokeID = nil
                }
                Button("取消", role: .cancel) { model.pendingRevokeID = nil }
            },
            message: { Text("該裝置需要重新掃配對 QR 才能再連上。") }
        )
    }

    // MARK: Helpers

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.espresso.opacity(0.08)))
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.headline).foregroundStyle(Brand.ink)
    }

    private func icon(for platform: String?) -> String {
        let p = (platform ?? "").lowercased()
        if p.contains("ipad") { return "ipad" }
        if p.contains("mac") { return "laptopcomputer" }
        return "iphone"
    }

    private func subtitle(_ d: BridgeClient.PairedDevice) -> String {
        var parts: [String] = []
        if let p = d.platform, !p.isEmpty { parts.append(p) }
        if d.accountBound { parts.append("已綁定帳號") }
        if let s = d.lastSeen { parts.append("最後上線 " + relative.localizedString(for: s, relativeTo: Date())) }
        return parts.isEmpty ? "已配對" : parts.joined(separator: " · ")
    }
}

extension AppDelegate {
    @objc func showDashboard() {
        if dashboardWindow == nil {
            let model = DashboardViewModel(appDelegate: self)
            dashboardModel = model
            let hosting = NSHostingController(rootView: DashboardView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Pocket 控制台"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true            // 標題列拿掉，奶油底滿版
            win.styleMask.insert(.fullSizeContentView)
            win.isMovableByWindowBackground = true
            win.backgroundColor = NSColor(srgbRed: 1, green: 0.949, blue: 0.839, alpha: 1)  // cream #FFF2D6
            win.setContentSize(NSSize(width: 500, height: 640))
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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === dashboardWindow else { return }
        dashboardRefreshTimer?.invalidate()
        dashboardRefreshTimer = nil
        dashboardModel?.stopPairing()
    }
}
