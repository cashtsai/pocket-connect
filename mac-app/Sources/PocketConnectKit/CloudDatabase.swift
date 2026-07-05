import CloudKit
import Foundation

// Thin protocol over the handful of CKDatabase operations the discovery layer
// needs, so unit tests can substitute an in-memory mock (no entitlement, no
// iCloud account, no network).

public struct ZoneChanges {
    public let changed: [CKRecord]
    public let deletedRecordIDs: [CKRecord.ID]
    /// Opaque serialized CKServerChangeToken (nil for mocks / first fetch).
    public let changeToken: Data?

    public init(changed: [CKRecord], deletedRecordIDs: [CKRecord.ID], changeToken: Data?) {
        self.changed = changed
        self.deletedRecordIDs = deletedRecordIDs
        self.changeToken = changeToken
    }
}

public protocol CloudDatabase {
    func saveZone(_ zone: CKRecordZone, completion: @escaping (Result<Void, Error>) -> Void)
    func save(_ record: CKRecord,
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              completion: @escaping (Result<CKRecord, Error>) -> Void)
    /// Resolves to .success(nil) when the record simply doesn't exist yet.
    func fetchRecord(with recordID: CKRecord.ID,
                     completion: @escaping (Result<CKRecord?, Error>) -> Void)
    func deleteRecord(with recordID: CKRecord.ID,
                      completion: @escaping (Result<Void, Error>) -> Void)
    func fetchZoneChanges(zoneID: CKRecordZone.ID, since token: Data?,
                          completion: @escaping (Result<ZoneChanges, Error>) -> Void)
    func saveSubscription(_ subscription: CKSubscription,
                          completion: @escaping (Result<Void, Error>) -> Void)
}

// MARK: - Live adapter

extension CKDatabase: CloudDatabase {
    public func saveZone(_ zone: CKRecordZone, completion: @escaping (Result<Void, Error>) -> Void) {
        save(zone) { _, error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    public func save(_ record: CKRecord,
                     savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
                     completion: @escaping (Result<CKRecord, Error>) -> Void) {
        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = savePolicy
        op.qualityOfService = .userInitiated
        var saved: CKRecord?
        var perRecordError: Error?
        op.perRecordSaveBlock = { _, result in
            switch result {
            case .success(let r): saved = r
            case .failure(let e): perRecordError = e
            }
        }
        op.modifyRecordsResultBlock = { result in
            switch result {
            case .success:
                completion(.success(saved ?? record))
            case .failure(let e):
                // Prefer the per-record error — for conflicts it carries the
                // server record in its userInfo (serverRecordChanged).
                completion(.failure(perRecordError ?? e))
            }
        }
        add(op)
    }

    public func fetchRecord(with recordID: CKRecord.ID,
                            completion: @escaping (Result<CKRecord?, Error>) -> Void) {
        fetch(withRecordID: recordID) { record, error in
            if let record { return completion(.success(record)) }
            if let ck = error as? CKError, ck.code == .unknownItem {
                return completion(.success(nil))
            }
            completion(.failure(error ?? CKError(.internalError)))
        }
    }

    public func deleteRecord(with recordID: CKRecord.ID,
                             completion: @escaping (Result<Void, Error>) -> Void) {
        delete(withRecordID: recordID) { _, error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }

    public func fetchZoneChanges(zoneID: CKRecordZone.ID, since token: Data?,
                                 completion: @escaping (Result<ZoneChanges, Error>) -> Void) {
        let previous = token.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: previous, resultsLimit: nil, desiredKeys: nil)
        let op = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config])
        op.qualityOfService = .userInitiated
        var changed: [CKRecord] = []
        var deleted: [CKRecord.ID] = []
        var newToken: Data?
        op.recordWasChangedBlock = { _, result in
            if case .success(let record) = result { changed.append(record) }
        }
        op.recordWithIDWasDeletedBlock = { recordID, _ in deleted.append(recordID) }
        op.recordZoneFetchResultBlock = { _, result in
            if case .success(let (serverToken, _, _)) = result {
                newToken = try? NSKeyedArchiver.archivedData(
                    withRootObject: serverToken, requiringSecureCoding: true)
            }
        }
        op.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .success:
                completion(.success(ZoneChanges(changed: changed,
                                                deletedRecordIDs: deleted,
                                                changeToken: newToken)))
            case .failure(let e):
                completion(.failure(e))
            }
        }
        add(op)
    }

    public func saveSubscription(_ subscription: CKSubscription,
                                 completion: @escaping (Result<Void, Error>) -> Void) {
        save(subscription) { _, error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }
    }
}
