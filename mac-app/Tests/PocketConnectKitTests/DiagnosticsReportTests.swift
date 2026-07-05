import CloudKit
import XCTest
@testable import PocketConnectKit

final class DiagnosticsReportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testBuildsTextBlockWithAllSections() {
        let mac = DeviceSummary(record: makeDeviceRecord(deviceID: "mac-1", name: "Test Mac Studio"))!
        let pairing = PairingSummary(record: makePairingInfoRecord(
            clientDeviceID: "phone-1", hostDeviceID: "mac-1", lastConnectedAt: now))!
        let error = ErrorLogEntry(record: makeErrorLogRecord(
            deviceID: "mac-1", ts: now, code: "bridge_unreachable", message: "bridge 無回應"))!

        let input = DiagnosticsInput(
            appVersion: "0.2.0", osVersion: "macOS 15.1", bridgeReachable: true,
            bridgeLatencyMs: 42, hostCandidates: ["http://100.100.1.2:8081"],
            cloudStatusText: "同步中", devices: [mac], pairings: [pairing],
            recentErrors: [error], configJSON: ["theme": "dark"])

        let text = DiagnosticsReport.build(input, now: now)
        XCTAssertTrue(text.contains("0.2.0"))
        XCTAssertTrue(text.contains("macOS 15.1"))
        XCTAssertTrue(text.contains("存活"))
        XCTAssertTrue(text.contains("42ms"))
        XCTAssertTrue(text.contains("100.100.1.2"))
        XCTAssertTrue(text.contains("同步中"))
        XCTAssertTrue(text.contains("Test Mac Studio"), "pairing section resolves device name")
        XCTAssertTrue(text.contains("theme = dark"))
        XCTAssertTrue(text.contains("bridge_unreachable"))
    }

    func testEmptySectionsRenderPlaceholdersNotCrash() {
        let input = DiagnosticsInput(appVersion: "dev", osVersion: "macOS 15",
                                     bridgeReachable: false, cloudStatusText: "停用(無 iCloud 簽章)")
        let text = DiagnosticsReport.build(input, now: now)
        XCTAssertTrue(text.contains("無回應"))
        XCTAssertTrue(text.contains("（無）"))
        XCTAssertTrue(text.contains("組態漫遊尚未上線"))
    }

    func testDefensiveRedLineRedactsTokenLikeLines() {
        let error = ErrorLogEntry(record: makeErrorLogRecord(
            deviceID: "mac-1", ts: now, code: "auth_failed", message: "unexpected: token=abc123"))!
        let input = DiagnosticsInput(appVersion: "dev", osVersion: "macOS 15",
                                     bridgeReachable: true, cloudStatusText: "同步中",
                                     recentErrors: [error])
        let text = DiagnosticsReport.build(input, now: now)
        XCTAssertFalse(text.lowercased().contains("abc123"))
        XCTAssertTrue(text.contains("已濾除"))
    }

    func testScrubIsCaseInsensitiveAndLineScoped() {
        let text = "line one ok\nsecret Token=xyz\nline three ok"
        let scrubbed = DiagnosticsRedLine.scrub(text)
        XCTAssertTrue(scrubbed.contains("line one ok"))
        XCTAssertTrue(scrubbed.contains("line three ok"))
        XCTAssertFalse(scrubbed.contains("xyz"))
    }
}
