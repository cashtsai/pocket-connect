import CloudKit
import Foundation

// Read-side models for the dashboard (design §5 M2c). Parsed straight out of
// CKRecord so DashboardStore stays a thin query+decode layer — no separate
// "sync engine" beyond what CloudSyncController already runs for M2a.

public struct DeviceSummary: Equatable, Identifiable {
    public var id: String { deviceID }
    public let deviceID: String
    public let name: String
    public let platform: String
    public let role: String
    public let appVersion: String?
    public let osVersion: String?
    public let hostCandidates: [String]
    public let lastSeenAt: Date?

    public init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.device,
              let name = record[CloudSchema.DeviceField.name] as? String,
              let platform = record[CloudSchema.DeviceField.platform] as? String,
              let role = record[CloudSchema.DeviceField.role] as? String
        else { return nil }
        self.deviceID = record.recordID.recordName
        self.name = name
        self.platform = platform
        self.role = role
        self.appVersion = record[CloudSchema.DeviceField.appVersion] as? String
        self.osVersion = record[CloudSchema.DeviceField.osVersion] as? String
        self.hostCandidates = record[CloudSchema.DeviceField.hostCandidates] as? [String] ?? []
        self.lastSeenAt = record[CloudSchema.DeviceField.lastSeenAt] as? Date
    }
}

public struct PairingSummary: Equatable, Identifiable {
    public var id: String { recordName }
    public let recordName: String
    public let clientDeviceID: String?
    public let hostDeviceID: String?
    public let status: String
    public let pairedAt: Date?
    public let lastConnectedAt: Date?

    public init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.pairingInfo,
              let status = record[CloudSchema.PairingInfoField.status] as? String
        else { return nil }
        self.recordName = record.recordID.recordName
        self.clientDeviceID = (record[CloudSchema.PairingInfoField.clientDevice] as? CKRecord.Reference)?
            .recordID.recordName
        self.hostDeviceID = (record[CloudSchema.PairingInfoField.hostDevice] as? CKRecord.Reference)?
            .recordID.recordName
        self.status = status
        self.pairedAt = record[CloudSchema.PairingInfoField.pairedAt] as? Date
        self.lastConnectedAt = record[CloudSchema.PairingInfoField.lastConnectedAt] as? Date
    }
}

public enum ErrorLevel: String, Equatable {
    case info, warning, error
}

public struct ErrorLogEntry: Equatable, Identifiable {
    public var id: String { recordName }
    public let recordName: String
    public let deviceID: String?
    public let ts: Date
    public let level: String
    public let code: String
    public let message: String
    public let context: [String: String]

    public init?(record: CKRecord) {
        guard record.recordType == CloudSchema.RecordType.errorLog,
              let ts = record[CloudSchema.ErrorLogField.ts] as? Date,
              let level = record[CloudSchema.ErrorLogField.level] as? String,
              let code = record[CloudSchema.ErrorLogField.code] as? String,
              let message = record[CloudSchema.ErrorLogField.message] as? String
        else { return nil }
        self.recordName = record.recordID.recordName
        self.deviceID = (record[CloudSchema.ErrorLogField.device] as? CKRecord.Reference)?
            .recordID.recordName
        self.ts = ts
        self.level = level
        self.code = code
        self.message = message
        if let data = record[CloudSchema.ErrorLogField.context] as? Data,
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            self.context = decoded
        } else {
            self.context = [:]
        }
    }
}

public struct DashboardSnapshot: Equatable {
    public var devices: [DeviceSummary] = []
    public var pairings: [PairingSummary] = []
    /// Local + remote, mixed and sorted newest-first (design §5 M2c 驗收 ①-④).
    public var errorLogs: [ErrorLogEntry] = []

    public init(devices: [DeviceSummary] = [], pairings: [PairingSummary] = [],
               errorLogs: [ErrorLogEntry] = []) {
        self.devices = devices
        self.pairings = pairings
        self.errorLogs = errorLogs
    }
}
