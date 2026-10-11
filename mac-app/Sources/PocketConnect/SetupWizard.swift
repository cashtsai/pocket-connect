import AppKit
import PocketConnectKit
import SwiftUI

// 首次安裝引導精靈 —— 一張六列檢查清單,每一列「自己會驗 + 紅的時候給得出下一步」。
//
// 這張清單替代了舊的「執行環境」頁。差別在最後三列:舊版只看 bridge 活著就放人去
// 掃 QR,結果使用者在 Claude Code / Codex 沒裝/沒登入的情況下配對「成功」,手機進
// 分頁卻是鎖頭或空白,而且他完全不知道為什麼。
//
// 硬規則(QR 的唯一放行條件):④ Claude Code 與 ⑤ Codex **至少一個「裝了且已登入」**。
// 判定全在 PocketConnectKit/SetupWizard.swift(純函式、有測試);這裡只負責
//   • 去把資料撈回來(bridge 探測 / bridge 的 /app/v1/agents/auth / 本機網路位址)
//   • 把每一列的動作真的做掉(安裝、啟動、登入、重測)
//   • 畫出來

final class SetupWizardModel: ObservableObject {

    @Published private(set) var plan = SetupWizardPlan(rows: [], gate: .waitingBridge)
    /// 正在自動做事時的一句話(安裝 bridge、安裝 CLI…)。
    @Published private(set) var busyMessage: String?
    /// 自動修失敗時的一句話 —— 絕不無聲失敗,但也不給使用者看 traceback。
    @Published private(set) var note: String?

    /// bridge 安裝/啟動沿用既有的一鍵流程。
    let environment: BridgeEnvironmentModel
    /// CLI 登入沿用既有的一鍵連接(codex 開瀏覽器、claude 開授權視窗)。
    private let agentConnect: AgentConnectModel

    private let bridgeClient: () -> BridgeClient
    /// 回傳「實測連得上的公網網址」;連不上就回 nil(③ 不准謊報)。
    private let verifiedTunnelURL: () -> String?
    private let bridgePort: Int

    private var bridgeState: BridgeEnvironmentState?
    private var bridgeProbe = BridgeEnvironmentProbe()
    private var agents: AgentAuthSnapshot?
    private var reach = ReachabilityReport.checking
    private var pollTimer: Timer?
    private var agentInstall: Process?

    /// 六列都過關(QR 可以出現了)時呼叫一次。
    var onGateOpened: (() -> Void)?
    /// 使用者按下「好了,拿手機掃這個」。
    var onRequestQR: (() -> Void)?
    /// 第一次算出**有定論**的結果(放行或明確缺引擎)時呼叫一次,參數 = 放不放行。
    /// 整條鏈本來就通的機器靠這個直接跳到登入頁,不必多看一張清單。
    var onFirstEvaluation: ((Bool) -> Void)?
    /// 每次 bridge 探測完的結果(選單那一行的文字靠它保持新鮮)。
    var onBridgeProbed: ((BridgeEnvironmentState) -> Void)?
    private var firstEvaluationDone = false

    init(environment: BridgeEnvironmentModel,
         agentConnect: AgentConnectModel,
         bridgeClient: @escaping () -> BridgeClient,
         verifiedTunnelURL: @escaping () -> String?,
         bridgePort: Int) {
        self.environment = environment
        self.agentConnect = agentConnect
        self.bridgeClient = bridgeClient
        self.verifiedTunnelURL = verifiedTunnelURL
        self.bridgePort = bridgePort
        environment.onProbed = { [weak self] probe, state in
            self?.applyBridge(probe: probe, state: state)
        }
    }

    deinit { pollTimer?.invalidate() }

    // MARK: 探測

    func refresh() {
        environment.refresh()        // → onProbed → applyBridge
        refreshReachability()
    }

