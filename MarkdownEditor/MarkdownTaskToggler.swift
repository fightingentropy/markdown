import Foundation

struct MarkdownTaskToggleResult: Equatable {
    let text: String
    let selection: NSRange
}

enum MarkdownTaskToggler {
    static func toggle(in text: String, selection: NSRange) -> MarkdownTaskToggleResult {
        let nsText = text as NSString
        let safeLocation = min(selection.location, nsText.length)
        let safeLength = min(selection.length, nsText.length - safeLocation)
        let lineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: safeLength))
        let selectedLines = nsText.substring(with: lineRange)
        let transformed = selectedLines
            .components(separatedBy: .newlines)
            .enumerated()
            .map { index, line in
                guard !line.isEmpty || index < selectedLines.components(separatedBy: .newlines).count - 1 else {
                    return line
                }
                return toggleLine(line)
            }
            .joined(separator: "\n")

        let updated = nsText.replacingCharacters(in: lineRange, with: transformed)
        return MarkdownTaskToggleResult(
            text: updated,
            selection: NSRange(location: lineRange.location, length: (transformed as NSString).length)
        )
    }

    private static func toggleLine(_ line: String) -> String {
        let nsLine = line as NSString
        let openPattern = #"^(\s*[-*+]\s+)\[ \](\s*)"#
        let donePattern = #"^(\s*[-*+]\s+)\[[xX]\](\s*)"#

        if let regex = try? NSRegularExpression(pattern: openPattern),
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            let prefix = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 2))
            return regex.stringByReplacingMatches(
                in: line,
                range: match.range,
                withTemplate: NSRegularExpression.escapedTemplate(for: "\(prefix)[x]\(spacing)")
            )
        }

        if let regex = try? NSRegularExpression(pattern: donePattern),
           let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            let prefix = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 2))
            return regex.stringByReplacingMatches(
                in: line,
                range: match.range,
                withTemplate: NSRegularExpression.escapedTemplate(for: "\(prefix)[ ]\(spacing)")
            )
        }

        let leadingWhitespace = line.prefix(while: { $0 == " " || $0 == "\t" })
        let content = line.dropFirst(leadingWhitespace.count)
        return "\(leadingWhitespace)- [ ] \(content)"
    }
}
