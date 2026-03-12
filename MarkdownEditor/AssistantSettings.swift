import Foundation

@Observable
@MainActor
final class AssistantSettings {
    static let supportedModels: [AssistantModel] = [
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
            persistAPIKey()
        }
    }

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

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let userDefaults: UserDefaults

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
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.apiKey = userDefaults.string(forKey: Self.apiKeyDefaultsKey) ?? ""
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

    private func persistAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: Self.apiKeyDefaultsKey)
        } else {
            userDefaults.set(trimmed, forKey: Self.apiKeyDefaultsKey)
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