    /// 探一次並在有定論(或逾時)時回報 —— 決定「要不要讓使用者看到這張清單」。
    func evaluateOnce(deadline: TimeInterval = 3) {
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, !self.firstEvaluationDone else { return }
            self.firstEvaluationDone = true
            self.onFirstEvaluation?(false)   // 還沒有定論 → 清單攤開給他看,別卡在空白
        }
    }

    /// 清單還沒全綠時每 4 秒自動重測 —— 使用者在別的視窗把 CLI 登入好之後,
    /// 這裡要自己變綠,不該逼他回來按按鈕。
    func startAutoRefresh() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.plan.gate.allowsQR else { return self.stopAutoRefresh() }
            guard self.busyMessage == nil else { return }   // 自動安裝中別插隊
            self.refresh()
        }
    }

    func stopAutoRefresh() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func applyBridge(probe: BridgeEnvironmentProbe, state: BridgeEnvironmentState) {
        bridgeProbe = probe
        bridgeState = state
        onBridgeProbed?(state)
        if state.isReady {
            refreshAgents()
        } else {
            agents = nil        // bridge 沒活就問不準 —— 不留舊答案冒充現況
        }
        rebuild()
    }

    private func refreshAgents() {
        bridgeClient().fetchAgentAuth { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.agents = snapshot
                if self.note?.hasPrefix("問不到") == true { self.note = nil }
            case .failure:
                // 問不到就維持「檢查中」(擋住 QR 是安全的那一邊),並明說在重試。
                self.agents = nil
                self.note = "問不到 AI 引擎的登入狀態,正在重試…"
            }
            self.rebuild()
        }
    }

    private func refreshReachability() {
        let addresses = HostCandidates.localIPv4Addresses()
        let tunnel = verifiedTunnelURL()
        reach = ReachabilityReport.make(localIPv4: addresses, bridgePort: bridgePort, tunnelURL: tunnel)
        rebuild()
    }

    private func rebuild() {
        let wasOpen = plan.gate.allowsQR
        plan = SetupWizardPlanner.plan(bridgeState: bridgeState,
                                       probe: bridgeProbe,
                                       layout: environment.bootstrap.layout,
                                       agents: agents,
                                       reach: reach)
        if plan.gate.allowsQR, !wasOpen {
            stopAutoRefresh()
            onGateOpened?()
        }
        // .waitingBridge / .checkingAgents 都還在動,不算定論。
        let settled = (plan.gate == .ready || plan.gate == .noUsableAgent)
        if settled, !firstEvaluationDone {
            firstEvaluationDone = true
            onFirstEvaluation?(plan.gate.allowsQR)
        }
    }

    // MARK: 動作

    func perform(_ action: SetupWizardAction) {
        note = nil
        switch action {
        case .installBridge, .startBridge:
            environment.runPrimaryAction()      // 既有的「一鍵安裝並啟動 / 啟動」
        case .pasteToken:
            askForToken()
        case .installAgent(let cli):
            installAgent(cli)
        case .loginAgent(let cli):
            agentConnect.connect(cli)           // codex 開瀏覽器;claude 開授權視窗
            startAutoRefresh()
        case .recheck:
            refresh()
        case .openQR:
            onRequestQR?()
        }
    }

    func openHelp(_ raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLog() { environment.revealLog() }

    /// 自動裝 AI CLI —— 使用者不必開終端機打指令。
    /// 裝不起來(沒有 npm、沒網路…)不硬撐:收掉忙碌狀態,改成「照說明裝」。
    private func installAgent(_ cli: AgentCLI) {
        guard agentInstall == nil else { return }
        busyMessage = "正在安裝 \(cli.displayName) —— 大約一兩分鐘,不用動手。"
        environment.bootstrap.appendLog("[wizard] install \(cli.rawValue): \(cli.installCommand)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", cli.installCommand]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentCLIProbe.augmentedPATH(home: NSHomeDirectory(), existing: env["PATH"])
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // 輸出只進記錄檔,不上畫面(使用者不該看到英文安裝腳本的噪音)。
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.environment.bootstrap.appendLog(text.trimmingCharacters(in: .newlines))
        }
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.agentInstall = nil
                self.busyMessage = nil
                if status != 0 {
                    self.note = "\(cli.displayName) 自動安裝沒成功。按那一列的「說明」照官網做一次,裝好回來按「重新檢查」。"
                }
                self.refresh()
            }
        }
        do {
            try process.run()
            agentInstall = process
        } catch {
            agentInstall = nil
            busyMessage = nil
            note = "\(cli.displayName) 自動安裝啟動不了。按那一列的「說明」照官網做一次。"
            return
        }
        // 保險:5 分鐘沒裝完就收掉,不讓畫面永遠卡在「安裝中」。
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, let running = self.agentInstall, running.isRunning else { return }
            running.terminate()
        }
    }

    /// 自己架 bridge 的使用者可能要手動貼金鑰。登入前沒有控制台可開,所以就地問。
    private func askForToken() {
        let alert = NSAlert()
        alert.messageText = "貼上你的 Bridge 金鑰"
        alert.informativeText = "你自己架的 Bridge 需要一組金鑰,Pocket 才能幫你產生配對 QR。\n沒有的話讓 Pocket 幫你裝一套就不用管這個。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "金鑰"
        alert.accessoryView = field
        alert.addButton(withTitle: "存起來")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        BridgeToken.setOverride(value)
        refresh()
    }
}

