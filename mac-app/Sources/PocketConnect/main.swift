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
    // Where users download the iOS app (App Store).
    var downloadURL = "https://apps.apple.com/app/id6787644476"
    // UserDefaults flag marking first-run onboarding as complete.
    let onboardedKey = "pocketConnectOnboarded"
    // Local bridge port — CloudKit hostCandidates (tailnet/LAN URLs) point the
    // phone straight at it. Kept in sync with BridgeInstallLayout so the app,
    // the LaunchAgent and the QR payload all agree on one port.
    var bridgePort = BridgeInstallLayout.resolve(
        home: NSHomeDirectory(),
        environment: ProcessInfo.processInfo.environment).port
}

// MARK: - Reachability prober
// 這個 App **不**自己 spawn bridge/cloudflared:bridge 由 launchd 管
// (見 BridgeBootstrap — 裝 LaunchAgent 才是正確做法,直接 spawn 會跟 launchd 搶埠、
// 且 App 一關服務就死),cloudflared 由 TunnelManager 管。這裡只剩「通不通」的探測。
final class Supervisor {
    var onChange: (() -> Void)?
    private let cfg: Config
    init(_ cfg: Config) { self.cfg = cfg }

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
    private var webAppleSignIn: WebAppleSignInCoordinator?

    // M2 — Claude/Codex account linking window (retained so it isn't deallocated
    // while open; recreated on demand from the menu).
    private var accountLinking: AccountLinkingWindowController?

    // M3 — 執行環境偵測 + bridge bootstrap。
    lazy var bridgeBootstrap = BridgeBootstrap()
    private var environmentModel: BridgeEnvironmentModel?
    /// 最近一次偵測的結果（選單顯示 + 登入前的把關）。
    private(set) var environmentState: BridgeEnvironmentState?

    // CloudKit discovery layer (M2a) — nil until setupCloudSync() runs.
    var cloudSync: CloudSyncController?
    var cloudStatusText = "—"

    // 自動更新(feed = GitHub releases/latest;見 Updater.swift 的安全鏈)。
    let updater = Updater()

    // Dashboard window (M2c) — lazily created on first "儀表板…" click.
    // Foreground refresh timer runs only while the window is open — a
    // fallback for the CKSubscription push (design §3.2 "前景 fetch 兜底").
    var dashboardWindow: NSWindow?
    var dashboardModel: DashboardViewModel?
    var dashboardRefreshTimer: Timer?

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
        rebuildMenu()
        // periodic reachability poll
        Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        updater.startBackgroundChecks()

        // M3 — 每次啟動都跑一次環境健檢（不只首次啟動）。環境會壞掉：使用者可能
        // 砍了 LaunchAgent、升級系統弄掉 python、或另一個程式占走了埠。
        refreshEnvironment()

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

