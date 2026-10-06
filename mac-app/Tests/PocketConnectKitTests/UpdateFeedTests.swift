import XCTest
@testable import PocketConnectKit

final class UpdateFeedTests: XCTestCase {

    // MARK: 版本比較

    func testNewerBasics() {
        XCTAssertTrue(UpdateFeed.isNewer(candidate: "0.4.2", than: "0.4.1"))
        XCTAssertTrue(UpdateFeed.isNewer(candidate: "0.5", than: "0.4.9"))
        XCTAssertTrue(UpdateFeed.isNewer(candidate: "1.0.0", than: "0.9.9"))
        XCTAssertFalse(UpdateFeed.isNewer(candidate: "0.4.1", than: "0.4.1"))
        XCTAssertFalse(UpdateFeed.isNewer(candidate: "0.4.0", than: "0.4.1"))
    }

    /// 數字分段比較,不是字串比較 —— 0.10 要比 0.9 新。
    func testNewerIsNumericNotLexicographic() {
        XCTAssertTrue(UpdateFeed.isNewer(candidate: "0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateFeed.isNewer(candidate: "0.9.0", than: "0.10.0"))
    }

    /// 缺段補 0:0.4 == 0.4.0;0.4.1 > 0.4。
    func testNewerPadsMissingSegments() {
        XCTAssertFalse(UpdateFeed.isNewer(candidate: "0.4", than: "0.4.0"))
        XCTAssertTrue(UpdateFeed.isNewer(candidate: "0.4.1", than: "0.4"))
    }

    // MARK: releases/latest JSON 解析

    private let sample = """
    {"tag_name":"v0.4.1","draft":false,"prerelease":false,
     "body":"Privacy hotfix.",
     "assets":[
       {"name":"Pocket-0.4.1.dmg",
        "browser_download_url":"https://github.com/cashtsai/pocket-connect/releases/download/v0.4.1/Pocket-0.4.1.dmg"},
       {"name":"Pocket-0.4.1.dmg.sha256",
        "browser_download_url":"https://github.com/cashtsai/pocket-connect/releases/download/v0.4.1/Pocket-0.4.1.dmg.sha256"}]}
    """

    func testParsePicksDmgAndSha() throws {
        let r = try XCTUnwrap(UpdateFeed.parse(Data(sample.utf8)))
        XCTAssertEqual(r.version, "0.4.1")          // v 前綴要剝掉
        XCTAssertEqual(r.notes, "Privacy hotfix.")
        XCTAssertTrue(r.dmgURL.lastPathComponent.hasSuffix(".dmg"))
        XCTAssertEqual(r.sha256URL?.lastPathComponent, "Pocket-0.4.1.dmg.sha256")
    }

    /// 沒有 .dmg 資產 = 不是我們的發行形狀,整筆不給。
    func testParseRejectsReleaseWithoutDmg() {
        let json = """
        {"tag_name":"v9.9.9","draft":false,"prerelease":false,"body":"",
         "assets":[{"name":"notes.txt","browser_download_url":"https://example.com/n.txt"}]}
        """
        XCTAssertNil(UpdateFeed.parse(Data(json.utf8)))
    }

    /// draft / prerelease 不走正式更新通道。
    func testParseRejectsDraftAndPrerelease() {
        let draft = sample.replacingOccurrences(of: "\"draft\":false", with: "\"draft\":true")
        XCTAssertNil(UpdateFeed.parse(Data(draft.utf8)))
        let pre = sample.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")
        XCTAssertNil(UpdateFeed.parse(Data(pre.utf8)))
    }

    /// sha256 資產缺席是允許的(舊版發行),dmg 照常回。
    func testParseAllowsMissingSha() throws {
        let json = """
        {"tag_name":"0.4.0","draft":false,"prerelease":false,"body":"x",
         "assets":[{"name":"Pocket-0.4.dmg","browser_download_url":"https://example.com/P.dmg"}]}
        """
        let r = try XCTUnwrap(UpdateFeed.parse(Data(json.utf8)))
        XCTAssertEqual(r.version, "0.4.0")
        XCTAssertNil(r.sha256URL)
    }
}