// MARK: - 無頭渲染出口(POCKET_WIZARD_SHOT=/path/out.png)
//
// 同 POCKET_ENV_DOCTOR 的精神:讓「畫面長什麼樣」這件事能在沒有人坐在螢幕前的
// 情況下被驗證(CI、鎖屏的機器都能跑)。把清單畫進離螢幕視窗再存成 PNG,
// 不碰 Dock、不搶焦點、不開任何真視窗。
enum WizardShot {

    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["POCKET_WIZARD_SHOT"]
    }

    static func runAndExit(path: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)      // 不進 Dock、不搶焦點

        let env = ProcessInfo.processInfo.environment
        let port = BridgeInstallLayout.resolve(home: NSHomeDirectory(), environment: env).port
        let fakeTunnel = env["POCKET_WIZARD_FAKE_TUNNEL"]
        let agents = AgentConnectModel()
        let environment = BridgeEnvironmentModel(bootstrap: BridgeBootstrap(), agents: agents)
        let model = SetupWizardModel(
            environment: environment,
            agentConnect: agents,
            bridgeClient: { BridgeClient(baseURL: "http://127.0.0.1:\(port)") },
            verifiedTunnelURL: { fakeTunnel },
            bridgePort: port)
        model.refresh()

        // 等探測回來(bridge /health + /app/v1/agents/auth 都是秒級)。
        let wait = Double(env["POCKET_WIZARD_SHOT_WAIT"] ?? "") ?? 4
        RunLoop.main.run(until: Date().addingTimeInterval(wait))

        // POCKET_WIZARD_SHOT_WINDOW=1:驗**真的**引導視窗(OnboardingWindowController
        // → showWizard)有沒有把清單掛上去、視窗有沒有長到清單需要的高度。
        // 這裡不出圖:視窗沒上螢幕時圖層不會合成(鎖屏的機器必定一片白),
        // 出一張白圖比不出圖更糟 —— 所以改印結構報告。
        if env["POCKET_WIZARD_SHOT_WINDOW"] == "1" {
            let controller = OnboardingWindowController()
            controller.showWizard(model: model)
            guard let content = controller.window?.contentView else { exit(2) }
            content.layoutSubtreeIfNeeded()
            let kinds = content.subviews.map { String(describing: type(of: $0)) }
            let hostsWizard = kinds.contains { $0.contains("SetupWizardView") }
            print("window=\(Int(content.bounds.width))x\(Int(content.bounds.height)) "
                  + "hostsWizard=\(hostsWizard)\n\(kinds.joined(separator: " + "))")
            exit(hostsWizard && content.bounds.height >= 600 ? 0 : 3)
        }

        let width: CGFloat = 460
        let hosting = NSHostingView(rootView:
            SetupWizardView(model: model, environment: environment)
                .padding(.horizontal, 22)
                .padding(.vertical, 24)
                .frame(width: width, alignment: .leading))
        let height = max(360, hosting.fittingSize.height)
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)

        let backdrop = BrandBackgroundView(frame: bounds)
        hosting.frame = bounds
        let container = NSView(frame: bounds)
        container.addSubview(backdrop)
        container.addSubview(hosting)

        // 離螢幕視窗:SwiftUI 要掛在 window 上才會完成一次完整 layout。
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))   // 讓 SwiftUI 畫完

        write(view: container, to: path, plan: model.plan)
    }

    /// 把 view 畫進點陣圖存成 PNG,並印一行機器可讀的摘要(截圖與判定對得起來)。
    private static func write(view: NSView, to path: String, plan: SetupWizardPlan) -> Never {
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            FileHandle.standardError.write(Data("cannot allocate bitmap\n".utf8))
            exit(2)
        }
        // 圖層化的視窗(fullSizeContentView 會強制 layer-backed)cacheDisplay 會畫出
        // 一片白 —— 那種就走 CALayer.render。
        if let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            layer.render(in: ctx.cgContext)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            view.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("cannot encode png\n".utf8))
            exit(2)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        let summary = plan.rows
            .map { "\($0.number)\($0.title)=\(statusWord($0.status))" }
            .joined(separator: " ")
        print("gate=\(plan.gate) allowsQR=\(plan.gate.allowsQR)\n\(summary)\n\(path)")
        exit(0)
    }

    private static func statusWord(_ s: BridgeChecklistItem.Status) -> String {
        switch s {
        case .ok: return "綠"
        case .warning: return "黃"
        case .blocked: return "紅"
        case .pending: return "待"
        }
    }
}

