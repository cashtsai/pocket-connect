import CloudKit
import Foundation
@testable import PocketConnectKit

/// In-memory CloudDatabase: no entitlement, no iCloud account, no network.
/// Completions run synchronously, so tests stay deterministic.
final class MockCloudDatabase: CloudDatabase {
    var store: [CKRecord.ID: CKRecord] = [:]
    /// Errors consumed one-per-save call (FIFO); empty → saves succeed.
    var scriptedSaveErrors: [Error] = []
    var savedPolicies: [CKModifyRecordsOperation.RecordSavePolicy] = []
    var zonesSaved: [CKRecordZone.ID] = []
    var subscriptionsSaved: [CKSubscription] = []
    var deletedIDs: [CKRecord.ID] = []
    var fetchZoneChangesError: Error?

    func saveZone(_ zone: CKRecordZone, completion: @escaping (Result<Void, Error>) -> Void) {
        zonesSaved.append(zone.zoneID)
        completion(.success(()))
    }

    func save(_ record: CKRecord,
              savePolicy: CKModifyRecordsOperation.RecordSavePolicy,
              completion: @escaping (Result<CKRecord, Error>) -> Void) {
        savedPolicies.append(savePolicy)
        if !scriptedSaveErrors.isEmpty {
            return completion(.failure(scriptedSaveErrors.removeFirst()))
        }
        store[record.recordID] = record
        completion(.success(record))
    }

    func fetchRecord(with recordID: CKRecord.ID,
                     completion: @escaping (Result<CKRecord?, Error>) -> Void) {
        completion(.success(store[recordID]))
    }

    func deleteRecord(with recordID: CKRecord.ID,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        store.removeValue(forKey: recordID)
        deletedIDs.append(recordID)
        completion(.success(()))
    }

    func fetchZoneChanges(zoneID: CKRecordZone.ID, since token: Data?,
                          completion: @escaping (Result<ZoneChanges, Error>) -> Void) {
        if let e = fetchZoneChangesError {
            fetchZoneChangesError = nil
            return completion(.failure(e))
        }
        completion(.success(ZoneChanges(changed: Array(store.values),
                                        deletedRecordIDs: [],
                                        changeToken: nil)))
    }

    func saveSubscription(_ subscription: CKSubscription,
                          completion: @escaping (Result<Void, Error>) -> Void) {
        subscriptionsSaved.append(subscription)
        completion(.success(()))
    }
}

/// Builds the same conflict error CloudKit returns when a save loses the race.
func serverRecordChangedError(server: CKRecord) -> Error {
    NSError(domain: CKError.errorDomain,
            code: CKError.Code.serverRecordChanged.rawValue,
            userInfo: [CKRecordChangedErrorServerRecordKey: server])
}

// MARK: - Shared fixtures

func makeInviteRecord(recordName: String = "phone-1-mac-1",
                      state: PairingInvite.State = .requested,
                      clientDeviceID: String = "phone-1",
                      hostDeviceID: String = "mac-1",
                      expiresAt: Date? = nil) -> CKRecord {
    let id = CKRecord.ID(recordName: recordName, zoneID: CloudSchema.zoneID)
    let record = CKRecord(recordType: CloudSchema.RecordType.pairingInvite, recordID: id)
    record[CloudSchema.InviteField.state] = state.rawValue
    record[CloudSchema.InviteField.clientDevice] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: clientDeviceID, zoneID: CloudSchema.zoneID), action: .none)
    record[CloudSchema.InviteField.hostDevice] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: hostDeviceID, zoneID: CloudSchema.zoneID), action: .none)
    if let expiresAt { record[CloudSchema.InviteField.expiresAt] = expiresAt }
    return record
}

func makeDeviceInfo(deviceID: String = "mac-1",
                    hostCandidates: [String] = ["http://100.100.1.2:8081", "http://192.168.1.9:8081"])
    -> DeviceInfo {
    DeviceInfo(deviceID: deviceID, name: "Test Mac", hostCandidates: hostCandidates,
               bridgeFingerprint: "abc123", appVersion: "0.1.1", osVersion: "macOS 15")
}
