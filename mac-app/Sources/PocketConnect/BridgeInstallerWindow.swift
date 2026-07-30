import AppKit

enum BridgeProviderSelection: String {
    case hermes
    case openclaw
    case none

    var title: String {
        switch self {
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .none: return "稍後再設定"
        }
    }
}

final class BridgeInstallerWindowController: NSWindowController, NSWindowDelegate {
    var onStartInstall: ((BridgeProviderSelection) -> Void)?
    var onCloseAfterFinish: (() -> Void)?

    private var selectedProvider: BridgeProviderSelection

    private let titleLabel = NSTextField(labelWithString: "設定 Pocket Connect")
    private let subtitleLabel = NSTextField(wrappingLabelWithString:
        "這台 Mac 需要一個本機 bridge，讓手機可以安全地連到桌面上的 AI provider。你可以選擇要讓 Pocket 幫你安裝哪一個，或先只安裝 bridge。")
    private let statusLabel = NSTextField(labelWithString: "選擇安裝方式")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private let logView = NSTextView()
    private let startButton = NSButton(title: "開始設定", target: nil, action: nil)
    private let closeButton = NSButton(title: "稍後", target: nil, action: nil)
    private var optionButtons: [BridgeProviderSelection: NSButton] = [:]
    private var didFinish = false
    private var isInstalling = false

    init(defaultProvider: String, existingSummary: String) {
        let provider = BridgeProviderSelection(rawValue: defaultProvider) ?? .hermes
        self.selectedProvider = provider == .none ? .hermes : provider

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 640))
        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pocket Connect 設定"
        window.contentView = content
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI(in: content, existingSummary: existingSummary)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func beginInstall() {
        didFinish = false
        isInstalling = true
        statusLabel.stringValue = "正在設定 \(selectedProvider.title)…"
        detailLabel.stringValue = "Pocket 正在準備本機 bridge。第一次安裝可能需要下載 Hermes 或 OpenClaw，時間會依網路而不同。"
        startButton.isEnabled = false
        closeButton.isEnabled = false
        optionButtons.values.forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        progressBar.startAnimation(nil)
        appendLog("開始設定：\(selectedProvider.title)")
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = logView.string.isEmpty ? trimmed : logView.string + "\n" + trimmed
        logView.string = text
        logView.scrollToEndOfDocument(nil)
        if trimmed.hasPrefix("==>") {
            statusLabel.stringValue = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        }
    }

    func markCompleted() {
        didFinish = true
        isInstalling = false
        spinner.stopAnimation(nil)
        progressBar.stopAnimation(nil)
        progressBar.doubleValue = 100
        statusLabel.stringValue = "設定完成"
        detailLabel.stringValue = "bridge 已安裝並交給 macOS 背景服務管理。接下來可以登入並配對手機。"
        startButton.title = "繼續"
        closeButton.title = "關閉"
        startButton.isEnabled = true
        closeButton.isEnabled = true
        appendLog("完成。")
    }

    func markFailed(_ message: String) {
        didFinish = false
        isInstalling = false
        spinner.stopAnimation(nil)
        progressBar.stopAnimation(nil)
        statusLabel.stringValue = "設定失敗"
        detailLabel.stringValue = message
        startButton.title = "重試"
        startButton.isEnabled = true
        closeButton.isEnabled = true
        optionButtons.values.forEach { $0.isEnabled = true }
        appendLog("失敗：\(message)")
    }

    @objc private func startTapped() {
        if didFinish {
            close()
        } else {
            beginInstall()
            onStartInstall?(selectedProvider)
        }
    }

    @objc private func closeTapped() {
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !isInstalling
    }

    func windowWillClose(_ notification: Notification) {
        if didFinish {
            onCloseAfterFinish?()
        }
    }

    @objc private func optionTapped(_ sender: NSButton) {
        for (provider, button) in optionButtons {
            let selected = (button == sender)
            button.state = selected ? .on : .off
            if selected { selectedProvider = provider }
        }
    }

    private func buildUI(in content: NSView, existingSummary: String) {
        let background = BrandBackgroundView(frame: content.bounds)
        background.autoresizingMask = [.width, .height]
        content.addSubview(background)

        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = PocketPalette.ink
        titleLabel.frame = NSRect(x: 32, y: 580, width: 496, height: 34)
        content.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = PocketPalette.ink.withAlphaComponent(0.78)
        subtitleLabel.frame = NSRect(x: 32, y: 522, width: 496, height: 52)
        content.addSubview(subtitleLabel)

        let options = [
            makeOption(
                .hermes,
                title: "安裝/使用 Hermes",
                body: "適合 Pocket 預設體驗。若已安裝 Hermes，會採用既有安裝；沒有才 fresh install。"
            ),
            makeOption(
                .openclaw,
                title: "安裝/使用 OpenClaw",
                body: "適合要測 OpenClaw gateway 的使用者。若已有設定，會採用既有設定；沒有才 fresh install。"
            ),
            makeOption(
                .none,
                title: "先不自動安裝 AI provider",
                body: "只安裝 Pocket bridge。適合公司 IT 已先裝好 provider，或使用者想稍後手動設定。"
            ),
        ]

        var y: CGFloat = 430
        for option in options {
            option.frame = NSRect(x: 32, y: y, width: 496, height: 74)
            content.addSubview(option)
            y -= 82
        }

        let existing = NSTextField(wrappingLabelWithString: existingSummary)
        existing.font = .systemFont(ofSize: 12)
        existing.textColor = .secondaryLabelColor
        existing.frame = NSRect(x: 44, y: 226, width: 472, height: 34)
        content.addSubview(existing)

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.frame = NSRect(x: 32, y: 196, width: 360, height: 20)
        content.addSubview(statusLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 398, y: 196, width: 18, height: 18)
        content.addSubview(spinner)

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.frame = NSRect(x: 32, y: 172, width: 496, height: 20)
        content.addSubview(detailLabel)

        progressBar.isIndeterminate = true
        progressBar.style = .bar
        progressBar.frame = NSRect(x: 32, y: 154, width: 496, height: 12)
        content.addSubview(progressBar)

        let logScroll = NSScrollView(frame: NSRect(x: 32, y: 62, width: 496, height: 84))
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .secondaryLabelColor
        logView.backgroundColor = .textBackgroundColor.withAlphaComponent(0.82)
        logScroll.documentView = logView
        content.addSubview(logScroll)

        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.frame = NSRect(x: 408, y: 22, width: 120, height: 30)
        content.addSubview(startButton)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 300, y: 22, width: 96, height: 30)
        content.addSubview(closeButton)
    }

    private func makeOption(_ provider: BridgeProviderSelection, title: String, body: String) -> NSView {
        let box = NSBox(frame: .zero)
        box.boxType = .custom
        box.cornerRadius = 12
        box.borderColor = PocketPalette.espresso.withAlphaComponent(0.12)
        box.fillColor = .windowBackgroundColor.withAlphaComponent(0.86)

        let radio = NSButton(radioButtonWithTitle: title, target: self, action: #selector(optionTapped(_:)))
        radio.font = .systemFont(ofSize: 14, weight: .semibold)
        radio.state = provider == selectedProvider ? .on : .off
        radio.frame = NSRect(x: 14, y: 38, width: 460, height: 22)
        optionButtons[provider] = radio
        box.addSubview(radio)

        let desc = NSTextField(wrappingLabelWithString: body)
        desc.font = .systemFont(ofSize: 12)
        desc.textColor = .secondaryLabelColor
        desc.frame = NSRect(x: 36, y: 10, width: 432, height: 28)
        box.addSubview(desc)
        return box
    }
}
