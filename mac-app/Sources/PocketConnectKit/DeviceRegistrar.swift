import CloudKit
import Foundation

// Upserts this Mac's Device record (design §4.1): role=host, hostCandidates,
// bridgeFingerprint, versions, lastSeenAt heartbeat. Only this machine ever
// writes its own Device record, so conflicts are rare — on serverRecordChanged
// we take the server copy, reapply our fields and retry once.

public struct DeviceInfo {
    public var deviceID: String
    public var name: String
    public var platform: String
    public var role: String
    public var hostCandidates: [String]
    public var bridgeFingerprint: String?
    public var appVersion: String
    public var osVersion: String

    public init(deviceID: String, name: String, platform: String = "macos", role: String = "host",
                hostCandidates: [String], bridgeFingerprint: String?,
                appVersion: String, osVersion: String) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.role = role
        self.hostCandidates = hostCandidates
        self.bridgeFingerprint = bridgeFingerprint
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

public final class DeviceRegistrar {
    private let database: CloudDatabase
    private let infoProvider: () -> DeviceInfo
    private let now: () -> Date

    public init(database: CloudDatabase,
                infoProvider: @escaping () -> DeviceInfo,
                now: @escaping () -> Date = Date.init) {
        self.database = database
        self.infoProvider = infoProvider
        self.now = now
    }

    /// Fetch-or-create the Device record, refresh all fields + lastSeenAt.
    /// Called at startup and then every heartbeat tick (15 min).
    public func upsert(completion: @escaping (Result<Void, Error>) -> Void) {
        let info = infoProvider()
        let recordID = CKRecord.ID(recordName: info.deviceID, zoneID: CloudSchema.zoneID)
        database.fetchRecord(with: recordID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                completion(.failure(e))
            case .success(let existing):
                let record = existing ?? CKRecord(
                    recordType: CloudSchema.RecordType.device, recordID: recordID)
                self.save(record, info: info, retriesLeft: 1, completion: completion)
            }
        }
    }

    private func save(_ record: CKRecord, info: DeviceInfo, retriesLeft: Int,
                      completion: @escaping (Result<Void, Error>) -> Void) {
        Self.apply(info, to: record, lastSeenAt: now())
        do { try TokenRedLine.check(record) } catch { return completion(.failure(error)) }
        database.save(record, savePolicy: .ifServerRecordUnchanged) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                if retriesLeft > 0,
                   let ck = error as? CKError, ck.code == .serverRecordChanged,
                   let server = ck.serverRecord {
                    // Take the server's copy (fresh change tag) and reapply.
                    self.save(server, info: info, retriesLeft: retriesLeft - 1, completion: completion)
                } else {
                    completion(.failure(error))
                }
            }
        }
    }

    static func apply(_ info: DeviceInfo, to record: CKRecord, lastSeenAt: Date) {
        record[CloudSchema.DeviceField.name] = info.name
        record[CloudSchema.DeviceField.platform] = info.platform
        record[CloudSchema.DeviceField.role] = info.role
        record[CloudSchema.DeviceField.hostCandidates] = info.hostCandidates
        record[CloudSchema.DeviceField.bridgeFingerprint] = info.bridgeFingerprint
        record[CloudSchema.DeviceField.appVersion] = info.appVersion
        record[CloudSchema.DeviceField.osVersion] = info.osVersion
        record[CloudSchema.DeviceField.lastSeenAt] = lastSeenAt
    }
}