    /// 重跑一次環境健檢並更新選單。
    func refreshEnvironment() {
        bridgeBootstrap.probe { [weak self] _, state in
            guard let self else { return }
            self.environmentState = state
            self.rebuildMenu()
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
        // M3 — 環境沒就緒時，選單就直接說出原因並給入口，別讓使用者自己猜。
        if let state = environmentState, !state.isReady {
            let envLine = NSMenuItem(title: "⚠ " + Self.environmentSummary(state),
                                     action: #selector(showEnvironmentSetup), keyEquivalent: "")
            m.addItem(envLine)
        }
        m.addItem(.separator())
        // 未登入 → 只能「登入」；登入後才有「控制台」+「帳號連結」。
        if isSignedIn {
            m.addItem(NSMenuItem(title: "控制台", action: #selector(showDashboard), keyEquivalent: "d"))
            m.addItem(NSMenuItem(title: "帳號連結…", action: #selector(showAccountLinking), keyEquivalent: "l"))
        } else {
            m.addItem(NSMenuItem(title: "登入…", action: #selector(showLogin), keyEquivalent: "d"))
        }
        // 啟動路徑的另一半：手機那頭要先有 App。QR 直接掃到 App Store。
        m.addItem(NSMenuItem(title: "下載手機 App…", action: #selector(showDownloadQR), keyEquivalent: ""))
        m.addItem(.separator())
        // 自動更新:手動入口。背景每 24h 也會查一次(applicationDidFinishLaunching)。
        let ver = Updater.currentVersion.map { "(\($0))" } ?? ""
        m.addItem(NSMenuItem(title: "檢查更新…\(ver.isEmpty ? "" : " \(ver)")",
                             action: #selector(checkForUpdates), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "狀態列隱藏", action: #selector(hideStatusBar), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "結束", action: #selector(quit), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        statusItem.menu = m
    }

    /// 未登入時選單的「登入…」入口 → 開登入頁。
    @objc func showLogin() { presentOnboarding() }

    /// 選單「檢查更新…」。
    @objc func checkForUpdates() { updater.checkInteractively() }

    /// M3 —「執行環境」入口。已登入就開控制台（那裡有常駐的環境卡），
    /// 還沒登入就開引導視窗的環境頁。
    @objc func showEnvironmentSetup() {
        if isSignedIn {
            showDashboard()
        } else {
            presentOnboarding()
        }
    }

    /// 選單那一行的一句話。
    static func environmentSummary(_ state: BridgeEnvironmentState) -> String {
        switch state {
        case .ready: return "執行環境已就緒"
        case .readyButNoToken: return "缺 BRIDGE_TOKEN"
        case .installedNotRunning: return "Bridge 沒在跑"
        case .needsInstall: return "Bridge 尚未安裝"
        case .portBusy: return "Bridge 埠被占用"
        case .missingPython: return "缺 Python 3.10+"
        case .missingBridgeSource: return "找不到 Bridge 程式"
        }
    }

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

    /// 結束 App。bridge 由 launchd 管、不隨 App 結束（手機要能一直連得到），
    /// 這裡只收掉 App 自己開的臨時 tunnel。
    @objc func quit() { tunnelManager.stop(); NSApp.terminate(nil) }

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
        gateOnEnvironment(controller)
    }

    /// M3 — 登入前先把關執行環境。就緒就直接進歡迎頁；沒就緒就顯示檢查清單，
    /// 等到它變就緒（使用者按了「一鍵安裝」或自己補好後按「重新檢查」）再自動放行。
    private func gateOnEnvironment(_ c: OnboardingWindowController) {
        let model = environmentModel ?? BridgeEnvironmentModel(bootstrap: bridgeBootstrap)
        environmentModel = model
        model.onBecameReady = { [weak self, weak c] in
            self?.rebuildMenu()
            c?.showWelcome()
        }
        bridgeBootstrap.probe { [weak self, weak c] _, state in
            guard let self, let c else { return }
            self.environmentState = state
            self.rebuildMenu()
            if state.isReady {
                c.showWelcome()
            } else {
                c.showEnvironment(model: model)
            }
        }
    }

    // OnboardingDelegate — the delegate owns the actual auth + pairing calls.
    func onboardingDidTapSignIn(_ c: OnboardingWindowController) {
        // 環境沒就緒就不要送出登入請求 —— 它會打到不存在的本機 bridge，
        // 使用者只會看到看不懂的網路錯誤。改成把真正的原因攤開給他看。
        if let state = environmentState, !state.isReady {
            c.showSignInError("")
            if let model = environmentModel { c.showEnvironment(model: model) }
            return
        }
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
            // M1 spec §2：登入成功後直接看到配對 QR，不要讓使用者自己再去找。
            // 控制台就是 QR 的家，所以開控制台 + 立刻產碼。
            showDashboard()
            dashboardModel?.startPairing()
        }
    }

    func onboardingWindowDidClose(_ c: OnboardingWindowController) {
        webAppleSignIn?.cancel()
        webAppleSignIn = nil
        onboarding = nil
    }
}

// M3 乾跑出口：POCKET_ENV_DOCTOR=1 只跑環境偵測、印出 JSON 就結束，不開 UI。
// 把 POCKET_BRIDGE_* 那組路徑指到一個 TEMP prefix，就能在現有機器上重現
// 「全新 Mac」的每一個分支（缺 python / 缺 bridge / 沒 plist / 已在跑 / 埠被占）。
if BridgeEnvironmentDoctor.isRequested {
    BridgeEnvironmentDoctor.runAndExit()
}

let app = NSApplication.shared
// 更新鏈無頭自測(見 Updater.runE2E)— 在 AppKit 起來前攔截,直接跑完退出。
if CommandLine.arguments.contains("--update-e2e") {
    exit(Updater.runE2E())
}

let delegate = AppDelegate()
app.delegate = delegate
app.run()
