import CloudKit
import XCTest
@testable import PocketConnectKit

final class ErrorLogWriterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeWriter(_ db: MockCloudDatabase, deviceID: String = "mac-1") -> ErrorLogWriter {
        ErrorLogWriter(database: db, deviceID: deviceID, now: { self.now })
    }

    func testAppendCreatesRecordWithAllFields() {
        let db = MockCloudDatabase()
        var result: Result<Void, Error>?
        makeWriter(db).append(level: .error, code: "bridge_unreachable", message: "bridge 無回應",
                              context: ["latencyMs": "—"]) { result = $0 }

        guard case .success = result else { return XCTFail("append failed: \(String(describing: result))") }
        XCTAssertEqual(db.store.count, 1)
        let record = db.store.values.first!
        XCTAssertEqual(record.recordType, CloudSchema.RecordType.errorLog)
        XCTAssertEqual((record[CloudSchema.ErrorLogField.device] as? CKRecord.Reference)?
            .recordID.recordName, "mac-1")
        XCTAssertEqual(record[CloudSchema.ErrorLogField.ts] as? Date, now)
        XCTAssertEqual(record[CloudSchema.ErrorLogField.level] as? String, "error")
        XCTAssertEqual(record[CloudSchema.ErrorLogField.code] as? String, "bridge_unreachable")
        XCTAssertEqual(record[CloudSchema.ErrorLogField.message] as? String, "bridge 無回應")
        XCTAssertNotNil(record[CloudSchema.ErrorLogField.context] as? Data)
        XCTAssertEqual(db.savedPolicies, [.allKeys])
    }

    func testRedLineBlocksMessageContainingToken() {
        let db = MockCloudDatabase()
        var result: Result<Void, Error>?
        makeWriter(db).append(level: .error, code: "auth_failed",
                              message: "session token 無效") { result = $0 }

        guard case .failure(let error) = result else { return XCTFail("expected red-line failure") }
        XCTAssertTrue(error is TokenRedLineError)
        XCTAssertTrue(db.store.isEmpty, "nothing may reach CloudKit")
    }

    func testRotationKeepsOnlyNewest200OfOwnDevice() {
        let db = MockCloudDatabase()
        // Seed 200 pre-existing records for mac-1, oldest first, all strictly
        // before `now` — the writer's own append() below lands exactly at
        // `now`, so it must never tie with the seeded records (a tie would
        // make deletion order depend on Dictionary iteration, which Swift
        // randomizes per process).
        for i in 0..<200 {
            let record = makeErrorLogRecord(recordName: "mac1-\(i)", deviceID: "mac-1",
                                            ts: now.addingTimeInterval(TimeInterval(i - 200)))
            db.store[record.recordID] = record
        }
        // One record belonging to another device — must never be touched.
        let otherDeviceRecord = makeErrorLogRecord(recordName: "other-1", deviceID: "phone-1",
                                                   ts: now.addingTimeInterval(-1000))
        db.store[otherDeviceRecord.recordID] = otherDeviceRecord

        // Appending the 201st record for mac-1 should push it over the cap.
        // The mock's save/query/delete all complete synchronously, so the
        // rotation's store mutations are already applied by the time
        // append()'s own completion fires.
        var appended = false
        makeWriter(db).append(level: .warning, code: "heartbeat_slow", message: "test") { _ in
            appended = true
        }
        XCTAssertTrue(appended)

        let mine = db.store.values.filter {
            ($0[CloudSchema.ErrorLogField.device] as? CKRecord.Reference)?.recordID.recordName == "mac-1"
        }
        XCTAssertEqual(mine.count, ErrorLogWriter.maxPerDevice)
        // The oldest (mac1-0) must be the one that got rotated out.
        XCTAssertNil(db.store[CKRecord.ID(recordName: "mac1-0", zoneID: CloudSchema.zoneID)])
        XCTAssertNotNil(db.store[CKRecord.ID(recordName: "mac1-199", zoneID: CloudSchema.zoneID)])
        // The other device's record is untouched by mac-1's self-cleanup.
        XCTAssertNotNil(db.store[otherDeviceRecord.recordID])
    }

    func testRotationLeavesUnderCapUntouched() {
        let db = MockCloudDatabase()
        for i in 0..<5 {
            let record = makeErrorLogRecord(recordName: "mac1-\(i)", deviceID: "mac-1",
                                            ts: now.addingTimeInterval(TimeInterval(i)))
            db.store[record.recordID] = record
        }
        makeWriter(db).append(level: .info, code: "startup", message: "ok") { _ in }
        XCTAssertEqual(db.store.count, 6)
        XCTAssertTrue(db.deletedIDs.isEmpty)
    }
}
