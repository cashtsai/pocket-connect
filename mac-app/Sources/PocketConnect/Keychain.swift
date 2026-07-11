import Foundation
import Security

// Local Keychain storage for the account session token.
//
// The desktop is the home of all credentials (see pocket-pair.py's security
// model), so we use a plain generic-password item WITHOUT kSecAttrSynchronizable
// — this session token is deliberately machine-local and must not iCloud-sync.
enum Keychain {
    // Service/account namespace for the account session token.
    private static let service = "com.pocketagent.desktop"
    private static let account = "account-session-token"
    // Concrete keychain access group. The provisioning profile grants the
    // wildcard `4F8B93R3SH.*`; macOS can't resolve a wildcard as the *write*
    // group, so SecItemAdd must name a concrete group the wildcard covers —
    // otherwise it fails with errSecMissingEntitlement (-34018). We also opt
    // into the data-protection keychain so access-group semantics apply on
    // macOS the same way they do on iOS.
    private static let accessGroup = "4F8B93R3SH.com.pocketagent.desktop"

    /// Base query shared by save/load/clear so the item is addressed identically.
    private static func baseQuery(useAccessGroup: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useAccessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Store (or replace) the session token. Returns the SecItemAdd OSStatus
    /// (`errSecSuccess` on success) so callers can surface the real code.
    @discardableResult
    static func saveSessionToken(_ token: String) -> OSStatus {
        var attrs = baseQuery(useAccessGroup: true)
        // Delete any existing item first, then add fresh — simplest correct upsert.
        clearSessionToken()
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecSuccess { return status }

        var fallback = baseQuery(useAccessGroup: false)
        fallback[kSecValueData as String] = Data(token.utf8)
        fallback[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(fallback as CFDictionary, nil)
    }

    /// Load the stored session token, or nil if none.
    static func loadSessionToken() -> String? {
        if let token = loadSessionToken(useAccessGroup: true) { return token }
        return loadSessionToken(useAccessGroup: false)
    }

    private static func loadSessionToken(useAccessGroup: Bool) -> String? {
        var query = baseQuery(useAccessGroup: useAccessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Remove the stored session token (used by "重新設定").
    static func clearSessionToken() {
        SecItemDelete(baseQuery(useAccessGroup: true) as CFDictionary)
        SecItemDelete(baseQuery(useAccessGroup: false) as CFDictionary)
    }
}
