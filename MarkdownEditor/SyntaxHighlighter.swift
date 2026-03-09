import AppKit

enum EditorLinkDetector {
    private static let markdownLinkRegex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#)
    private static let bareLinkRegex = try! NSRegularExpression(pattern: #"https?://[^\s)>\"]+"#)

    static func url(near characterIndex: Int, in text: String) -> URL? {
        let nsText = text as NSString
        guard nsText.length > 0 else {
            return nil
        }

        let candidateIndices = Set([
            characterIndex,
            max(0, characterIndex - 1),
        ].filter { $0 < nsText.length })

        for index in candidateIndices.sorted() {
            if let url = markdownLinkURL(at: index, in: text, nsText: nsText) {
                return url
            }

            if let url = bareLinkURL(at: index, in: text, nsText: nsText) {
                return url
            }
        }

        return nil
    }

    private static func markdownLinkURL(at characterIndex: Int, in text: String, nsText: NSString) -> URL? {
        let fullRange = NSRange(location: 0, length: nsText.length)
        for match in markdownLinkRegex.matches(in: text, range: fullRange) {
            guard NSLocationInRange(characterIndex, match.range) else {
                continue
            }

            if match.range.location > 0, nsText.character(at: match.range.location - 1) == 33 {
                continue
            }

            let urlString = nsText.substring(with: match.range(at: 2))
            guard let url = URL(string: urlString), url.scheme != nil else {
                return nil
            }

            return url
        }

        return nil
    }

    private static func bareLinkURL(at characterIndex: Int, in text: String, nsText: NSString) -> URL? {
        let fullRange = NSRange(location: 0, length: nsText.length)
        for match in bareLinkRegex.matches(in: text, range: fullRange) {
            guard NSLocationInRange(characterIndex, match.range) else {
                continue
            }

            let urlString = nsText.substring(with: match.range)
            return URL(string: urlString)
        }

        return nil
    }
}

@MainActor
final class SyntaxHighlighter {

    func highlight(_ textStorage: NSTextStorage) {
        let text = textStorage.string
        let fullRange = NSRange(location: 0, length: textStorage.length)

        textStorage.beginEditing()
        textStorage.setAttributes(Theme.defaultAttributes, range: fullRange)

        let codeBlockRanges = highlightCodeBlocks(textStorage, text: text)
        let safeRanges = subtractRanges(codeBlockRanges, from: fullRange)

        for range in safeRanges {
            highlightInRange(textStorage, text: text, range: range)
        }

        textStorage.endEditing()
    }

    // MARK: - Code Blocks

    private func highlightCodeBlocks(_ textStorage: NSTextStorage, text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let lines = text.components(separatedBy: "\n")
        var inCodeBlock = false
        var blockStart = 0
        var currentPos = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    let end = currentPos + line.utf16.count
                    let range = NSRange(location: blockStart, length: end - blockStart)
                    applyCodeBlockStyle(textStorage, range: range)
                    ranges.append(range)
                    inCodeBlock = false
                } else {
                    blockStart = currentPos
                    inCodeBlock = true
                }
            }
            currentPos += line.utf16.count + 1
        }

        if inCodeBlock {
            let range = NSRange(location: blockStart, length: max(0, textStorage.length - blockStart))
            if range.length > 0 {
                applyCodeBlockStyle(textStorage, range: range)
                ranges.append(range)
            }
        }

        return ranges
    }

    private func applyCodeBlockStyle(_ textStorage: NSTextStorage, range: NSRange) {
        textStorage.addAttributes([
            .font: Theme.codeFont,
            .foregroundColor: Theme.codeColor,
            .backgroundColor: Theme.codeBackground,
        ], range: range)
    }

    // MARK: - Inline Highlighting

    private func highlightInRange(_ textStorage: NSTextStorage, text: String, range: NSRange) {
        apply(#"^#{1,6}\s.*$"#, to: textStorage, in: text, range: range,
              attrs: [.font: Theme.editorBoldFont, .foregroundColor: Theme.headingColor])

        apply(#"\*{2}.+?\*{2}"#, to: textStorage, in: text, range: range,
              attrs: [.font: Theme.editorBoldFont])

        apply(#"`[^`\n]+`"#, to: textStorage, in: text, range: range,
              attrs: [.font: Theme.codeFont, .foregroundColor: Theme.codeColor, .backgroundColor: Theme.codeBackground])

        applyMarkdownLinks(to: textStorage, in: text, range: range)

        apply(#"!\[.*?\]\(.+?\)"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.linkColor])

        apply(#"!\[\[[^\]]+\]\]"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.linkColor])

        applyBareLinks(to: textStorage, in: text, range: range)

        apply(#"^>.*$"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.quoteColor])

        apply(#"^\s*[-*+]\s"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.metaColor])

        apply(#"^\s*\d+\.\s"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.metaColor])

        apply(#"^([-*_]\s*){3,}$"#, to: textStorage, in: text, range: range,
              attrs: [.foregroundColor: Theme.metaColor])
    }

    // MARK: - Helpers

    private func apply(
        _ pattern: String,
        to storage: NSTextStorage,
        in text: String,
        range: NSRange,
        attrs: [NSAttributedString.Key: Any]
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return }
        for match in regex.matches(in: text, range: range) {
            storage.addAttributes(attrs, range: match.range)
        }
    }

    private func applyMarkdownLinks(to storage: NSTextStorage, in text: String, range: NSRange) {
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\(([^)\s]+)\)"#) else { return }

        let nsText = text as NSString
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges >= 3 else { continue }
            if match.range.location > 0, nsText.character(at: match.range.location - 1) == 33 {
                continue
            }

            storage.addAttributes([
                .foregroundColor: Theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private func applyBareLinks(to storage: NSTextStorage, in text: String, range: NSRange) {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s)>\"]+"#) else { return }

        let nsText = text as NSString
        for match in regex.matches(in: text, range: range) {
            let urlString = nsText.substring(with: match.range)
            guard URL(string: urlString) != nil else { continue }

            storage.addAttributes([
                .foregroundColor: Theme.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }

    private func subtractRanges(_ exclusions: [NSRange], from full: NSRange) -> [NSRange] {
        let sorted = exclusions.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        var pos = full.location
        for ex in sorted {
            if ex.location > pos {
                result.append(NSRange(location: pos, length: ex.location - pos))
            }
            pos = ex.location + ex.length
        }
        let end = full.location + full.length
        if pos < end {
            result.append(NSRange(location: pos, length: end - pos))
        }
        return result
    }
}
