import CloudKit
import Foundation

// Read side of the M2c dashboard (design §5 M2c 驗收 ①②④): pulls Device,
// PairingInfo and ErrorLog straight from the zone via CloudDatabase.queryRecords
// and folds them into one DashboardSnapshot. Refreshed on demand — the window
// calls refresh() on appear, on a foreground timer, and when a CKSubscription
// silent push arrives (CloudSyncController.onDashboardShouldRefresh).
//
// Each section degrades independently: a failed query for one record type
// just yields an empty list for that section rather than failing the whole
// refresh (mirrors the "every failure degrades silently" rule from
// CloudSyncController).

public final class DashboardStore {
    private let database: CloudDatabase

    public init(database: CloudDatabase) {
        self.database = database
    }

    public func refresh(completion: @escaping (DashboardSnapshot) -> Void) {
        queryType(CloudSchema.RecordType.device) { deviceRecords in
            let devices = deviceRecords.compactMap(DeviceSummary.init)
                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            self.queryType(CloudSchema.RecordType.pairingInfo) { pairingRecords in
                let pairings = pairingRecords.compactMap(PairingSummary.init)
                self.queryType(CloudSchema.RecordType.errorLog) { errorRecords in
                    let errors = errorRecords.compactMap(ErrorLogEntry.init)
                        .sorted { $0.ts > $1.ts }   // newest first, local+remote mixed
                    completion(DashboardSnapshot(devices: devices, pairings: pairings, errorLogs: errors))
                }
            }
        }
    }

    private func queryType(_ recordType: String, completion: @escaping ([CKRecord]) -> Void) {
        database.queryRecords(ofType: recordType, zoneID: CloudSchema.zoneID) { result in
            switch result {
            case .success(let records):
                completion(records)
            case .failure(let error):
                NSLog("PocketCloud: dashboard query for %@ failed: %@", recordType, "\(error)")
                completion([])
            }
        }
    }
}
