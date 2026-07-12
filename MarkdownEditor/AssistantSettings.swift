import Foundation

@Observable
@MainActor
final class AssistantSettings {
    static let supportedModels: [AssistantModel] = [
        AssistantModel(
            id: "assistant-subscription",
            displayName: "assistant (Subscription)",
            endpoint: URL(string: "cli:assistant")!,
            apiStyle: .assistantCodeCLI
        ),
        AssistantModel(
            id: "gpt-5.4",
            displayName: "GPT-5.4",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiStyle: .chatCompletions,
            supportedReasoningEfforts: [.none, .low, .medium, .high, .xhigh]
        ),
        AssistantModel(
            id: "gpt-5.3-codex-spark",
            displayName: "GPT-5.3-Codex-Spark (limited preview)",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiStyle: .chatCompletions,
            supportedReasoningEfforts: [.low, .medium, .high, .xhigh]
        ),
        AssistantModel(
            id: "gpt-4o-mini",
            displayName: "GPT-4o mini",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiStyle: .chatCompletions
        ),
        AssistantModel(
            id: "gpt-4o",
            displayName: "GPT-4o",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiStyle: .chatCompletions
        ),
        AssistantModel(
            id: "gpt-4.1-mini",
            displayName: "GPT-4.1 mini",
            endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiStyle: .chatCompletions
        )
    ]

    static let authURL = URL(string: "https://platform.openai.com/api-keys")!
    static let supportedLauncherSymbols: [AssistantLauncherSymbol] = [
        AssistantLauncherSymbol(id: "bubble.left.and.bubble.right.fill", displayName: "Chat"),
        AssistantLauncherSymbol(id: "ellipsis.bubble.fill", displayName: "Reply"),
        AssistantLauncherSymbol(id: "message.fill", displayName: "Message")
    ]

    var apiKey: String {
        didSet {
            guard !isNormalizingAPIKey else { return }
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if apiKey != trimmed {
                isNormalizingAPIKey = true
                apiKey = trimmed
                isNormalizingAPIKey = false
            }
            persistAPIKey()
        }
    }

    /// Non-nil when the in-memory field and the Keychain could not be brought
    /// into agreement. The settings UI surfaces this rather than claiming a
    /// credential was saved or deleted when the operation actually failed.
    var apiKeyPersistenceError: String?

    var selectedModel: String {
        didSet {
            userDefaults.set(selectedModel, forKey: Self.modelDefaultsKey)
        }
    }

