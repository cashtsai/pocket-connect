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

    /// Store (or replace) the session token. Returns true on success.
    @discardableResult
    static func saveSessionToken(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Delete any existing item first, then add fresh — simplest correct upsert.
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Load the stored session token, or nil if none.
    static func loadSessionToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Remove the stored session token (used by "重新設定").
    static func clearSessionToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
