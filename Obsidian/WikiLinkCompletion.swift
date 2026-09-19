import Foundation

enum WikiLinkCompletion {
    static func partialRange(in text: String, selection: NSRange) -> NSRange? {
        let nsText = text as NSString
        guard selection.length == 0,
              selection.location <= nsText.length else { return nil }

        let prefixRange = NSRange(location: 0, length: selection.location)
        let openingRange = nsText.range(of: "[[", options: .backwards, range: prefixRange)
        guard openingRange.location != NSNotFound else { return nil }

        let start = NSMaxRange(openingRange)
        let length = selection.location - start
        let partialRange = NSRange(location: start, length: length)
        let partial = nsText.substring(with: partialRange)
        guard !partial.contains("]"), !partial.contains("\n") else { return nil }
        return partialRange
    }

    static func suggestions(
        for partial: String,
        candidates: [String],
        limit: Int = 20
    ) -> [String] {
        let query = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let foldedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)

        return candidates
            .filter { candidate in
                foldedQuery.isEmpty || candidate.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: nil
                ).contains(foldedQuery)
            }
            .sorted { lhs, rhs in
                let leftStarts = lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .hasPrefix(foldedQuery)
                let rightStarts = rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    .hasPrefix(foldedQuery)
                if leftStarts != rightStarts { return leftStarts }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 + "]]" }
    }
}
