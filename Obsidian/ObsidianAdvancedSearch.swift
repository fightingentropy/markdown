import Foundation

enum ObsidianTaskSearchState: Equatable, Sendable {
    case any
    case open
    case done
    case text(String)
}

enum ObsidianSearchPredicate: Equatable, Sendable {
    case text(value: String, quoted: Bool)
    case file(value: String, quoted: Bool)
    case path(value: String, quoted: Bool)
    case tag(value: String, quoted: Bool)
    case property(name: String, value: String?, quoted: Bool)
    case task(ObsidianTaskSearchState)
}

struct ObsidianSearchTerm: Equatable, Sendable {
    let predicate: ObsidianSearchPredicate
    let isExcluded: Bool
}

/// Terms within a group are ANDed. Groups are ORed.
struct ObsidianSearchGroup: Equatable, Sendable {
    let terms: [ObsidianSearchTerm]
}

struct ObsidianAdvancedSearchQuery: Equatable, Sendable {
    let groups: [ObsidianSearchGroup]

    var isEmpty: Bool { groups.allSatisfy(\.terms.isEmpty) }
}

enum ObsidianAdvancedSearchParser {
    static func parse(_ source: String) -> ObsidianAdvancedSearchQuery {
        let tokens = lex(source)
        var groups: [[ObsidianSearchTerm]] = [[]]

        for token in tokens {
            if !token.containsQuotedContent, token.text == "OR" {
                if groups.last?.isEmpty == false {
                    groups.append([])
                }
                continue
            }

            if let term = parseTerm(token) {
                groups[groups.count - 1].append(term)
            }
        }

        let populated = groups.filter { !$0.isEmpty }.map(ObsidianSearchGroup.init(terms:))
        return ObsidianAdvancedSearchQuery(groups: populated)
    }

    /// Returns a normalized phrase when the query contains only ordinary text.
    /// Operators, exclusions, and OR groups return `nil` so the caller can use
    /// the advanced evaluator instead.
    static func plainTextQuery(in source: String) -> String? {
        let query = parse(source)
        guard query.groups.count <= 1 else { return nil }
        guard let group = query.groups.first else {
            return source.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var values: [String] = []
        for term in group.terms {
            guard !term.isExcluded else { return nil }
            guard case .text(let value, _) = term.predicate else { return nil }
            values.append(value)
        }
        return values.joined(separator: " ")
    }

    private struct Token {
        let text: String
        let containsQuotedContent: Bool
    }

    private static func lex(_ source: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var containsQuote = false

        func flush() {
            if !current.isEmpty || containsQuote {
                tokens.append(Token(text: current, containsQuotedContent: containsQuote))
            }
            current = ""
            containsQuote = false
        }

        for character in source {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }

            if character == "\\", quote != nil {
                escaped = true
                continue
            }

            if character == "\"" || character == "'" {
                if quote == character {
                    quote = nil
                } else if quote == nil {
                    quote = character
                } else {
                    current.append(character)
                }
                containsQuote = true
                continue
            }

            if character.isWhitespace, quote == nil {
                flush()
            } else {
                current.append(character)
            }
        }

        if escaped { current.append("\\") }
        flush()
        return tokens
    }

    private static func parseTerm(_ token: Token) -> ObsidianSearchTerm? {
        var value = token.text
        let excluded = value.hasPrefix("-") && value.count > 1
        if excluded { value.removeFirst() }
        guard !value.isEmpty else { return nil }

        guard let colon = value.firstIndex(of: ":") else {
            return ObsidianSearchTerm(
                predicate: .text(value: value, quoted: token.containsQuotedContent),
                isExcluded: excluded
            )
        }

        let field = value[..<colon].lowercased()
        let operand = String(value[value.index(after: colon)...])
        guard !operand.isEmpty else {
            return ObsidianSearchTerm(
                predicate: .text(value: value, quoted: token.containsQuotedContent),
                isExcluded: excluded
            )
        }

        let predicate: ObsidianSearchPredicate
        switch field {
        case "file":
            predicate = .file(value: operand, quoted: token.containsQuotedContent)
        case "path":
            predicate = .path(value: operand, quoted: token.containsQuotedContent)
        case "tag":
            predicate = .tag(value: normalizedTagOperand(operand), quoted: token.containsQuotedContent)
        case "property":
            let parts = operand.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let propertyValue = parts.count == 2 ? String(parts[1]) : nil
            guard !name.isEmpty else {
                predicate = .text(value: value, quoted: token.containsQuotedContent)
                break
            }
            predicate = .property(name: name, value: propertyValue, quoted: token.containsQuotedContent)
        case "task":
            predicate = .task(taskState(for: operand))
        default:
            predicate = .text(value: value, quoted: token.containsQuotedContent)
        }

        return ObsidianSearchTerm(predicate: predicate, isExcluded: excluded)
    }

    private static func normalizedTagOperand(_ operand: String) -> String {
        var value = operand
        while value.hasPrefix("#") { value.removeFirst() }
        return value
    }

    private static func taskState(for operand: String) -> ObsidianTaskSearchState {
        switch operand.lowercased() {
        case "any", "all":
            return .any
        case "todo", "open", "unchecked", "incomplete":
            return .open
        case "done", "checked", "complete", "completed":
            return .done
        default:
            return .text(operand)
        }
    }
}
