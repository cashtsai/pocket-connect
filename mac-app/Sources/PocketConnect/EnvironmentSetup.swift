import AppKit
import PocketConnectKit
import SwiftUI

// M3 — 「執行環境」畫面。同一份 view 用在兩個地方:
//   • 首次啟動:環境沒就緒時擋在 Apple 登入前面(不然登入會打一個不存在的
//     127.0.0.1 bridge,使用者只會看到「暫時連不到伺服器」這種查不出原因的錯)。
//   • 控制台:常駐一張卡,隨時看得到環境狀態。
//
// 原則:app 能自動做的就一鍵做完(裝 bridge、寫 LaunchAgent、啟動、驗 /health);
// 自動不了的(沒 python、埠被別人占、要自己裝 Claude Code)一律變成清單上一條
// 明確的項目 + 可複製指令/說明連結,絕不無聲失敗。

final class BridgeEnvironmentModel: ObservableObject {

    @Published private(set) var state: BridgeEnvironmentState?
    @Published private(set) var probe = BridgeEnvironmentProbe()
    @Published private(set) var checklist: [BridgeChecklistItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var busyMessage = ""
    @Published var lastError: String?

    /// 環境從「沒就緒」變成「就緒」時呼叫一次(首次啟動用來自動往下走)。
    var onBecameReady: (() -> Void)?

    let bootstrap: BridgeBootstrap
    /// AI 引擎狀態的來源。控制台會傳既有的 model 進來,兩邊才不會講不一樣的話。
    private let agents: AgentConnectModel
    private var wasReady = false

    init(bootstrap: BridgeBootstrap = BridgeBootstrap(), agents: AgentConnectModel? = nil) {
        self.bootstrap = bootstrap
        self.agents = agents ?? AgentConnectModel()
        if agents == nil { self.agents.refreshAll() }
    }

    var isReady: Bool { state?.isReady ?? false }

    func refresh() {
        bootstrap.probe { [weak self] probe, state in
            guard let self else { return }
            self.probe = probe
            self.state = state
            self.checklist = BridgeChecklist.build(
                state: state, probe: probe, layout: self.bootstrap.layout,
                agentStates: self.agents.rows.map { ($0.cli, Self.connectionState($0.phase)) })
            if state.isReady, !self.wasReady {
                self.wasReady = true
                self.onBecameReady?()
            }
            if !state.isReady { self.wasReady = false }
        }
    }

    private static func connectionState(_ phase: AgentConnectModel.Phase) -> AgentConnectionState {
        switch phase {
        case .connected(let account): return .connected(account: account)
        case .notInstalled: return .notInstalled
        case .notLoggedIn, .connecting, .checking: return .notLoggedIn
        }
    }

    // MARK: 主要動作

    /// 目前狀態對應的主要按鈕文案;nil = 沒有可自動執行的動作。
    var primaryActionTitle: String? {
        switch state {
        case .needsInstall: return "一鍵安裝並啟動"
        case .installedNotRunning: return "啟動 Bridge"
        case .none, .some(.ready), .some(.readyButNoToken),
             .some(.portBusy), .some(.missingPython), .some(.missingBridgeSource):
            return nil
        }
    }

    func runPrimaryAction() {
        guard !isBusy, let state else { return }
        switch state {
        case .needsInstall(let source):
            start { [weak self] progress in self?.bootstrap.install(source: source, progress: progress) }
        case .installedNotRunning:
            start { [weak self] progress in self?.bootstrap.kickstart(progress: progress) }
        default:
            break
        }
    }

    private func start(_ work: (@escaping (BridgeBootstrap.Progress) -> Void) -> Void) {
        isBusy = true
        lastError = nil
        busyMessage = "準備中…"
        work { [weak self] progress in
            guard let self else { return }
            switch progress {
            case .message(let text):
                self.busyMessage = text
            case .finished(let result):
                self.isBusy = false
                self.busyMessage = ""
                if case .failure(let error) = result {
                    self.lastError = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    func revealLog() { bootstrap.revealLog() }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 標題列的一句話總結。
    var headline: String {
        switch state {
        case .none: return "檢查執行環境…"
        case .some(.ready): return "執行環境已就緒"
        case .some(.readyButNoToken): return "Bridge 活著,但讀不到金鑰"
        case .some(.installedNotRunning): return "Bridge 已安裝,但沒在跑"
        case .some(.needsInstall): return "還差一步:把 Bridge 裝起來"
        case .some(.portBusy): return "埠被其他程式占用了"
        case .some(.missingPython): return "需要 Python 3.10 以上"
        case .some(.missingBridgeSource): return "找不到 Bridge 程式"
        }
    }
}

// MARK: - View

struct EnvironmentSetupView: View {
    @ObservedObject var model: BridgeEnvironmentModel
    /// true = 首次啟動的全畫面版(標題大一點、附說明);false = 控制台的卡片版。
    var isOnboarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isOnboarding {
                Text("Pocket 需要在這台 Mac 上跑一個小型服務(Bridge),手機才連得上。\n下面是這台機器的檢查結果。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.checklist) { item in
                row(item)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(Brand.red)
            }
            actions
        }
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("執行環境").font(.headline).foregroundStyle(Brand.ink)
            Text(model.headline).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private func row(_ item: BridgeChecklistItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusGlyph(item.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).foregroundStyle(Brand.ink)
                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if item.fixItCommand != nil || item.fixItURL != nil, item.status != .ok {
                fixIt(item)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusGlyph(_ status: BridgeChecklistItem.Status) -> some View {
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

    @ViewBuilder
    private func fixIt(_ item: BridgeChecklistItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let command = item.fixItCommand {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Brand.espresso.opacity(0.06)))
            }
            HStack(spacing: 10) {
                if let command = item.fixItCommand {
                    Button("複製指令") { model.copy(command) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if let raw = item.fixItURL, let url = URL(string: raw) {
                    Link("說明", destination: url).font(.caption)
                }
                Spacer()
            }
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private var actions: some View {
        if model.isBusy {
            Text(model.busyMessage)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        HStack(spacing: 8) {
            if let title = model.primaryActionTitle {
                Button(title) { model.runPrimaryAction() }
                    .buttonStyle(.borderedProminent).tint(Brand.red)
                    .controlSize(.small).disabled(model.isBusy)
            }
            Button("重新檢查") { model.refresh() }
                .buttonStyle(.bordered).controlSize(.small).disabled(model.isBusy)
            Button("查看記錄檔") { model.revealLog() }
                .buttonStyle(.borderless).controlSize(.small).font(.caption)
            Spacer()
        }
    }
}
