import AppKit

@MainActor
enum Theme {
    static let headingColor = NSColor.labelColor
    static let codeColor = NSColor.systemOrange
    static let codeBackground = NSColor.quaternaryLabelColor
    static let linkColor = NSColor.systemOrange
    static let quoteColor = NSColor.secondaryLabelColor
    static let metaColor = NSColor.tertiaryLabelColor

    static func editorFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.nsFont(size: preferences.editorFontSizeCGFloat)
    }

    static func editorBoldFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.nsFont(size: preferences.editorFontSizeCGFloat, weight: .bold)
    }

    static func headingFont(level: Int, using preferences: AppPreferences) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.85
        case 2: scale = 1.52
        case 3: scale = 1.28
        case 4: scale = 1.12
        default: scale = 1
        }
        return preferences.editorFontChoice.nsFont(
            size: min(36, preferences.editorFontSizeCGFloat * scale),
            weight: level <= 3 ? .bold : .semibold
        )
    }

    static func codeFont(using preferences: AppPreferences) -> NSFont {
        preferences.editorFontChoice.codeFont(size: max(12, preferences.editorFontSizeCGFloat - 1))
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

    static func headingAttributes(level: Int, using preferences: AppPreferences) -> [NSAttributedString.Key: Any] {
        let style = defaultParagraphStyle(using: preferences)
        style.lineSpacing = max(2, preferences.editorLineSpacingCGFloat * 0.45)
        style.paragraphSpacingBefore = level == 1 ? 18 : 12
        style.paragraphSpacing = level <= 2 ? 10 : 6

        return [
            .font: headingFont(level: level, using: preferences),
            .foregroundColor: headingColor,
            .paragraphStyle: style,
        ]
    }
}
