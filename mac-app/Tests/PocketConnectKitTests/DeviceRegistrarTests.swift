import CloudKit
import XCTest
@testable import PocketConnectKit

final class DeviceRegistrarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRegistrar(_ db: MockCloudDatabase,
                               info: DeviceInfo = makeDeviceInfo()) -> DeviceRegistrar {
        DeviceRegistrar(database: db, infoProvider: { info }, now: { self.now })
    }

    func testUpsertCreatesRecordWithAllFields() {
        let db = MockCloudDatabase()
        var result: Result<Void, Error>?
        makeRegistrar(db).upsert { result = $0 }

        guard case .success = result else { return XCTFail("upsert failed: \(String(describing: result))") }
        let id = CKRecord.ID(recordName: "mac-1", zoneID: CloudSchema.zoneID)
        guard let record = db.store[id] else { return XCTFail("record missing") }
        XCTAssertEqual(record.recordType, CloudSchema.RecordType.device)
        XCTAssertEqual(record[CloudSchema.DeviceField.name] as? String, "Test Mac")
        XCTAssertEqual(record[CloudSchema.DeviceField.platform] as? String, "macos")
        XCTAssertEqual(record[CloudSchema.DeviceField.role] as? String, "host")
        XCTAssertEqual(record[CloudSchema.DeviceField.hostCandidates] as? [String],
                       ["http://100.100.1.2:8081", "http://192.168.1.9:8081"])
        XCTAssertEqual(record[CloudSchema.DeviceField.bridgeFingerprint] as? String, "abc123")
        XCTAssertEqual(record[CloudSchema.DeviceField.appVersion] as? String, "0.1.1")
        XCTAssertEqual(record[CloudSchema.DeviceField.lastSeenAt] as? Date, now)
        // Saves must use the conflict-detecting policy.
        XCTAssertEqual(db.savedPolicies, [.ifServerRecordUnchanged])
    }

    func testHeartbeatUpdatesExistingRecordInPlace() {
        let db = MockCloudDatabase()
        let id = CKRecord.ID(recordName: "mac-1", zoneID: CloudSchema.zoneID)
        let existing = CKRecord(recordType: CloudSchema.RecordType.device, recordID: id)
        existing[CloudSchema.DeviceField.lastSeenAt] = now.addingTimeInterval(-900)
        existing[CloudSchema.DeviceField.name] = "Old Name"
        db.store[id] = existing

        var result: Result<Void, Error>?
        makeRegistrar(db).upsert { result = $0 }

        guard case .success = result else { return XCTFail("upsert failed") }
        let record = db.store[id]!
        // Same record instance updated (change tag preserved), fields refreshed.
        XCTAssertTrue(record === existing)
        XCTAssertEqual(record[CloudSchema.DeviceField.lastSeenAt] as? Date, now)
        XCTAssertEqual(record[CloudSchema.DeviceField.name] as? String, "Test Mac")
    }

    func testConflictRetriesOnceWithServerRecord() {
        let db = MockCloudDatabase()
        let id = CKRecord.ID(recordName: "mac-1", zoneID: CloudSchema.zoneID)
        let serverCopy = CKRecord(recordType: CloudSchema.RecordType.device, recordID: id)
        db.scriptedSaveErrors = [serverRecordChangedError(server: serverCopy)]

        var result: Result<Void, Error>?
        makeRegistrar(db).upsert { result = $0 }

        guard case .success = result else { return XCTFail("expected retry to succeed") }
        XCTAssertEqual(db.savedPolicies.count, 2)
        // The retry wrote through the server's copy of the record.
        XCTAssertTrue(db.store[id] === serverCopy)
        XCTAssertEqual(serverCopy[CloudSchema.DeviceField.lastSeenAt] as? Date, now)
    }

    func testConflictGivesUpAfterOneRetry() {
        let db = MockCloudDatabase()
        let id = CKRecord.ID(recordName: "mac-1", zoneID: CloudSchema.zoneID)
        let serverCopy = CKRecord(recordType: CloudSchema.RecordType.device, recordID: id)
        db.scriptedSaveErrors = [serverRecordChangedError(server: serverCopy),
                                 serverRecordChangedError(server: serverCopy)]

        var result: Result<Void, Error>?
        makeRegistrar(db).upsert { result = $0 }

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual((error as? CKError)?.code, .serverRecordChanged)
        XCTAssertEqual(db.savedPolicies.count, 2)
    }

    func testRedLineBlocksUploadOfTokenBearingCandidates() {
        let db = MockCloudDatabase()
        let bad = makeDeviceInfo(hostCandidates: ["http://host?auth_token=abc"])
        var result: Result<Void, Error>?
        makeRegistrar(db, info: bad).upsert { result = $0 }

        guard case .failure(let error) = result else { return XCTFail("expected red-line failure") }
        XCTAssertTrue(error is TokenRedLineError)
        XCTAssertTrue(db.store.isEmpty, "nothing may reach CloudKit")
        XCTAssertTrue(db.savedPolicies.isEmpty)
    }
}
