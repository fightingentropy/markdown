import Foundation
import Security

@Observable
@MainActor
final class AssistantSettings {
    static let supportedModels: [String] = [
        "gpt-5.4",
        "gpt-5.3-codex",
        "gpt-5.3-codex-spark",
        "gpt-5.1",
        "gpt-5.1-codex-mini"
    ]

    static let authURL = URL(string: "https://opencode.ai/auth")!
    static let responsesEndpoint = URL(string: "https://opencode.ai/zen/v1/responses")!

    var apiKey: String {
        didSet {
            persistAPIKey()
        }
    }

    var selectedModel: String {
        didSet {
            userDefaults.set(selectedModel, forKey: Self.modelDefaultsKey)
        }
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let userDefaults: UserDefaults
    private let keychain: AssistantKeychainStore

    private static let modelDefaultsKey = "assistant.selectedModel"
    private static let defaultModel = "gpt-5.1-codex-mini"

    init(
        userDefaults: UserDefaults = .standard,
        keychain: AssistantKeychainStore = .shared
    ) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.apiKey = keychain.read()
        let storedModel = userDefaults.string(forKey: Self.modelDefaultsKey)
        if let storedModel, Self.supportedModels.contains(storedModel) {
            self.selectedModel = storedModel
        } else {
            self.selectedModel = Self.defaultModel
        }
    }

    private func persistAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            keychain.delete()
        } else {
            keychain.write(trimmed)
            if apiKey != trimmed {
                apiKey = trimmed
            }
        }
    }
}

struct AssistantKeychainStore {
    static let shared = AssistantKeychainStore()

    private let service = "com.md.MarkdownEditor"
    private let account = "OpenCodeZenAPIKey"

    func read() -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }

        return string
    }

    func write(_ value: String) {
        let data = Data(value.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updates = [kSecValueData as String: data] as CFDictionary
            SecItemUpdate(baseQuery as CFDictionary, updates)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
