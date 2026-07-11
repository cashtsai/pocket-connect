import AppKit

// M2 — Claude / Codex account linking via the official CLIs' browser OAuth
// (spec docs/M2_ACCOUNT_LINKING_SPEC.md, 方案 B). Pocket never touches the OAuth
// tokens: the official CLI owns them (~/.claude/.credentials.json,
// ~/.codex/auth.json). We only (1) trigger `login`, (2) poll `status`, and
// (3) show linked / unlinked + account email/plan in the UI. Nothing is sent to
// the bridge this round (spec §3 — pure local detection).

// MARK: - Model

enum LinkStatus: Equatable {
    case unknown
    case checking
    case linked(email: String?, plan: String?)
    case unlinked
    case linking
    case error(String)
}

enum AIProvider {
    case claude, codex

    var displayName: String { self == .claude ? "Claude Code" : "Codex" }

    /// status probe — parsed differently per provider (see AccountLinkChecker).
    var statusCommand: [String] {
        switch self {
        case .claude: return ["auth", "status", "--json"]
        case .codex:  return ["login", "status"]
        }
    }
    /// login command (opens a browser for OAuth; hangs until the user finishes).
    var loginCommand: [String] {
        switch self {
        case .claude: return ["auth", "login", "--claudeai"]
        case .codex:  return ["login"]
        }
    }
    var binaryName: String { self == .claude ? "claude" : "codex" }
}

// MARK: - CLI probe / trigger

