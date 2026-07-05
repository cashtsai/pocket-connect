import AppKit

// Pocket — macOS menu-bar app.
// Supervises the local bridge + Cloudflare tunnel so the phone connects with no
// setup, shows a QR to download the iOS app, and (M1) does Sign in with Apple +
// mints an account-bound pairing QR so the phone can pair to THIS desktop.
// Built as a plain AppKit agent (LSUIElement) so it packages into a .app/.dmg
// without Xcode.

// MARK: - Config (the installer/first-run will eventually fill these in)
struct Config {
    // Public connect URL the phone points at (the Cloudflare tunnel hostname).
    // Also the base for all bridge app-API calls (auth/apple, pair/new).
    var connectURL = "https://pocket.tsai.cash"
    // Where users download the iOS app (TestFlight public link / App Store).
    var downloadURL = "https://testflight.apple.com/"   // TODO: real link
    // UserDefaults flag marking first-run onboarding as complete.
    let onboardedKey = "pocketConnectOnboarded"
    // Commands this app supervises. For a shipped installer these get bundled;
    // for now they point at the local dev setup.
    var bridge = LaunchSpec(
        exe: "/opt/homebrew/bin/python3",
        args: ["-m", "uvicorn", "bridge:app", "--host", "127.0.0.1", "--port", "8081"],
        cwd: NSString(string: "~/apps/hermes-openwebui-bridge").expandingTildeInPath)
    var tunnel = LaunchSpec(
        exe: "/opt/homebrew/bin/cloudflared",
        args: ["tunnel", "--config", NSString(string: "~/.cloudflared/pocket.yml").expandingTildeInPath, "run", "pocket"],
        cwd: nil)
}
struct LaunchSpec { var exe: String; var args: [String]; var cwd: String? }

