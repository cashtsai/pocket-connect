import AppKit

// First-run onboarding + the reusable "pair this desktop" QR surface.
//
// Flow (spec §2): welcome → Sign in with Apple → pairing QR (with a 5-minute
// countdown). After onboarding completes once, the app lives in the menu bar and
// this window only reappears via the menu's "重新設定".

// MARK: - Pairing state shared by the onboarding window and the menu QR window.
enum PairingState {
    case needLogin              // no session token yet
    case loading                // minting a code
    case active(NSImage, Int)   // QR image + seconds remaining
    case expired                // code TTL elapsed
    case error(String)          // bridge/token failure
}

// Mints a one-time pairing code, renders its QR, and runs the countdown.
final class PairingCoordinator {
    private let client: BridgeClient
    private let sessionProvider: () -> String?
    var onState: ((PairingState) -> Void)?

    private var timer: Timer?
    private var remaining = 0
    private var lastPayloadHost: String { client.host }

    init(client: BridgeClient, sessionProvider: @escaping () -> String?) {
        self.client = client
        self.sessionProvider = sessionProvider
    }

    /// Mint a fresh pairing code and (re)start the countdown.
    func refresh() {
        timer?.invalidate()
        guard let session = sessionProvider() else { return emit(.needLogin) }
        guard let bridgeToken = BridgeToken.read() else {
            return emit(.error("找不到 BRIDGE_TOKEN(檢查 LaunchAgent plist 或環境變數)"))
        }
        emit(.loading)
        client.pairNew(bridgeToken: bridgeToken, sessionToken: session) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.emit(.error(e.localizedDescription.isEmpty ? "\(e)" : "\(e)"))
            case .success(let pair):
                let payload = pairingPayload(scheme: self.client.scheme, host: self.lastPayloadHost, code: pair.code)
                let img = makeQR(payload, size: 320)
                self.startCountdown(from: pair.ttl, image: img)
            }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func startCountdown(from ttl: Int, image: NSImage) {
        remaining = max(1, ttl)
        emit(.active(image, remaining))
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            self.remaining -= 1
            if self.remaining <= 0 {
                t.invalidate()
                self.emit(.expired)
            } else {
                self.emit(.active(image, self.remaining))
            }
        }
    }

    private func emit(_ s: PairingState) { DispatchQueue.main.async { self.onState?(s) } }
}

// MARK: - Reusable QR view (QR image + status line + regenerate button).
final class PairingQRView: NSView {
    private let imageView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "重新產生配對碼", target: nil, action: nil)
    var onRegenerate: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.frame = NSRect(x: (frame.width - 320) / 2, y: 90, width: 320, height: 320)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        statusLabel.frame = NSRect(x: 0, y: 56, width: frame.width, height: 20)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        actionButton.frame = NSRect(x: (frame.width - 200) / 2, y: 16, width: 200, height: 28)
        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(regenerate)
        actionButton.isHidden = true
        addSubview(imageView); addSubview(statusLabel); addSubview(actionButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func regenerate() { onRegenerate?() }

    func apply(_ state: PairingState) {
        switch state {
        case .needLogin:
            imageView.image = nil
            statusLabel.stringValue = "請先登入"
            actionButton.isHidden = true
        case .loading:
            statusLabel.stringValue = "產生配對碼中…"
            actionButton.isHidden = true
        case .active(let img, let secs):
            imageView.image = img
            statusLabel.stringValue = "用手機掃描配對這台桌機 · 剩 \(secs / 60):\(String(format: "%02d", secs % 60))"
            actionButton.isHidden = true
        case .expired:
            statusLabel.stringValue = "配對碼已過期"
            actionButton.title = "重新產生配對碼"
            actionButton.isHidden = false
        case .error(let msg):
            imageView.image = nil
            statusLabel.stringValue = "錯誤:\(msg)"
            actionButton.title = "重試"
            actionButton.isHidden = false
        }
    }
}

// MARK: - Onboarding window (welcome → sign in → pairing QR).
protocol OnboardingDelegate: AnyObject {
    func onboardingDidTapSignIn(_ c: OnboardingWindowController)
    func onboardingWindowDidClose(_ c: OnboardingWindowController)
}

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    weak var flowDelegate: OnboardingDelegate?
    private let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
    let pairingView = PairingQRView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))

    // Welcome-screen controls (kept around so we can swap views in place).
    private let titleLabel = NSTextField(labelWithString: "歡迎使用 Pocket Connect")
    private let bodyLabel = NSTextField(wrappingLabelWithString:
        "這台 Mac 會成為你的 Pocket 執行主機。手機當遙控,所有登入與金鑰都留在這台桌機。\n\n先用 Apple 登入,完成後掃 QR 就能把手機配對上來。")
    private let signInButton = NSButton(title: "  使用 Apple 登入  ", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Pocket Connect 設定"
        win.center()
        super.init(window: win)
        win.delegate = self
        win.contentView = container
        buildWelcome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func buildWelcome() {
        titleLabel.frame = NSRect(x: 30, y: 400, width: 360, height: 32)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        bodyLabel.frame = NSRect(x: 30, y: 230, width: 360, height: 150)
        bodyLabel.alignment = .center
        bodyLabel.textColor = .secondaryLabelColor
        signInButton.frame = NSRect(x: 110, y: 150, width: 200, height: 40)
        signInButton.bezelStyle = .rounded
        signInButton.controlSize = .large
        signInButton.font = .systemFont(ofSize: 15, weight: .medium)
        signInButton.target = self
        signInButton.action = #selector(tapSignIn)
        errorLabel.frame = NSRect(x: 30, y: 110, width: 360, height: 20)
        errorLabel.alignment = .center
        errorLabel.textColor = .systemRed
        spinner.frame = NSRect(x: 200, y: 100, width: 20, height: 20)
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false
        container.subviews.forEach { $0.removeFromSuperview() }
        [titleLabel, bodyLabel, signInButton, errorLabel, spinner].forEach { container.addSubview($0) }
    }

    @objc private func tapSignIn() {
        errorLabel.stringValue = ""
        signInButton.isEnabled = false
        spinner.startAnimation(nil)
        flowDelegate?.onboardingDidTapSignIn(self)
    }

    /// Called by the delegate when sign-in fails — stay on the welcome screen.
    func showSignInError(_ msg: String) {
        spinner.stopAnimation(nil)
        signInButton.isEnabled = true
        errorLabel.stringValue = msg
    }

    /// Called by the delegate on success — swap to the pairing QR screen.
    func showPairing() {
        window?.title = "配對這台桌機"
        container.subviews.forEach { $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: "登入成功 · 用手機掃描配對")
        heading.frame = NSRect(x: 30, y: 430, width: 360, height: 24)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.alignment = .center
        container.addSubview(heading)
        pairingView.frame = NSRect(x: 0, y: -40, width: 420, height: 480)
        container.addSubview(pairingView)
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        flowDelegate?.onboardingWindowDidClose(self)
    }
}
