import CloudKit
import XCTest
@testable import PocketConnectKit

final class PairingInviteMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Harness {
        let db = MockCloudDatabase()
        var approvals: [(PairingInvite, (Bool) -> Void)] = []
        var issueCalls = 0
        var issueResult: Result<(code: String, ttlSeconds: Int), Error> =
            .success((code: "K7QX42", ttlSeconds: 300))
        var storedToken: Data?
        lazy var monitor: PairingInviteMonitor = {
            PairingInviteMonitor(
                database: db,
                hostDeviceID: "mac-1",
                approvalHandler: { [weak self] invite, respond in
                    self?.approvals.append((invite, respond))
                },
                codeIssuer: { [weak self] completion in
                    guard let self else { return }
                    self.issueCalls += 1
                    completion(self.issueResult)
                },
                now: { Date(timeIntervalSince1970: 1_800_000_000) },
                loadChangeToken: { [weak self] in self?.storedToken },
                saveChangeToken: { [weak self] in self?.storedToken = $0 })
        }()
    }

    func testRequestedInviteFlowsToIssuedWithCodeAndTTL() {
        let h = Harness()
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        XCTAssertEqual(h.approvals.count, 1, "human confirmation is mandatory")
        XCTAssertEqual(h.issueCalls, 0, "no code before approval")

        h.approvals[0].1(true)   // user clicks 允許配對
        XCTAssertEqual(h.issueCalls, 1)
        let saved = h.db.store[record.recordID]!
        XCTAssertEqual(saved[CloudSchema.InviteField.state] as? String, "issued")
        XCTAssertEqual(saved[CloudSchema.InviteField.oneTimeCode] as? String, "K7QX42")
        XCTAssertEqual(saved[CloudSchema.InviteField.expiresAt] as? Date,
                       now.addingTimeInterval(300))
        XCTAssertEqual(h.db.savedPolicies, [.ifServerRecordUnchanged])
    }

    func testDenialMarksInviteExpiredWithoutMintingACode() {
        let h = Harness()
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        h.approvals[0].1(false)   // user clicks 拒絕

        XCTAssertEqual(h.issueCalls, 0)
        XCTAssertEqual(h.db.store[record.recordID]?[CloudSchema.InviteField.state] as? String,
                       "expired")
    }

    func testPendingApprovalIsNotRePromptedByNextPoll() {
        let h = Harness()
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        h.monitor.pollOnce()   // alert still on screen — must not stack another
        XCTAssertEqual(h.approvals.count, 1)
    }

    func testSaveConflictBacksOffAndAllowsReprocessing() {
        let h = Harness()
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record
        let other = makeInviteRecord()
        h.db.scriptedSaveErrors = [serverRecordChangedError(server: other)]

        h.monitor.pollOnce()
        h.approvals[0].1(true)
        XCTAssertEqual(h.issueCalls, 1)
        // Loser abandons (design §3.2) — record untouched in store…
        XCTAssertEqual(h.db.store[record.recordID]?[CloudSchema.InviteField.state] as? String,
                       "issued") // local mutation only; mock store kept the same instance
        // …and the invite is no longer in-flight, so the next poll re-evaluates it.
        h.db.store[record.recordID] = makeInviteRecord()   // fresh server copy, still requested
        h.monitor.pollOnce()
        XCTAssertEqual(h.approvals.count, 2)
    }

    func testExpiredIssuedInviteIsDeleted() {
        let h = Harness()
        let record = makeInviteRecord(state: .issued, expiresAt: now.addingTimeInterval(-10))
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        XCTAssertEqual(h.db.deletedIDs, [record.recordID])
        XCTAssertNil(h.db.store[record.recordID])
        XCTAssertTrue(h.approvals.isEmpty)
    }

    func testInviteForAnotherHostIsUntouched() {
        let h = Harness()
        let record = makeInviteRecord(recordName: "phone-1-mac-9", hostDeviceID: "mac-9")
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        XCTAssertTrue(h.approvals.isEmpty)
        XCTAssertTrue(h.db.deletedIDs.isEmpty)
        XCTAssertEqual(h.db.store[record.recordID]?[CloudSchema.InviteField.state] as? String,
                       "requested")
    }

    func testChangeTokenExpiredResetsTokenAndRefetches() {
        let h = Harness()
        h.storedToken = Data([1, 2, 3])
        h.db.fetchZoneChangesError = NSError(domain: CKError.errorDomain,
                                             code: CKError.Code.changeTokenExpired.rawValue)
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        XCTAssertNil(h.storedToken, "stale token must be cleared")
        XCTAssertEqual(h.approvals.count, 1, "refetch after reset still processes invites")
    }

    func testIssueFailureLeavesInviteRequestedForRetry() {
        let h = Harness()
        h.issueResult = .failure(NSError(domain: "bridge", code: 1))
        let record = makeInviteRecord()
        h.db.store[record.recordID] = record

        h.monitor.pollOnce()
        h.approvals[0].1(true)
        XCTAssertEqual(h.db.store[record.recordID]?[CloudSchema.InviteField.state] as? String,
                       "requested")
        // Next poll may prompt again (bridge might be back).
        h.monitor.pollOnce()
        XCTAssertEqual(h.approvals.count, 2)
    }
}
