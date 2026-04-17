import Foundation
import Security

/// Thin wrapper around the Keychain for storing generic passwords as UTF-8
/// strings, keyed by service + account. The assistant API key moved here from
/// `UserDefaults` so it is no longer written to the plist in plain text.
///
/// The wrapper is intentionally tiny: it does not support attributes other
/// than accessibility, does not attempt any complex error handling, and only
/// reports a binary success/failure signal. Callers fall back gracefully when
/// writes fail (e.g. during early boot, before the keychain is unlocked).
enum KeychainStore {
    /// Reads the stored string value for the given (service, account) pair.
    /// Returns `nil` if no entry exists or the value is unreadable.
    static func readString(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Writes the given UTF-8 string to the Keychain, creating a new entry or
    /// updating an existing one. Returns `true` on success.
    @discardableResult
    static func writeString(
        _ value: String,
        service: String,
        account: String
    ) -> Bool {
        let data = Data(value.utf8)

        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(
            matchQuery as CFDictionary,
            updateAttributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return true
        }

        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var addQuery = matchQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Removes the stored value for the given (service, account) pair.
    /// Returns `true` if the entry was removed or did not exist to begin with.
    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
