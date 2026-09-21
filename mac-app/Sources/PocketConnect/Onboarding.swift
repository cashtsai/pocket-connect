import AppKit
import AuthenticationServices
import CoreText
import SwiftUI

// Pocket 品牌色（CIS 五色瑪利歐：紅/奶油/黃/藍/綠）— 桌面 onboarding 用，
// 對齊 iOS 登入頁的觀感。這裡就地定義，pocket-connect 不依賴 PocketDesign。
enum PocketPalette {
    static func c(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static let red    = c(0xEE2D2A)
    static let cream  = c(0xFFF2D6)
    static let yellow = c(0xFBD000)
    static let blue   = c(0x049CD8)
    static let green  = c(0x43B14A)
    static let ink    = c(0x17171A)
    static let espresso = c(0x2A1D18)   // 雲朵線色（配奶油底，同 iOS PocketSkyBackground）
}

/// 奶油底 + 淡雲圖樣背景（呼應 iOS 登入頁）。純繪製、無資產。
///
/// 品牌特規（logo 頁）：設 `logoSafeZone`（本 view 自身座標）後,任何**與該區相交
/// 的雲會被略過**,確保 logo 正下方/周圍淨空、logo 不壓到雲。其他頁面 `logoSafeZone`
/// 留 nil ＝ 原本的完整雲背景。詳見 docs/BRAND_CLOUD_BACKGROUND.md。
final class BrandBackgroundView: NSView {
    /// 非 nil 時，落在此矩形內（相交）的雲不畫 — logo 頁特規。
    var logoSafeZone: NSRect? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }   // y 向下，與 iOS Canvas 同座標

    override func draw(_ dirtyRect: NSRect) {
        PocketPalette.cream.setFill()
        bounds.fill()
        // 與 iOS PocketSkyBackground 完全一致：espresso 9%、線寬 1.5、
        // 300×220 網格每格一大一小(小雲 0.62 錯開 180,150)的瑪利歐雲。
        PocketPalette.espresso.withAlphaComponent(0.09).setStroke()
        let tileW: CGFloat = 300, tileH: CGFloat = 220
        var y: CGFloat = 0
        while y < bounds.height + tileH {
            var x: CGFloat = 0
            while x < bounds.width + tileW {
                for path in [cloud(scale: 1, dx: x, dy: y),
                             cloud(scale: 0.62, dx: x + 180, dy: y + 150)] {
                    if let safe = logoSafeZone, path.bounds.intersects(safe) { continue }  // logo 頁：跳過壓到 logo 的雲
                    path.stroke()
                }
                x += tileW
            }
            y += tileH
        }
    }

