import CloudKit
import XCTest
@testable import PocketConnectKit

final class DashboardStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAggregatesDevicesPairingsAndErrorsMixedAndSortedNewestFirst() {
        let db = MockCloudDatabase()
        let mac = makeDeviceRecord(deviceID: "mac-1", name: "Test Mac Studio", role: "host")
        let phone = makeDeviceRecord(deviceID: "phone-1", name: "Test iPhone", role: "client")
        db.store[mac.recordID] = mac
        db.store[phone.recordID] = phone

        let pairing = makePairingInfoRecord(clientDeviceID: "phone-1", hostDeviceID: "mac-1",
                                            lastConnectedAt: now)
        db.store[pairing.recordID] = pairing

        // Mixed sources, out-of-order timestamps — must come back newest-first.
        let macError = makeErrorLogRecord(recordName: "e-mac", deviceID: "mac-1",
                                          ts: now.addingTimeInterval(-60), code: "bridge_unreachable")
        let phoneError = makeErrorLogRecord(recordName: "e-phone", deviceID: "phone-1",
                                            ts: now, code: "pair_claim_failed")
        db.store[macError.recordID] = macError
        db.store[phoneError.recordID] = phoneError

        var snapshot: DashboardSnapshot?
        DashboardStore(database: db).refresh { snapshot = $0 }

        guard let snapshot else { return XCTFail("no snapshot") }
        XCTAssertEqual(snapshot.devices.map(\.deviceID).sorted(), ["mac-1", "phone-1"])
        XCTAssertEqual(snapshot.pairings.count, 1)
        XCTAssertEqual(snapshot.pairings.first?.lastConnectedAt, now)
        // Newest first, source device tagged.
        XCTAssertEqual(snapshot.errorLogs.map(\.recordName), ["e-phone", "e-mac"])
        XCTAssertEqual(snapshot.errorLogs[0].deviceID, "phone-1")
        XCTAssertEqual(snapshot.errorLogs[1].deviceID, "mac-1")
    }

    func testDegradesToEmptySectionWhenOneQueryFails() {
        let db = MockCloudDatabase()
        let mac = makeDeviceRecord(deviceID: "mac-1")
        db.store[mac.recordID] = mac
        db.scriptedQueryErrors[CloudSchema.RecordType.errorLog] =
            [NSError(domain: "CKError", code: 1)]

        var snapshot: DashboardSnapshot?
        DashboardStore(database: db).refresh { snapshot = $0 }

        guard let snapshot else { return XCTFail("no snapshot") }
        XCTAssertEqual(snapshot.devices.count, 1, "devices section unaffected by errorLog failure")
        XCTAssertTrue(snapshot.errorLogs.isEmpty, "failed section degrades to empty, not a crash")
    }

    func testEmptyZoneYieldsEmptySnapshot() {
        let db = MockCloudDatabase()
        var snapshot: DashboardSnapshot?
        DashboardStore(database: db).refresh { snapshot = $0 }
        XCTAssertEqual(snapshot, DashboardSnapshot())
    }
}
