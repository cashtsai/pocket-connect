import Foundation

/// 免費零設定連線的核心:自動開一條 Cloudflare「臨時 tunnel」(trycloudflare.com)
/// 把本機 bridge 公開出去 —— 免帳號、免網域。
///
/// 注意:臨時 tunnel 的網址是**會變的**(每次重開換一個),所以拿到 / 變更時要
/// 透過 CloudKit discovery 把新網址(hostCandidates)同步給手機讓它跟上
/// (見 docs/FREE_TIER_CONNECTION_PLAN.md;免費 tier 因此強制要求開 iCloud)。
/// 只有在使用者「沒設自己的固定網址」時才啟用。
final class TunnelManager {
    private let localPort: Int
    private let cloudflaredPath: String
    private var process: Process?
    /// 是否應該保持運行 —— stop() 設 false，讓非預期結束才自動重啟。
    private var shouldRun = false

    /// 拿到 / 變更公開網址時在主執行緒回呼。
    var onURL: ((String) -> Void)?
    private(set) var currentURL: String?

    init(localPort: Int, cloudflaredPath: String) {
        self.localPort = localPort
        self.cloudflaredPath = cloudflaredPath
    }

    /// 這台機器上找得到 cloudflared 嗎(打包版 > Homebrew > /usr/local)。
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: cloudflaredPath) }

    static func resolveCloudflaredPath() -> String {
        if let bundled = Bundle.main.url(forResource: "cloudflared", withExtension: nil)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        for p in ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return "/opt/homebrew/bin/cloudflared"
    }

    func start() {
        guard isAvailable else { return }
        shouldRun = true
        launch()
    }

    private func launch() {
        guard process == nil, shouldRun else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cloudflaredPath)
        // quick tunnel:不需要帳號/設定檔,cloudflared 自己配一個 trycloudflare 網址。
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(localPort)"]
        let pipe = Pipe()
        p.standardError = pipe      // cloudflared 把指派的網址印在 stderr
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self?.scanForURL(s)
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                // 非預期結束（shouldRun 還是 true）→ 3 秒後自動重啟。
                guard self.shouldRun else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.launch()
                }
            }
        }
        do { try p.run(); process = p } catch { process = nil }
    }

    func stop() {
        shouldRun = false
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminate()
        process = nil
    }

    /// 從 cloudflared 的輸出撈出 `https://xxxx.trycloudflare.com`。
    private func scanForURL(_ chunk: String) {
        guard let range = chunk.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#,
                                      options: .regularExpression) else { return }
        let url = String(chunk[range])
        guard url != currentURL else { return }
        currentURL = url
        DispatchQueue.main.async { [weak self] in self?.onURL?(url) }
    }
}
