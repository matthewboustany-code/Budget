import Foundation
import Security

/// Minimal Keychain wrapper for the session bearer token. A finance app must
/// not keep auth material in UserDefaults, and FlightBag has no auth to borrow
/// a pattern from — so this is a small, dependency-free helper (in the spirit
/// of FlightBag keeping third-party deps to a minimum).
struct Keychain {
    let service: String

    init(service: String = "app.budget.session") {
        self.service = service
    }

    func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        // Delete any existing item first so we upsert.
        delete(account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
