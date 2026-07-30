import AppKit
import PocketConnectKit

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
    // Fixed Apple web-auth broker. Unlike connectURL/tunnel discovery, Apple's
    // registered return URL cannot change per user or per launch.
    var webAuthURL = "https://pocket.tsai.cash"
    // Where users download the iOS app (TestFlight public link / App Store).
    var downloadURL = "https://testflight.apple.com/"   // TODO: real link
    // UserDefaults flag marking first-run onboarding as complete.
    let onboardedKey = "pocketConnectOnboarded"
    // Local bridge port — CloudKit hostCandidates (tailnet/LAN URLs) point the
    // phone straight at it; must match the uvicorn --port below.
    var bridgePort = 8081
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
    /// Fired for anything worth surfacing on the dashboard's ErrorLog
    /// (design §4.4 "bridge 起不來"): missing executable or an early,
    /// non-normal process exit. Best-effort — the app keeps running either way.
    var onLaunchFailure: ((String) -> Void)?
    private(set) var running = false
    private var procs: [Process] = []
    private let cfg: Config
    init(_ cfg: Config) { self.cfg = cfg }

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        for spec in [cfg.bridge, cfg.tunnel] {
            guard FileManager.default.isExecutableFile(atPath: spec.exe) else {
                onLaunchFailure?("找不到可執行檔:\(spec.exe)")
                continue
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: spec.exe)
            p.arguments = spec.args
            if let cwd = spec.cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            p.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    if proc.terminationStatus != 0 {
                        self?.onLaunchFailure?("\(spec.exe) 異常結束(exit \(proc.terminationStatus))")
                    }
                    self?.refresh()
                }
            }
            do {
                try p.run()
                procs.append(p)
            } catch {
                onLaunchFailure?("啟動失敗:\(spec.exe) — \(error.localizedDescription)")
            }
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
        probeLatency(url) { ok, _ in done(ok) }
    }

    // Same probe, also timing the round trip — dashboard §5 M2c 驗收 ① wants
    // "bridge 存活/延遲" at a glance. latencyMs is nil when unreachable.
    func probeLatency(_ url: String, _ done: @escaping (Bool, Double?) -> Void) {
        guard let u = Self.healthURL(for: url) else { return done(false, nil) }
        var r = URLRequest(url: u, timeoutInterval: 6)
        r.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        let start = DispatchTime.now()
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(status)
            DispatchQueue.main.async { done(ok, ok ? elapsedMs : nil) }
        }.resume()
    }

    private static func healthURL(for baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            components.path = "/health"
        } else if trimmedPath != "health" {
            components.path = components.path.hasSuffix("/") ? components.path + "health" : components.path + "/health"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

// MARK: - App
final class AppDelegate: NSObject, NSApplicationDelegate, OnboardingDelegate {
    let cfg = Config()
    lazy var supervisor = Supervisor(cfg)
    // 連線網址：使用者自訂（進階）> 自動臨時 tunnel（免費）> 內建 fallback。
    private let customURLKey = "pocketCustomConnectURL"
    var customConnectURL: String? {
        let s = UserDefaults.standard.string(forKey: customURLKey)
        return (s?.isEmpty ?? true) ? nil : s
    }
    var autoTunnelURL: String?
    var effectiveConnectURL: String { customConnectURL ?? autoTunnelURL ?? cfg.connectURL }
    var localBridgeURL: String { "http://127.0.0.1:\(cfg.bridgePort)" }
    lazy var bridge = BridgeClient(baseURL: localBridgeURL, pairingBaseURL: effectiveConnectURL)
    lazy var webAuthBridge = BridgeClient(baseURL: cfg.webAuthURL)
    lazy var tunnelManager = TunnelManager(localPort: cfg.bridgePort,
                                           cloudflaredPath: TunnelManager.resolveCloudflaredPath())
    var statusItem: NSStatusItem!
    var downloadQRWindow: NSWindow?
    var reachable = false

    // Onboarding + pairing state.
    private var onboarding: OnboardingWindowController?
    private var onboardingPairing: PairingCoordinator?
    private var webAppleSignIn: WebAppleSignInCoordinator?
    private var pairWindow: NSWindow?
    private var pairWindowView: PairingQRView?
    private var pairWindowCoordinator: PairingCoordinator?

    // M2 — Claude/Codex account linking window (retained so it isn't deallocated
    // while open; recreated on demand from the menu).
    private var accountLinking: AccountLinkingWindowController?

    // CloudKit discovery layer (M2a) — nil until setupCloudSync() runs.
    var cloudSync: CloudSyncController?
    var cloudStatusText = "—"

    // Dashboard window (M2c) — lazily created on first "儀表板…" click.
    // Foreground refresh timer runs only while the window is open — a
    // fallback for the CKSubscription push (design §3.2 "前景 fetch 兜底").
    var dashboardWindow: NSWindow?
    var dashboardModel: DashboardViewModel?
    var dashboardRefreshTimer: Timer?
    private var bridgeInstallProcess: Process?

    private var isSignedIn: Bool { Keychain.loadSessionToken() != nil }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon(connected: false)   // CIS §06 彩色雙態
            button.imagePosition = .imageOnly
            button.toolTip = "Pocket"
        }
        supervisor.onChange = { [weak self] in self?.rebuildMenu() }
        supervisor.onLaunchFailure = { [weak self] message in
            self?.cloudSync?.logError(level: .error, code: "bridge_launch_failed", message: message)
        }
        ensureBundledBridgeInstalled()
        rebuildMenu()
        // periodic reachability poll
        Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.poll() }
        poll()

        // First-run: show onboarding unless already completed.
        if !UserDefaults.standard.bool(forKey: cfg.onboardedKey) {
            presentOnboarding()
        }

        // 開發/自動化驗證用:POCKET_SHOW_DASHBOARD=1 啟動即開控制台
        // (menu-bar app 沒視窗,UI 驗證不用再手點選單)。
        if ProcessInfo.processInfo.environment["POCKET_SHOW_DASHBOARD"] == "1" {
            DispatchQueue.main.async { [weak self] in self?.showDashboard() }
        }

        // CloudKit discovery (M2a) — self-gating: silently off on builds
        // without the iCloud entitlement or when no iCloud account is present.
        setupCloudSync()

        // 免費零設定：沒設自己的固定網址 → 自動開一條臨時 tunnel（trycloudflare），
        // 網址回來就重建 client、刷新畫面。設了自訂網址（進階）就不開。
        if customConnectURL == nil {
            tunnelManager.onURL = { [weak self] url in
                guard let self else { return }
                self.autoTunnelURL = url
                self.onConnectURLChanged()
            }
            tunnelManager.start()
        }
    }

    private func ensureBundledBridgeInstalled() {
        guard let bundleRoot = Bundle.main.resourceURL?.appendingPathComponent("bridge"),
              FileManager.default.isExecutableFile(
                atPath: bundleRoot.appendingPathComponent("deploy/install-local-bridge.sh").path
              )
        else { return }

        let layout = BridgeInstallLayout(homeDirectory: NSHomeDirectory())
        let bridgePy = layout.bridgeInstallRoot + "/bridge.py"
        let needsInstall = !FileManager.default.fileExists(atPath: layout.launchAgentPath)
            || !FileManager.default.fileExists(atPath: bridgePy)
        guard needsInstall else { return }

        let plan = BridgeInstallPlan(
            layout: layout,
            bridgeBundleRoot: bundleRoot.path,
            existingEnvironment: ProcessInfo.processInfo.environment
        )
        var installerEnvironment = plan.environment
        installerEnvironment["POCKET_DEFAULT_PROVIDER"] = bundledBridgeDefaultProvider()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: plan.installScriptPath)
        process.environment = installerEnvironment
        process.currentDirectoryURL = bundleRoot
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.bridgeInstallProcess = nil
                if proc.terminationStatus != 0 {
                    self?.cloudSync?.logError(
                        level: .error,
                        code: "bridge_install_failed",
                        message: "Bundled bridge installer exited \(proc.terminationStatus)"
                    )
                }
                self?.poll()
            }
        }
        do {
            try process.run()
            bridgeInstallProcess = process
        } catch {
            cloudSync?.logError(
                level: .error,
                code: "bridge_install_failed",
                message: error.localizedDescription
            )
        }
    }

    private func bundledBridgeDefaultProvider() -> String {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("BridgeDefaultProvider"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return "hermes" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "hermes", "openclaw", "none":
            return value
        default:
            return "hermes"
        }
    }

    func poll() {
        // The desktop app's own control path is the local bridge. The public
        // tunnel can churn or fail DNS while local Hermes remains healthy, so
        // do not use it for the menu-bar connection light.
        supervisor.probe(localBridgeURL) { [weak self] ok in
            guard let self else { return }
            self.reachable = ok
            // v005 狀態列雙態:連線/離線各自的 template 圖(系統自動配
            // light/dark);tooltip 保留文字說明。
            self.statusItem.button?.image = Self.menuBarIcon(connected: ok)
            self.statusItem.button?.toolTip = ok ? "Pocket — ● 已連線" : "Pocket — ○ 離線"
            self.rebuildMenu()
        }
    }

    /// CIS §06 狀態列雙態(彩色,非 template):
    ///   · connected = 貼紙口袋(box logo 貼紙縫上,MenuBarIconOn)
    ///   · offline   = 素口袋(MenuBarIconOff)
    /// 「連上了＝貼紙縫上去了」;彩色 icon 在一排灰 template icon 裡最大聲,
    /// 是刻意的品牌選擇(與 `Pocket macOS` 的 MenuBarExtra 一致,PR #113)。
    /// 因此 **isTemplate=false** —— 若設 true,AppKit 只拿 alpha 當遮罩,填滿的
    /// 彩色口袋就變一坨白方塊(這正是先前的 bug)。Falls back to the legacy
    /// monochrome MenuBarIcon.png(仍 template)when the dual-state assets are
    /// missing from an old bundle.
    private static func menuBarIcon(connected: Bool) -> NSImage {
        let name = connected ? "MenuBarIconOn" : "MenuBarIconOff"
        let coloredURL = Bundle.main.url(forResource: name, withExtension: "png")
        guard let url = coloredURL
                ?? Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
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
        // Menu bar icons read best around 18pt tall — scale the high-res source.
        image.size = NSSize(width: 18 * (image.size.width / image.size.height), height: 18)
        // Colored dual-state pocket renders as-is (CIS §06); only the legacy
        // monochrome MenuBarIcon.png fallback is a recolorable template.
        image.isTemplate = (coloredURL == nil)
        return image
    }

    func rebuildMenu() {
        let m = NSMenu()
        // 第一行：燈號 + 連線狀態（反白不可點）。
        let status = NSMenuItem(title: reachable ? "● 已連線" : "○ 未連線", action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        // 第二行：登入狀態（反白不可點）。
        let loginLine = NSMenuItem(title: isSignedIn ? "● 已登入" : "○ 尚未登入", action: nil, keyEquivalent: "")
        loginLine.isEnabled = false
        m.addItem(loginLine)
        m.addItem(.separator())
        // 未登入 → 只能「登入」；登入後才有「控制台」+「帳號連結」。
        if isSignedIn {
            m.addItem(NSMenuItem(title: "控制台", action: #selector(showDashboard), keyEquivalent: "d"))
            m.addItem(NSMenuItem(title: "帳號連結…", action: #selector(showAccountLinking), keyEquivalent: "l"))
        } else {
            m.addItem(NSMenuItem(title: "登入…", action: #selector(showLogin), keyEquivalent: "d"))
        }
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "狀態列隱藏", action: #selector(hideStatusBar), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "結束", action: #selector(quit), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        statusItem.menu = m
    }

    /// 未登入時選單的「登入…」入口 → 開登入頁。
    @objc func showLogin() { presentOnboarding() }

    /// 連線網址變了（拿到臨時 tunnel、或使用者改自訂網址）→ 重建 client、更新畫面。
    func onConnectURLChanged() {
        bridge = BridgeClient(baseURL: localBridgeURL, pairingBaseURL: effectiveConnectURL)
        rebuildMenu()
        dashboardModel?.refresh()
        poll()
    }

    /// 使用者設/清自己的固定網址（進階）。填了 → 停臨時 tunnel、用自訂；
    /// 清空 → 回到免費自動 tunnel。
    func setCustomConnectURL(_ url: String?) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        UserDefaults.standard.set(value, forKey: customURLKey)
        if value == nil {
            // 回到免費自動 tunnel
            tunnelManager.onURL = { [weak self] u in
                guard let self else { return }
                self.autoTunnelURL = u
                self.onConnectURLChanged()
            }
            tunnelManager.start()
        } else {
            // 用自訂網址 → 不需要臨時 tunnel
            tunnelManager.stop()
            autoTunnelURL = nil
        }
        onConnectURLChanged()
    }

    /// M2 —「帳號連結…」入口 → 開 Claude/Codex 帳號連結視窗（獨立於 Apple 登入
    /// 與 QR 配對流程；開窗即冷啟動偵測兩邊 CLI 狀態）。
    @objc func showAccountLinking() {
        let controller = accountLinking ?? AccountLinkingWindowController()
        accountLinking = controller
        controller.present()
    }

    /// 把登入時的網路錯誤翻成看得懂、可行動的中文（防呆）。
    static func friendlyLoginError(_ e: Error) -> String {
        if let urlErr = e as? URLError {
            switch urlErr.code {
            case .timedOut:
                return "連線逾時,請確認網路後再按一次登入。"
            case .notConnectedToInternet, .networkConnectionLost:
                return "網路中斷了,確認網路後再試一次。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "暫時連不到伺服器,請稍後再試。"
            default:
                return "登入連線出錯（\(urlErr.code.rawValue)）,請再試一次。"
            }
        }
        return "登入失敗:\(e.localizedDescription)"
    }

    /// 隱藏選單列圖示（服務照跑）。先跳提醒說明怎麼叫回來，按「確認」才真的隱藏。
    @objc func hideStatusBar() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "要隱藏選單列圖示嗎？"
        alert.informativeText = "Pocket 會繼續在背景執行（配對、連線都照常）。\n\n之後要再顯示圖示，從「應用程式」或 Launchpad 重新開啟 Pocket 就會回來。"
        alert.addButton(withTitle: "確認隱藏")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            statusItem.isVisible = false
        }
    }

    @objc func toggleServices() { supervisor.toggle() }

    @objc func quit() { tunnelManager.stop(); supervisor.stop(); NSApp.terminate(nil) }

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

    // MARK: 配對新裝置 — 開控制台並在裡面內嵌產生 QR（不再另開視窗）。
    @objc func showPairingQR() {
        guard isSignedIn else { presentOnboarding(); return }
        showDashboard()
        dashboardModel?.startPairing()
    }

    // MARK: Onboarding
    @objc func resetOnboarding() {
        webAppleSignIn?.cancel()
        webAppleSignIn = nil
        Keychain.clearSessionToken()
        UserDefaults.standard.set(false, forKey: cfg.onboardedKey)
        // 登出 → 強制關掉控制台，回到登入頁。
        dashboardModel?.stopPairing()
        dashboardWindow?.close()
        dashboardWindow = nil
        dashboardModel = nil
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
        if AppleSignInCoordinator.isAvailableForCurrentBuild {
            startNativeAppleSignIn(c)
        } else {
            startWebAppleSignIn(c)
        }
    }

    private func startNativeAppleSignIn(_ c: OnboardingWindowController) {
        guard let window = c.window else { return }
        let coordinator = AppleSignInCoordinator(presentingOver: window)
        coordinator.start { [weak self, weak c] result in
            guard let self, let c else { return }
            switch result {
            case .failure(let error):
                c.showSignInError(Self.friendlyLoginError(error))
            case .success(let credential):
                self.bridge.authApple(
                    appleUserID: credential.userID,
                    identityToken: credential.identityToken,
                    displayName: credential.displayName,
                    email: credential.email
                ) { [weak self, weak c] authResult in
                    guard let self, let c else { return }
                    self.completeAppleSignIn(authResult, controller: c)
                }
            }
        }
    }

    private func startWebAppleSignIn(_ c: OnboardingWindowController) {
        webAppleSignIn?.cancel()
        let coordinator = WebAppleSignInCoordinator(bridge: webAuthBridge)
        webAppleSignIn = coordinator
        coordinator.start { [weak self, weak c] result in
            guard let self, let c else { return }
            self.webAppleSignIn = nil
            switch result {
            case .failure(let error):
                c.showSignInError(Self.friendlyLoginError(error))
            case .success(let identity):
                self.bridge.authApple(
                    appleUserID: identity.appleUserID,
                    identityToken: identity.identityToken,
                    displayName: identity.displayName,
                    email: identity.email
                ) { [weak self, weak c] authResult in
                    guard let self, let c else { return }
                    self.completeAppleSignIn(authResult, controller: c)
                }
            }
        }
    }

    private func completeAppleSignIn(
        _ result: Result<AppleAuthResult, Error>,
        controller c: OnboardingWindowController
    ) {
        switch result {
        case .failure(let error):
            c.showSignInError(Self.friendlyLoginError(error))
        case .success(let session):
            let status = Keychain.saveSessionToken(session.sessionToken)
            guard status == errSecSuccess else {
                return c.showSignInError("無法寫入 Keychain (OSStatus \(status))")
            }
            UserDefaults.standard.set(true, forKey: cfg.onboardedKey)
            rebuildMenu()
            c.window?.close()
            onboarding = nil
            showDashboard()
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
        webAppleSignIn?.cancel()
        webAppleSignIn = nil
        onboardingPairing?.stop()
        onboardingPairing = nil
        onboarding = nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
