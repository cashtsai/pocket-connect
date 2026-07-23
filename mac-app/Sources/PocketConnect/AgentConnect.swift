import AppKit
import PocketConnectKit
import SwiftUI

// 「AI 引擎」一鍵連接 — 給不會用終端機的使用者連接 Claude Code / Codex。
//
//   • 探測:掃 ~/.local/bin、/opt/homebrew/bin、/usr/local/bin 等常見位置
//     (GUI app 的 PATH 沒有 shell profile,不能只靠 PATH — 見 AgentCLIProbe)。
//   • 三態:未安裝(給安裝指令+官網連結)/ 已安裝未登入(「連接」)/ 已連接(綠勾+帳號)。
//   • codex:`codex login` 會自己開瀏覽器 + 起 localhost:1455 回呼 server,背景 Process
//     直接跑即可。⚠️ 子程序必須活到授權完成 — CLI 先死的話瀏覽器授權完會沒人接聽
//     (實測踩過)。所以輪詢期間絕不 terminate,只在逾時(5 分鐘)或成功後收掉。
//   • claude:`claude auth login` 沒有 TTY 時會停在「Paste code here」等貼授權碼
//     (實測),GUI Process 跑不完 → 產生 .command 檔開「終端機」跑,UI 註明。
//   • 按下「連接」後每 2.5 秒重查 status,成功即轉綠勾。

final class AgentConnectModel: ObservableObject {

    enum Phase: Equatable {
        case checking
        case notInstalled
        case notLoggedIn
        case connecting
        case connected(String?)   // 帳號描述(如有)
    }

    struct Row: Identifiable {
        let cli: AgentCLI
        var id: String { cli.rawValue }
        var binaryPath: String?
        var phase: Phase = .checking
        var showInstallHelp = false
        var justCopied = false
        var note: String?         // 連接失敗等一次性提示
    }

    @Published var rows: [Row] = AgentCLI.allCases.map { Row(cli: $0) }

    private var pollTimers: [AgentCLI: Timer] = [:]
    private var pollDeadlines: [AgentCLI: Date] = [:]
    /// 進行中的 login 子程序 — 持強參考,授權完成前絕不 terminate。
    private var loginProcesses: [AgentCLI: Process] = [:]

    // MARK: 探測

    func refreshAll() {
        AgentCLI.allCases.forEach { probe($0) }
    }

    func probe(_ cli: AgentCLI) {
        guard let idx = rows.firstIndex(where: { $0.cli == cli }) else { return }
        let env = ProcessInfo.processInfo.environment
        let path = AgentCLIProbe.resolveBinary(
            named: cli.binaryName,
            home: NSHomeDirectory(),
            pathVariable: env["PATH"],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
        rows[idx].binaryPath = path
        guard let path else {
            rows[idx].phase = .notInstalled
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.runCLI(path: path, arguments: cli.statusArguments)
            let state = AgentCLIProbe.parseStatus(for: cli, exitCode: result.exitCode, output: result.output)
            DispatchQueue.main.async { self?.apply(state, to: cli) }
        }
    }

    private func apply(_ state: AgentConnectionState, to cli: AgentCLI) {
        guard let idx = rows.firstIndex(where: { $0.cli == cli }) else { return }
        switch state {
        case .connected(let account):
            rows[idx].phase = .connected(account)
            rows[idx].note = nil
            stopPolling(cli)
            loginProcesses[cli] = nil   // 已完成,子程序自己會結束
        case .notLoggedIn:
            // 連接流程進行中就維持 connecting,別把進度蓋回「未登入」。
            if rows[idx].phase != .connecting { rows[idx].phase = .notLoggedIn }
        case .notInstalled:
            rows[idx].phase = .notInstalled
        }
    }

    // MARK: 連接(login)

    func connect(_ cli: AgentCLI) {
        guard let idx = rows.firstIndex(where: { $0.cli == cli }),
              let path = rows[idx].binaryPath else { return }
        rows[idx].note = nil
        rows[idx].phase = .connecting

        switch cli {
        case .codex:
            // 背景跑 `codex login`:自己開瀏覽器、起 localhost 回呼 server。
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = cli.loginArguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = AgentCLIProbe.augmentedPATH(home: NSHomeDirectory(), existing: env["PATH"])
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async { self?.loginProcessEnded(cli, status: proc.terminationStatus) }
            }
            do {
                try process.run()
                loginProcesses[cli] = process
            } catch {
                rows[idx].phase = .notLoggedIn
                rows[idx].note = "無法啟動 codex:\(error.localizedDescription)"
                return
            }
        case .claude:
            // 沒 TTY 跑不完(要貼授權碼)→ 開終端機視窗跑,授權完自動偵測。
            do {
                try Self.openTerminalLogin(binaryPath: path, arguments: cli.loginArguments)
            } catch {
                rows[idx].phase = .notLoggedIn
                rows[idx].note = "無法開啟終端機:\(error.localizedDescription)"
                return
            }
        }
        startPolling(cli)
    }

    /// codex login 子程序結束:成功會被下一輪 status 輪詢轉綠勾;
    /// 失敗(非零)就直接收掉並提示重試。
    private func loginProcessEnded(_ cli: AgentCLI, status: Int32) {
        guard loginProcesses[cli] != nil else { return }
        loginProcesses[cli] = nil
        probe(cli)
        guard status != 0,
              let idx = rows.firstIndex(where: { $0.cli == cli }),
              rows[idx].phase == .connecting else { return }
        stopPolling(cli)
        rows[idx].phase = .notLoggedIn
        rows[idx].note = "登入沒有完成,請再按一次「連接」。"
    }

    // MARK: 輪詢(2.5 秒查一次 status,成功轉綠勾,5 分鐘逾時)

