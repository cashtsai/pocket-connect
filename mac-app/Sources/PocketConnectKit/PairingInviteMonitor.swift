import CloudKit
import Foundation

// Watches PocketZone for PairingInvite records aimed at this host
// (design §4.2). Delivery is silent-push (CKSubscription) with a 30 s poll as
// the guaranteed fallback — pokePoll() is also called when a push arrives.
//
// requested → ask the human (approvalHandler; anti-silent-pairing)
//   approved → codeIssuer (bridge POST /app/v1/pair/new) → update the invite:
//              state=issued, oneTimeCode, expiresAt=now+TTL
//   denied   → state=expired (phone shows failure, falls back to QR)
// issued+past TTL / claimed / expired → delete the record (cleanup).
//
// The oneTimeCode is the ONLY secret-ish value that ever crosses CloudKit:
// 5-minute TTL, single-use, and NOT a token (red line enforced on every save).

public final class PairingInviteMonitor {
    public typealias ApprovalHandler = (PairingInvite, @escaping (Bool) -> Void) -> Void
    public typealias CodeIssuer = (@escaping (Result<(code: String, ttlSeconds: Int), Error>) -> Void) -> Void

    private let database: CloudDatabase
    private let hostDeviceID: String
    private let approvalHandler: ApprovalHandler
    private let codeIssuer: CodeIssuer
    private let now: () -> Date
    private let loadChangeToken: () -> Data?
    private let saveChangeToken: (Data?) -> Void

    private let lock = NSLock()
    private var inFlight: Set<String> = []
    private var polling = false
    private var timer: Timer?

    public init(database: CloudDatabase,
                hostDeviceID: String,
                approvalHandler: @escaping ApprovalHandler,
                codeIssuer: @escaping CodeIssuer,
                now: @escaping () -> Date = Date.init,
                loadChangeToken: @escaping () -> Data?,
                saveChangeToken: @escaping (Data?) -> Void) {
        self.database = database
        self.hostDeviceID = hostDeviceID
        self.approvalHandler = approvalHandler
        self.codeIssuer = codeIssuer
        self.now = now
        self.loadChangeToken = loadChangeToken
        self.saveChangeToken = saveChangeToken
    }

    // MARK: - Scheduling

    /// Start the fallback polling loop. Must be called on the main thread.
    public func start(pollInterval: TimeInterval = 30) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollOnce()
        }
        pollOnce()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Immediate poll — wired to the CKSubscription silent push.
    public func pokePoll() { pollOnce() }

    // MARK: - Poll cycle

    public func pollOnce(completion: (() -> Void)? = nil) {
        lock.lock()
        if polling { lock.unlock(); completion?(); return }
        polling = true
        lock.unlock()

        fetchChanges(allowTokenReset: true) { [weak self] records in
            guard let self else { completion?(); return }
            for record in records where record.recordType == CloudSchema.RecordType.pairingInvite {
                guard let invite = PairingInvite(record: record) else { continue }
                self.handle(invite)
            }
            self.lock.lock(); self.polling = false; self.lock.unlock()
            completion?()
        }
    }

    private func fetchChanges(allowTokenReset: Bool, completion: @escaping ([CKRecord]) -> Void) {
        database.fetchZoneChanges(zoneID: CloudSchema.zoneID, since: loadChangeToken()) { [weak self] result in
            guard let self else { return completion([]) }
            switch result {
            case .success(let changes):
                if let token = changes.changeToken { self.saveChangeToken(token) }
                completion(changes.changed)
            case .failure(let error):
                if allowTokenReset, let ck = error as? CKError, ck.code == .changeTokenExpired {
                    // Stored token too old — reset and refetch from scratch.
                    self.saveChangeToken(nil)
                    self.fetchChanges(allowTokenReset: false, completion: completion)
                } else {
                    NSLog("PocketCloud: fetchZoneChanges failed: %@", "\(error)")
                    completion([])
                }
            }
        }
    }

    private func handle(_ invite: PairingInvite) {
        switch InviteRules.action(for: invite, hostDeviceID: hostDeviceID, now: now()) {
        case .ignore:
            break
        case .delete:
            database.deleteRecord(with: invite.record.recordID) { _ in }
        case .promptApproval:
            lock.lock()
            let alreadyHandling = inFlight.contains(invite.recordName)
            if !alreadyHandling { inFlight.insert(invite.recordName) }
            lock.unlock()
            guard !alreadyHandling else { return }
            approvalHandler(invite) { [weak self] approved in
                guard let self else { return }
                if approved {
                    self.issue(invite)
                } else {
                    self.transition(invite, to: .expired)
                }
            }
        }
    }

    // MARK: - Issue / deny

    private func issue(_ invite: PairingInvite) {
        codeIssuer { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                NSLog("PocketCloud: pair/new failed, leaving invite untouched: %@", "\(error)")
                self.finish(invite)
            case .success(let pair):
                let record = invite.record
                record[CloudSchema.InviteField.state] = PairingInvite.State.issued.rawValue
                record[CloudSchema.InviteField.oneTimeCode] = pair.code
                record[CloudSchema.InviteField.expiresAt] =
                    self.now().addingTimeInterval(TimeInterval(pair.ttlSeconds))
                self.saveInvite(record, from: invite)
            }
        }
    }

    private func transition(_ invite: PairingInvite, to state: PairingInvite.State) {
        guard InviteRules.canTransition(from: invite.state, to: state) else { return finish(invite) }
        let record = invite.record
        record[CloudSchema.InviteField.state] = state.rawValue
        saveInvite(record, from: invite)
    }

    private func saveInvite(_ record: CKRecord, from invite: PairingInvite) {
        do { try TokenRedLine.check(record) } catch {
            NSLog("PocketCloud: %@", "\(error)")
            return finish(invite)
        }
        // ifServerRecordUnchanged: if another party won the race we back off
        // (design §3.2 — the loser abandons and re-reads next poll).
        database.save(record, savePolicy: .ifServerRecordUnchanged) { [weak self] result in
            if case .failure(let error) = result {
                NSLog("PocketCloud: invite save conflict/failure, backing off: %@", "\(error)")
            }
            self?.finish(invite)
        }
    }

    private func finish(_ invite: PairingInvite) {
        lock.lock()
        inFlight.remove(invite.recordName)
        lock.unlock()
    }
}
