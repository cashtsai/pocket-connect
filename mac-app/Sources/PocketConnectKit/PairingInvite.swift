import CloudKit
import Foundation

// PairingInvite model + the pure state machine (design §3.1 / §3.2 / §4.2).
// State flow is strictly one-way: requested → issued → claimed / expired.
// claimed/expired records get deleted; the oneTimeCode inside has a 5-minute
// TTL and is single-use on the bridge side (Q3=A: plaintext short-lived code,
// no ECIES — can be upgraded later without schema changes).

public struct PairingInvite {
    public enum State: String {
        case requested, issued, claimed, expired
    }

    public let recordName: String
    public let state: State
    public let clientDeviceID: String?
    public let hostDeviceID: String?
    public let expiresAt: Date?
    /// Underlying record — updates go through it so the server change tag is
    /// preserved (conflict = another party won the race; we back off).
    public let record: CKRecord

    public init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.pairingInvite,
              let raw = record[CloudSchema.InviteField.state] as? String,
              let state = State(rawValue: raw)
        else { return nil }
        self.record = record
        self.recordName = record.recordID.recordName
        self.state = state
        self.clientDeviceID = (record[CloudSchema.InviteField.clientDevice] as? CKRecord.Reference)?
            .recordID.recordName
        self.hostDeviceID = (record[CloudSchema.InviteField.hostDevice] as? CKRecord.Reference)?
            .recordID.recordName
        self.expiresAt = record[CloudSchema.InviteField.expiresAt] as? Date
    }
}

public enum InviteAction: Equatable {
    /// Fresh request aimed at this host — ask the human (anti-silent-pairing).
    case promptApproval
    /// Terminal/expired record — clean it up.
    case delete
    case ignore
}

public enum InviteRules {
    /// One-way state machine; anything else is a downgrade and gets rejected.
    public static func canTransition(from: PairingInvite.State, to: PairingInvite.State) -> Bool {
        switch (from, to) {
        case (.requested, .issued),
             (.requested, .expired),
             (.issued, .claimed),
             (.issued, .expired):
            return true
        default:
            return false
        }
    }

    public static func isExpired(expiresAt: Date?, now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// Requested invites older than this are stale (phone gave up long ago).
    public static let maxRequestAge: TimeInterval = 10 * 60

    /// What the host should do with an invite record it sees during a poll.
    public static func action(for invite: PairingInvite, hostDeviceID: String, now: Date) -> InviteAction {
        guard invite.hostDeviceID == hostDeviceID else { return .ignore }
        switch invite.state {
        case .requested:
            if let created = invite.record.creationDate, now.timeIntervalSince(created) > maxRequestAge {
                return .delete
            }
            return .promptApproval
        case .issued:
            return isExpired(expiresAt: invite.expiresAt, now: now) ? .delete : .ignore
        case .claimed, .expired:
            // Terminal states — phone normally deletes, but sweep leftovers.
            return .delete
        }
    }
}
