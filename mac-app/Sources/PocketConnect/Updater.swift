import AppKit
import PocketConnectKit

// 自動更新(零依賴,不上 Sparkle):feed 就是 GitHub releases/latest 的 API
// 回應(發行流程已經固定走 gh release create,DMG+sha256 都在上面),這裡
// 只做四件事:查 → 問 → 驗 → 換。
//
// 安全鏈,缺一不可,順序固定:
//   1. HTTPS 拿 feed(api.github.com)與資產(objects.githubusercontent.com)
//   2. sha256 資產校驗下載的 DMG(有就驗,驗不過即棄)
//   3. 掛載後對新 app 跑 codesign --verify + spctl assess,**並且釘死
//      TeamIdentifier=4F8B93R3SH** —— 就算 GitHub 帳號被接管、換上別人
//      簽的公證 app,這關也過不去
//   4. 全過才落地換包;换包前先 ditto 到同卷軸的暫存位,舊包丟垃圾桶
//      (可救回),新包就位後 relaunch
// 任何一關失敗 → 不動現有安裝,interactive 時彈窗說明,背景檢查時靜默。
final class Updater: NSObject {

    static let feedURL = URL(string:
        ProcessInfo.processInfo.environment["POCKET_UPDATE_FEED"]
        ?? "https://api.github.com/repos/cashtsai/pocket-connect/releases/latest")!
    static let expectedTeamID = "4F8B93R3SH"
    private static let skipKey = "pocketUpdateSkipVersion"
    private static let lastCheckKey = "pocketUpdateLastCheck"

    private var inFlight = false

