import XCTest
@testable import PocketConnectKit

/// 配對 QR payload 的契約 —— 必須與 `pocket-pair.py` 產生的位元組一致。
///
/// 背景(2026-10-11):桌面 app 發的 QR 一直是 v1(單一 host = 公網 tunnel),
/// 而 `pocket-pair.py` 早已升到 v2 帶 `hosts=`。結果照官方安裝流程配對的
/// 使用者**拿不到任何私網候選,在家也繞公網出去**。候選算得出來
/// (`HostCandidates.gather()` 早就有、也有測試),只是只被 CloudKit 那條路
/// 呼叫,而 CloudKit 在出貨的 kernel build 是關掉的 —— 送錯管道。
///
/// 這支把兩件事釘住:
///   1. v1 的 `scheme`/`host` 鍵必須保留(舊 App 掃 v2 QR 要還能配對)
///   2. 編碼要與 Python `quote()` 對齊(`,` 與 `:` 都要轉義)
final class PairingPayloadTests: XCTestCase {

    func testV1KeysAlwaysPresent() {
        let p = pairingPayload(scheme: "https", host: "gw.example", code: "abc123")
        XCTAssertTrue(p.hasPrefix("pocket://pair?"))
        XCTAssertTrue(p.contains("scheme=https"))
        XCTAssertTrue(p.contains("host=gw.example"))
        XCTAssertTrue(p.contains("code=abc123"))
    }

    func testNoHostsKeyWhenCandidatesEmpty() {
        // 沒有候選就不要發一個空的 `hosts=` —— iOS 端雖然會退回 v1,
        // 但空鍵會讓「這支 QR 是 v2 嗎」的判斷變得模糊。
        let p = pairingPayload(scheme: "https", host: "gw.example", code: "c")
        XCTAssertFalse(p.contains("hosts="))
    }

    func testHostsEncodedLikePythonQuote() {
        let p = pairingPayload(
            scheme: "https", host: "gw.example", code: "c",
            hosts: ["http://192.168.1.9:8081", "https://mac.tail1234.ts.net"])
        // Python: quote("http://192.168.1.9:8081,https://mac.tail1234.ts.net")
        //   → "/" 保留,":" → %3A,"," → %2C
        let expected = "hosts=http%3A//192.168.1.9%3A8081%2Chttps%3A//mac.tail1234.ts.net"
        XCTAssertTrue(p.contains(expected),
                      "編碼與 pocket-pair.py 不一致。實際 payload:\n\(p)")
    }

    func testHostsKeepDesktopOrder() {
        let p = pairingPayload(scheme: "https", host: "gw", code: "c",
                               hosts: ["http://10.0.0.2:8081", "https://tunnel.example"])
        let lanAt = p.range(of: "10.0.0.2")!.lowerBound
        let tunAt = p.range(of: "tunnel.example")!.lowerBound
        XCTAssertLessThan(lanAt, tunAt, "候選順序就是優先序,不可被重排")
    }

    func testCodeIsLastSoTruncationLosesTheSecretFirst() {
        // 掃描失敗時使用者看到的是「無效連結」而不是一個沒有 code 卻看似
        // 可用的 host 清單 —— 順序與 pocket-pair.py 相同(code 在最後)。
        let p = pairingPayload(scheme: "https", host: "gw", code: "SECRET",
                               hosts: ["http://10.0.0.2:8081"])
        XCTAssertTrue(p.hasSuffix("code=SECRET"))
    }

    // MARK: - 候選順序(LAN 先於 tailnet)

    func testGatherPutsLANBeforeTailnet() {
        // 真實網路介面不可控,所以用 isPrivateIP/isTailnetIP 的分類保證:
        // tailnet 用 100.64/10,LAN 用 RFC1918 —— 兩者互斥,分組邏輯才成立。
        XCTAssertTrue(HostCandidates.isTailnetIP("100.101.102.103"))
        XCTAssertFalse(HostCandidates.isPrivateIP("100.101.102.103"))
        XCTAssertTrue(HostCandidates.isPrivateIP("192.168.1.9"))
        XCTAssertFalse(HostCandidates.isTailnetIP("192.168.1.9"))
    }

    func testTunnelStillLast() {
        let list = HostCandidates.gather(bridgePort: 8081,
                                         tunnelURL: "https://tunnel.example")
        XCTAssertEqual(list.last, "https://tunnel.example",
                       "公網過路一定擺最後 —— 它是保底,不是首選")
    }
}
