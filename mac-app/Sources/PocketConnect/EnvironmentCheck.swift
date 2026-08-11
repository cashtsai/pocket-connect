import Foundation

// M3 環境偵測（docs/M3_ENV_DETECTION_SPEC.md §1）：
// 啟動進 onboarding 前先確認「hermes 指令存在 + bridge /health 有回應」，
// 缺一就停在引導安裝畫面，不讓使用者登入完才發現連不上。

enum EnvironmentStatus: Equatable {
    case ready
    case missingHermes
    case missingBridge   // hermes 裝了但 bridge 沒跑起來
}

enum EnvironmentCheck {
    /// 測試用強制覆寫：POCKET_ENV_FORCE=ready|missingHermes|missingBridge。
    /// 驗收「未裝 Hermes」情境時不必真的砍掉本機 Hermes（spec §5）。
    static var forcedStatus: EnvironmentStatus? {
        switch ProcessInfo.processInfo.environment["POCKET_ENV_FORCE"] {
        case "ready": return .ready
        case "missingHermes": return .missingHermes
        case "missingBridge": return .missingBridge
        default: return nil
        }
    }

    /// GUI app 拿到的 PATH 沒有使用者 shell 的自訂路徑，所以除了 PATH
    /// 之外再掃 pip --user／Homebrew 等已知安裝位置。
    static func resolveBinary(_ name: String) -> String? {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        dirs += ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin",
                 "/usr/local/bin", "/usr/bin", "/bin"]
        for dir in dirs where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        return nil
    }

    /// GET http://127.0.0.1:<port>/health，2 秒 timeout（spec §1）。
    static func pingBridgeHealth(port: Int, _ done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return done(false) }
        var req = URLRequest(url: url, timeoutInterval: 2)
        req.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = ((resp as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    /// spec §1 checkEnvironmentReady()——health ping 是非同步，包成 completion 版。
    /// completion 保證回到 main queue。
    static func run(bridgePort: Int, _ done: @escaping (EnvironmentStatus) -> Void) {
        if let forced = forcedStatus { return DispatchQueue.main.async { done(forced) } }
        let hasHermes = resolveBinary("hermes") != nil
        pingBridgeHealth(port: bridgePort) { healthy in
            if hasHermes && healthy { done(.ready) }
            else if !hasHermes { done(.missingHermes) }
            else { done(.missingBridge) }
        }
    }
}

// MARK: - 一鍵安裝（spec §2/§3）
/// 以背景 Process 跑 install_hermes.sh，stdout/stderr 合併寫進
/// ~/Library/Logs/Pocket/install.log，供引導畫面的「查看記錄檔」使用。
final class HermesInstaller {
    static let logPath = NSString(string: "~/Library/Logs/Pocket/install.log").expandingTildeInPath

    /// install_hermes.sh 的位置：.app bundle Resources 優先；
    /// swift build 開發版從執行檔往上找原始碼樹的 packaging/。
    static func scriptURL() -> URL? {
        if let url = Bundle.main.url(forResource: "install_hermes", withExtension: "sh") { return url }
        var dir = Bundle.main.bundleURL   // 未打包時＝執行檔所在目錄（.build/release）
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("packaging/install_hermes.sh")
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private var proc: Process?
    private let outputQueue = DispatchQueue(label: "pocket.install.output")

    /// 完成時回 main queue：ok=exit 0；失敗時 detail 帶 exit code + 最後幾行輸出。
    func run(_ done: @escaping (_ ok: Bool, _ detail: String) -> Void) {
        guard let script = Self.scriptURL() else {
            return done(false, "找不到 install_hermes.sh（app bundle 未包含安裝腳本）")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin")
            + ":\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        var buffer = Data()
        // 邊跑邊收，避免輸出塞滿 pipe buffer 讓腳本卡死。
        pipe.fileHandleForReading.readabilityHandler = { [outputQueue] handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outputQueue.sync { buffer.append(chunk) } }
        }
        p.terminationHandler = { [outputQueue] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let output: String = outputQueue.sync {
                buffer.append(rest)
                return String(data: buffer, encoding: .utf8) ?? ""
            }
            Self.appendLog(output, exitCode: proc.terminationStatus)
            let ok = proc.terminationStatus == 0
            let tail = output.split(separator: "\n").suffix(3).joined(separator: "\n")
            DispatchQueue.main.async {
                done(ok, ok ? "" : "安裝失敗（exit \(proc.terminationStatus)）\n\(tail)")
            }
        }
        do {
            try p.run()
            proc = p
        } catch {
            done(false, "無法啟動安裝腳本:\(error.localizedDescription)")
        }
    }

    private static func appendLog(_ output: String, exitCode: Int32) {
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "=== install_hermes \(stamp) (exit \(exitCode)) ===\n\(output)\n"
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? entry.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}