    /// 現在裝的版本。CLI 裸跑(swift run,沒有 bundle plist)回 nil → 更新器
    /// 整個閉嘴,不會在開發迴圈裡亂彈窗。
    static var currentVersion: String? {
        if let v = ProcessInfo.processInfo.environment["POCKET_UPDATE_CURRENT"] { return v }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: 進入點

    /// 選單「檢查更新…」— 一定給回饋(已最新/有新版/查失敗都講)。
    func checkInteractively() { check(interactive: true) }

    /// 背景自動檢查:啟動 30 秒後一次 + 之後每 24 小時。只在真的有新版
    /// 時出聲;查失敗/已最新一律靜默(背景不打擾是鐵律)。
    func startBackgroundChecks() {
        guard Updater.currentVersion != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.check(interactive: false)
        }
        Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.check(interactive: false)
        }
    }

    private func check(interactive: Bool) {
        guard !inFlight else { return }
        guard let current = Updater.currentVersion else {
            if interactive { Self.info("無法判定目前版本", "這份執行檔沒有版本資訊(開發模式?),略過更新檢查。") }
            return
        }
        inFlight = true
        var req = URLRequest(url: Updater.feedURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                UserDefaults.standard.set(Date(), forKey: Updater.lastCheckKey)
                guard let data, err == nil, let release = UpdateFeed.parse(data) else {
                    if interactive { Self.info("檢查更新失敗", "拿不到發行資訊:\(err?.localizedDescription ?? "回應格式不對")。稍後再試,或直接到下載頁。") }
                    return
                }
                guard UpdateFeed.isNewer(candidate: release.version, than: current) else {
                    if interactive { Self.info("已是最新版本", "Pocket \(current) 就是目前的最新發行。") }
                    return
                }
                // 背景檢查尊重「略過此版」;手動檢查永遠重新問(使用者主動查就是想看)。
                if !interactive,
                   UserDefaults.standard.string(forKey: Updater.skipKey) == release.version { return }
                // 無人值守(端到端測試/未來靜默更新):跳過詢問直接走安全鏈安裝。
                if ProcessInfo.processInfo.environment["POCKET_UPDATE_AUTOINSTALL"] == "1" {
                    NSLog("[Updater] autoinstall %@ (current %@)", release.version, current)
                    self.install(release)
                    return
                }
                self.offer(release, current: current)
            }
        }.resume()
    }

    // MARK: 問

    private func offer(_ release: UpdateFeed.Release, current: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Pocket 有新版本:\(release.version)"
        a.informativeText = "目前版本 \(current)。\n\n" +
            (release.notes.isEmpty ? "" : String(release.notes.prefix(600)) + "\n\n") +
            "更新會下載公證過的新版、驗證簽章後原地換新並重新啟動。"
        a.addButton(withTitle: "立即更新")
        a.addButton(withTitle: "稍後")
        a.addButton(withTitle: "略過此版")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: Updater.skipKey)
        default: break
        }
    }

    // MARK: 驗 + 換

    private func install(_ release: UpdateFeed.Release) {
        let progress = Self.makeProgressWindow("正在下載 Pocket \(release.version)…")
        progress.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.downloadVerifyAndSwap(release)
            DispatchQueue.main.async {
                progress.orderOut(nil)
                switch result {
                case .success(let newAppURL):
                    // 換包完成 → 啟新殺舊。open -n 保證起的是新 bundle。
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    p.arguments = ["-n", newAppURL.path]
                    try? p.run()
                    NSApp.terminate(nil)
                case .failure(let why):
                    let a = NSAlert()
                    a.messageText = "自動更新沒有完成"
                    a.informativeText = why + "\n\n現有安裝未被更動。可以到下載頁手動更新。"
                    a.addButton(withTitle: "前往下載頁")
                    a.addButton(withTitle: "好")
                    if a.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(URL(string: "https://github.com/cashtsai/pocket-connect/releases/latest")!)
                    }
                }
            }
        }
    }

    private enum SwapResult {
        case success(URL)
        case failure(String)
    }

    private static func fail(_ why: String) -> SwapResult {
        NSLog("[Updater] FAIL: %@", why)
        return .failure(why)
    }


    private static func downloadVerifyAndSwap(_ release: UpdateFeed.Release) -> SwapResult {
        NSLog("[Updater] start download %@", release.dmgURL.absoluteString)
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("pocket-update-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: work) }
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("update.dmg")

        // 下載 DMG(同步;已在背景 queue)。
        guard let dmgData = try? Data(contentsOf: release.dmgURL) else {
            return fail("下載失敗(\(release.dmgURL.lastPathComponent))。")
        }
        do { try dmgData.write(to: dmg) } catch { return fail("寫入暫存失敗:\(error.localizedDescription)") }

        // sha256 校驗(資產在就必須過;不在 — 舊發行 — 跳過,後面還有簽章關)。
        if let shaURL = release.sha256URL,
           let shaText = try? String(contentsOf: shaURL, encoding: .utf8) {
            let expected = shaText.split(separator: " ").first.map(String.init) ?? ""
            let got = run("/usr/bin/shasum", ["-a", "256", dmg.path])?
                .split(separator: " ").first.map(String.init) ?? "?"
            guard !expected.isEmpty, expected == got else {
                return fail("下載內容的 sha256 與發行紀錄不符,已放棄。")
            }
        }

        // 掛載(隱藏、唯讀)。
        let mount = work.appendingPathComponent("mnt")
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly",
                                       "-mountpoint", mount.path]) != nil else {
            return fail("DMG 掛載失敗。")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let appName = (try? fm.contentsOfDirectory(atPath: mount.path))?
                .first(where: { $0.hasSuffix(".app") }) else {
            return fail("DMG 裡找不到 .app。")
        }
        let newApp = mount.appendingPathComponent(appName)

        // 簽章鏈:codesign 完整性 + Gatekeeper(公證)+ Team ID 釘死。
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) != nil else {
            return fail("新版簽章驗證失敗,已放棄。")
        }
        guard let assess = run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", newApp.path], mergeStderr: true),
              assess.contains("accepted") else {
            return fail("新版未通過 Gatekeeper 公證檢查,已放棄。")
        }
        guard let detail = run("/usr/bin/codesign", ["-dv", newApp.path], mergeStderr: true),
              detail.contains("TeamIdentifier=\(expectedTeamID)") else {
            return fail("新版簽章的開發者與本 App 不符,已放棄。")
        }

        // 換包:ditto 到目的卷軸的暫存位 → 舊包進垃圾桶 → 新包就位。
        let appURL = Bundle.main.bundleURL
        let appDir = appURL.deletingLastPathComponent()
        let staged = appDir.appendingPathComponent(".Pocket-staged-\(ProcessInfo.processInfo.processIdentifier).app")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) != nil else {
            return fail("沒有寫入 \(appDir.path) 的權限,無法原地更新。")
        }
        // 驗過才拆 quarantine,新版第一次啟動不用再被 Gatekeeper 攔一次。
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        do {
            try fm.trashItem(at: appURL, resultingItemURL: nil)
        } catch {
            // 垃圾桶不行(如網路卷軸)→ 改名擱置,總之不蓋掉正在跑的 bundle。
            let aside = appDir.appendingPathComponent(".Pocket-old-\(ProcessInfo.processInfo.processIdentifier).app")
            do { try fm.moveItem(at: appURL, to: aside) } catch {
                try? fm.removeItem(at: staged)
                return fail("無法移開舊版(\(error.localizedDescription)),已放棄。")
            }
        }
        do {
            try fm.moveItem(at: staged, to: appURL)
        } catch {
            return fail("新版就位失敗:\(error.localizedDescription)。舊版在垃圾桶,可拖回 \(appDir.path)。")
        }
        NSLog("[Updater] swap complete → %@", appURL.path)
        return .success(appURL)
    }

    // MARK: 自測模式(--update-e2e)

    /// 無頭端到端自測:不進 AppKit 生命週期(不建選單、不碰 Keychain),
    /// 同步跑「查 feed → 比版本 → 下載 → 驗 → 換包」,逐段印到 stdout,
    /// 成功回 0。發行前驗更新鏈、或遠端 debug 使用者的更新問題都靠它:
    ///   POCKET_UPDATE_CURRENT=0.0.1 Pocket.app/Contents/MacOS/PocketConnect --update-e2e
    static func runE2E() -> Int32 {
        guard let current = currentVersion else { print("E2E: 無版本資訊"); return 2 }
        print("E2E: current=\(current) feed=\(feedURL.absoluteString)")
        var req = URLRequest(url: feedURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        var feedData: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, e in
            feedData = d
            if let e { print("E2E: feed 失敗 \(e.localizedDescription)") }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        guard let data = feedData, let release = UpdateFeed.parse(data) else {
            print("E2E: feed 解析失敗"); return 3
        }
        print("E2E: latest=\(release.version) dmg=\(release.dmgURL.lastPathComponent)")
        guard UpdateFeed.isNewer(candidate: release.version, than: current) else {
            print("E2E: 已是最新,無事可做"); return 0
        }
        switch downloadVerifyAndSwap(release) {
        case .success(let url): print("E2E: SWAP-OK → \(url.path)"); return 0
        case .failure(let why): print("E2E: SWAP-FAIL → \(why)"); return 1
        }
    }

    // MARK: 小工具

    /// 跑一支系統工具,exit 0 回 stdout(+可選 stderr),非 0 回 nil。
    private static func run(_ tool: String, _ args: [String], mergeStderr: Bool = false) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = mergeStderr ? out : Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return p.terminationStatus == 0 ? text : nil
    }

    private static func info(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    /// 非 modal 的小進度窗(modal + 背景 dispatch 的組合太脆,不用)。
    private static func makeProgressWindow(_ title: String) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 84),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Pocket 更新"
        w.isReleasedWhenClosed = false
        w.center()
        w.level = .floating
        let label = NSTextField(labelWithString: title + "\n下載與驗證中,完成後會自動重新啟動。")
        label.frame = NSRect(x: 48, y: 16, width: 260, height: 52)
        label.font = .systemFont(ofSize: 12)
        let spinner = NSProgressIndicator(frame: NSRect(x: 14, y: 30, width: 24, height: 24))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        w.contentView?.addSubview(label)
        w.contentView?.addSubview(spinner)
        NSApp.activate(ignoringOtherApps: true)
        return w
    }
}
