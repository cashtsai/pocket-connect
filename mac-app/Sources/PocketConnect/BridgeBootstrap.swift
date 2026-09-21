import AppKit
import Foundation
import PocketConnectKit

// M3 — 執行環境偵測 + bridge bootstrap 的「執行層」。
//
// 決策全在 PocketConnectKit/BridgeEnvironment.swift(純函式、有單元測試);
// 這裡只負責去問真實世界:python 在哪、bridge 程式在哪、plist 在不在、
// /health 通不通、埠被誰占,然後把 install-local-bridge.sh 跑起來。
//
// 一條紅線:安裝一律走 per-user 佈局(label `com.pocketconnect.bridge`、
// 裝到 ~/Library/Application Support/PocketConnect/bridge),**絕不**碰開發機上
// production 的 `ai.studio.hermes-bridge`。若 8081 已經有服務在回 /health,
// planner 會判 .ready 直接沿用,不會重裝也不會搶埠。

final class BridgeBootstrap {

    /// 安裝過程的階段回報(UI 顯示用)。
    enum Progress {
        case message(String)
        case finished(Result<Void, Error>)
    }

    struct BootstrapError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let layout: BridgeInstallLayout
    private let home = NSHomeDirectory()
    private let fm = FileManager.default

    /// 正在跑的安裝子程序(避免重入)。
    private(set) var isInstalling = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.layout = BridgeInstallLayout.resolve(
            home: NSHomeDirectory(),
            environment: environment,
            bundledBridgePath: Self.bundledBridgePath())
    }

    /// `Pocket.app/Contents/Resources/bridge` —— 打包時用 `BUNDLE_BRIDGE=1` 才會有。
    /// 沒有就回 nil,偵測會退到本機 checkout 或直接報「找不到 bridge 程式」。
    static func bundledBridgePath() -> String? {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("bridge") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resources.path, isDirectory: &isDir), isDir.boolValue
        else { return nil }
        return resources.path
    }

    // MARK: - 探測

    /// 跑一次完整偵測。網路/子程序都在背景,completion 回主執行緒。
    func probe(completion: @escaping (BridgeEnvironmentProbe, BridgeEnvironmentState) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var result = BridgeEnvironmentProbe(
                pythonPath: self.resolvePython(),
                bridgeSource: self.resolveBridgeSource(),
                launchAgentInstalled: self.fm.fileExists(atPath: self.layout.launchAgentPath),
                tokenSource: BridgeToken.resolve(layout: self.layout)?.source,
                health: self.checkHealth(),
                portOccupant: nil)
            // 只有服務不通時才需要知道「那埠上是誰」—— 通了就不必花這個成本。
            if !result.health.isOK {
                result.portOccupant = self.portOccupant()
            }
            let state = BridgeEnvironmentPlanner.plan(result, layout: self.layout)
            DispatchQueue.main.async { completion(result, state) }
        }
    }

    /// 依候選清單找 python3。
    func resolvePython() -> String? {
        layout.pythonCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// 依候選清單找 bridge 程式來源。認定標準是目錄裡有 `bridge.py`
    /// (不是只要目錄在就算,免得抓到空目錄後 rsync 出一個跑不起來的服務)。
    func resolveBridgeSource() -> BridgeSource? {
        for candidate in layout.bridgeSourceCandidates {
            guard fm.fileExists(atPath: candidate + "/bridge.py") else { continue }
            if candidate == layout.installRoot { return .installed(candidate) }
            if candidate == Self.bundledBridgePath() { return .bundled(candidate) }
            return .localCheckout(candidate)
        }
        return nil
    }

    /// 同步打 /health(呼叫端負責丟背景)。
    func checkHealth(timeout: TimeInterval = 3) -> BridgeHealth {
        guard let url = URL(string: layout.healthURL) else { return .unreachable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = BridgeHealth.unreachable
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                outcome = (200..<300).contains(http.statusCode) ? .ok : .httpError(http.statusCode)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return outcome
    }

    /// 誰占著這個埠。lsof 拿 pid/command,ps 補完整執行檔路徑(用來判斷是不是
    /// Pocket 自己 venv 底下的 python)。
    func portOccupant() -> PortOccupant? {
        let lsof = Self.run("/usr/sbin/lsof",
                            ["-nP", "-iTCP:\(layout.port)", "-sTCP:LISTEN", "-F", "pcn"])
            ?? Self.run("/usr/bin/lsof",
                        ["-nP", "-iTCP:\(layout.port)", "-sTCP:LISTEN", "-F", "pcn"])
        guard let output = lsof, let occupant = PortProbeParser.parseLsof(output) else { return nil }
        let comm = Self.run("/bin/ps", ["-p", "\(occupant.pid)", "-o", "comm="])
            .flatMap(PortProbeParser.parsePSComm)
        return PortOccupant(pid: occupant.pid, command: occupant.command, executablePath: comm)
    }

    // MARK: - 安裝 / 啟動

    /// 跑 `install-local-bridge.sh`(bridge repo 現成的 per-user 安裝腳本 ——
    /// 這就是 M3 spec §3 TODO 的答案),把輸出寫進 ~/Library/Logs/Pocket/install.log。
    func install(source: BridgeSource, progress: @escaping (Progress) -> Void) {
        guard !isInstalling else { return }
        let script = source.path + "/deploy/install-local-bridge.sh"
        guard fm.isExecutableFile(atPath: script) else {
            return progress(.finished(.failure(BootstrapError(
                message: "找不到安裝腳本:\(script)"))))
        }
        isInstalling = true
        prepareLogDirectory()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func emit(_ text: String) {
                self.appendLog(text)
                DispatchQueue.main.async { progress(.message(text)) }
            }
            func finish(_ result: Result<Void, Error>) {
                self.isInstalling = false
                DispatchQueue.main.async { progress(.finished(result)) }
            }

            emit("▸ 開始安裝 bridge(來源:\(source.displayName))")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script]
            process.currentDirectoryURL = URL(fileURLWithPath: source.path)
            var env = ProcessInfo.processInfo.environment
            layout.installerEnvironment.forEach { env[$0] = $1 }
            // 安裝腳本自己會依需要抓 provider;Pocket 這條路只要 bridge 本體,
            // AI 引擎(Claude Code / Codex)由使用者自己裝,清單上有明確項目。
            env["POCKET_PROVIDER"] = env["POCKET_PROVIDER"] ?? "none"
            env["PATH"] = AgentCLIProbe.augmentedPATH(home: self.home, existing: env["PATH"])
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.split(separator: "\n") where !line.isEmpty {
                    emit(String(line))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                emit("✗ 無法啟動安裝腳本:\(error.localizedDescription)")
                return finish(.failure(error))
            }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil

            guard process.terminationStatus == 0 else {
                emit("✗ 安裝腳本失敗(exit \(process.terminationStatus))")
                return finish(.failure(BootstrapError(
                    message: "安裝失敗(exit \(process.terminationStatus))。記錄檔:\(self.layout.installLogPath)")))
            }

            emit("▸ 等待 bridge 回應 \(self.layout.healthURL)")
            guard self.waitForHealth() else {
                emit("✗ 安裝完成但 bridge 沒有回應")
                return finish(.failure(BootstrapError(
                    message: "bridge 裝好了但沒回應。記錄檔:\(self.layout.installLogPath)")))
            }
            emit("✓ bridge 已就緒")
            finish(.success(()))
        }
    }

    /// 服務已安裝但沒跑 → 踢一下。
    func kickstart(progress: @escaping (Progress) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func emit(_ text: String) {
                self.appendLog(text)
                DispatchQueue.main.async { progress(.message(text)) }
            }
            let uid = getuid()
            emit("▸ 啟動 \(self.layout.label)")
            // 先確保 plist 已 bootstrap(重開機後可能只是沒載入)。
            _ = Self.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", self.layout.launchAgentPath])
            _ = Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(uid)/\(self.layout.label)"])
            guard self.waitForHealth() else {
                emit("✗ 啟動後仍沒有回應")
                return DispatchQueue.main.async {
                    progress(.finished(.failure(BootstrapError(
                        message: "啟動了但 bridge 沒回應。記錄檔:\(self.layout.installLogPath)"))))
                }
            }
            emit("✓ bridge 已就緒")
            DispatchQueue.main.async { progress(.finished(.success(()))) }
        }
    }

    /// 輪詢 /health 直到通或逾時。
    func waitForHealth(attempts: Int = 20, interval: TimeInterval = 1) -> Bool {
        for _ in 0..<attempts {
            if checkHealth(timeout: 2).isOK { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    // MARK: - 記錄檔

    private func prepareLogDirectory() {
        try? fm.createDirectory(atPath: layout.logDirectory, withIntermediateDirectories: true)
    }

    func appendLog(_ line: String) {
        prepareLogDirectory()
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: layout.installLogPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: layout.installLogPath))
        }
    }

    func revealLog() {
        prepareLogDirectory()
        if !fm.fileExists(atPath: layout.installLogPath) {
            appendLog("(還沒有安裝記錄)")
        }
        NSWorkspace.shared.selectFile(layout.installLogPath,
                                      inFileViewerRootedAtPath: layout.logDirectory)
    }

    // MARK: - Process helper

    /// 同步跑一支小工具拿 stdout。找不到執行檔或非零退出就回 nil。
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - 乾跑診斷(POCKET_ENV_DOCTOR=1)

