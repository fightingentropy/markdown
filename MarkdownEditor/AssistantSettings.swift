import Foundation
import Security

@Observable
@MainActor
final class AssistantSettings {
    static let supportedModels: [AssistantModel] = [
        AssistantModel(
            id: "glm-5",
            displayName: "GLM 5",
            endpoint: URL(string: "https://opencode.ai/zen/v1/chat/completions")!,
            apiStyle: .chatCompletions
        ),
        AssistantModel(
            id: "kimi-k2.5",
            displayName: "Kimi K2.5",
            endpoint: URL(string: "https://opencode.ai/zen/v1/chat/completions")!,
            apiStyle: .chatCompletions
        ),
        AssistantModel(
            id: "minimax-m2.5",
            displayName: "MiniMax M2.5",
            endpoint: URL(string: "https://opencode.ai/zen/v1/chat/completions")!,
            apiStyle: .chatCompletions
        )
    ]

    static let authURL = URL(string: "https://opencode.ai/auth")!
    static let supportedLauncherSymbols: [AssistantLauncherSymbol] = [
        AssistantLauncherSymbol(id: "bubble.left.and.bubble.right.fill", displayName: "Chat"),
        AssistantLauncherSymbol(id: "ellipsis.bubble.fill", displayName: "Reply"),
        AssistantLauncherSymbol(id: "message.fill", displayName: "Message")
    ]

    var apiKey: String {
        didSet {
            guard !isLoadingAPIKey else { return }
            hasLoadedAPIKey = true
            persistAPIKey()
        }
    }

    var selectedModel: String {
        didSet {
            userDefaults.set(selectedModel, forKey: Self.modelDefaultsKey)
        }
    }

    var launcherSymbol: String {
        didSet {
            userDefaults.set(launcherSymbol, forKey: Self.launcherSymbolDefaultsKey)
        }
    }

    var launcherSize: Double {
        didSet {
            userDefaults.set(launcherSize, forKey: Self.launcherSizeDefaultsKey)
        }
    }

    var launcherCornerRadius: Double {
        didSet {
            userDefaults.set(launcherCornerRadius, forKey: Self.launcherCornerRadiusDefaultsKey)
        }
    }

    var launcherBackgroundLevel: Double {
        didSet {
            userDefaults.set(launcherBackgroundLevel, forKey: Self.launcherBackgroundDefaultsKey)
        }
    }

    var launcherForegroundLevel: Double {
        didSet {
            userDefaults.set(launcherForegroundLevel, forKey: Self.launcherForegroundDefaultsKey)
        }
    }

    var launcherBorderLevel: Double {
        didSet {
            userDefaults.set(launcherBorderLevel, forKey: Self.launcherBorderDefaultsKey)
        }
    }

    var showsLauncherStatusBadge: Bool {
        didSet {
            userDefaults.set(showsLauncherStatusBadge, forKey: Self.launcherBadgeDefaultsKey)
        }
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let userDefaults: UserDefaults
    private let keychain: AssistantKeychainStore
    private var hasLoadedAPIKey = false
    private var isLoadingAPIKey = false

    private static let modelDefaultsKey = "assistant.selectedModel"
    private static let launcherSymbolDefaultsKey = "assistant.launcher.symbol"
    private static let launcherSizeDefaultsKey = "assistant.launcher.size"
    private static let launcherCornerRadiusDefaultsKey = "assistant.launcher.cornerRadius"
    private static let launcherBackgroundDefaultsKey = "assistant.launcher.backgroundLevel"
    private static let launcherForegroundDefaultsKey = "assistant.launcher.foregroundLevel"
    private static let launcherBorderDefaultsKey = "assistant.launcher.borderLevel"
    private static let launcherBadgeDefaultsKey = "assistant.launcher.showsStatusBadge"
    private static let defaultModel = "glm-5"
    private static let defaultLauncherSymbol = "bubble.left.and.bubble.right.fill"
    private static let defaultLauncherSize = 58.0
    private static let defaultLauncherCornerRadius = 18.0
    private static let defaultLauncherBackgroundLevel = 0.10
    private static let defaultLauncherForegroundLevel = 0.24
    private static let defaultLauncherBorderLevel = 0.20
    private static let defaultShowsLauncherStatusBadge = true

    init(
        userDefaults: UserDefaults = .standard,
        keychain: AssistantKeychainStore = .shared
    ) {
        self.userDefaults = userDefaults
        self.keychain = keychain
        self.apiKey = ""
        let storedModel = userDefaults.string(forKey: Self.modelDefaultsKey)
        if let storedModel, Self.model(for: storedModel) != nil {
            self.selectedModel = storedModel
        } else {
            self.selectedModel = Self.defaultModel
        }
        let storedLauncherSymbol = userDefaults.string(forKey: Self.launcherSymbolDefaultsKey)
        if let storedLauncherSymbol, Self.launcherSymbol(for: storedLauncherSymbol) != nil {
            self.launcherSymbol = storedLauncherSymbol
        } else {
            self.launcherSymbol = Self.defaultLauncherSymbol
        }
        let storedLauncherSize = userDefaults.object(forKey: Self.launcherSizeDefaultsKey) as? Double
        self.launcherSize = storedLauncherSize ?? Self.defaultLauncherSize
        let storedLauncherCornerRadius = userDefaults.object(forKey: Self.launcherCornerRadiusDefaultsKey) as? Double
        self.launcherCornerRadius = storedLauncherCornerRadius ?? Self.defaultLauncherCornerRadius
        let storedLauncherBackgroundLevel = userDefaults.object(forKey: Self.launcherBackgroundDefaultsKey) as? Double
        self.launcherBackgroundLevel = storedLauncherBackgroundLevel ?? Self.defaultLauncherBackgroundLevel
        let storedLauncherForegroundLevel = userDefaults.object(forKey: Self.launcherForegroundDefaultsKey) as? Double
        self.launcherForegroundLevel = storedLauncherForegroundLevel ?? Self.defaultLauncherForegroundLevel
        let storedLauncherBorderLevel = userDefaults.object(forKey: Self.launcherBorderDefaultsKey) as? Double
        self.launcherBorderLevel = storedLauncherBorderLevel ?? Self.defaultLauncherBorderLevel
        if userDefaults.object(forKey: Self.launcherBadgeDefaultsKey) != nil {
            self.showsLauncherStatusBadge = userDefaults.bool(forKey: Self.launcherBadgeDefaultsKey)
        } else {
            self.showsLauncherStatusBadge = Self.defaultShowsLauncherStatusBadge
        }
    }

    static func model(for id: String) -> AssistantModel? {
        supportedModels.first(where: { $0.id == id })
    }

    static func launcherSymbol(for id: String) -> AssistantLauncherSymbol? {
        supportedLauncherSymbols.first(where: { $0.id == id })
    }

    func loadAPIKeyIfNeeded() {
        guard !hasLoadedAPIKey else { return }
        isLoadingAPIKey = true
        apiKey = keychain.read()
        isLoadingAPIKey = false
        hasLoadedAPIKey = true
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

struct AssistantModel: Identifiable, Equatable {
    enum APIStyle: Equatable {
        case chatCompletions
    }

    let id: String
    let displayName: String
    let endpoint: URL
    let apiStyle: APIStyle
}

struct AssistantLauncherSymbol: Identifiable, Equatable {
    let id: String
    let displayName: String
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
