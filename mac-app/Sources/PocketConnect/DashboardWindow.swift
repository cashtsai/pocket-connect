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

// MARK: - SwiftUI 品牌色(AgentConnect.swift 也用)
enum Brand {
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
    /// 只有「手動按刷新」才會亮 —— 定時刷新也走 refresh(),但不該讓狀態列每隔
    /// 一段時間自己閃一下轉圈。
    @Published var isRefreshing = false
    /// 上次量到連線狀態的時間。少了它,使用者分不出「現在真的連得到」與
    /// 「這是幾分鐘前的舊結果」—— 而那正是會讓人想按刷新的那個疑問。
    @Published var lastCheckedAt: Date?
    @Published var connectHost = ""
    @Published var cloudStatusText = "—"
    // 連線設定（進階）
    @Published var customURLField = ""
    @Published var usingCustomURL = false
    @Published var tokenDetected = false
    @Published var isTesting = false
    @Published var testResult: String?
    @Published var tokenField = ""
    // 中繼隧道（遠端連線）。relayStatus 是 bridge 回報的**現實**，relayBusy 是
    // 「按下去了、但 supervisor 最多 30 秒後才會動」的過渡 —— 兩個分開存，
    // 才不會在使用者按下開關的瞬間就謊稱已經連上。
    @Published var relayStatus: BridgeClient.RelayStatus?
    @Published var relayError: String?
    @Published var relayBusy = false
    @Published var devices: [BridgeClient.PairedDevice] = []
    @Published var isLoadingDevices = false
    @Published var devicesError: String?
    @Published var pendingRevokeID: String?

    // AI 用量(/app/v1/usage)。錯誤時保留上一份快照,只在沒資料時顯示錯誤。
    @Published var usage: UsageSnapshot?
    @Published var usageError: String?

    // 內嵌配對狀態
    @Published var pairingVisible = false
    @Published var qrImage: NSImage?
    @Published var pairingStatus = ""
    @Published var pairingExpired = false

    /// AI 引擎(Claude Code / Codex)一鍵連接 — 見 AgentConnect.swift。
    let agents = AgentConnectModel()
    /// M3 執行環境(bridge 有沒有裝好/跑著)— 見 EnvironmentSetup.swift。
    /// 共用同一個 agents model,清單與「AI 引擎」卡片才不會講不一樣的話。
    let environment: BridgeEnvironmentModel