// 沒辦法真的清空一台 Mac,所以留這個出口:把整組路徑用環境變數指到一個 TEMP
// prefix,就能在這台機器上重現「全新 Mac」的每一個分支並印出 JSON 佐證。
// 正式使用者不會走到這裡(要顯式帶環境變數)。
enum BridgeEnvironmentDoctor {

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["POCKET_ENV_DOCTOR"] == "1"
    }

    /// 印出 JSON 後結束行程。
    static func runAndExit() -> Never {
        let bootstrap = BridgeBootstrap()
        let layout = bootstrap.layout
        var probe = BridgeEnvironmentProbe(
            pythonPath: bootstrap.resolvePython(),
            bridgeSource: bootstrap.resolveBridgeSource(),
            launchAgentInstalled: FileManager.default.fileExists(atPath: layout.launchAgentPath),
            tokenSource: BridgeToken.resolve(layout: layout)?.source,
            health: bootstrap.checkHealth(),
            portOccupant: nil)
        if !probe.health.isOK { probe.portOccupant = bootstrap.portOccupant() }
        let state = BridgeEnvironmentPlanner.plan(probe, layout: layout)
        let items = BridgeChecklist.build(state: state, probe: probe, layout: layout)

        var layoutJSON: [String: Any] = [:]
        layoutJSON["installRoot"] = layout.installRoot
        layoutJSON["venv"] = layout.venvPath
        layoutJSON["label"] = layout.label
        layoutJSON["launchAgent"] = layout.launchAgentPath
        layoutJSON["port"] = layout.port
        layoutJSON["healthURL"] = layout.healthURL
        layoutJSON["installLog"] = layout.installLogPath

        var occupantJSON: Any = NSNull()
        if let occupant = probe.portOccupant {
            var dict: [String: Any] = [:]
            dict["pid"] = Int(occupant.pid)
            dict["command"] = occupant.command
            dict["exe"] = occupant.executablePath ?? ""
            occupantJSON = dict
        }

        var probeJSON: [String: Any] = [:]
        probeJSON["python"] = probe.pythonPath ?? NSNull()
        probeJSON["bridgeSource"] = probe.bridgeSource.map { "\($0)" } ?? NSNull()
        probeJSON["launchAgentInstalled"] = probe.launchAgentInstalled
        probeJSON["tokenSource"] = probe.tokenSource?.rawValue ?? NSNull()
        probeJSON["health"] = "\(probe.health)"
        probeJSON["portOccupant"] = occupantJSON

        let checklistJSON: [[String: Any]] = items.map { item in
            var dict: [String: Any] = [:]
            dict["id"] = item.id
            dict["title"] = item.title
            dict["status"] = "\(item.status)"
            dict["detail"] = item.detail
            dict["fixItCommand"] = item.fixItCommand ?? ""
            return dict
        }

        var payload: [String: Any] = [:]
        payload["layout"] = layoutJSON
        payload["probe"] = probeJSON
        payload["state"] = describe(state)
        payload["checklist"] = checklistJSON
        if let data = try? JSONSerialization.data(withJSONObject: payload,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        exit(state.isReady ? 0 : 1)
    }

    static func describe(_ state: BridgeEnvironmentState) -> String {
        switch state {
        case .ready(let source): return "ready(\(source.rawValue))"
        case .readyButNoToken: return "readyButNoToken"
        case .installedNotRunning: return "installedNotRunning"
        case .portBusy(let o): return "portBusy(pid:\(o.pid),\(o.command))"
        case .needsInstall(let s): return "needsInstall(\(s.displayName))"
        case .missingPython: return "missingPython"
        case .missingBridgeSource: return "missingBridgeSource"
        }
    }
}
