import AppKit

@MainActor
enum Theme {
    static let headingColor = NSColor.systemBlue
    static let codeColor = NSColor.systemOrange
    static let codeBackground = NSColor.quaternaryLabelColor
    static let linkColor = NSColor.systemCyan
    static let quoteColor = NSColor.secondaryLabelColor
    static let metaColor = NSColor.tertiaryLabelColor

    static func editorFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.nsFont(size: preferences.editorFontSizeCGFloat)
    }

    static func editorBoldFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.nsFont(size: preferences.editorFontSizeCGFloat, weight: .bold)
    }

    static func codeFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.nsFont(size: max(12, preferences.editorFontSizeCGFloat - 1))
    }

    static func defaultParagraphStyle(using preferences: AppPreferences) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = preferences.editorLineSpacingCGFloat
        return style
    }

    static func defaultAttributes(using preferences: AppPreferences) -> [NSAttributedString.Key: Any] {
        [
            .font: editorFont(using: preferences),
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: defaultParagraphStyle(using: preferences),
        ]
    }
}
