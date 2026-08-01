import Foundation

/// Immutable note text shared by the metadata cache, maintained search index,
/// palette snapshots, and lazy result snippets. `String` is copy-on-write, but
/// an explicit reference makes that sharing durable as arrays and dictionaries
/// are reconciled during iCloud bursts.
final class SearchableNoteBody: Sendable {
    let text: String
    let foldedText: String

    init(_ text: String) {
        self.text = text
        self.foldedText = Workspace.foldedForSearch(text)
    }
}

/// A self-contained, `Sendable` index record. Small title/path strings are
/// values; the complete note body is shared through `SearchableNoteBody`.
struct NoteSearchEntry: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let relativePath: String?
    let bodyStorage: SearchableNoteBody
    let foldedTitle: String
    let foldedTitleHaystack: String
    var searchMetadata: ObsidianSearchMetadata? = nil

    var body: String { bodyStorage.text }

    init(
        id: URL,
        url: URL,
        title: String,
        relativePath: String?,
        body: String,
        foldedTitle: String,
        foldedTitleHaystack: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) {
        self.init(
            id: id,
            url: url,
            title: title,
            relativePath: relativePath,
            bodyStorage: SearchableNoteBody(body),
            foldedTitle: foldedTitle,
            foldedTitleHaystack: foldedTitleHaystack,
            searchMetadata: searchMetadata
        )
    }

    init(
        id: URL,
        url: URL,
        title: String,
        relativePath: String?,
        bodyStorage: SearchableNoteBody,
        foldedTitle: String,
        foldedTitleHaystack: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.relativePath = relativePath
        self.bodyStorage = bodyStorage
        self.foldedTitle = foldedTitle
        self.foldedTitleHaystack = foldedTitleHaystack
        self.searchMetadata = searchMetadata
    }
}

/// A snippet recipe rather than an eagerly allocated snippet. SwiftUI's lazy
/// result rows ask for `subtitle` only when they are rendered.
final class NoteSearchSnippetSource: @unchecked Sendable {
    let bodyStorage: SearchableNoteBody
    let query: String
    private let lock = NSLock()
    private var cachedSnippet: String?
    private var hasComputedSnippet = false

    init(bodyStorage: SearchableNoteBody, query: String) {
        self.bodyStorage = bodyStorage
        self.query = query
    }

    var isMaterialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasComputedSnippet
    }

    func snippet() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if hasComputedSnippet {
            return cachedSnippet
        }
        cachedSnippet = Workspace.searchSnippet(in: bodyStorage.text, query: query)
        hasComputedSnippet = true
        return cachedSnippet
    }
}

struct NoteSearchResult: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let fallbackSubtitle: String?
    let snippetSource: NoteSearchSnippetSource?
    let isBodyMatch: Bool

    var subtitle: String? {
        guard let snippetSource else { return fallbackSubtitle }
        return snippetSource.snippet() ?? fallbackSubtitle
    }

    init(
        id: URL,
        url: URL,
        title: String,
        subtitle: String?,
        isBodyMatch: Bool
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.fallbackSubtitle = subtitle
        self.snippetSource = nil
        self.isBodyMatch = isBodyMatch
    }

    init(
        id: URL,
        url: URL,
        title: String,
        fallbackSubtitle: String?,
        snippetSource: NoteSearchSnippetSource,
        isBodyMatch: Bool
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.fallbackSubtitle = fallbackSubtitle
        self.snippetSource = snippetSource
        self.isBodyMatch = isBodyMatch
    }
}

/// Main-actor-owned, incrementally reconciled search index. Unchanged records
/// retain their body storage and parsed advanced-search metadata. Add/change/
/// rename/delete operations only replace the affected dictionary entries.
struct NoteSearchIndex: Sendable {
    private var recordsByPath: [String: NoteSearchEntry] = [:]
    private var orderedPaths: [String] = []

    var count: Int { recordsByPath.count }

    var entries: [NoteSearchEntry] {
        orderedPaths.compactMap { recordsByPath[$0] }
    }

    @discardableResult
    mutating func reconcile(_ candidates: [NoteSearchEntry]) -> Bool {
        let candidatePaths = candidates.map { Self.key(for: $0.url) }
        var nextRecords: [String: NoteSearchEntry] = [:]
        nextRecords.reserveCapacity(candidates.count)
        var didChange = candidatePaths != orderedPaths || candidates.count != recordsByPath.count

        for (path, candidate) in zip(candidatePaths, candidates) {
            if let existing = recordsByPath[path], Self.canReuse(existing, for: candidate) {
                nextRecords[path] = existing
            } else {
                nextRecords[path] = candidate
                didChange = true
            }
        }

        recordsByPath = nextRecords
        orderedPaths = candidatePaths
        return didChange
    }

    mutating func removeAll() -> Bool {
        guard !recordsByPath.isEmpty || !orderedPaths.isEmpty else { return false }
        recordsByPath.removeAll(keepingCapacity: false)
        orderedPaths.removeAll(keepingCapacity: false)
        return true
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func canReuse(_ existing: NoteSearchEntry, for candidate: NoteSearchEntry) -> Bool {
        existing.id == candidate.id
            && existing.url == candidate.url
            && existing.title == candidate.title
            && existing.relativePath == candidate.relativePath
            && existing.foldedTitle == candidate.foldedTitle
            && existing.foldedTitleHaystack == candidate.foldedTitleHaystack
            && existing.bodyStorage === candidate.bodyStorage
    }
}