final class AccountLinkChecker {
    /// Resolve the official CLI's absolute path. A GUI .app does NOT inherit the
    /// user's shell PATH, so we can't assume `claude`/`codex` are on PATH. Try the
    /// known install locations first, then fall back to a login shell `which`.
    static func resolveBinary(_ name: String) -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/node-v24.14.1-darwin-arm64/bin/\(name)",  // 實測路徑
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.local/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Fallback: a login shell picks up the PATH from the user's shell profile.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "which \(name)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let out, !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) else { return nil }
        return out
    }

    /// Run the status command and parse it. Blocks — callers dispatch to a
    /// background queue and marshal the result back to main themselves.
    static func checkStatus(_ provider: AIProvider) -> LinkStatus {
        guard let bin = resolveBinary(provider.binaryName) else {
            return .error("找不到 \(provider.binaryName) CLI，請先安裝")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = provider.statusCommand
        let outPipe = Pipe(); p.standardOutput = outPipe
        let errPipe = Pipe(); p.standardError = errPipe
        do { try p.run() } catch { return .error("執行失敗：\(error.localizedDescription)") }
        // Drain both pipes BEFORE waitUntilExit to avoid deadlocking on a full
        // 64 KB OS pipe buffer (status output is tiny, but this is the correct shape).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        switch provider {
        case .claude:
            // `claude auth status --json` → stdout JSON:
            //   {"loggedIn":bool,"email":..,"subscriptionType":..}
            guard let json = try? JSONSerialization.jsonObject(with: outData) as? [String: Any],
                  let loggedIn = json["loggedIn"] as? Bool else { return .unlinked }
            if !loggedIn { return .unlinked }
            return .linked(email: json["email"] as? String,
                           plan: json["subscriptionType"] as? String)
        case .codex:
            // `codex login status` has no --json and prints to STDERR (verified
            // codex-cli 0.142.2): "Logged in using ChatGPT" / "Not logged in".
            // Read both streams so we don't miss it.
            let text = ((String(data: outData, encoding: .utf8) ?? "")
                        + (String(data: errData, encoding: .utf8) ?? "")).lowercased()
            if text.contains("logged in") && !text.contains("not logged in") {
                return .linked(email: nil, plan: nil)
            }
            return .unlinked
        }
    }

    /// Trigger login (opens a browser). Fire-and-forget — the command may hang
    /// until the user completes OAuth, so we never wait on it; completion is
    /// detected by polling checkStatus. Callers run this off the main queue.
    static func startLogin(_ provider: AIProvider) throws {
        guard let bin = resolveBinary(provider.binaryName) else {
            throw NSError(domain: "AccountLinking", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(provider.binaryName)"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = provider.loginCommand
        // Discard I/O — no TTY is attached to a GUI-launched process.
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
    }
}

// MARK: - Polling helper

/// Poll `checkStatus` every 2s until linked or timeout. `onUpdate` runs on main.
func pollUntilLinked(_ provider: AIProvider, timeout: TimeInterval = 120,
                     onUpdate: @escaping (LinkStatus) -> Void) {
    let deadline = Date().addingTimeInterval(timeout)
    func tick() {
        DispatchQueue.global().async {
            let status = AccountLinkChecker.checkStatus(provider)
            DispatchQueue.main.async { onUpdate(status) }
            if case .linked = status { return }              // done
            if Date() >= deadline {
                DispatchQueue.main.async { onUpdate(.error("逾時，請重試")) }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: tick)
        }
    }
    tick()
}

// MARK: - UI: one row per provider (independent — neither blocks the other)

final class ProviderRowView: NSView {
    let provider: AIProvider
    private(set) var status: LinkStatus = .unknown
    /// Fires whenever this row's status changes — lets the container re-evaluate
    /// the "至少一邊已連結" gate without the row knowing about siblings.
    var onStatusChange: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    /// Guards against a stale poll from a previous attempt updating the UI.
    private var pollGeneration = 0

    var isLinked: Bool { if case .linked = status { return true }; return false }

    init(provider: AIProvider, width: CGFloat) {
        self.provider = provider
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 92))

        nameLabel.stringValue = provider.displayName
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = PocketPalette.ink
        nameLabel.drawsBackground = false
        nameLabel.frame = NSRect(x: 16, y: 62, width: width - 140, height: 22)

        badgeLabel.font = .systemFont(ofSize: 12, weight: .medium)
        badgeLabel.alignment = .right
        badgeLabel.drawsBackground = false
        badgeLabel.frame = NSRect(x: width - 140, y: 63, width: 124, height: 20)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = PocketPalette.ink.withAlphaComponent(0.6)
        detailLabel.drawsBackground = false
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 16, y: 38, width: width - 32, height: 18)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .regular
        actionButton.target = self
        actionButton.action = #selector(tapAction)
        actionButton.frame = NSRect(x: 16, y: 6, width: 150, height: 28)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 176, y: 9, width: 18, height: 18)

        [nameLabel, badgeLabel, detailLabel, actionButton, spinner].forEach { addSubview($0) }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Cold-start / manual re-check: probe status on a background queue.
    func refresh() {
        set(.checking)
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            let s = AccountLinkChecker.checkStatus(self.provider)
            DispatchQueue.main.async { self.set(s) }
        }
    }

    @objc private func tapAction() {
        switch status {
        case .checking, .linking:
            return                              // busy — ignore
        default:
            beginLink()
        }
    }

    /// Trigger the browser OAuth and start polling until linked or timeout.
    private func beginLink() {
        set(.linking)
        pollGeneration += 1
        let generation = pollGeneration
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            do {
                try AccountLinkChecker.startLogin(self.provider)
            } catch {
                DispatchQueue.main.async { self.set(.error(error.localizedDescription)) }
                return
            }
            pollUntilLinked(self.provider) { [weak self] s in
                guard let self, generation == self.pollGeneration else { return }  // ignore stale poll
                // While waiting, an intermediate `.unlinked` just means "not done
                // yet" — keep showing the linking spinner until linked/timeout.
                if case .unlinked = s, case .linking = self.status { return }
                self.set(s)
            }
        }
    }

    private func set(_ s: LinkStatus) {
        status = s
        render()
        onStatusChange?()
    }

    private func render() {
        switch status {
        case .unknown, .checking:
            badgeLabel.stringValue = "檢查中…"
            badgeLabel.textColor = PocketPalette.ink.withAlphaComponent(0.5)
            detailLabel.stringValue = ""
            actionButton.title = "連結 \(provider.displayName)"
            actionButton.isEnabled = false
            spinner.startAnimation(nil)
        case .linked(let email, let plan):
            badgeLabel.stringValue = "已連結 ✓"
            badgeLabel.textColor = PocketPalette.green
            var detail = email ?? "已登入"
            if let plan, !plan.isEmpty { detail += "（\(plan)）" }
            detailLabel.stringValue = detail
            detailLabel.textColor = PocketPalette.ink.withAlphaComponent(0.6)
            actionButton.title = "重新連結"
            actionButton.isEnabled = true
            spinner.stopAnimation(nil)
        case .unlinked:
            badgeLabel.stringValue = "未連結"
            badgeLabel.textColor = PocketPalette.ink.withAlphaComponent(0.5)
            detailLabel.stringValue = ""
            actionButton.title = "連結 \(provider.displayName)"
            actionButton.isEnabled = true
            spinner.stopAnimation(nil)
        case .linking:
            badgeLabel.stringValue = "連結中…"
            badgeLabel.textColor = PocketPalette.blue
            detailLabel.stringValue = "已開啟瀏覽器，完成登入後會自動偵測…"
            detailLabel.textColor = PocketPalette.ink.withAlphaComponent(0.6)
            actionButton.title = "連結中…"
            actionButton.isEnabled = false
            spinner.startAnimation(nil)
        case .error(let msg):
            badgeLabel.stringValue = "錯誤"
            badgeLabel.textColor = PocketPalette.red
            detailLabel.stringValue = msg
            detailLabel.textColor = PocketPalette.red
            actionButton.title = "重試"
            actionButton.isEnabled = true
            spinner.stopAnimation(nil)
        }
    }
}

