import AppKit

@MainActor
enum Theme {
    static let editorFontSize: CGFloat = 14
    static let codeFontSize: CGFloat = 13

    static let editorFont = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    static let editorBoldFont = NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .bold)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)

    static let headingColor = NSColor.systemBlue
    static let codeColor = NSColor.systemOrange
    static let codeBackground = NSColor.quaternaryLabelColor
    static let linkColor = NSColor.systemCyan
    static let quoteColor = NSColor.secondaryLabelColor
    static let metaColor = NSColor.tertiaryLabelColor

    static let defaultParagraphStyle: NSMutableParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }()

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [
            .font: editorFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: defaultParagraphStyle,
        ]
    }
}
