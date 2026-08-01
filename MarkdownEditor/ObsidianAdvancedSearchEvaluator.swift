import Foundation

enum ObsidianAdvancedSearchEvaluator {
    static func search(_ entries: [NoteSearchEntry], query source: String) -> [NoteSearchResult] {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Workspace.search(entries, query: "") }
        if let plainText = ObsidianAdvancedSearchParser.plainTextQuery(in: trimmed) {
            return Workspace.search(entries, query: plainText)
        }

        let query = ObsidianAdvancedSearchParser.parse(trimmed)
        guard !query.isEmpty else { return Workspace.search(entries, query: trimmed) }

        var results: [NoteSearchResult] = []
        for entry in entries {
            guard !Task.isCancelled else { return [] }
            let metadata = entry.searchMetadata
                ?? ObsidianMetadataParser.searchMetadata(in: entry.body)
            guard query.groups.contains(where: { group in
                group.terms.allSatisfy { term in
                    let matches = matches(term.predicate, entry: entry, metadata: metadata)
                    return term.isExcluded ? !matches : matches
                }
            }) else { continue }

            let snippetTerm = query.groups
                .flatMap(\.terms)
                .first(where: { !$0.isExcluded && isTextPredicate($0.predicate) })
            let snippetQuery = snippetTerm.flatMap { term -> String? in
                guard case .text(let value, _) = term.predicate else { return nil }
                return value
            }
            if let snippetQuery,
               entry.bodyStorage.foldedText.contains(Workspace.foldedForSearch(snippetQuery)) {
                results.append(
                    NoteSearchResult(
                        id: entry.id,
                        url: entry.url,
                        title: entry.title,
                        fallbackSubtitle: entry.relativePath,
                        snippetSource: NoteSearchSnippetSource(
                            bodyStorage: entry.bodyStorage,
                            query: snippetQuery
                        ),
                        isBodyMatch: true
                    )
                )
            } else {
                results.append(
                    NoteSearchResult(
                        id: entry.id,
                        url: entry.url,
                        title: entry.title,
                        subtitle: entry.relativePath,
                        isBodyMatch: false
                    )
                )
            }
        }
        return results
    }

    private static func matches(
        _ predicate: ObsidianSearchPredicate,
        entry: NoteSearchEntry,
        metadata: ObsidianSearchMetadata
    ) -> Bool {
        switch predicate {
        case .text(let value, _):
            return contains(value, in: entry.title)
                || contains(value, in: entry.relativePath ?? "")
                || contains(value, in: entry.body)
        case .file(let value, _):
            return contains(value, in: entry.title)
                || contains(value, in: entry.url.lastPathComponent)
        case .path(let value, _):
            return contains(value, in: entry.relativePath ?? entry.url.path)
        case .tag(let value, _):
            return metadata.tags.contains { tag in
                contains(value, in: tag)
            }
        case .property(let name, let value, _):
            guard let property = metadata.properties.first(where: {
                $0.key.caseInsensitiveCompare(name) == .orderedSame
            })?.value else { return false }
            guard let value else { return true }
            return contains(value, in: propertyText(property))
        case .task(let state):
            return matchesTask(state, body: entry.body)
        }
    }

    private static func matchesTask(_ state: ObsidianTaskSearchState, body: String) -> Bool {
        let lines = body.components(separatedBy: .newlines)
        switch state {
        case .any:
            return lines.contains(where: { taskState(in: $0) != nil })
        case .open:
            return lines.contains(where: { taskState(in: $0) == false })
        case .done:
            return lines.contains(where: { taskState(in: $0) == true })
        case .text(let value):
            return lines.contains { line in
                taskState(in: line) != nil && contains(value, in: line)
            }
        }
    }

    private static func taskState(in line: String) -> Bool? {
        let pattern = #"^\s*[-*+]\s+\[([ xX])\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: line,
                range: NSRange(location: 0, length: (line as NSString).length)
              ),
              match.numberOfRanges > 1 else { return nil }
        let marker = (line as NSString).substring(with: match.range(at: 1))
        return marker.lowercased() == "x"
    }

    private static func propertyText(_ value: ObsidianPropertyValue) -> String {
        switch value {
        case .string(let value): value
        case .strings(let values): values.joined(separator: " ")
        case .boolean(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .null: "null"
        case .raw(let value): value
        }
    }

    private static func contains(_ needle: String, in haystack: String) -> Bool {
        haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }

    private static func isTextPredicate(_ predicate: ObsidianSearchPredicate) -> Bool {
        if case .text = predicate { return true }
        return false
    }
}
