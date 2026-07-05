import CloudKit
import Foundation

// CloudKit schema constants for the Pocket discovery layer
// (APPLE_ID_PAIRING_DESIGN §3). One custom container + custom zone shared by
// the desktop, iOS and kernel lines. Everything lives in the user's PRIVATE
// database — we never see any of it.
public enum CloudSchema {
    public static let containerID = "iCloud.com.pocketagent"
    public static let zoneName = "PocketZone"

    public static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public enum RecordType {
        public static let device = "Device"
        public static let pairingInvite = "PairingInvite"
        public static let pairingInfo = "PairingInfo"
        public static let errorLog = "ErrorLog"
    }

    // Device — one record per signed-in device; recordName = stable deviceID.
    public enum DeviceField {
        public static let name = "name"
        public static let platform = "platform"
        public static let role = "role"
        public static let hostCandidates = "hostCandidates"
        public static let bridgeFingerprint = "bridgeFingerprint"
        public static let appVersion = "appVersion"
        public static let osVersion = "osVersion"
        public static let lastSeenAt = "lastSeenAt"
    }

    // PairingInvite — short-lived handshake record (design §3.1 / §4.2).
    public enum InviteField {
        public static let clientDevice = "clientDevice"
        public static let hostDevice = "hostDevice"
        public static let state = "state"
        public static let oneTimeCode = "oneTimeCode"
        public static let expiresAt = "expiresAt"
    }

    // PairingInfo — recordName = "{clientDeviceID}-{hostDeviceID}" (design §3.1).
    // Mac side only READS this (written by the phone on claim / the QR path's
    // best-effort backfill) — the dashboard shows it as "已配對裝置".
    public enum PairingInfoField {
        public static let clientDevice = "clientDevice"
        public static let hostDevice = "hostDevice"
        public static let pairedAt = "pairedAt"
        public static let lastConnectedAt = "lastConnectedAt"
        public static let status = "status"
    }

    // ErrorLog — append-only diagnostic record (design §3.1 / §4.4). Each
    // device writes only its OWN entries and self-cleans past 200 (design §5
    // M2c 驗收 ④); every device reads the whole type for the dashboard's
    // mixed local+remote timeline.
    public enum ErrorLogField {
        public static let device = "device"
        public static let ts = "ts"
        public static let level = "level"
        public static let code = "code"
        public static let message = "message"
        public static let context = "context"
    }
}

// Red line (design §3.3): no value containing the word "token" may ever be
// written to a CKRecord — tokens live in the Keychain only. The oneTimeCode
// from /pair/new is NOT a token and is explicitly allowed; this guard rejects
// field names and string values that literally carry the word "token".
public struct TokenRedLineError: Error, CustomStringConvertible {
    public let offendingFields: [String]
    public var description: String {
        "紅線:欄位含 token 字樣,拒絕寫入 CloudKit:\(offendingFields.joined(separator: ", "))"
    }
}

public enum TokenRedLine {
    /// Returns the field keys that violate the red line (empty == clean).
    public static func violations(in record: CKRecord) -> [String] {
        var bad: [String] = []
        for key in record.allKeys() {
            if key.lowercased().contains("token") {
                bad.append(key)
                continue
            }
            switch record[key] {
            case let s as String where s.lowercased().contains("token"):
                bad.append(key)
            case let list as [String] where list.contains(where: { $0.lowercased().contains("token") }):
                bad.append(key)
            default:
                break
            }
        }
        return bad
    }

    /// Throws if the record must not be uploaded.
    public static func check(_ record: CKRecord) throws {
        let bad = violations(in: record)
        if !bad.isEmpty { throw TokenRedLineError(offendingFields: bad) }
    }
}
