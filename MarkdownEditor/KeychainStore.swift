import Foundation
import Security

/// Minimal storage boundary for secrets used by the assistant. Keeping this
/// protocol small lets `AssistantSettings` exercise migration behavior in unit
/// tests without touching the developer's real login Keychain.
protocol APIKeyStoring {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

struct KeychainStore: APIKeyStoring {
    enum StoreError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "The Keychain operation failed with status \(status)."
            }
        }
    }

    let service: String
    let account: String

    func read() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw StoreError.unexpectedStatus(errSecDecode)
            }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw StoreError.unexpectedStatus(status)
        }
    }

    func save(_ value: String) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let addStatus = SecItemAdd(item as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                // Another process may have created the item between the update
                // and add. Retry the update once instead of replacing it.
                let retryStatus = SecItemUpdate(
                    baseQuery as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard retryStatus == errSecSuccess else {
                    throw StoreError.unexpectedStatus(retryStatus)
                }
                return
            }
            guard addStatus == errSecSuccess else {
                throw StoreError.unexpectedStatus(addStatus)
            }
        default:
            throw StoreError.unexpectedStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.unexpectedStatus(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