// MARK: - Process supervisor
final class Supervisor {
    var onChange: (() -> Void)?
    private(set) var running = false
    private var procs: [Process] = []
    private let cfg: Config
    init(_ cfg: Config) { self.cfg = cfg }

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        for spec in [cfg.bridge, cfg.tunnel] {
            guard FileManager.default.isExecutableFile(atPath: spec.exe) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: spec.exe)
            p.arguments = spec.args
            if let cwd = spec.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            try? p.run()
            procs.append(p)
        }
        running = !procs.isEmpty
        onChange?()
    }

    func stop() {
        procs.forEach { $0.terminate() }
        procs.removeAll()
        running = false
        onChange?()
    }

    private func refresh() { running = procs.contains { $0.isRunning }; onChange?() }

    // Reachability check: is the public URL answering? (bridge returns 401/403 w/o
    // a token, which still proves the pipe is up.)
    func probe(_ url: String, _ done: @escaping (Bool) -> Void) {
        guard let u = URL(string: url) else { return done(false) }
        var r = URLRequest(url: u, timeoutInterval: 6)
        r.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            DispatchQueue.main.async { done((resp as? HTTPURLResponse) != nil) }
        }.resume()
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate, OnboardingDelegate {
    let cfg = Config()
    lazy var supervisor = Supervisor(cfg)
    lazy var bridge = BridgeClient(baseURL: cfg.connectURL)
    var statusItem: NSStatusItem!
    var downloadQRWindow: NSWindow?
    var reachable = false

    // Onboarding + pairing state.
    private var onboarding: OnboardingWindowController?
    private var onboardingPairing: PairingCoordinator?
    private var pairWindow: NSWindow?
    private var pairWindowView: PairingQRView?
    private var pairWindowCoordinator: PairingCoordinator?

    private var isSignedIn: Bool { Keychain.loadSessionToken() != nil }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()   // template "P" — auto light/dark
            button.imagePosition = .imageOnly
            button.toolTip = "Pocket"
        }
        supervisor.onChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        // periodic reachability poll
        Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.poll() }
        poll()

        // First-run: show onboarding unless already completed.
        if !UserDefaults.standard.bool(forKey: cfg.onboardedKey) {
            presentOnboarding()
        }
    }

    func poll() {
        supervisor.probe(cfg.connectURL) { [weak self] ok in
            guard let self else { return }
            self.reachable = ok
            // Icon stays the branded pocket mark; reachability shows on hover instead of
            // cluttering the menu bar with a status glyph.
            self.statusItem.button?.toolTip = ok ? "Pocket — ● 已連線" : "Pocket — ○ 離線"
            self.rebuildMenu()
        }
    }

    /// The real Pocket brand mark (denim-pocket outline), monochrome
    /// template version for the menu bar. Loaded from the bundled
    /// MenuBarIcon.png (menubar_36 from the official pocket brand set —
    /// NOT a system-font "P" placeholder). Template images are
    /// recolored by AppKit to match the active light/dark menu-bar
    /// appearance, so the full-color cowboy-pocket icon stays in the
    /// Dock/Finder while the bar shows a clean monochrome glyph of the
    /// SAME logo.
    private static func menuBarIcon() -> NSImage {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            // Fallback so the app never crashes if the asset is missing from
            // an old bundle — draws a plain "P" as a last resort.
            let size = NSSize(width: 18, height: 18)
            let fallback = NSImage(size: size, flipped: false) { rect in
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 15, weight: .bold),
                    .foregroundColor: NSColor.black,
                ]
                let text = "P" as NSString
                let textSize = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: rect.midX - textSize.width / 2,
                                      y: rect.midY - textSize.height / 2), withAttributes: attrs)
                return true
            }
            fallback.isTemplate = true
            return fallback
        }
        // Menu bar glyphs read best around 18pt tall — scale the high-res
        // source down while keeping it a template (system recolors it).
        image.size = NSSize(width: 18 * (image.size.width / image.size.height), height: 18)
        image.isTemplate = true
        return image
    }

    func rebuildMenu() {
        let m = NSMenu()
        let header = NSMenuItem(title: "Pocket", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        let status = NSMenuItem(
            title: reachable ? "● 已連線  \(cfg.connectURL)" : (supervisor.running ? "◐ 服務啟動中…" : "○ 離線"),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        // Login state line.
        let loginLine = NSMenuItem(title: isSignedIn ? "✓ 已用 Apple 登入" : "— 尚未登入", action: nil, keyEquivalent: "")
        loginLine.isEnabled = false
        m.addItem(loginLine)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "複製連線網址", action: #selector(copyURL), keyEquivalent: "c"))
        m.addItem(NSMenuItem(title: "顯示下載 App QR…", action: #selector(showDownloadQR), keyEquivalent: "q"))
        // Pairing QR — only actionable once signed in; otherwise prompts login.
        let pairItem = NSMenuItem(title: isSignedIn ? "配對這台桌機 QR…" : "配對這台桌機(請先登入)",
                                  action: #selector(showPairingQR), keyEquivalent: "p")
        m.addItem(pairItem)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: supervisor.running ? "停止服務" : "啟動服務",
                             action: #selector(toggleServices), keyEquivalent: "s"))
        m.addItem(NSMenuItem(title: "重新設定…", action: #selector(resetOnboarding), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "結束 Pocket", action: #selector(quit), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        statusItem.menu = m
    }

    @objc func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cfg.connectURL, forType: .string)
    }

    @objc func toggleServices() { supervisor.toggle() }

    @objc func quit() { supervisor.stop(); NSApp.terminate(nil) }

    // MARK: Download-app QR (unchanged behaviour, now using shared makeQR).
    @objc func showDownloadQR() {
        let img = makeQR(cfg.downloadURL, size: 320)
        let win = downloadQRWindow ?? makeDownloadQRWindow()
        downloadQRWindow = win
        if let iv = win.contentView?.subviews.compactMap({ $0 as? NSImageView }).first { iv.image = img }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeDownloadQRWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "下載 Pocket App"
        win.center()
        let content = NSView(frame: win.contentRect(forFrameRect: win.frame))
        let iv = NSImageView(frame: NSRect(x: 20, y: 80, width: 320, height: 320))
        iv.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: "用手機相機掃描下載 Pocket App")
        label.frame = NSRect(x: 0, y: 36, width: 360, height: 20)
        label.alignment = .center; label.textColor = .secondaryLabelColor
        content.addSubview(iv); content.addSubview(label)
        win.contentView = content
        return win
    }

    // MARK: Pairing QR from the menu (post-onboarding).
    @objc func showPairingQR() {
        guard isSignedIn else { presentOnboarding(); return }
        let view = pairWindowView ?? PairingQRView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))
        pairWindowView = view
        let coordinator = pairWindowCoordinator ?? PairingCoordinator(
            client: bridge, sessionProvider: { Keychain.loadSessionToken() })
        pairWindowCoordinator = coordinator
        coordinator.onState = { [weak view] s in view?.apply(s) }
        view.onRegenerate = { [weak coordinator] in coordinator?.refresh() }

        let win = pairWindow ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "配對這台桌機"
            w.center()
            w.contentView = view
            pairWindow = w
            return w
        }()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        coordinator.refresh()
    }

    // MARK: Onboarding
    @objc func resetOnboarding() {
        Keychain.clearSessionToken()
        UserDefaults.standard.set(false, forKey: cfg.onboardedKey)
        rebuildMenu()
        presentOnboarding()
    }

    private func presentOnboarding() {
        let controller = onboarding ?? OnboardingWindowController()
        controller.flowDelegate = self
        onboarding = controller
        controller.present()
    }

    // OnboardingDelegate — the delegate owns the actual auth + pairing calls.
    func onboardingDidTapSignIn(_ c: OnboardingWindowController) {
        guard let window = c.window else { return }
        let coordinator = AppleSignInCoordinator(presentingOver: window)
        coordinator.start { [weak self, weak c] result in
            guard let self, let c else { return }
            switch result {
            case .failure(let e):
                c.showSignInError("Apple 登入失敗:\(e.localizedDescription)")
            case .success(let cred):
                self.bridge.authApple(appleUserID: cred.userID, identityToken: cred.identityToken,
                                      displayName: cred.displayName, email: cred.email) { authResult in
                    switch authResult {
                    case .failure(let e):
                        c.showSignInError("登入伺服器失敗:\(e)")
                    case .success(let session):
                        guard Keychain.saveSessionToken(session.sessionToken) else {
                            return c.showSignInError("無法寫入 Keychain")
                        }
                        UserDefaults.standard.set(true, forKey: self.cfg.onboardedKey)
                        self.rebuildMenu()
                        self.startOnboardingPairing(c)
                    }
                }
            }
        }
    }

    private func startOnboardingPairing(_ c: OnboardingWindowController) {
        c.showPairing()
        let coordinator = PairingCoordinator(client: bridge, sessionProvider: { Keychain.loadSessionToken() })
        onboardingPairing = coordinator
        coordinator.onState = { [weak c] s in c?.pairingView.apply(s) }
        c.pairingView.onRegenerate = { [weak coordinator] in coordinator?.refresh() }
        coordinator.refresh()
    }

    func onboardingWindowDidClose(_ c: OnboardingWindowController) {
        onboardingPairing?.stop()
        onboardingPairing = nil
        onboarding = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
