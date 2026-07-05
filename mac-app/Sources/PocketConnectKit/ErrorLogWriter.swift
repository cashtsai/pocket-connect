import CloudKit
import Foundation

// Append-only ErrorLog writer (design §3.1 / §4.4 / §5 M2c 驗收 ④):
//   append() → new UUID record, TokenRedLine-checked, saved with .allKeys
//              (always a fresh record — no conflict is possible)
//   rotate() → after every append, query this device's own ErrorLog records
//              and delete the oldest ones past the 200-per-device cap.
// Only ever touches records whose `device` reference is THIS device — never
// another device's history, so there is no cross-device write contention.

public final class ErrorLogWriter {
    public static let maxPerDevice = 200

    private let database: CloudDatabase
    private let deviceID: String
    private let now: () -> Date

    public init(database: CloudDatabase, deviceID: String, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.deviceID = deviceID
        self.now = now
    }

    public func append(level: ErrorLevel, code: String, message: String,
                       context: [String: String] = [:],
                       completion: ((Result<Void, Error>) -> Void)? = nil) {
        let recordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: CloudSchema.zoneID)
        let record = CKRecord(recordType: CloudSchema.RecordType.errorLog, recordID: recordID)
        record[CloudSchema.ErrorLogField.device] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: deviceID, zoneID: CloudSchema.zoneID), action: .none)
        record[CloudSchema.ErrorLogField.ts] = now()
        record[CloudSchema.ErrorLogField.level] = level.rawValue
        record[CloudSchema.ErrorLogField.code] = code
        record[CloudSchema.ErrorLogField.message] = message
        if !context.isEmpty, let data = try? JSONSerialization.data(withJSONObject: context) {
            record[CloudSchema.ErrorLogField.context] = data
        }

        do {
            try TokenRedLine.check(record)
        } catch {
            NSLog("PocketCloud: ErrorLog append rejected by red line: %@", "\(error)")
            completion?(.failure(error))
            return
        }

        database.save(record, savePolicy: .allKeys) { [weak self] result in
            switch result {
            case .success:
                self?.rotate()
                completion?(.success(()))
            case .failure(let error):
                NSLog("PocketCloud: ErrorLog append failed: %@", "\(error)")
                completion?(.failure(error))
            }
        }
    }

    /// Self-clean: keep only the newest `maxPerDevice` records belonging to
    /// this device. Best-effort — failures here never block anything else.
    func rotate(completion: (() -> Void)? = nil) {
        database.queryRecords(ofType: CloudSchema.RecordType.errorLog, zoneID: CloudSchema.zoneID) { [weak self] result in
            guard let self else { completion?(); return }
            guard case .success(let records) = result else { completion?(); return }
            let mine = records
                .filter { ($0[CloudSchema.ErrorLogField.device] as? CKRecord.Reference)?
                    .recordID.recordName == self.deviceID }
                .sorted { lhs, rhs in
                    let lt = lhs[CloudSchema.ErrorLogField.ts] as? Date ?? .distantPast
                    let rt = rhs[CloudSchema.ErrorLogField.ts] as? Date ?? .distantPast
                    return lt < rt
                }
            guard mine.count > Self.maxPerDevice else { completion?(); return }
            let excess = mine.prefix(mine.count - Self.maxPerDevice)
            let group = DispatchGroup()
            for record in excess {
                group.enter()
                self.database.deleteRecord(with: record.recordID) { _ in group.leave() }
            }
            group.notify(queue: .main) { completion?() }
        }
    }
}
