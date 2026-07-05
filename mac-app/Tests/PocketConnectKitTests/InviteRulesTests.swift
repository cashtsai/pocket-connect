import CloudKit
import XCTest
@testable import PocketConnectKit

final class InviteRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: State machine (design §3.2 — strictly one-way)

    func testAllowedTransitions() {
        XCTAssertTrue(InviteRules.canTransition(from: .requested, to: .issued))
        XCTAssertTrue(InviteRules.canTransition(from: .requested, to: .expired))
        XCTAssertTrue(InviteRules.canTransition(from: .issued, to: .claimed))
        XCTAssertTrue(InviteRules.canTransition(from: .issued, to: .expired))
    }

    func testRejectedTransitions() {
        XCTAssertFalse(InviteRules.canTransition(from: .issued, to: .requested))
        XCTAssertFalse(InviteRules.canTransition(from: .claimed, to: .issued))
        XCTAssertFalse(InviteRules.canTransition(from: .expired, to: .requested))
        XCTAssertFalse(InviteRules.canTransition(from: .requested, to: .claimed))
        XCTAssertFalse(InviteRules.canTransition(from: .claimed, to: .expired))
    }

    // MARK: TTL expiry

    func testIsExpiredBoundaries() {
        XCTAssertFalse(InviteRules.isExpired(expiresAt: nil, now: now))
        XCTAssertFalse(InviteRules.isExpired(expiresAt: now.addingTimeInterval(1), now: now))
        XCTAssertTrue(InviteRules.isExpired(expiresAt: now, now: now))
        XCTAssertTrue(InviteRules.isExpired(expiresAt: now.addingTimeInterval(-1), now: now))
    }

    // MARK: Poll actions

    func testRequestedInviteForThisHostPromptsApproval() {
        let invite = PairingInvite(record: makeInviteRecord(state: .requested))!
        XCTAssertEqual(InviteRules.action(for: invite, hostDeviceID: "mac-1", now: now),
                       .promptApproval)
    }

    func testInviteForAnotherHostIsIgnored() {
        let invite = PairingInvite(record: makeInviteRecord(hostDeviceID: "mac-OTHER"))!
        XCTAssertEqual(InviteRules.action(for: invite, hostDeviceID: "mac-1", now: now), .ignore)
    }

    func testIssuedUnexpiredIsLeftAlone() {
        let record = makeInviteRecord(state: .issued, expiresAt: now.addingTimeInterval(120))
        let invite = PairingInvite(record: record)!
        XCTAssertEqual(InviteRules.action(for: invite, hostDeviceID: "mac-1", now: now), .ignore)
    }

    func testIssuedPastTTLIsDeleted() {
        let record = makeInviteRecord(state: .issued, expiresAt: now.addingTimeInterval(-1))
        let invite = PairingInvite(record: record)!
        XCTAssertEqual(InviteRules.action(for: invite, hostDeviceID: "mac-1", now: now), .delete)
    }

    func testTerminalStatesAreSweptUp() {
        for state: PairingInvite.State in [.claimed, .expired] {
            let invite = PairingInvite(record: makeInviteRecord(state: state))!
            XCTAssertEqual(InviteRules.action(for: invite, hostDeviceID: "mac-1", now: now), .delete)
        }
    }

    func testMalformedRecordParsesToNil() {
        let id = CKRecord.ID(recordName: "x", zoneID: CloudSchema.zoneID)
        let record = CKRecord(recordType: CloudSchema.RecordType.pairingInvite, recordID: id)
        record[CloudSchema.InviteField.state] = "not-a-state"
        XCTAssertNil(PairingInvite(record: record))
        XCTAssertNil(PairingInvite(record: CKRecord(
            recordType: CloudSchema.RecordType.device,
            recordID: CKRecord.ID(recordName: "d", zoneID: CloudSchema.zoneID))))
    }
}

final class TokenRedLineTests: XCTestCase {
    func testValueContainingTokenIsFlagged() {
        let record = makeInviteRecord()
        record[CloudSchema.InviteField.oneTimeCode] = "my-Token-123"
        XCTAssertEqual(TokenRedLine.violations(in: record), [CloudSchema.InviteField.oneTimeCode])
        XCTAssertThrowsError(try TokenRedLine.check(record))
    }

    func testFieldNameContainingTokenIsFlagged() {
        let record = makeInviteRecord()
        record["deviceToken"] = "whatever"
        XCTAssertEqual(TokenRedLine.violations(in: record), ["deviceToken"])
    }

    func testStringListValuesAreScanned() {
        let id = CKRecord.ID(recordName: "mac-1", zoneID: CloudSchema.zoneID)
        let record = CKRecord(recordType: CloudSchema.RecordType.device, recordID: id)
        record[CloudSchema.DeviceField.hostCandidates] = ["http://ok", "http://x?token=1"]
        XCTAssertEqual(TokenRedLine.violations(in: record), [CloudSchema.DeviceField.hostCandidates])
    }

    func testOrdinaryOneTimeCodePasses() {
        let record = makeInviteRecord()
        record[CloudSchema.InviteField.oneTimeCode] = "K7QX-42MZ"
        XCTAssertTrue(TokenRedLine.violations(in: record).isEmpty)
        XCTAssertNoThrow(try TokenRedLine.check(record))
    }
}

final class HostCandidatesTests: XCTestCase {
    func testTailnetRange() {
        XCTAssertTrue(HostCandidates.isTailnetIP("100.64.0.1"))
        XCTAssertTrue(HostCandidates.isTailnetIP("100.127.255.254"))
        XCTAssertFalse(HostCandidates.isTailnetIP("100.63.0.1"))
        XCTAssertFalse(HostCandidates.isTailnetIP("100.128.0.1"))
        XCTAssertFalse(HostCandidates.isTailnetIP("10.0.0.1"))
    }

    func testPrivateRanges() {
        XCTAssertTrue(HostCandidates.isPrivateIP("10.1.2.3"))
        XCTAssertTrue(HostCandidates.isPrivateIP("172.16.0.1"))
        XCTAssertTrue(HostCandidates.isPrivateIP("172.31.9.9"))
        XCTAssertTrue(HostCandidates.isPrivateIP("192.168.1.10"))
        XCTAssertFalse(HostCandidates.isPrivateIP("172.32.0.1"))
        XCTAssertFalse(HostCandidates.isPrivateIP("8.8.8.8"))
        XCTAssertFalse(HostCandidates.isPrivateIP("not-an-ip"))
    }

    func testTunnelURLAppendedLast() {
        let list = HostCandidates.gather(bridgePort: 8081, tunnelURL: "https://example.invalid")
        XCTAssertEqual(list.last, "https://example.invalid")
    }
}
