import CloudKit
import Foundation
import Security

// Runtime feature gate (design §5 "kernel/OSS 線" + Q1=B / Q2=A rulings):
// CloudKit only turns on when ALL of these hold —
//   1. the kill switch UserDefaults flag is off (OSS builds can default it on),
//   2. our code signature actually carries the iCloud container entitlement
//      (ad-hoc/unsigned builds → silently disabled, the rest of the app runs),
//   3. CKAccountStatus == .available (checked async by CloudSyncController).
// No entitlement must never crash the app: we probe the signature via SecTask
// BEFORE ever touching CKContainer.

public enum CloudGate {
    /// UserDefaults kill switch — set true to force-disable the discovery layer
    /// even on entitled builds (OSS/kernel line ships with it on by default).
    public static let killSwitchDefaultsKey = "pocketCloudKitDisabled"

    /// iCloud container IDs embedded in our code signature, if any.
    public static func entitledContainers() -> [String] {
        entitlementArray("com.apple.developer.icloud-container-identifiers")
    }

    private static func entitlementArray(_ key: String) -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [] }
        guard let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        else { return [] }
        return (value as? [String]) ?? []
    }

    private static func entitlementString(_ key: String) -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? String
    }

    public static var hasEntitlement: Bool {
        entitledContainers().contains(CloudSchema.containerID) &&
        entitlementArray("com.apple.developer.icloud-services").contains("CloudKit") &&
        entitlementString("com.apple.application-identifier")?.isEmpty == false &&
        entitlementString("com.apple.developer.team-identifier")?.isEmpty == false
    }

    public static var killSwitchOn: Bool {
        UserDefaults.standard.bool(forKey: killSwitchDefaultsKey)
    }

    /// Synchronous part of the gate. `.none` means "may proceed to the async
    /// CKAccountStatus check".
    public static func staticDisableReason() -> String? {
        if killSwitchOn { return "已由設定停用" }
        if !hasEntitlement { return "無 iCloud 簽章(entitlement)" }
        return nil
    }
}