    private func startPolling(_ cli: AgentCLI) {
        pollDeadlines[cli] = Date().addingTimeInterval(300)
        pollTimers[cli]?.invalidate()
        pollTimers[cli] = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let deadline = self.pollDeadlines[cli], Date() > deadline {
                self.timeOutConnect(cli)
                return
            }
            self.probe(cli)
        }
    }

    private func timeOutConnect(_ cli: AgentCLI) {
        stopPolling(cli)
        // 只有逾時才收掉還在跑的 login 子程序(使用者可再按一次重來)。
        if let process = loginProcesses[cli], process.isRunning { process.terminate() }
        loginProcesses[cli] = nil
        guard let idx = rows.firstIndex(where: { $0.cli == cli }),
              rows[idx].phase == .connecting else { return }
        rows[idx].phase = .notLoggedIn
        rows[idx].note = "等不到授權完成(5 分鐘),請再按一次「連接」。"
    }

    private func stopPolling(_ cli: AgentCLI) {
        pollTimers[cli]?.invalidate()
        pollTimers[cli] = nil
        pollDeadlines[cli] = nil
    }

    // MARK: 安裝說明

    func toggleInstallHelp(_ cli: AgentCLI) {
        guard let idx = rows.firstIndex(where: { $0.cli == cli }) else { return }
        rows[idx].showInstallHelp.toggle()
    }

    func copyInstallCommand(_ cli: AgentCLI) {
        guard let idx = rows.firstIndex(where: { $0.cli == cli }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cli.installCommand, forType: .string)
        rows[idx].justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let i = self.rows.firstIndex(where: { $0.cli == cli }) else { return }
            self.rows[i].justCopied = false
        }
    }

    // MARK: Process helpers

    /// 同步跑 CLI(呼叫端負責丟背景 queue),10 秒 watchdog 防卡死。
    private static func runCLI(path: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = AgentCLIProbe.augmentedPATH(home: NSHomeDirectory(), existing: env["PATH"])
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// 產生 .command 檔交給「終端機」跑(免 Apple Events 自動化授權)。
    private static func openTerminalLogin(binaryPath: String, arguments: [String]) throws {
        let script = """
        #!/bin/zsh
        clear
        echo "Pocket — 連接授權"
        echo "瀏覽器會開啟授權頁;完成後回到 Pocket 控制台看到綠勾,即可關閉此視窗。"
        echo
        exec '\(binaryPath)' \(arguments.joined(separator: " "))
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pocket-agent-login.command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

// MARK: - View(嵌進控制台的卡片內容)

struct AgentEnginesSection: View {
    @ObservedObject var model: AgentConnectModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 引擎").font(.headline).foregroundStyle(Brand.ink)
            Text("連接你的 AI 帳號,手機那頭才有引擎可用。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.rows) { row in
                engineRow(row)
                if row.cli != AgentCLI.allCases.last {
                    Divider().opacity(0.4)
                }
            }
        }
    }

    @ViewBuilder
    private func engineRow(_ row: AgentConnectModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                statusIcon(row.phase).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.cli.displayName).foregroundStyle(Brand.ink)
                    Text(subtitle(row)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailingControl(row)
            }
            if row.showInstallHelp, row.phase == .notInstalled {
                installHelp(row)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func statusIcon(_ phase: AgentConnectModel.Phase) -> some View {
        switch phase {
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16)).foregroundStyle(Brand.green)
        case .connecting, .checking:
            ProgressView().controlSize(.small)
        case .notLoggedIn:
            Circle().fill(Brand.red).frame(width: 8, height: 8)
        case .notInstalled:
            Circle().fill(Brand.espresso.opacity(0.25)).frame(width: 8, height: 8)
        }
    }

    private func subtitle(_ row: AgentConnectModel.Row) -> String {
        if let note = row.note { return note }
        switch row.phase {
        case .checking: return "檢查中…"
        case .notInstalled: return "尚未安裝"
        case .notLoggedIn:
            return row.cli == .claude
                ? "已安裝 · 按「連接」會開啟終端機視窗完成授權"
                : "已安裝 · 按「連接」會開啟瀏覽器授權"
        case .connecting:
            return row.cli == .claude
                ? "已開啟終端機視窗 — 完成瀏覽器授權後會自動偵測"
                : "已開啟瀏覽器 — 在網頁按「授權」即可,完成後自動偵測"
        case .connected(let account): return account ?? "已連接"
        }
    }

    @ViewBuilder
    private func trailingControl(_ row: AgentConnectModel.Row) -> some View {
        switch row.phase {
        case .notInstalled:
            Button(row.showInstallHelp ? "收起說明" : "安裝說明") {
                model.toggleInstallHelp(row.cli)
            }
            .buttonStyle(.bordered).controlSize(.small)
        case .notLoggedIn:
            Button("連接") { model.connect(row.cli) }
                .buttonStyle(.borderedProminent).tint(Brand.red).controlSize(.small)
        case .connected:
            Text("已連接").font(.caption).foregroundStyle(Brand.green)
        case .checking, .connecting:
            EmptyView()
        }
    }

    private func installHelp(_ row: AgentConnectModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("打開「終端機」App,貼上這行指令安裝:")
                .font(.caption).foregroundStyle(.secondary)
            Text(row.cli.installCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.espresso.opacity(0.06)))
            HStack(spacing: 10) {
                Button(row.justCopied ? "已複製 ✓" : "複製指令") {
                    model.copyInstallCommand(row.cli)
                }
                .buttonStyle(.bordered).controlSize(.small)
                if let url = URL(string: row.cli.websiteURL) {
                    Link("官網說明", destination: url).font(.caption)
                }
                Spacer()
                Button("我裝好了,重新檢查") { model.probe(row.cli) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(Brand.red)
            }
        }
        .padding(.leading, 30)
    }
}
