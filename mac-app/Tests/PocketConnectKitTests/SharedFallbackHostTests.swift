import XCTest
@testable import PocketConnectKit

/// 配對 QR 絕不可以指向共用後備網域（2026-10-18 一星風險排查）。
///
/// `effectiveConnectURL` 是 `customConnectURL ?? autoTunnelURL ?? cfg.connectURL`，
/// 最後那個是寫死的維護者網域。cloudflared 沒裝／還沒跟上／剛掛掉時，舊版照樣
/// 畫出 QR 並倒數「剩 5:00」—— 而那個 QR 會把使用者的手機指向別人的機器：
/// 配對碼是對他自己的 bridge 發的，位址卻不是，於是 401，而且畫面上沒有任何訊息。
///
/// 這裡測的是 payload 層的不變量；UI 層的守門在 `PairingCodeController.refresh()`
/// 與 `DashboardWindow.startPairing()`，兩處都有註解交叉指回來。
final class SharedFallbackHostTests: XCTestCase {

    /// 與 `Config.sharedFallbackHost` 同值。刻意**重寫一次**而不是 import ——
    /// 哪天有人改了那個常數，這條會紅，逼他回來想一次「QR 會不會又指向它」。
    private let fallback = "pocket.tsai.cash"

    func testPayloadCarriesTheHostItWasGiven() {
        let p = pairingPayload(scheme: "https", host: "abc.trycloudflare.com", code: "123456")
        XCTAssertTrue(p.contains("host=abc.trycloudflare.com"), p)
        XCTAssertFalse(p.contains(fallback), "不該憑空冒出後備網域")
    }

    func testHostsListIsEncodedAndOrdered() {
        // 在家直連要排在過路前面 —— LAN 不需要手機開 Tailscale。
        let p = pairingPayload(scheme: "http", host: "192.168.1.9:8081", code: "x",
                               hosts: ["http://192.168.1.9:8081", "https://t.trycloudflare.com"])
        XCTAssertTrue(p.contains("hosts="), p)
        let hosts = p.components(separatedBy: "hosts=").last ?? ""
        let lan = hosts.range(of: "192.168.1.9")
        let tunnel = hosts.range(of: "trycloudflare")
        XCTAssertNotNil(lan); XCTAssertNotNil(tunnel)
        XCTAssertTrue(lan!.lowerBound < tunnel!.lowerBound, "LAN 要在前面：\(hosts)")
    }

    func testGatherPutsLanBeforeTunnel() {
        // tunnelURL 一定排最後 —— 它是保底，不是首選。
        let out = HostCandidates.gather(bridgePort: 8081,
                                        tunnelURL: "https://t.trycloudflare.com")
        XCTAssertEqual(out.last, "https://t.trycloudflare.com",
                       "過路必須墊底，實際：\(out)")
        XCTAssertFalse(out.contains { $0.contains(fallback) },
                       "候選清單裡不該有共用後備網域：\(out)")
    }
}

/// 本地化的兩個不變量（2026-10-18）。
final class L10nInvariantTests: XCTestCase {

    /// `String.LocalizationValue` 對 Int 會做在地化數字格式（加千分位）。
    /// 對 PID / port / exit code 這種識別碼來說那是**錯的** ——
    /// 使用者照著複製 `lsof -nP -iTCP:8,081` 會是廢的。
    ///
    /// 這條先證明那個行為真的存在（免得有人覺得我在防一個想像中的問題），
    /// 再要求原始碼裡不准有裸的數字插值。
    func testIntegerInterpolationWouldBeGroupSeparated() {
        XCTAssertEqual(String(localized: "port \(8081)"), "port 8,081",
                       "若這條變了，代表 Foundation 的行為改了，下面那條可以放寬")
        XCTAssertEqual(String(localized: "port \(String(8081))"), "port 8081",
                       "轉成 String 就不會被格式化 —— 這是正確寫法")
    }

    /// 原始碼掃描：`L10n.t` 裡不准出現已知的數字插值。
    func testNoBareNumericInterpolationInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PocketConnectKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // mac-app
            .appendingPathComponent("Sources")
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("走不到 Sources")
        }
        // 已知會是數字的插值表達式。新增數字欄位時請一併加進來。
        let numeric = ["\\(layout.port)", "\\(occupant.pid)", "\\(process.terminationStatus)",
                       "\\(status)", "\\(urlErr.code.rawValue)", "\\(secs)", "\\(attempt)"]
        var bad: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in src.split(separator: "\n") where line.contains("L10n.t(") {
                for n in numeric where line.contains(n) {
                    bad.append("\(url.lastPathComponent): \(n)")
                }
            }
        }
        XCTAssertTrue(bad.isEmpty,
                      "L10n.t 裡有裸的數字插值，會被加千分位：\(bad)")
    }
}