    /// 單朵瑪利歐雲（圓凸頂、平底），local 座標同 iOS PocketSkyBackground.cloud。
    private func cloud(scale s: CGFloat, dx: CGFloat, dy: CGFloat) -> NSBezierPath {
        func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * s + dx, y: y * s + dy) }
        let p = NSBezierPath()
        p.lineWidth = 1.5
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: P(40, 96))
        p.curve(to: P(36, 70), controlPoint1: P(22, 96), controlPoint2: P(18, 74))
        p.curve(to: P(70, 62), controlPoint1: P(33, 50), controlPoint2: P(62, 44))
        p.curve(to: P(104, 68), controlPoint1: P(76, 46), controlPoint2: P(104, 48))
        p.curve(to: P(108, 90), controlPoint1: P(124, 64), controlPoint2: P(126, 86))
        p.line(to: P(108, 96))
        p.close()
        return p
    }
}

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
    private let background = BrandBackgroundView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
    private let wordmark = NSImageView()   // 真 POCKET wordmark 資產（pocket-wordmark.png），非自製字
    private let tagline = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString:
        "這台 Mac 會成為你的 Pocket 執行主機。手機當遙控,所有登入與金鑰都留在這台桌機。\n先用 Apple 登入,完成後掃 QR 就能把手機配對上來。")
    private let appleButton = ASAuthorizationAppleIDButton(authorizationButtonType: .signIn,
                                                           authorizationButtonStyle: .black)
    private let footerLabel = NSTextField(labelWithString: "登入即代表你同意基本使用條款。")
    private let errorLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    /// 註冊 bundle 內的 Luckiest Guy（品牌 wordmark 字型）一次，slogan 用它。
    private static let brandFontRegistered: Bool = {
        guard let url = Bundle.main.url(forResource: "LuckiestGuy-Regular", withExtension: "ttf") else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// Luckiest Guy；未註冊成功時安全退回系統重體（不應發生，資產已 bundle）。
    private static func brandFont(_ size: CGFloat) -> NSFont {
        _ = brandFontRegistered
        return NSFont(name: "LuckiestGuy-Regular", size: size) ?? .systemFont(ofSize: size, weight: .black)
    }

    init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "Pocket"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true          // 奶油底貫到頂，去掉系統白標題列
        win.isMovableByWindowBackground = true
        win.backgroundColor = PocketPalette.cream
        win.center()
        super.init(window: win)
        win.delegate = self
        win.contentView = container
        buildWelcome()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// 彩虹副標「PUT WORLD INTO POCKET」— 逐字上色，對齊 iOS 登入頁。
    private func rainbowTagline() -> NSAttributedString {
        let words: [(String, NSColor)] = [
            ("PUT ", PocketPalette.red), ("WORLD ", PocketPalette.yellow),
            ("INTO ", PocketPalette.blue), ("POCKET", PocketPalette.green),
        ]
        let out = NSMutableAttributedString()
        let font = Self.brandFont(17)   // Luckiest Guy — slogan 與 wordmark 同一套字（對齊 iOS）
        let para = NSMutableParagraphStyle(); para.alignment = .center   // 設 attributedStringValue 會蓋掉 field 的 alignment，這裡補回置中
        for (w, color) in words {
            out.append(NSAttributedString(string: w, attributes: [
                .foregroundColor: color, .font: font, .kern: 0.5, .paragraphStyle: para,
            ]))
        }
        return out
    }

    private func buildWelcome() {
        background.frame = container.bounds
        background.autoresizingMask = [.width, .height]

        // 真 wordmark 資產（紅字 PNG，iOS 登入頁同款）；等比縮到寬 232。
        if let url = Bundle.main.url(forResource: "pocket-wordmark", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            wordmark.image = img
            let w: CGFloat = 232, h = w * (img.size.height / max(img.size.width, 1))
            wordmark.frame = NSRect(x: (420 - w) / 2, y: 316, width: w, height: h)
        } else {
            wordmark.frame = NSRect(x: 94, y: 316, width: 232, height: 56)
        }
        wordmark.imageScaling = .scaleProportionallyUpOrDown

        tagline.attributedStringValue = rainbowTagline()
        tagline.frame = NSRect(x: 30, y: 286, width: 360, height: 24)
        tagline.alignment = .center
        tagline.drawsBackground = false

        bodyLabel.frame = NSRect(x: 40, y: 178, width: 340, height: 72)
        bodyLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = PocketPalette.ink.withAlphaComponent(0.62)
        bodyLabel.drawsBackground = false

        errorLabel.frame = NSRect(x: 30, y: 150, width: 360, height: 20)
        errorLabel.alignment = .center
        errorLabel.textColor = PocketPalette.red
        errorLabel.drawsBackground = false

        appleButton.frame = NSRect(x: 70, y: 92, width: 280, height: 46)
        appleButton.cornerRadius = 12
        appleButton.target = self
        appleButton.action = #selector(tapSignIn)

        spinner.frame = NSRect(x: 200, y: 60, width: 20, height: 20)
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        footerLabel.frame = NSRect(x: 30, y: 34, width: 360, height: 18)
        footerLabel.alignment = .center
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = PocketPalette.ink.withAlphaComponent(0.4)
        footerLabel.drawsBackground = false

        // logo 頁特規：保留 wordmark+tagline 區並向下延伸，落在此區的雲不畫，
        // 讓 logo 正下方淨空、不壓到雲。（其他頁面不設 → 完整雲背景。）
        let logoUp = wordmark.frame.union(tagline.frame)
        let reservedUp = NSRect(x: logoUp.minX, y: logoUp.minY - 44,
                                width: logoUp.width, height: logoUp.height + 44)
        let hgt = container.bounds.height
        background.logoSafeZone = NSRect(x: reservedUp.minX, y: hgt - reservedUp.maxY,
                                         width: reservedUp.width, height: reservedUp.height)

        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(background)
        [wordmark, tagline, bodyLabel, errorLabel, appleButton, spinner, footerLabel]
            .forEach { container.addSubview($0) }
    }

    @objc private func tapSignIn() {
        errorLabel.stringValue = ""
        appleButton.isEnabled = false
        spinner.startAnimation(nil)
        flowDelegate?.onboardingDidTapSignIn(self)
    }

    /// Called by the delegate when sign-in fails — stay on the welcome screen.
    func showSignInError(_ msg: String) {
        spinner.stopAnimation(nil)
        appleButton.isEnabled = true
        errorLabel.stringValue = msg
    }

    /// M3 — 執行環境還沒就緒時,擋在歡迎/登入畫面前面。
    /// 沒有這一關的話,一台全新的 Mac 按下「Apple 登入」只會打到一個不存在的
    /// 本機 bridge,使用者拿到的是「暫時連不到伺服器」——完全查不出真正原因。
    func showEnvironment(model: BridgeEnvironmentModel) {
        container.subviews.forEach { $0.removeFromSuperview() }
        background.frame = container.bounds
        background.logoSafeZone = nil
        container.addSubview(background)
        let hosting = NSHostingView(rootView:
            ScrollView {
                EnvironmentSetupView(model: model, isOnboarding: true)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 28)
            })
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
    }

    /// 環境就緒後回到歡迎/登入畫面。
    func showWelcome() { buildWelcome() }

    /// Called by the delegate on success — swap to the pairing QR screen.
    func showPairing() {
        container.subviews.forEach { $0.removeFromSuperview() }
        background.frame = container.bounds
        background.logoSafeZone = nil                    // 配對頁無 logo → 完整雲背景（非特規）
        container.addSubview(background)                 // 奶油底延續到配對頁
        let heading = NSTextField(labelWithString: "登入成功 · 用手機掃描配對")
        heading.frame = NSRect(x: 30, y: 430, width: 360, height: 24)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.textColor = PocketPalette.ink
        heading.alignment = .center
        heading.drawsBackground = false
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
