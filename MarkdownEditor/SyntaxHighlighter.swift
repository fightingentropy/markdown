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
    private struct StyleSignature: Equatable {
        let fontChoice: MonospacedFontChoice
        let fontSize: Double
        let lineSpacing: Double
    }

    private struct Styles {
        let defaultAttributes: [NSAttributedString.Key: Any]
        let headingAttributes: [NSAttributedString.Key: Any]
        let boldAttributes: [NSAttributedString.Key: Any]
        let inlineCodeAttributes: [NSAttributedString.Key: Any]
        let codeBlockAttributes: [NSAttributedString.Key: Any]
        let linkAttributes: [NSAttributedString.Key: Any]
        let quoteAttributes: [NSAttributedString.Key: Any]
        let metaAttributes: [NSAttributedString.Key: Any]
    }

    private let preferences: AppPreferences
    private var cachedStyleSignature: StyleSignature?
    private var cachedStyles: Styles?

    init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    func highlight(_ textStorage: NSTextStorage, editedRange: NSRange? = nil) {
        let text = textStorage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let targetRange = incrementalHighlightRange(
            for: editedRange,
            in: text,
            fullRange: fullRange
        ) ?? fullRange

        let styles = currentStyles()
        textStorage.beginEditing()
        textStorage.setAttributes(styles.defaultAttributes, range: targetRange)

        let codeBlockRanges = highlightCodeBlocks(
            textStorage,
            text: text,
            intersecting: targetRange,
            styles: styles
        )
        let safeRanges = subtractRanges(codeBlockRanges, from: targetRange)

        for range in safeRanges {
            highlightInRange(textStorage, text: text, range: range, styles: styles)
        }

        textStorage.endEditing()
    }

    // MARK: - Code Blocks

    private func highlightCodeBlocks(
        _ textStorage: NSTextStorage,
        text: NSString,
        intersecting targetRange: NSRange,
        styles: Styles
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        var inCodeBlock = false
        var blockStart = 0
        enumerateLines(in: text) { lineRange, contentRange in
            guard isFenceLine(contentRange, in: text) else { return true }

            if inCodeBlock {
                let range = NSRange(location: blockStart, length: max(0, NSMaxRange(contentRange) - blockStart))
                let intersection = NSIntersectionRange(range, targetRange)
                if intersection.length > 0 {
                    applyCodeBlockStyle(textStorage, range: intersection, styles: styles)
                    ranges.append(intersection)
                }
                inCodeBlock = false
            } else {
                blockStart = lineRange.location
                inCodeBlock = true
            }

            return true
        }

        if inCodeBlock {
            let range = NSRange(location: blockStart, length: max(0, text.length - blockStart))
            let intersection = NSIntersectionRange(range, targetRange)
            if intersection.length > 0 {
                applyCodeBlockStyle(textStorage, range: intersection, styles: styles)
                ranges.append(intersection)
            }
        }

        return ranges
    }

    private func applyCodeBlockStyle(_ textStorage: NSTextStorage, range: NSRange, styles: Styles) {
        textStorage.addAttributes(styles.codeBlockAttributes, range: range)
    }

    // MARK: - Inline Highlighting

    private func highlightInRange(_ textStorage: NSTextStorage, text: NSString, range: NSRange, styles: Styles) {
        guard range.length > 0 else { return }

        var location = range.location
        let rangeEnd = NSMaxRange(range)

        while location < rangeEnd {
            let fullLineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSIntersectionRange(fullLineRange, range)
            let lineContentRange = contentRange(forLineRange: lineRange, in: text)

            if lineContentRange.length > 0 {
                if lineRange.location == fullLineRange.location {
                    highlightLineMetadata(textStorage, text: text, lineRange: lineContentRange, styles: styles)
                }

                applyBoldSpans(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyInlineCodeSpans(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyMarkdownConstructs(to: textStorage, in: text, range: lineContentRange, styles: styles)
                applyBareLinks(to: textStorage, in: text, range: lineContentRange, styles: styles)
            }

            let nextLocation = NSMaxRange(fullLineRange)
            guard nextLocation > location else { break }
            location = nextLocation
        }
    }

    // MARK: - Helpers

    private func highlightLineMetadata(
        _ textStorage: NSTextStorage,
        text: NSString,
        lineRange: NSRange,
        styles: Styles
    ) {
        if isHeadingLine(lineRange, in: text) {
            textStorage.addAttributes(styles.headingAttributes, range: lineRange)
        }

        if isBlockquoteLine(lineRange, in: text) {
            textStorage.addAttributes(styles.quoteAttributes, range: lineRange)
        }

        if let markerRange = unorderedListMarkerRange(for: lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: markerRange)
        }

        if let markerRange = orderedListMarkerRange(for: lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: markerRange)
        }

        if isHorizontalRuleLine(lineRange, in: text) {
            textStorage.addAttributes(styles.metaAttributes, range: lineRange)
        }
    }

    private func applyBoldSpans(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location + 1 < end {
            guard text.character(at: location) == 42, text.character(at: location + 1) == 42 else {
                location += 1
                continue
            }

            let contentStart = location + 2
            var closing = contentStart
            var matchedRange: NSRange?

            while closing + 1 < end {
                let character = text.character(at: closing)
                if isNewline(character) {
                    break
                }

                if character == 42, text.character(at: closing + 1) == 42, closing > contentStart {
                    matchedRange = NSRange(location: location, length: closing + 2 - location)
                    break
                }

                closing += 1
            }

            if let matchedRange {
                storage.addAttributes(styles.boldAttributes, range: matchedRange)
                location = NSMaxRange(matchedRange)
            } else {
                location += 2
            }
        }
    }

    private func applyInlineCodeSpans(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            guard text.character(at: location) == 96 else {
                location += 1
                continue
            }

            let contentStart = location + 1
            var closing = contentStart
            var matchedRange: NSRange?

            while closing < end {
                let character = text.character(at: closing)
                if isNewline(character) {
                    break
                }

                if character == 96, closing > contentStart {
                    matchedRange = NSRange(location: location, length: closing + 1 - location)
                    break
                }

                closing += 1
            }

            if let matchedRange {
                storage.addAttributes(styles.inlineCodeAttributes, range: matchedRange)
                location = NSMaxRange(matchedRange)
            } else {
                location += 1
            }
        }
    }

    private func applyMarkdownConstructs(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let character = text.character(at: location)

            if character == 33 {
                if let embedRange = obsidianImageRange(startingAt: location, in: text, limit: end) {
                    storage.addAttributes(styles.linkAttributes, range: embedRange)
                    location = NSMaxRange(embedRange)
                    continue
                }

                if let imageRange = markdownLinkRange(
                    startingAt: location,
                    in: text,
                    limit: end,
                    isImage: true
                ) {
                    storage.addAttributes(styles.linkAttributes, range: imageRange)
                    location = NSMaxRange(imageRange)
                    continue
                }
            } else if character == 91,
                      let linkRange = markdownLinkRange(
                        startingAt: location,
                        in: text,
                        limit: end,
                        isImage: false
                      ) {
                storage.addAttributes(styles.linkAttributes, range: linkRange)
                location = NSMaxRange(linkRange)
                continue
            }

            location += 1
        }
    }

    private func applyBareLinks(
        to storage: NSTextStorage,
        in text: NSString,
        range: NSRange,
        styles: Styles
    ) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            guard text.character(at: location) == 104 else {
                location += 1
                continue
            }

            if let linkRange = bareLinkRange(startingAt: location, in: text, limit: end) {
                storage.addAttributes(styles.linkAttributes, range: linkRange)
                location = NSMaxRange(linkRange)
            } else {
                location += 1
            }
        }
    }

    private func currentStyles() -> Styles {
        let signature = StyleSignature(
            fontChoice: preferences.editorFontChoice,
            fontSize: preferences.editorFontSize,
            lineSpacing: preferences.editorLineSpacing
        )

        if let cachedStyleSignature, cachedStyleSignature == signature, let cachedStyles {
            return cachedStyles
        }

        let editorBoldFont = Theme.editorBoldFont(using: preferences)
        let codeFont = Theme.codeFont(using: preferences)
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: Theme.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        let styles = Styles(
            defaultAttributes: Theme.defaultAttributes(using: preferences),
            headingAttributes: [.font: editorBoldFont, .foregroundColor: Theme.headingColor],
            boldAttributes: [.font: editorBoldFont],
            inlineCodeAttributes: [.font: codeFont, .foregroundColor: Theme.codeColor, .backgroundColor: Theme.codeBackground],
            codeBlockAttributes: [.font: codeFont, .foregroundColor: Theme.codeColor, .backgroundColor: Theme.codeBackground],
            linkAttributes: linkAttributes,
            quoteAttributes: [.foregroundColor: Theme.quoteColor],
            metaAttributes: [.foregroundColor: Theme.metaColor]
        )

        cachedStyleSignature = signature
        cachedStyles = styles
        return styles
    }

    private func incrementalHighlightRange(
        for editedRange: NSRange?,
        in text: NSString,
        fullRange: NSRange
    ) -> NSRange? {
        guard let editedRange else { return nil }
        guard fullRange.length > 0 else { return fullRange }

        let clampedLocation = min(max(editedRange.location, 0), fullRange.length)
        let clampedLength = min(max(editedRange.length, 0), max(0, fullRange.length - clampedLocation))
        let clampedRange = NSRange(location: clampedLocation, length: clampedLength)
        let probeRange = probeRange(for: clampedRange, fullRange: fullRange)
        let paragraphRange = text.paragraphRange(for: probeRange)

        if paragraphMayAffectCodeBlockState(paragraphRange, in: text) {
            return nil
        }

        if let codeBlockRange = codeBlockRange(containing: probeRange.location, in: text, fullLength: fullRange.length) {
            return codeBlockRange
        }

        return paragraphRange
    }

    private func probeRange(for editedRange: NSRange, fullRange: NSRange) -> NSRange {
        guard editedRange.length == 0 else { return editedRange }

        let location = min(editedRange.location, max(0, fullRange.length - 1))
        return NSRange(location: location, length: 1)
    }

    private func paragraphMayAffectCodeBlockState(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }

        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let fullLineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let lineRange = NSIntersectionRange(fullLineRange, range)
            let lineContentRange = contentRange(forLineRange: lineRange, in: text)
            if isFenceLine(lineContentRange, in: text) {
                return true
            }

            let nextLocation = NSMaxRange(fullLineRange)
            guard nextLocation > location else { break }
            location = nextLocation
        }

        return false
    }

    private func codeBlockRange(containing location: Int, in text: NSString, fullLength: Int) -> NSRange? {
        var inCodeBlock = false
        var blockStart = 0
        var matchedRange: NSRange?

        enumerateLines(in: text) { lineRange, contentRange in
            guard isFenceLine(contentRange, in: text) else { return true }

            if inCodeBlock {
                let range = NSRange(location: blockStart, length: max(0, NSMaxRange(contentRange) - blockStart))
                if NSLocationInRange(location, range) || location == NSMaxRange(range) {
                    matchedRange = range
                    return false
                }
                inCodeBlock = false
            } else {
                blockStart = lineRange.location
                inCodeBlock = true
            }

            return true
        }

        if let matchedRange {
            return matchedRange
        }

        guard inCodeBlock else { return nil }
        let range = NSRange(location: blockStart, length: max(0, fullLength - blockStart))
        return location >= blockStart ? range : nil
    }

    private func enumerateLines(
        in text: NSString,
        _ body: (NSRange, NSRange) -> Bool
    ) {
        guard text.length > 0 else { return }

        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let contentRange = contentRange(forLineRange: lineRange, in: text)
            guard body(lineRange, contentRange) else { return }

            let nextLocation = NSMaxRange(lineRange)
            guard nextLocation > location else { return }
            location = nextLocation
        }
    }

    private func contentRange(forLineRange lineRange: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location, isNewline(text.character(at: end - 1)) {
            end -= 1
        }
        return NSRange(location: lineRange.location, length: end - lineRange.location)
    }

    private func isFenceLine(_ range: NSRange, in text: NSString) -> Bool {
        let trimmedStart = skipLeadingWhitespace(in: range, text: text)
        let available = NSMaxRange(range) - trimmedStart
        guard available >= 3 else { return false }

        return text.character(at: trimmedStart) == 96 &&
            text.character(at: trimmedStart + 1) == 96 &&
            text.character(at: trimmedStart + 2) == 96
    }

    private func isHeadingLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length >= 2 else { return false }
        guard text.character(at: range.location) == 35 else { return false }

        var location = range.location
        var hashCount = 0
        let end = NSMaxRange(range)

        while location < end, text.character(at: location) == 35, hashCount < 6 {
            hashCount += 1
            location += 1
        }

        guard hashCount > 0, location < end else { return false }
        return isWhitespace(text.character(at: location))
    }

    private func isBlockquoteLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0 else { return false }
        return text.character(at: range.location) == 62
    }

    private func unorderedListMarkerRange(for range: NSRange, in text: NSString) -> NSRange? {
        let markerLocation = skipLeadingWhitespace(in: range, text: text)
        guard markerLocation < NSMaxRange(range) else { return nil }

        let marker = text.character(at: markerLocation)
        guard marker == 45 || marker == 42 || marker == 43 else { return nil }

        let whitespaceLocation = markerLocation + 1
        guard whitespaceLocation < NSMaxRange(range), isWhitespace(text.character(at: whitespaceLocation)) else {
            return nil
        }

        return NSRange(location: range.location, length: whitespaceLocation + 1 - range.location)
    }

    private func orderedListMarkerRange(for range: NSRange, in text: NSString) -> NSRange? {
        var location = skipLeadingWhitespace(in: range, text: text)
        let end = NSMaxRange(range)
        let firstDigitLocation = location

        while location < end, isDigit(text.character(at: location)) {
            location += 1
        }

        guard location > firstDigitLocation, location + 1 < end else { return nil }
        guard text.character(at: location) == 46, isWhitespace(text.character(at: location + 1)) else {
            return nil
        }

        return NSRange(location: range.location, length: location + 2 - range.location)
    }

    private func isHorizontalRuleLine(_ range: NSRange, in text: NSString) -> Bool {
        guard range.length > 0, !isWhitespace(text.character(at: range.location)) else { return false }

        var markerCount = 0
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            let character = text.character(at: location)
            if character == 45 || character == 42 || character == 95 {
                markerCount += 1
            } else if !isWhitespace(character) {
                return false
            }
            location += 1
        }

        return markerCount >= 3
    }

    private func markdownLinkRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int,
        isImage: Bool
    ) -> NSRange? {
        let bracketLocation = isImage ? location + 1 : location
        guard bracketLocation < limit, text.character(at: bracketLocation) == 91 else { return nil }

        let textStart = bracketLocation + 1
        guard textStart < limit else { return nil }

        guard let closingBracket = index(of: 93, in: text, from: textStart, limit: limit) else {
            return nil
        }

        if !isImage, closingBracket == textStart {
            return nil
        }

        let openingParen = closingBracket + 1
        guard openingParen < limit, text.character(at: openingParen) == 40 else { return nil }

        let destinationStart = openingParen + 1
        guard destinationStart < limit else { return nil }

        var destinationEnd = destinationStart
        while destinationEnd < limit {
            let character = text.character(at: destinationEnd)
            if character == 41 {
                break
            }
            if isNewline(character) || (!isImage && isWhitespace(character)) {
                return nil
            }
            destinationEnd += 1
        }

        guard destinationEnd < limit, destinationEnd > destinationStart else { return nil }
        return NSRange(location: location, length: destinationEnd + 1 - location)
    }

    private func obsidianImageRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int
    ) -> NSRange? {
        guard location + 3 < limit else { return nil }
        guard text.character(at: location) == 33,
              text.character(at: location + 1) == 91,
              text.character(at: location + 2) == 91 else {
            return nil
        }

        var closing = location + 3
        while closing + 1 < limit {
            if text.character(at: closing) == 93, text.character(at: closing + 1) == 93 {
                return NSRange(location: location, length: closing + 2 - location)
            }
            if isNewline(text.character(at: closing)) {
                return nil
            }
            closing += 1
        }

        return nil
    }

    private func bareLinkRange(
        startingAt location: Int,
        in text: NSString,
        limit: Int
    ) -> NSRange? {
        guard location < limit, text.character(at: location) == 104 else { return nil }

        let prefixLength: Int
        if matchesHTTPPrefix(at: location, in: text, limit: limit) {
            prefixLength = 7
        } else if matchesHTTPSPrefix(at: location, in: text, limit: limit) {
            prefixLength = 8
        } else {
            return nil
        }

        var end = location + prefixLength
        while end < limit {
            let character = text.character(at: end)
            if isWhitespace(character) || isNewline(character) || character == 41 || character == 62 || character == 34 {
                break
            }
            end += 1
        }

        guard end > location + prefixLength else { return nil }
        return NSRange(location: location, length: end - location)
    }

    private func matchesHTTPPrefix(at location: Int, in text: NSString, limit: Int) -> Bool {
        guard location + 7 <= limit else { return false }
        return text.character(at: location + 1) == 116 &&
            text.character(at: location + 2) == 116 &&
            text.character(at: location + 3) == 112 &&
            text.character(at: location + 4) == 58 &&
            text.character(at: location + 5) == 47 &&
            text.character(at: location + 6) == 47
    }

    private func matchesHTTPSPrefix(at location: Int, in text: NSString, limit: Int) -> Bool {
        guard location + 8 <= limit else { return false }
        return text.character(at: location + 1) == 116 &&
            text.character(at: location + 2) == 116 &&
            text.character(at: location + 3) == 112 &&
            text.character(at: location + 4) == 115 &&
            text.character(at: location + 5) == 58 &&
            text.character(at: location + 6) == 47 &&
            text.character(at: location + 7) == 47
    }

    private func index(of character: unichar, in text: NSString, from start: Int, limit: Int) -> Int? {
        guard start < limit else { return nil }

        var location = start
        while location < limit {
            let current = text.character(at: location)
            if current == character {
                return location
            }
            if isNewline(current) {
                return nil
            }
            location += 1
        }

        return nil
    }

    private func skipLeadingWhitespace(in range: NSRange, text: NSString) -> Int {
        var location = range.location
        let end = NSMaxRange(range)
        while location < end, isWhitespace(text.character(at: location)) {
            location += 1
        }
        return location
    }

    private func isWhitespace(_ character: unichar) -> Bool {
        character == 32 || character == 9
    }

    private func isNewline(_ character: unichar) -> Bool {
        character == 10 || character == 13
    }

    private func isDigit(_ character: unichar) -> Bool {
        character >= 48 && character <= 57
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