    private weak var appDelegate: AppDelegate?
    private var pairCoordinator: PairingCoordinator?
    private var pairPollTimer: Timer?
    private var pairKnownIDs: Set<String> = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        self.environment = BridgeEnvironmentModel(bootstrap: appDelegate.bridgeBootstrap,
                                                  agents: agents)
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
            self?.lastCheckedAt = Date()
            // 轉圈收在「量到結果」這一刻,不是按下去就收 —— 收太早等於在說謊。
            self?.isRefreshing = false
        }
        loadDevices()
        loadRelayStatus()
        agents.refreshAll()
        environment.refresh()
        loadUsage()
    }

    /// 手動刷新(狀態列右邊那顆)。與定時刷新走同一條路,差別只在會亮轉圈。
    /// 連按多次不重複發:probe 還沒回來就直接忽略。
    func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refresh()
    }

    func loadUsage() {
        appDelegate?.bridge.fetchUsage { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.usage = snapshot
                self.usageError = nil
            case .failure(let error):
                self.usageError = error.localizedDescription
            }
        }
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

    func loadRelayStatus() {
        guard let appDelegate else { return }
        appDelegate.bridge.fetchRelayStatus { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let s):
                self.relayStatus = s
                self.relayError = nil
                // supervisor 追上意圖了就收掉過渡態。
                if s.enabled == (s.state != "off") { self.relayBusy = false }
            case .failure(let error):
                // 保留上一份快照：連不到 bridge 不代表隧道斷了，把燈改成紅的
                // 反而是另一種謊。只標記錯誤，讓 UI 說「狀態不明」。
                self.relayError = error.localizedDescription
            }
        }
    }

    func setRelay(_ enabled: Bool) {
        guard let appDelegate else { return }
        relayBusy = true
        relayError = nil
        appDelegate.bridge.setRelayEnabled(enabled) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let s):
                self.relayStatus = s
            case .failure(let error):
                self.relayBusy = false
                self.relayError = error.localizedDescription
            }
            // 不管成敗都回頭問一次真實狀態 —— enable 的回應只是「旗標寫好了」。
            self.loadRelayStatus()
        }
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
            self?.testResult = ok ? String(format: L10n.t("● 連得到 · %.0fms"), ms ?? 0) : L10n.t("✗ 連不到，檢查網址")
        }
    }

    func saveConnection() {
        appDelegate?.setCustomConnectURL(customURLField)
        if !tokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BridgeToken.setOverride(tokenField)
            tokenField = ""
        }
        testResult = L10n.t("已儲存")
        refresh()
    }

    // MARK: 內嵌配對

    func startPairing() {
        guard let appDelegate else { return }
        pairingVisible = true
        pairingExpired = false
        qrImage = nil
        guard Keychain.loadSessionToken() != nil else { pairingStatus = L10n.t("請先登入"); return }
        pairingStatus = L10n.t("檢查中…")
        // 免費模式（自動臨時 tunnel）網址會變，靠 CloudKit 同步給手機 → 必須開 iCloud。
        // 有自訂固定網址（進階）就不需要（網址不變）。
        if appDelegate.customConnectURL == nil {
            // 沒有自訂固定網址 → QR 的位址就是臨時 tunnel。tunnel 還沒起來時
            // `effectiveConnectURL` 會退到共用後備網域(維護者的主機),發出去的
            // QR 會把使用者的手機指向別人的機器 —— 所以**先等 tunnel**,
            // 不管 iCloud 那關過不過。
            //
            // 舊版只有 CloudGate 被關掉的那條分支會等;entitled 那條直接
            // `mintPairingCode()`,於是「有 iCloud、但 cloudflared 慢了一步」
            // 就會發出一個錯的 QR。(2026-10-18 一星風險排查)
            if appDelegate.autoTunnelURL == nil,
               appDelegate.tunnelManager.currentURL == nil {
                waitForTunnelThenMint(
                    cloudGateReason: CloudGate.staticDisableReason() ?? "")
                return
            }
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
                        self.pairingStatus = L10n.t("免費模式要先開啟 iCloud（系統設定 → 你的 Apple ID → iCloud）才能配對；\n或到下方「連線設定」填你自己的固定網址。")
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
        pairingStatus = L10n.t("正在等待臨時連線網址…")
        guard attempt < 20 else {
            pairingStatus = L10n.t("等不到臨時連線網址。\n請稍後再按一次，或到下方「連線設定」填固定網址，或改用具備 iCloud entitlement 的簽章版本。（目前\(reason)）")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pairingVisible, self.qrImage == nil else { return }
            self.waitForTunnelThenMint(cloudGateReason: reason, attempt: attempt + 1)
        }
    }

    private func mintPairingCode() {
        guard let appDelegate else { return }
        pairingStatus = L10n.t("產生配對碼中…")
        pairKnownIDs = Set(devices.map(\.id))
        let coord = PairingCoordinator(client: appDelegate.bridge,
                                       sessionProvider: { Keychain.loadSessionToken() })
        pairCoordinator = coord
        coord.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .needLogin: self.pairingStatus = L10n.t("請先登入")
            case .loading:   self.pairingStatus = L10n.t("產生配對碼中…")
            case .active(let img, let secs):
                self.qrImage = img
                let mmss = String(format: "%d:%02d", secs / 60, secs % 60)
                self.pairingStatus = L10n.t("用手機掃描配對 · 剩 \(mmss)")
                self.pairingExpired = false
                self.ensurePairPoll()
            case .expired:
                self.pairingExpired = true; self.pairingStatus = L10n.t("配對碼已過期"); self.stopPairPoll()
            case .error(let m):
                self.pairingStatus = L10n.t("錯誤:\(m)"); self.stopPairPoll()
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
                self.pairingStatus = L10n.t("配對成功 ✓")
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
    /// 連線狀態的量測時刻。刻意用絕對時間(時:分:秒)而不是「幾分鐘前」——
    /// 這一列是要回答「這個數字是不是剛剛量的」,相對時間反而更模糊。
    private static let checkedFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    var body: some View {
        ZStack {
            PocketSky().ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    wordmarkHeader
                    card { pairingSection }
                    card { connectionSection }
                    card { EnvironmentSetupView(model: model.environment) }
                    card { AgentEnginesSection(model: model.agents) }
                    card { usageSection }
                    // 遠端連線排在「連線設定」前面：它是會改變這台機器對外曝光
                    // 程度的開關，不該被埋在進階設定的 TextField 底下。
                    card { relaySection }
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
                Label(L10n.t("登出並重新設定"), systemImage: "rectangle.portrait.and.arrow.right")
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
            sectionTitle(L10n.t("配對與設定"))
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
                            Button(L10n.t("重新產生")) { model.startPairing() }.buttonStyle(.borderedProminent).tint(Brand.red)
                        }
                        Button(L10n.t("關閉")) { model.stopPairing() }.buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button { model.startPairing() } label: {
                    Label(L10n.t("配對新裝置"), systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent).tint(Brand.red)
            }
        }
    }

    // MARK: 連線狀況

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("連線狀況"))
            HStack(spacing: 6) {
                Circle().fill(model.bridgeReachable ? Brand.green : Brand.red).frame(width: 8, height: 8)
                Text(model.bridgeReachable ? L10n.t("已連線") : L10n.t("未連線")).foregroundStyle(Brand.ink)
                if let ms = model.bridgeLatencyMs {
                    Text(String(format: "· %.0fms", ms))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if let at = model.lastCheckedAt {
                    Text(Self.checkedFormatter.string(from: at))
                        .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                }
                Button(action: { model.refreshNow() }) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help(L10n.t("重新檢查連線"))
                .accessibilityLabel(L10n.t("重新檢查連線"))
            }
            if !model.connectHost.isEmpty {
                Text(model.connectHost).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 連線設定（進階）

    // MARK: 遠端連線（中繼隧道）
    //
    // 這個開關的語意是「我把自家 Mac 的 bridge 端到公網上」。所以這裡刻意做三件事：
    //  1. 開關只表達**意圖**，燈號另外畫 bridge 回報的**現實** —— 兩者會不一致
    //     （沒訂閱 / token 被撤 / frpc 不在），而那個落差正是使用者要看到的。
    //  2. 開著的時候講清楚「現在誰連得到」，不要只給一個綠點。
    //  3. 關掉會失去什麼要寫出來，否則使用者不敢關，等於沒有開關。

    private var relayStateText: String {
        guard let s = model.relayStatus else {
            return model.relayError == nil ? L10n.t("讀取中…") : L10n.t("狀態不明")
        }
        if model.relayBusy { return L10n.t("切換中…") }
        switch s.state {
        case "connected":    return L10n.t("隧道已連線")
        case "connecting":   return L10n.t("連線中…")
        case "off":          return L10n.t("已關閉")
        case "not_configured": return L10n.t("這台 Mac 的 bridge 還沒接上 Pocket ID")
        case "not_enrolled": return L10n.t("這台 Mac 還沒在 Pocket ID 註冊")
        case "no_binary":    return L10n.t("找不到 frpc —— 這個版本沒有帶中繼元件")
        case "claiming":     return L10n.t("申請授權中…")
        case "unentitled":   return L10n.t("中繼需要訂閱（免費替代：你自己的 Tailscale）")
        case "rejected":     return L10n.t("伺服器拒絕了這條隧道")
        default:             return L10n.t("無法連線")
        }
    }

    private var relayDotColor: Color {
        guard let s = model.relayStatus, model.relayError == nil else { return .secondary }
        if model.relayBusy || s.state == "connecting" || s.state == "claiming" { return .orange }
        if s.isLive { return Brand.green }
        // 使用者要了卻沒成真 = 紅；本來就關著 = 灰（關著不是故障）。
        return s.enabled ? Brand.red : .secondary
    }

    /// 免費層：Tailscale。與中繼**並存**，不是二選一 —— 使用者可以只用這條、
    /// 只用中繼、或兩條都開（候選清單會優先走比較快的那條）。
    @ViewBuilder
    private var tailscaleRow: some View {
        if let ts = model.relayStatus?.tailscale {
            let dot: Color = ts.isPrivateReachable ? Brand.green
                : (ts.installed && ts.loggedIn ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(L10n.t("Tailscale（免費）")).font(.caption.weight(.medium))
                    Text(tailscaleStateText).font(.caption).foregroundStyle(.secondary)
                }
                if let h = ts.hostname, ts.isPrivateReachable {
                    HStack(spacing: 6) {
                        Text(h).font(.caption2.monospaced()).textSelection(.enabled)
                        // ⚠️ serve 與 funnel 是同一個網址，曝光範圍只能看 mode。
                        Text(ts.isPubliclyExposed ? L10n.t("· 公開（任何人）")
                                                  : L10n.t("· 僅限你的 Tailscale 裝置"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var tailscaleStateText: String {
        guard let ts = model.relayStatus?.tailscale else { return "" }
        if !ts.installed { return L10n.t("未安裝") }
        if !ts.loggedIn { return L10n.t("未登入") }
        switch ts.mode {
        case "funnel": return L10n.t("已開啟公網 Funnel")
        case "serve":  return L10n.t("已開啟，手機需在同一個 Tailscale")
        default:       return L10n.t("已登入但未對外開放（重跑安裝器可啟用）")
        }
    }

    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("遠端連線"))
            tailscaleRow
            Divider().padding(.vertical, 2)
            Text(L10n.t("Pocket 中繼（訂閱）")).font(.caption.weight(.medium))
            Toggle(isOn: Binding(
                get: { model.relayStatus?.enabled ?? false },
                set: { model.setRelay($0) }
            )) {
                Text(L10n.t("讓這台 Mac 從外網也連得到（透過 Pocket 中繼）"))
            }
            .toggleStyle(.switch)
            .disabled(model.relayBusy || model.relayStatus == nil)

            HStack(spacing: 6) {
                Circle().fill(relayDotColor).frame(width: 7, height: 7)
                Text(relayStateText).font(.caption).foregroundStyle(.secondary)
                if model.relayBusy { ProgressView().controlSize(.small) }
            }

            // 連上了才給網址，而且要能複製 —— 不然使用者得自己抄一串亂碼。
            if let host = model.relayStatus?.hostname, model.relayStatus?.isLive == true {
                HStack(spacing: 6) {
                    Text(host).font(.caption.monospaced()).textSelection(.enabled)
                    Button(L10n.t("複製")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("https://" + host, forType: .string)
                    }.buttonStyle(.link).controlSize(.small)
                }
            }

            // 卡住的原因要講出來。只顯示一個紅點等於叫使用者去猜。
            if let s = model.relayStatus, s.isStalled, let detail = s.detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
            if let err = model.relayError {
                Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }

            Text(L10n.t("關閉後，只有同一個網路或你的 Tailscale 連得到這台 Mac。"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var connectionSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.t("連線設定"))
            Text(L10n.t("你的 Pocket 網址（留空 = 用免費自動連線）"))
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://your-bridge.example.com", text: $model.customURLField)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Circle().fill(model.tokenDetected ? Brand.green : Brand.red).frame(width: 7, height: 7)
                Text(model.tokenDetected ? L10n.t("金鑰已自動讀到（來自 Hermes 設定）") : L10n.t("找不到金鑰 — 手動貼上或檢查 Hermes 設定"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.tokenDetected {
                SecureField(L10n.t("貼上 BRIDGE_TOKEN"), text: $model.tokenField)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                Button(L10n.t("測試連線")) { model.testConnection() }
                    .buttonStyle(.bordered).controlSize(.small).disabled(model.isTesting)
                Button(L10n.t("儲存")) { model.saveConnection() }
                    .buttonStyle(.borderedProminent).tint(Brand.red).controlSize(.small)
                if model.isTesting { ProgressView().controlSize(.small) }
                if let r = model.testResult {
                    Text(r).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: AI 用量(/app/v1/usage — Codex 5h + Claude 5h/7d,含降級狀態)

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(L10n.t("AI 用量"))
            if let usage = model.usage {
                codexUsageRows(usage.codex)
                Divider().opacity(0.4)
                claudeUsageRows(usage.claude)
            } else if let err = model.usageError {
                Text(L10n.t("讀不到用量資料:\(err)")).font(.caption).foregroundStyle(.orange)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("讀取用量中…")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func codexUsageRows(_ codex: CodexUsage?) -> some View {
        providerHeader("Codex")
        if let window = codex?.window, codex?.available == true {
            usageRow(L10n.t("5 小時額度"), window)
        } else {
            Text(L10n.t("用量資料暫不可用(本機沒有 Codex session 記錄)"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func claudeUsageRows(_ claude: ClaudeUsage?) -> some View {
        providerHeader("Claude Code")
        if let claude, claude.available {
            if claude.officialSynced {
                if let five = claude.fiveHour { usageRow(L10n.t("5 小時額度"), five) }
                if let seven = claude.sevenDay { usageRow(L10n.t("7 天額度"), seven) }
                if claude.fiveHour == nil && claude.sevenDay == nil {
                    Text(L10n.t("官方額度視窗已過期,等待下次同步"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                // 降級:沒裝 statusline hook → 只有本機 token 加總,絕不假裝百分比。
                if let tokens = claude.tokenUsage {
                    Text(L10n.t("本機估算:輸入 \(Self.tokenText(tokens.inputTokens)) · 輸出 \(Self.tokenText(tokens.outputTokens)) tokens"))
                        .font(.caption).foregroundStyle(Brand.ink)
                }
                Text(L10n.t("官方額度暫不可用(未安裝 statusline hook,僅顯示本機估算)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.t("用量資料暫不可用(本機沒有 Claude Code 記錄)"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func providerHeader(_ name: String) -> some View {
        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
    }

    /// 一條用量條:標題 + 已用/剩餘百分比 + 進度條 + 重置時間。
    private func usageRow(_ label: String, _ window: UsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(Brand.ink)
                Spacer()
                Text(String(format: L10n.t("已用 %.0f%% · 剩 %.0f%%"), window.usedPercent, window.remainingPercent))
                    .font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.espresso.opacity(0.12))
                    Capsule().fill(window.usedPercent >= 85 ? Brand.red : Brand.green)
                        .frame(width: max(4, geo.size.width * min(1, max(0, window.usedPercent / 100))))
                }
            }
            .frame(height: 8)
            if let reset = window.resetAt {
                Text(L10n.t("於 \(Self.resetFormatter.string(from: reset)) 重置"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f
    }()

    private static func tokenText(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    // MARK: 已配對裝置

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle(L10n.t("已配對裝置"))
                if model.isLoadingDevices { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let err = model.devicesError, model.devices.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange)
            } else if model.devices.isEmpty {
                Text(L10n.t("尚無配對裝置 — 用上面「配對新裝置」讓手機掃 QR。"))
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
                            Text(L10n.t("解除")).font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                    Divider().opacity(0.4)
                }
            }
        }
        .confirmationDialog(
            L10n.t("解除這台裝置的配對？"),
            isPresented: Binding(get: { model.pendingRevokeID != nil },
                                 set: { if !$0 { model.pendingRevokeID = nil } }),
            actions: {
                Button(L10n.t("解除配對"), role: .destructive) {
                    if let id = model.pendingRevokeID { model.revoke(id) }
                    model.pendingRevokeID = nil
                }
                Button(L10n.t("取消"), role: .cancel) { model.pendingRevokeID = nil }
            },
            message: { Text(L10n.t("該裝置需要重新掃配對 QR 才能再連上。")) }
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
        if d.accountBound { parts.append(L10n.t("已綁定帳號")) }
        if let s = d.lastSeen { parts.append(L10n.t("最後上線 ") + relative.localizedString(for: s, relativeTo: Date())) }
        return parts.isEmpty ? L10n.t("已配對") : parts.joined(separator: " · ")
    }
}

extension AppDelegate {
    @objc func showDashboard() {
        if dashboardWindow == nil {
            let model = DashboardViewModel(appDelegate: self)
            dashboardModel = model
            let hosting = NSHostingController(rootView: DashboardView(model: model))
            let win = NSWindow(contentViewController: hosting)
            win.title = L10n.t("Pocket 控制台")
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
