import AppKit
import SwiftUI

enum OpenViewMode: String, CaseIterable, Identifiable {
    case editor
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor:
            "Editor"
        case .preview:
            "Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor:
            "pencil"
        case .preview:
            "eye"
        }
    }
}

enum MonospacedFontChoice: String, CaseIterable, Identifiable {
    case system
    case sfMono = "SF Mono"
    case menlo = "Menlo"
    case monaco = "Monaco"
    case courierNew = "Courier New"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System Monospaced"
        case .sfMono:
            "SF Mono"
        case .menlo:
            "Menlo"
        case .monaco:
            "Monaco"
        case .courierNew:
            "Courier New"
        }
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        switch self {
        case .system:
            NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        default:
            NSFont(name: rawValue, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .system:
            .system(size: size, design: .monospaced)
        default:
            .custom(rawValue, size: size)
        }
    }

    var cssFontFamily: String {
        switch self {
        case .system:
            "'SF Mono', SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .sfMono:
            "'SF Mono', SFMono-Regular, Menlo, Monaco, Consolas, monospace"
        case .menlo:
            "'Menlo', Monaco, Consolas, monospace"
        case .monaco:
            "'Monaco', Menlo, Consolas, monospace"
        case .courierNew:
            "'Courier New', Courier, monospace"
        }
    }
}

