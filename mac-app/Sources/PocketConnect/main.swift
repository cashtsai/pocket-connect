import AppKit
import CoreImage.CIFilterBuiltins

// Pocket Connect — macOS menu-bar app.
// Supervises the local bridge + Cloudflare tunnel so the phone connects with no
// setup, and shows a QR to download the iOS app. Built as a plain AppKit agent
// (LSUIElement) so it packages into a .app/.dmg without Xcode.

// MARK: - Config (the installer/first-run will eventually fill these in)
struct Config {
    // Public connect URL the phone points at (the Cloudflare tunnel hostname).
    var connectURL = "https://pocket.tsai.cash"
    // Where users download the iOS app (TestFlight public link / App Store).
    var downloadURL = "https://testflight.apple.com/"   // TODO: real link
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    let cfg = Config()
    lazy var supervisor = Supervisor(cfg)
    var statusItem: NSStatusItem!
    var qrWindow: NSWindow?
    var reachable = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "P"
        statusItem.button?.toolTip = "Pocket Connect"
        supervisor.onChange = { [weak self] in self?.rebuildMenu() }
        rebuildMenu()
        // periodic reachability poll
        Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func poll() {
        supervisor.probe(cfg.connectURL) { [weak self] ok in
            guard let self else { return }
            self.reachable = ok
            self.statusItem.button?.title = ok ? "P●" : "P○"
            self.rebuildMenu()
        }
    }

    func rebuildMenu() {
        let m = NSMenu()
        let header = NSMenuItem(title: "Pocket Connect", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        let status = NSMenuItem(
            title: reachable ? "● 已連線  \(cfg.connectURL)" : (supervisor.running ? "◐ 服務啟動中…" : "○ 離線"),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        m.addItem(status)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "複製連線網址", action: #selector(copyURL), keyEquivalent: "c"))
        m.addItem(NSMenuItem(title: "顯示下載 App QR…", action: #selector(showQR), keyEquivalent: "q"))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: supervisor.running ? "停止服務" : "啟動服務",
                             action: #selector(toggleServices), keyEquivalent: "s"))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "結束 Pocket Connect", action: #selector(quit), keyEquivalent: ""))
        m.items.forEach { $0.target = self }
        statusItem.menu = m
    }

    @objc func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cfg.connectURL, forType: .string)
    }

    @objc func toggleServices() { supervisor.toggle() }

    @objc func quit() { supervisor.stop(); NSApp.terminate(nil) }

    @objc func showQR() {
        let img = qr(cfg.downloadURL, size: 320)
        let win = qrWindow ?? makeQRWindow()
        qrWindow = win
        if let iv = win.contentView?.subviews.compactMap({ $0 as? NSImageView }).first { iv.image = img }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeQRWindow() -> NSWindow {
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

    // QR via CoreImage
    private func qr(_ string: String, size: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return NSImage(size: .init(width: size, height: size)) }
        let scale = size / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
