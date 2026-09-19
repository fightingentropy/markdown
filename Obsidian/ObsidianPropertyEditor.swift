import Foundation

enum ObsidianPropertyEditorError: LocalizedError {
    case invalidKey
    case rawValueNotEditable

    var errorDescription: String? {
        switch self {
        case .invalidKey: "Property names may contain letters, numbers, underscores, and hyphens."
        case .rawValueNotEditable: "This complex YAML value must be edited in source mode."
        }
    }
}

enum ObsidianPropertyEditor {
    static func setting(
        key: String,
        value: ObsidianPropertyValue?,
        in markdown: String
    ) throws -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanKey.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ObsidianPropertyEditorError.invalidKey
        }
        if case .raw = value { throw ObsidianPropertyEditorError.rawValueNotEditable }

        let metadata = ObsidianMetadataParser.parse(markdown)
        guard let frontmatter = metadata.frontmatter,
              let sourceRange = Range(frontmatter.sourceRange, in: markdown) else {
            guard let value else { return markdown }
            let newline = markdown.contains("\r\n") ? "\r\n" : "\n"
            return "---\(newline)\(cleanKey): \(try encoded(value))\(newline)---\(newline)" + markdown
        }

        let newline = frontmatter.rawBlock.contains("\r\n") ? "\r\n" : "\n"
        var lines = frontmatter.rawBlock.components(separatedBy: newline)
        guard lines.first == "---" else { return markdown }
        let closingIndex = lines.indices.dropFirst().first(where: {
            lines[$0] == "---" || lines[$0] == "..."
        }) ?? max(1, lines.count - 1)

        var propertyStart: Int?
        for index in 1..<closingIndex {
            let line = lines[index]
            guard line.first?.isWhitespace != true,
                  let colon = line.firstIndex(of: ":") else { continue }
            let existingKey = line[..<colon].trimmingCharacters(in: .whitespaces)
            if existingKey.caseInsensitiveCompare(cleanKey) == .orderedSame {
                propertyStart = index
                break
            }
        }

        if let propertyStart {
            var propertyEnd = propertyStart + 1
            while propertyEnd < closingIndex {
                let line = lines[propertyEnd]
                if line.first?.isWhitespace != true,
                   line.first != "#",
                   line.contains(":") {
                    break
                }
                propertyEnd += 1
            }
            lines.removeSubrange(propertyStart..<propertyEnd)
            if let value {
                lines.insert("\(cleanKey): \(try encoded(value))", at: propertyStart)
            }
        } else if let value {
            lines.insert("\(cleanKey): \(try encoded(value))", at: closingIndex)
        }

        var updated = markdown
        updated.replaceSubrange(sourceRange, with: lines.joined(separator: newline))
        return updated
    }

    private static func encoded(_ value: ObsidianPropertyValue) throws -> String {
        switch value {
        case .string(let value):
            return quote(value)
        case .strings(let values):
            return "[" + values.map(quote).joined(separator: ", ") + "]"
        case .boolean(let value):
            return value ? "true" : "false"
        case .number(let value):
            return String(value)
        case .null:
            return "null"
        case .raw:
            throw ObsidianPropertyEditorError.rawValueNotEditable
        }
    }

    private static func quote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}