    var selectedReasoningEffort: AssistantReasoningEffortOption {
        didSet {
            userDefaults.set(selectedReasoningEffort.rawValue, forKey: Self.reasoningEffortDefaultsKey)
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

    /// True when the assistant is ready to take a request for the currently
    /// selected model — either because the user provided an API key, or
    /// because the active model uses a local credential source (the
    /// `assistant` CLI / assistant subscription) that doesn't need one.
    var isConfigured: Bool {
        if let model = Self.model(for: selectedModel), !model.requiresAPIKey {
            return true
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let userDefaults: UserDefaults
    private let apiKeyStore: any APIKeyStoring
    @ObservationIgnored private var isNormalizingAPIKey = false

    private static let keychainService: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.md.MarkdownEditor"
        return "\(bundleID).assistant"
    }()
    private static let keychainAccount = "openai.apiKey"

    private static let apiKeyDefaultsKey = "assistant.apiKey"
    private static let modelDefaultsKey = "assistant.selectedModel"
    private static let reasoningEffortDefaultsKey = "assistant.reasoningEffort"
    private static let launcherSymbolDefaultsKey = "assistant.launcher.symbol"
    private static let launcherSizeDefaultsKey = "assistant.launcher.size"
    private static let launcherCornerRadiusDefaultsKey = "assistant.launcher.cornerRadius"
    private static let launcherBackgroundDefaultsKey = "assistant.launcher.backgroundLevel"
    private static let launcherForegroundDefaultsKey = "assistant.launcher.foregroundLevel"
    private static let launcherBorderDefaultsKey = "assistant.launcher.borderLevel"
    private static let launcherBadgeDefaultsKey = "assistant.launcher.showsStatusBadge"
    private static let defaultModel = "gpt-4o-mini"
    private static let defaultReasoningEffort: AssistantReasoningEffortOption = .modelDefault
    private static let defaultLauncherSymbol = "bubble.left.and.bubble.right.fill"
    private static let defaultLauncherSize = 58.0
    private static let defaultLauncherCornerRadius = 18.0
    private static let defaultLauncherBackgroundLevel = 0.10
    private static let defaultLauncherForegroundLevel = 0.24
    private static let defaultLauncherBorderLevel = 0.20
    private static let defaultShowsLauncherStatusBadge = true
    init(
        userDefaults: UserDefaults = .standard,
        apiKeyStore: any APIKeyStoring = KeychainStore(
            service: AssistantSettings.keychainService,
            account: AssistantSettings.keychainAccount
        )
    ) {
        self.userDefaults = userDefaults
        self.apiKeyStore = apiKeyStore

        // Current builds briefly wrote this secret to UserDefaults. Migrate
        // that value back to the same Keychain slot older builds used, and
        // scrub the plaintext only after the secure write succeeds. If the
        // Keychain is temporarily unavailable, retaining the legacy value is
        // safer than silently losing the user's credential; the next launch
        // retries the migration.
        let legacyDefaultsKey = userDefaults.string(forKey: Self.apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let legacyDefaultsKey, !legacyDefaultsKey.isEmpty {
            self.apiKey = legacyDefaultsKey
            do {
                try apiKeyStore.save(legacyDefaultsKey)
                userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            } catch {
                // Leave the existing defaults value in place for a future
                // retry. Never copy a newly entered key into UserDefaults.
                self.apiKeyPersistenceError = Self.keychainErrorMessage(
                    action: "move the API key to Keychain",
                    error: error
                )
            }
        } else if let keychainKey = try? apiKeyStore.read(),
                  !keychainKey.isEmpty {
            self.apiKey = keychainKey
            userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
        } else {
            self.apiKey = ""
            if userDefaults.object(forKey: Self.apiKeyDefaultsKey) != nil {
                userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            }
        }

        let storedModel = userDefaults.string(forKey: Self.modelDefaultsKey)
        if let storedModel, Self.model(for: storedModel) != nil {
            self.selectedModel = storedModel
        } else {
            self.selectedModel = Self.defaultModel
        }
        if let storedReasoningEffort = userDefaults.string(forKey: Self.reasoningEffortDefaultsKey),
           let selectedReasoningEffort = AssistantReasoningEffortOption(rawValue: storedReasoningEffort) {
            self.selectedReasoningEffort = selectedReasoningEffort
        } else {
            self.selectedReasoningEffort = Self.defaultReasoningEffort
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

    func retryAPIKeyPersistence() {
        persistAPIKey()
    }

    private func persistAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            do {
                try apiKeyStore.delete()
                apiKeyPersistenceError = nil
            } catch {
                apiKeyPersistenceError = Self.keychainErrorMessage(
                    action: "remove the API key from Keychain",
                    error: error
                )
            }
            return
        }

        do {
            try apiKeyStore.save(trimmed)
            // This also scrubs a legacy value after a transient migration
            // failure once the Keychain becomes available again.
            userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
            apiKeyPersistenceError = nil
        } catch {
            // Keep the key in memory for this session. Writing a newly entered
            // secret back to plaintext would undo the security boundary.
            apiKeyPersistenceError = Self.keychainErrorMessage(
                action: "save the API key in Keychain",
                error: error
            )
        }
    }

    private static func keychainErrorMessage(action: String, error: Error) -> String {
        "Couldn’t \(action). \(error.localizedDescription) Try again after unlocking Keychain."
    }
}

struct AssistantModel: Identifiable, Equatable {
    enum APIStyle: Equatable {
        /// OpenAI-compatible `POST /v1/chat/completions` with an API key.
        case chatCompletions
        /// Runs the locally installed `assistant` CLI (assistant Code) which
        /// authenticates against the user's assistant subscription — no API
        /// key is required.
        case assistantCodeCLI
    }

    let id: String
    let displayName: String
    let endpoint: URL
    let apiStyle: APIStyle
    let supportedReasoningEfforts: [AssistantReasoningEffort]

    init(
        id: String,
        displayName: String,
        endpoint: URL,
        apiStyle: APIStyle,
        supportedReasoningEfforts: [AssistantReasoningEffort] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.endpoint = endpoint
        self.apiStyle = apiStyle
        self.supportedReasoningEfforts = supportedReasoningEfforts
    }

    /// Whether the user needs to supply an API key for this model. CLI-
    /// based models (e.g. the assistant subscription bridge) authenticate via
    /// the local CLI's stored credentials and don't need one.
    var requiresAPIKey: Bool {
        switch apiStyle {
        case .chatCompletions:
            return true
        case .assistantCodeCLI:
            return false
        }
    }
}

enum AssistantReasoningEffort: String, CaseIterable, Identifiable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X-High"
        }
    }
}

enum AssistantReasoningEffortOption: String, CaseIterable, Identifiable {
    case modelDefault = "default"
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .modelDefault:
            return "Model default"
        case .none:
            return "None"
        case .minimal:
            return "Minimal"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .xhigh:
            return "X-High"
        }
    }

    var reasoningEffort: AssistantReasoningEffort? {
        switch self {
        case .modelDefault:
            return nil
        case .none:
            return AssistantReasoningEffort.none
        case .minimal:
            return .minimal
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .xhigh:
            return .xhigh
        }
    }
}

struct AssistantLauncherSymbol: Identifiable, Equatable {
    let id: String
    let displayName: String
}