// MARK: - Account linking window

final class AccountLinkingWindowController: NSWindowController {
    private let width: CGFloat = 420
    private lazy var claudeRow = ProviderRowView(provider: .claude, width: width)
    private lazy var codexRow = ProviderRowView(provider: .codex, width: width)
    private let continueButton = NSButton(title: "完成", target: nil, action: nil)

    init() {
        let height: CGFloat = 380
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: height),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "帳號連結"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = PocketPalette.cream
        win.center()
        super.init(window: win)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        let background = BrandBackgroundView(frame: container.bounds)
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)

        let title = NSTextField(labelWithString: "連結你的 AI 帳號")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = PocketPalette.ink
        title.alignment = .center
        title.drawsBackground = false
        title.frame = NSRect(x: 20, y: height - 56, width: 380, height: 26)
        container.addSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString:
            "用官方 CLI 的瀏覽器登入連結你的 Claude / Codex 帳號。憑證由官方 CLI 自己保管，Pocket 不會碰到你的 token。")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = PocketPalette.ink.withAlphaComponent(0.55)
        subtitle.alignment = .center
        subtitle.drawsBackground = false
        subtitle.frame = NSRect(x: 30, y: height - 104, width: 360, height: 40)
        container.addSubview(subtitle)

        claudeRow.frame.origin = NSPoint(x: 0, y: height - 210)
        codexRow.frame.origin = NSPoint(x: 0, y: height - 306)
        claudeRow.onStatusChange = { [weak self] in self?.updateContinueGate() }
        codexRow.onStatusChange = { [weak self] in self?.updateContinueGate() }
        container.addSubview(claudeRow)
        container.addSubview(codexRow)

        // Hairline between the two provider rows for visual separation.
        let divider = NSBox(frame: NSRect(x: 16, y: height - 214, width: 388, height: 1))
        divider.boxType = .separator
        container.addSubview(divider)

        continueButton.bezelStyle = .rounded
        continueButton.controlSize = .large
        continueButton.keyEquivalent = "\r"
        continueButton.target = self
        continueButton.action = #selector(finish)
        continueButton.frame = NSRect(x: 130, y: 20, width: 160, height: 32)
        container.addSubview(continueButton)

        win.contentView = container
        updateContinueGate()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Cold-start detection — probe both providers when the window appears.
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        claudeRow.refresh()
        codexRow.refresh()
    }

    /// Spec §1: 「繼續」在至少一邊已連結時才可點（寬鬆版）。這裡的按鈕是「完成」，
    /// 同樣沿用此門檻：兩邊都沒連結時 disable，避免使用者以為沒事就關掉。
    private func updateContinueGate() {
        continueButton.isEnabled = claudeRow.isLinked || codexRow.isLinked
    }

    @objc private func finish() {
        window?.close()
    }
}