enum PreviewFontChoice: String, CaseIterable, Identifiable {
    case system
    case georgia = "Georgia"
    case palatino = "Palatino"
    case baskerville = "Baskerville"
    case timesNewRoman = "Times New Roman"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System Sans"
        case .georgia:
            "Georgia"
        case .palatino:
            "Palatino"
        case .baskerville:
            "Baskerville"
        case .timesNewRoman:
            "Times New Roman"
        }
    }

    func swiftUIFont(size: CGFloat) -> Font {
        switch self {
        case .system:
            .system(size: size)
        default:
            .custom(rawValue, size: size)
        }
    }

    var cssFontFamily: String {
        switch self {
        case .system:
            "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', sans-serif"
        case .georgia:
            "'Georgia', serif"
        case .palatino:
            "'Palatino', 'Palatino Linotype', serif"
        case .baskerville:
            "'Baskerville', 'Times New Roman', serif"
        case .timesNewRoman:
            "'Times New Roman', Times, serif"
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    var editorFontChoice: MonospacedFontChoice {
        didSet { userDefaults.set(editorFontChoice.rawValue, forKey: Self.editorFontChoiceKey) }
    }

    var editorFontSize: Double {
        didSet { userDefaults.set(editorFontSize, forKey: Self.editorFontSizeKey) }
    }

    var editorLineSpacing: Double {
        didSet { userDefaults.set(editorLineSpacing, forKey: Self.editorLineSpacingKey) }
    }

    var editorReadableWidth: Double {
        didSet { userDefaults.set(editorReadableWidth, forKey: Self.editorReadableWidthKey) }
    }

    var previewFontChoice: PreviewFontChoice {
        didSet { userDefaults.set(previewFontChoice.rawValue, forKey: Self.previewFontChoiceKey) }
    }

    var previewCodeFontChoice: MonospacedFontChoice {
        didSet { userDefaults.set(previewCodeFontChoice.rawValue, forKey: Self.previewCodeFontChoiceKey) }
    }

    var previewFontSize: Double {
        didSet { userDefaults.set(previewFontSize, forKey: Self.previewFontSizeKey) }
    }

    var previewPageWidth: Double {
        didSet { userDefaults.set(previewPageWidth, forKey: Self.previewPageWidthKey) }
    }

    var defaultOpenViewMode: OpenViewMode {
        didSet { userDefaults.set(defaultOpenViewMode.rawValue, forKey: Self.defaultOpenViewModeKey) }
    }

    var autosaveDelaySeconds: Double {
        didSet { userDefaults.set(autosaveDelaySeconds, forKey: Self.autosaveDelayKey) }
    }

    var defaultSortOrder: SortOrder {
        didSet { userDefaults.set(defaultSortOrder.rawValue, forKey: Self.defaultSortOrderKey) }
    }

    var restoresExpandedFolders: Bool {
        didSet { userDefaults.set(restoresExpandedFolders, forKey: Self.restoresExpandedFoldersKey) }
    }

    var collapsesFoldersOnVaultSwitch: Bool {
        didSet { userDefaults.set(collapsesFoldersOnVaultSwitch, forKey: Self.collapsesFoldersOnVaultSwitchKey) }
    }

    private let userDefaults: UserDefaults

    private static let editorFontChoiceKey = "preferences.editorFontChoice"
    private static let editorFontSizeKey = "preferences.editorFontSize"
    private static let editorLineSpacingKey = "preferences.editorLineSpacing"
    private static let editorReadableWidthKey = "preferences.editorReadableWidth"
    private static let previewFontChoiceKey = "preferences.previewFontChoice"
    private static let previewCodeFontChoiceKey = "preferences.previewCodeFontChoice"
    private static let previewFontSizeKey = "preferences.previewFontSize"
    private static let previewPageWidthKey = "preferences.previewPageWidth"
    private static let defaultOpenViewModeKey = "preferences.defaultOpenViewMode"
    private static let autosaveDelayKey = "preferences.autosaveDelaySeconds"
    private static let defaultSortOrderKey = "preferences.defaultSortOrder"
    private static let restoresExpandedFoldersKey = "preferences.restoresExpandedFolders"
    private static let collapsesFoldersOnVaultSwitchKey = "preferences.collapsesFoldersOnVaultSwitch"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.editorFontChoice = MonospacedFontChoice(rawValue: userDefaults.string(forKey: Self.editorFontChoiceKey) ?? "") ?? .system
        self.editorFontSize = userDefaults.object(forKey: Self.editorFontSizeKey) as? Double ?? 14
        self.editorLineSpacing = userDefaults.object(forKey: Self.editorLineSpacingKey) as? Double ?? 4
        self.editorReadableWidth = userDefaults.object(forKey: Self.editorReadableWidthKey) as? Double ?? 920
        self.previewFontChoice = PreviewFontChoice(rawValue: userDefaults.string(forKey: Self.previewFontChoiceKey) ?? "") ?? .system
        self.previewCodeFontChoice = MonospacedFontChoice(rawValue: userDefaults.string(forKey: Self.previewCodeFontChoiceKey) ?? "") ?? .system
        self.previewFontSize = userDefaults.object(forKey: Self.previewFontSizeKey) as? Double ?? 15
        self.previewPageWidth = userDefaults.object(forKey: Self.previewPageWidthKey) as? Double ?? 920
        self.defaultOpenViewMode = OpenViewMode(rawValue: userDefaults.string(forKey: Self.defaultOpenViewModeKey) ?? "") ?? .editor
        self.autosaveDelaySeconds = userDefaults.object(forKey: Self.autosaveDelayKey) as? Double ?? 0.5
        self.defaultSortOrder = SortOrder(rawValue: userDefaults.string(forKey: Self.defaultSortOrderKey) ?? "") ?? .byDate
        if userDefaults.object(forKey: Self.restoresExpandedFoldersKey) != nil {
            self.restoresExpandedFolders = userDefaults.bool(forKey: Self.restoresExpandedFoldersKey)
        } else {
            self.restoresExpandedFolders = true
        }
        if userDefaults.object(forKey: Self.collapsesFoldersOnVaultSwitchKey) != nil {
            self.collapsesFoldersOnVaultSwitch = userDefaults.bool(forKey: Self.collapsesFoldersOnVaultSwitchKey)
        } else {
            self.collapsesFoldersOnVaultSwitch = false
        }
    }

    var editorFontSizeCGFloat: CGFloat {
        CGFloat(editorFontSize)
    }

    var editorLineSpacingCGFloat: CGFloat {
        CGFloat(editorLineSpacing)
    }

    var editorReadableWidthCGFloat: CGFloat {
        CGFloat(editorReadableWidth)
    }

    var previewFontSizeCGFloat: CGFloat {
        CGFloat(previewFontSize)
    }

    var previewPageWidthCGFloat: CGFloat {
        CGFloat(previewPageWidth)
    }

    var previewCodeFontSizeCGFloat: CGFloat {
        max(12, previewFontSizeCGFloat * 0.88)
    }
}