// MARK: - View

struct SetupWizardView: View {
    @ObservedObject var model: SetupWizardModel
    @ObservedObject var environment: BridgeEnvironmentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.plan.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.35) }
                    rowView(row)
                }
            }
            .padding(.vertical, 2)
            footer
        }
        .onAppear { model.startAutoRefresh() }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: 標題

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("設定這台 Mac").font(.title3.weight(.semibold)).foregroundStyle(Brand.ink)
            Text(model.plan.gate.allowsQR
                 ? "都好了 —— 拿手機掃 QR 就能開始用。"
                 : "照著下面走完,手機掃 QR 就能馬上用。")
                .font(.callout)
                .foregroundStyle(model.plan.gate.allowsQR ? Brand.green : .secondary)
        }
    }

    // MARK: 一列

    @ViewBuilder
    private func rowView(_ row: SetupWizardRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            glyph(row.status).frame(width: 18, height: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(row.number).font(.caption).foregroundStyle(.secondary)
                    Text(row.title).font(.body.weight(.medium)).foregroundStyle(Brand.ink)
                }
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(row.status == .blocked ? Brand.ink.opacity(0.75) : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            controls(row)
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func glyph(_ status: BridgeChecklistItem.Status) -> some View {
        switch status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .blocked:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.red)
        case .pending:
            ProgressView().controlSize(.small)
        }
    }

    /// 紅燈必有可按的東西 —— 動作鈕優先,再不然至少有「說明」。
    @ViewBuilder
    private func controls(_ row: SetupWizardRow) -> some View {
        HStack(spacing: 6) {
            if let action = row.action {
                Button(action.title) { model.perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(row.step == .qr ? Brand.green : Brand.red)
                    .controlSize(.small)
                    .disabled(isBusy)
            }
            if let help = row.helpURL, row.status != .ok {
                Button("說明") { model.openHelp(help) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .fixedSize()
    }

    private var isBusy: Bool { environment.isBusy || model.busyMessage != nil }

    // MARK: 收尾

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 擋住的理由已經寫在 ⑥ 那一列了,這裡不再重複一次 —— 只留收尾感。
            if model.plan.gate.allowsQR {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Brand.green)
                    Text("準備好了").font(.body.weight(.semibold)).foregroundStyle(Brand.green)
                }
            }
            if let busy = model.busyMessage ?? (environment.isBusy ? environment.busyMessage : nil) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(Brand.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("重新檢查") { model.perform(.recheck) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(isBusy)
                Button("查看記錄檔") { model.revealLog() }
                    .buttonStyle(.borderless).controlSize(.small).font(.caption)
                Spacer()
            }
        }
    }
}
