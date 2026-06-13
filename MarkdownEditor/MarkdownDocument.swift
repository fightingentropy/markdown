import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let url: URL
    let modificationDate: Date
    let noteTitle: String?

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    var sidebarTitle: String {
        noteTitle ?? displayName
    }
}

struct SidebarNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
    }

    let id: URL
    let url: URL
    let name: String
    let kind: Kind
    let modificationDate: Date
    var children: [SidebarNode] = []

    var isFolder: Bool {
        kind == .folder
    }
}

enum SortOrder: String, Sendable {
    case byName
    case byDate
}

enum ItemRenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case nameAlreadyExists

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a name."
        case .invalidName:
            "Names can't contain slashes, colons, or line breaks."
        case .nameAlreadyExists:
            "An item with that name already exists."
        }
    }
}

private let markdownFileExtensions: Set<String> = ["md", "markdown", "mdown"]
private let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp"]

struct CachedMarkdownMetadata: Sendable {
    let modificationDate: Date
    let noteTitle: String?
    let noteLinks: [NoteLinkReference]
    let noteBody: String
}

/// Describes an unreconciled external modification: the file on disk changed
/// since we last loaded/saved it and its contents differ from the editor
/// buffer. Carries snapshots so resolution is correct even if the user has
/// navigated to another file in the meantime.
struct SaveConflict: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let fileName: String
    let onDiskContent: String
    let editorContent: String
}

/// A self-contained, `Sendable` snapshot of one note used for full-text
/// command-palette search. Folded (case- and diacritic-insensitive) haystacks
/// are precomputed once so per-keystroke filtering is a cheap substring test
/// instead of a locale-aware scan over every file body on every render.
struct NoteSearchEntry: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let relativePath: String?
    let body: String
    fileprivate let foldedTitleHaystack: String
}

/// Result of a search pass. `Sendable` so the filtering can run off the main
/// actor and the result handed back to the view.
struct NoteSearchResult: Sendable, Identifiable {
    let id: URL
    let url: URL
    let title: String
    let subtitle: String?
    let isBodyMatch: Bool
}

@Observable
@MainActor
final class Workspace {
    var files: [FileItem] = []
    var sidebarNodes: [SidebarNode] = []
    var selectedFileURL: URL?
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            scheduleNoteGraphRefresh()
        }
    }
    var noteGraph: NoteGraphSnapshot = .empty
    var vaultURL: URL?
    var sortOrder: SortOrder {
        didSet {
            guard oldValue != sortOrder else { return }
            persistSortOrder()
            guard vaultURL != nil else { return }
            refreshFiles()
        }
    }
    var isCommandPalettePresented = false
    var isLoadingSnapshot = false

    /// Set when a save fails (disk full, permissions, unmounted volume, …) so
    /// the UI can surface it instead of silently dropping the user's edits. The
    /// in-memory `text` is preserved so a later save can recover the content.
    var saveError: String?
    /// Set when the file changed on disk since we last read/wrote it, so we can
    /// ask the user how to resolve instead of clobbering the external edits.
    var saveConflict: SaveConflict?

    var hasVault: Bool { vaultURL != nil }
    var selectedFileIsMarkdown: Bool {
        guard let selectedFileURL else { return false }
        return Self.isMarkdownFile(selectedFileURL)
    }

    var selectedFileIsImage: Bool {
        guard let selectedFileURL else { return false }
        return Self.isImageFile(selectedFileURL)
    }

    var selectedFileName: String {
        guard let selectedFileURL else { return "" }
        if let selected = fileItem(for: selectedFileURL) {
            return title(for: selected)
        }
        if let node = sidebarNode(for: selectedFileURL) {
            return node.name
        }
        return selectedFileURL.deletingPathExtension().lastPathComponent
    }

    var sortedFiles: [FileItem] { files }
    var assetLookupSnapshot: [String: [URL]] { assetLookupByFilename }

    private static let bookmarkKey = "vaultBookmark"
    private static let editorSelectionKeyPrefix = "editorSelection::"
    private static let noteGraphDebounceNanoseconds: UInt64 = 250_000_000
    private let preferences: AppPreferences
    private var activeSecurityScopedVaultURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var snapshotLoadTask: Task<Void, Never>?
    private var noteGraphRefreshTask: Task<Void, Never>?
    private var snapshotGeneration = 0
    private var cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata] = [:]
    private var assetLookupByFilename: [String: [URL]] = [:]
    private var pendingEditorSelectionsByKey: [String: [Int]] = [:]
    private var editorSelectionPersistTasksByKey: [String: Task<Void, Never>] = [:]

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
        self.sortOrder = preferences.defaultSortOrder
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            restoreVault(from: data)
        }
    }

    // MARK: - Vault Management

    func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder for your markdown files"
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(url)
    }

    func openVault(_ url: URL) {
        beginAccessingVault(url)
        persistVaultBookmark(for: url)
        vaultURL = url
        restoreSortOrder()
        files = []
        sidebarNodes = []
        selectedFileURL = nil
        text = ""
        noteGraph = .empty
        cachedMarkdownMetadataByPath = [:]
        assetLookupByFilename = [:]
        refreshFilesInBackground(
            preferredSelectionURL: restoreSelectedFileURL(),
            selectFirstFileIfNeeded: true
        )
    }

    private func restoreVault(from bookmarkData: Data) {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        beginAccessingVault(url)
        vaultURL = url
        restoreSortOrder()

        if isStale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }

        files = []
        sidebarNodes = []
        selectedFileURL = nil
        text = ""
        noteGraph = .empty
        cachedMarkdownMetadataByPath = [:]
        assetLookupByFilename = [:]
        refreshFilesInBackground(
            preferredSelectionURL: restoreSelectedFileURL(),
            selectFirstFileIfNeeded: true
        )
    }

    // MARK: - File Operations

    func refreshFiles() {
        snapshotLoadTask?.cancel()
        snapshotGeneration += 1
        isLoadingSnapshot = false

        guard let vaultURL else {
            files = []
            sidebarNodes = []
            cachedMarkdownMetadataByPath = [:]
            assetLookupByFilename = [:]
            noteGraph = .empty
            return
        }

        let snapshot = Self.snapshotDirectory(
            at: vaultURL,
            sortOrder: sortOrder,
            cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath
        )
        cachedMarkdownMetadataByPath = snapshot.markdownMetadataByPath
        assetLookupByFilename = snapshot.assetLookupByFilename
        files = snapshot.files
        sidebarNodes = snapshot.nodes

        if let selectedFileURL {
            if let matchingURL = matchingSidebarURL(for: selectedFileURL) {
                self.selectedFileURL = matchingURL
            } else {
                self.selectedFileURL = nil
                text = ""
                clearStoredSelectedFileURL()
            }
        }

        refreshNoteGraph()
    }

    func selectFile(_ url: URL) {
        let canonicalURL = matchingSidebarURL(for: url) ?? url
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, canonicalURL) {
            return
        }

        saveCurrentFile()
        if Self.isMarkdownFile(canonicalURL), let content = readFile(canonicalURL) {
            let normalizedContent = Self.normalizedContent(
                for: canonicalURL,
                content: content,
                persistIfMissingTitle: true
            )
            selectedFileURL = canonicalURL
            text = normalizedContent
            persistSelectedFileURL(canonicalURL)
            updateCachedMetadata(for: canonicalURL, content: normalizedContent)
        } else {
            selectedFileURL = canonicalURL
            text = ""
            persistSelectedFileURL(canonicalURL)
        }
    }

    private func readFile(_ url: URL) -> String? {
        Self.readFileContents(url)
    }

    func saveCurrentFile() {
        autosaveTask?.cancel()
        guard let url = selectedFileURL else { return }
        guard Self.isMarkdownFile(url) else { return }
        // While a conflict alert is pending, don't keep re-writing/re-prompting.
        guard saveConflict == nil else { return }
        writeBuffer(text, to: url)
    }

    /// Writes `content` to `url`, but first guards against clobbering an
    /// external modification, and surfaces (rather than swallows) write errors.
    private func writeBuffer(_ content: String, to url: URL) {
        let key = Self.metadataCacheKey(for: url.standardizedFileURL)
        // Read the on-disk date via FileManager rather than URL.resourceValues:
        // URL caches resource values per instance, which would mask an external
        // modification made after we first read the file.
        let currentDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let knownDate = cachedMarkdownMetadataByPath[key]?.modificationDate,
           let currentDate,
           // 1s tolerance absorbs filesystem timestamp granularity and our own
           // just-written timestamp; anything beyond that is an external write.
           currentDate.timeIntervalSince(knownDate) > 1.0,
           let diskContent = Self.readFileContents(url),
           diskContent != content {
            saveConflict = SaveConflict(
                url: url,
                fileName: url.lastPathComponent,
                onDiskContent: diskContent,
                editorContent: content
            )
            return
        }

        do {
            try Data(content.utf8).write(to: url, options: .atomic)
            saveError = nil
            updateCachedMetadata(for: url, content: content)
        } catch {
            saveError = "Couldn\u{2019}t save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Conflict resolution: overwrite the on-disk file with the editor buffer.
    func resolveSaveConflictKeepingMine() {
        guard let conflict = saveConflict else { return }
        saveConflict = nil
        do {
            try Data(conflict.editorContent.utf8).write(to: conflict.url, options: .atomic)
            saveError = nil
            updateCachedMetadata(for: conflict.url, content: conflict.editorContent)
        } catch {
            saveError = "Couldn\u{2019}t save \(conflict.fileName): \(error.localizedDescription)"
        }
    }

    /// Conflict resolution: discard the editor buffer and adopt the on-disk
    /// version (loading it into the editor if it is still the selected file).
    func resolveSaveConflictUsingDisk() {
        guard let conflict = saveConflict else { return }
        saveConflict = nil
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, conflict.url) {
            text = conflict.onDiskContent
        }
        updateCachedMetadata(for: conflict.url, content: conflict.onDiskContent)
    }

    func scheduleAutosave() {
        guard selectedFileIsMarkdown else { return }

        autosaveTask?.cancel()
        let delayNanoseconds = UInt64(preferences.autosaveDelaySeconds * 1_000_000_000)
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.saveCurrentFile()
        }
    }

    func createNewFile(in directoryURL: URL? = nil) {
        if let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) {
            let fileURL = uniqueMarkdownFileURL(in: destinationDirectoryURL)
            let name = fileURL.deletingPathExtension().lastPathComponent
            let content = Data("# \(name)\n\n".utf8)

            guard (try? content.write(to: fileURL, options: .atomic)) != nil else {
                if directoryURL == nil {
                    presentStandaloneFileSavePanel()
                }
                return
            }

            refreshFiles()
            selectFile(fileURL)
            return
        }

        presentStandaloneFileSavePanel()
    }

    func deleteItem(_ url: URL) {
        let itemURL = matchingSidebarURL(for: url) ?? url.resolvingSymlinksInPath().standardizedFileURL
        let isDirectory = isDirectoryURL(itemURL)
        let editorSelectionKeysToClear = editorSelectionKeys(forDeletedItemAt: itemURL, isDirectory: isDirectory)
        let shouldClearSelectedFile = selectedFileURL.map {
            deletedItem(itemURL, isDirectory: isDirectory, contains: $0)
        } ?? false

        guard (try? FileManager.default.trashItem(at: itemURL, resultingItemURL: nil)) != nil else {
            return
        }

        clearStoredEditorSelections(forKeys: editorSelectionKeysToClear)

        if shouldClearSelectedFile {
            text = ""
            self.selectedFileURL = nil
            clearStoredSelectedFileURL()
        }

        refreshFiles()
    }

    func importDroppedFile(_ url: URL) {
        openRequestedFiles([url])
    }

    func openRequestedFiles(_ urls: [URL]) {
        guard let url = urls
            .map({ $0.resolvingSymlinksInPath().standardizedFileURL })
            .first(where: { Self.isMarkdownFile($0) || Self.isImageFile($0) }) else {
            return
        }

        // If the file already lives inside the open vault, just select it.
        // Replacing the whole vault (tearing down the sidebar, file index, and
        // selection) is jarring and unnecessary for an in-vault file.
        if let vaultURL,
           url.standardizedFileURL.path.hasPrefix(vaultURL.standardizedFileURL.path + "/") {
            selectFile(url)
            return
        }

        saveCurrentFile()

        let parentURL = url.deletingLastPathComponent()
        beginAccessingVault(parentURL)
        persistVaultBookmark(for: parentURL)

        vaultURL = parentURL
        restoreSortOrder()

        if Self.isMarkdownFile(url), let content = readFile(url) {
            let normalizedContent = Self.normalizedContent(
                for: url,
                content: content,
                persistIfMissingTitle: true
            )
            ensureOpenedFileIsVisible(at: url, markdownContent: normalizedContent)
            text = normalizedContent
        } else {
            ensureOpenedFileIsVisible(at: url, markdownContent: nil)
            text = ""
        }

        selectedFileURL = url
        persistSelectedFileURL(url)
        refreshFilesInBackground(preferredSelectionURL: url, selectFirstFileIfNeeded: false)
    }

    func createNewFolder(in directoryURL: URL? = nil) {
        guard let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) else {
            pickVault()
            return
        }

        let folderURL = uniqueFolderURL(in: destinationDirectoryURL)
        guard (try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)) != nil else {
            return
        }

        refreshFiles()
    }

    @discardableResult
    func moveItem(_ url: URL, toFolder directoryURL: URL?) -> Bool {
        guard let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) else {
            return false
        }

        let sourceURL = matchingSidebarURL(for: url) ?? url.resolvingSymlinksInPath().standardizedFileURL
        let standardizedSourceURL = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        let standardizedDestinationDirectoryURL = destinationDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let currentParentURL = standardizedSourceURL.deletingLastPathComponent()

        guard standardizedSourceURL != standardizedDestinationDirectoryURL else {
            return false
        }

        guard currentParentURL != standardizedDestinationDirectoryURL else {
            return false
        }

        guard !isDescendant(standardizedDestinationDirectoryURL, of: standardizedSourceURL, allowEqual: true) else {
            return false
        }

        let destinationURL = standardizedDestinationDirectoryURL.appendingPathComponent(
            standardizedSourceURL.lastPathComponent,
            isDirectory: isDirectoryURL(standardizedSourceURL)
        )

        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return false
        }

        let isSelectedFile = selectedFileURL.map { Self.urlsMatch($0, standardizedSourceURL) } ?? false
        if isSelectedFile, Self.isMarkdownFile(standardizedSourceURL) {
            saveCurrentFile()
        }

        guard (try? FileManager.default.moveItem(at: standardizedSourceURL, to: destinationURL)) != nil else {
            return false
        }

        if isSelectedFile {
            selectedFileURL = destinationURL
            persistSelectedFileURL(destinationURL)
        }

        moveStoredEditorSelection(from: standardizedSourceURL, to: destinationURL)
        refreshFiles()
        return true
    }

    @discardableResult
    func renameItem(_ url: URL, to newName: String) throws -> URL {
        let newURL = try validatedRenamedURL(for: url, proposedName: newName)
        guard newURL != url else { return url }

        let isSelectedFile = selectedFileURL.map { Self.urlsMatch($0, url) } ?? false
        let existingContent = Self.isMarkdownFile(url)
            ? (isSelectedFile ? text : readFile(url))
            : nil

        if isSelectedFile {
            saveCurrentFile()
        }

        try moveItemForRename(at: url, to: newURL)

        if let existingContent {
            let updatedContent = contentAfterRename(
                oldURL: url,
                newURL: newURL,
                existingContent: existingContent
            )

            if updatedContent != existingContent {
                try Data(updatedContent.utf8).write(to: newURL, options: .atomic)
            }

            if isSelectedFile {
                text = updatedContent
            }
        }

        if isSelectedFile {
            selectedFileURL = newURL
            persistSelectedFileURL(newURL)
        }

        moveStoredEditorSelection(from: url, to: newURL)

        refreshFiles()
        return newURL
    }

    func persistEditorSelection(_ selection: NSRange, for url: URL?) {
        guard let url else { return }

        let storageKey = editorSelectionStorageKey(for: url)
        let sanitizedSelection = [max(0, selection.location), max(0, selection.length)]
        pendingEditorSelectionsByKey[storageKey] = sanitizedSelection
        editorSelectionPersistTasksByKey[storageKey]?.cancel()
        editorSelectionPersistTasksByKey[storageKey] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            guard self.pendingEditorSelectionsByKey[storageKey] == sanitizedSelection else { return }
            UserDefaults.standard.set(sanitizedSelection, forKey: storageKey)
            self.pendingEditorSelectionsByKey.removeValue(forKey: storageKey)
            self.editorSelectionPersistTasksByKey.removeValue(forKey: storageKey)
        }
    }

    func editorSelection(for url: URL?) -> NSRange? {
        guard let url else {
            return nil
        }

        let storageKey = editorSelectionStorageKey(for: url)
        let persistedSelection = (pendingEditorSelectionsByKey[storageKey] ?? UserDefaults.standard.array(forKey: storageKey) as? [Int]) ?? []
        guard persistedSelection.count == 2 else {
            return nil
        }

        return NSRange(
            location: max(0, persistedSelection[0]),
            length: max(0, persistedSelection[1])
        )
    }

    func title(for file: FileItem) -> String {
        if let selectedFileURL, Self.urlsMatch(file.url, selectedFileURL),
           let liveTitle = Self.extractTitle(from: text) {
            return liveTitle
        }
        return file.sidebarTitle
    }

    func fileItem(for url: URL) -> FileItem? {
        files.first(where: { Self.urlsMatch($0.url, url) })
    }

    func relativePath(for file: FileItem) -> String? {
        guard let vaultURL else {
            return file.name == file.displayName ? nil : file.name
        }

        let basePath = vaultURL.standardizedFileURL.path
        let filePath = file.url.standardizedFileURL.path
        guard filePath.hasPrefix(basePath) else {
            return file.name == file.displayName ? nil : file.name
        }

        let separatorAdjustedBase = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let relativePath = String(filePath.dropFirst(separatorAdjustedBase.count))
        return relativePath == file.name && file.name == file.displayName ? nil : relativePath
    }

    nonisolated static func extractTitle(from content: String) -> String? {
        let text = content as NSString
        guard text.length > 0 else { return nil }

        func isWhitespace(_ character: unichar) -> Bool {
            character == 32 || character == 9
        }

        func isNewline(_ character: unichar) -> Bool {
            character == 10 || character == 13
        }

        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            var start = lineRange.location
            var end = NSMaxRange(lineRange)

            while end > start, isNewline(text.character(at: end - 1)) {
                end -= 1
            }

            while start < end, isWhitespace(text.character(at: start)) {
                start += 1
            }

            while end > start, isWhitespace(text.character(at: end - 1)) {
                end -= 1
            }

            guard start < end else {
                location = NSMaxRange(lineRange)
                continue
            }

            guard text.character(at: start) == 35 else { return nil }

            while start < end, text.character(at: start) == 35 {
                start += 1
            }

            while start < end, isWhitespace(text.character(at: start)) {
                start += 1
            }

            while end > start, isWhitespace(text.character(at: end - 1)) {
                end -= 1
            }

            guard start < end else { return nil }
            return text.substring(with: NSRange(location: start, length: end - start))
        }

        return nil
    }

    private func refreshNoteGraph() {
        noteGraphRefreshTask?.cancel()
        noteGraphRefreshTask = nil
        noteGraph = NoteGraphBuilder.makeSnapshot(
            files: files,
            metadataByPath: cachedMarkdownMetadataByPath,
            vaultURL: vaultURL,
            selectedFileURL: selectedFileURL,
            liveSelectedMarkdown: selectedFileIsMarkdown ? text : nil
        )
    }

    private func scheduleNoteGraphRefresh() {
        noteGraphRefreshTask?.cancel()
        noteGraphRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.noteGraphDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.refreshNoteGraph()
        }
    }

    /// Best-effort body lookup for a file URL, used by full-text search.
    /// Returns the live editor contents when the URL is the selected file
    /// so search reflects unsaved edits.
    func noteBody(for url: URL) -> String? {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        if let selectedFileURL,
           Self.urlsMatch(selectedFileURL, standardized),
           selectedFileIsMarkdown {
            return text
        }
        let key = Self.metadataCacheKey(for: standardized)
        return cachedMarkdownMetadataByPath[key]?.noteBody
    }

    /// Builds a `Sendable` search index for the current vault. Called once when
    /// the command palette opens; the resulting array can be filtered repeatedly
    /// (and off the main actor) without touching `Workspace` state again.
    func makeSearchEntries() -> [NoteSearchEntry] {
        files.map { file in
            let title = title(for: file)
            let haystack = "\(title)\n\(file.displayName)\n\(file.name)"
            return NoteSearchEntry(
                id: file.id,
                url: file.url,
                title: title,
                relativePath: relativePath(for: file),
                body: noteBody(for: file.url) ?? "",
                foldedTitleHaystack: Self.foldedForSearch(haystack)
            )
        }
    }

    nonisolated static func foldedForSearch(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Pure, `nonisolated` full-text filter so it can run inside a detached task
    /// for large vaults. Title/name matches rank above body matches; body
    /// matches carry a centered snippet for context.
    nonisolated static func search(_ entries: [NoteSearchEntry], query rawQuery: String) -> [NoteSearchResult] {
        let trimmedQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return entries.map {
                NoteSearchResult(id: $0.id, url: $0.url, title: $0.title, subtitle: $0.relativePath, isBodyMatch: false)
            }
        }

        let foldedQuery = foldedForSearch(trimmedQuery)
        var titleMatches: [NoteSearchResult] = []
        var bodyMatches: [NoteSearchResult] = []

        for entry in entries {
            if entry.foldedTitleHaystack.contains(foldedQuery) {
                titleMatches.append(
                    NoteSearchResult(id: entry.id, url: entry.url, title: entry.title, subtitle: entry.relativePath, isBodyMatch: false)
                )
            } else if let snippet = searchSnippet(in: entry.body, query: trimmedQuery) {
                bodyMatches.append(
                    NoteSearchResult(id: entry.id, url: entry.url, title: entry.title, subtitle: snippet, isBodyMatch: true)
                )
            }
        }

        return titleMatches + bodyMatches
    }

    /// Returns a single-line, match-centered snippet, or `nil` if `query` is not
    /// present in `body`. Offsets are computed within the trimmed line so the
    /// window stays aligned with the visible text.
    nonisolated static func searchSnippet(in body: String, query: String) -> String? {
        guard !body.isEmpty, !query.isEmpty,
              body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else {
            return nil
        }

        guard let matchRange = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let lineRange = body.lineRange(for: matchRange)
        let trimmedLine = body[lineRange].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return nil }

        let maxLength = 140
        guard trimmedLine.count > maxLength else { return trimmedLine }

        // Re-locate the match inside the trimmed line so the window offsets are
        // consistent with the string we actually slice.
        guard let trimmedMatch = trimmedLine.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) else {
            return String(trimmedLine.prefix(maxLength)) + "\u{2026}"
        }

        let matchOffset = trimmedLine.distance(from: trimmedLine.startIndex, to: trimmedMatch.lowerBound)
        let windowStart = max(0, matchOffset - maxLength / 2)
        let startIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: windowStart)
        let endOffset = min(trimmedLine.count, windowStart + maxLength)
        let endIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: endOffset)
        var snippet = String(trimmedLine[startIndex..<endIndex])

        if startIndex != trimmedLine.startIndex {
            snippet = "\u{2026}" + snippet
        }
        if endIndex != trimmedLine.endIndex {
            snippet += "\u{2026}"
        }
        return snippet
    }


    private func validatedRenamedURL(for url: URL, proposedName: String) throws -> URL {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ItemRenameError.emptyName
        }

        guard trimmedName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else {
            throw ItemRenameError.invalidName
        }

        let pathExtension = url.pathExtension
        var sanitizedName = trimmedName

        if !pathExtension.isEmpty {
            let extensionSuffix = "." + pathExtension
            if sanitizedName.lowercased().hasSuffix(extensionSuffix.lowercased()) {
                sanitizedName.removeLast(extensionSuffix.count)
                sanitizedName = sanitizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !sanitizedName.isEmpty else {
            throw ItemRenameError.emptyName
        }

        let parentURL = url.deletingLastPathComponent()
        let newURL: URL

        if pathExtension.isEmpty {
            newURL = parentURL.appendingPathComponent(sanitizedName)
        } else {
            newURL = parentURL
                .appendingPathComponent(sanitizedName)
                .appendingPathExtension(pathExtension)
        }

        if newURL.standardizedFileURL == url.standardizedFileURL {
            return url
        }

        let isCaseOnlyRename = newURL.standardizedFileURL.path.caseInsensitiveCompare(url.standardizedFileURL.path) == .orderedSame
        if FileManager.default.fileExists(atPath: newURL.path), !isCaseOnlyRename {
            throw ItemRenameError.nameAlreadyExists
        }

        return newURL
    }

    private func contentAfterRename(oldURL: URL, newURL: URL, existingContent: String) -> String {
        let oldDisplayName = oldURL.deletingPathExtension().lastPathComponent
        let newDisplayName = newURL.deletingPathExtension().lastPathComponent
        guard let currentTitle = Self.extractTitle(from: existingContent), currentTitle == oldDisplayName else {
            return existingContent
        }

        return Self.replacingLeadingTitle(in: existingContent, with: newDisplayName)
    }

    private func moveItemForRename(at url: URL, to newURL: URL) throws {
        let standardizedSourceURL = url.standardizedFileURL
        let standardizedDestinationURL = newURL.standardizedFileURL
        let isCaseOnlyRename = standardizedSourceURL.path.caseInsensitiveCompare(standardizedDestinationURL.path) == .orderedSame

        if isCaseOnlyRename, standardizedSourceURL.path != standardizedDestinationURL.path {
            let temporaryURL = uniqueIntermediateRenameURL(for: url)
            try FileManager.default.moveItem(at: url, to: temporaryURL)

            do {
                try FileManager.default.moveItem(at: temporaryURL, to: newURL)
            } catch {
                try? FileManager.default.moveItem(at: temporaryURL, to: url)
                throw error
            }

            return
        }

        try FileManager.default.moveItem(at: url, to: newURL)
    }

    private func uniqueIntermediateRenameURL(for url: URL) -> URL {
        let folderURL = url.deletingLastPathComponent()
        let token = UUID().uuidString
        let baseName = "." + url.deletingPathExtension().lastPathComponent + "-" + token
        let pathExtension = url.pathExtension

        if pathExtension.isEmpty {
            return folderURL.appendingPathComponent(baseName)
        }

        return folderURL
            .appendingPathComponent(baseName)
            .appendingPathExtension(pathExtension)
    }

    private static func replacingLeadingTitle(in content: String, with title: String) -> String {
        var lineStart = content.startIndex

        while lineStart < content.endIndex {
            let lineEnd = content[lineStart...].firstIndex(where: \.isNewline) ?? content.endIndex
            let line = content[lineStart..<lineEnd]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                guard lineEnd < content.endIndex else { return content }
                lineStart = content.index(after: lineEnd)
                continue
            }

            guard trimmed.hasPrefix("#") else {
                return content
            }

            var titleStart = line.startIndex
            while titleStart < line.endIndex, line[titleStart].isWhitespace {
                titleStart = line.index(after: titleStart)
            }
            while titleStart < line.endIndex, line[titleStart] == "#" {
                titleStart = line.index(after: titleStart)
            }
            while titleStart < line.endIndex, line[titleStart].isWhitespace {
                titleStart = line.index(after: titleStart)
            }

            var updatedContent = content
            updatedContent.replaceSubrange(titleStart..<lineEnd, with: title)
            return updatedContent
        }

        return content
    }

    private func updateCachedMetadata(for url: URL, content: String) {
        let standardizedURL = url.standardizedFileURL
        let metadataKey = Self.metadataCacheKey(for: standardizedURL)
        let date = (try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? cachedMarkdownMetadataByPath[metadataKey]?.modificationDate
            ?? Date()
        let noteTitle = Self.extractTitle(from: content)
        let noteLinks = MarkdownNoteLinkExtractor.references(in: content)

        cachedMarkdownMetadataByPath[metadataKey] = CachedMarkdownMetadata(
            modificationDate: date,
            noteTitle: noteTitle,
            noteLinks: noteLinks,
            noteBody: content
        )

        guard let index = files.firstIndex(where: { Self.urlsMatch($0.url, standardizedURL) }) else { return }

        files[index] = FileItem(
            id: standardizedURL,
            name: standardizedURL.lastPathComponent,
            url: standardizedURL,
            modificationDate: date,
            noteTitle: noteTitle
        )
        resortFiles()
        refreshNoteGraph()
    }

    private func refreshFilesInBackground(
        preferredSelectionURL: URL?,
        selectFirstFileIfNeeded: Bool
    ) {
        snapshotLoadTask?.cancel()
        snapshotGeneration += 1

        guard let vaultURL else {
            isLoadingSnapshot = false
            files = []
            sidebarNodes = []
            selectedFileURL = nil
            text = ""
            cachedMarkdownMetadataByPath = [:]
            assetLookupByFilename = [:]
            noteGraph = .empty
            return
        }

        isLoadingSnapshot = true
        let generation = snapshotGeneration
        let sortOrder = sortOrder
        let cachedMarkdownMetadataByPath = cachedMarkdownMetadataByPath

        snapshotLoadTask = Task { [vaultURL] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.snapshotDirectory(
                    at: vaultURL,
                    sortOrder: sortOrder,
                    cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath
                )
            }.value

            guard !Task.isCancelled else { return }
            guard generation == self.snapshotGeneration else { return }
            guard self.vaultURL?.standardizedFileURL == vaultURL.standardizedFileURL else { return }

            self.cachedMarkdownMetadataByPath = snapshot.markdownMetadataByPath
            self.assetLookupByFilename = snapshot.assetLookupByFilename
            self.files = snapshot.files
            self.sidebarNodes = snapshot.nodes

            if let preferredSelectionURL,
               let matchingURL = self.matchingSidebarURL(for: preferredSelectionURL) {
                self.selectFile(matchingURL)
                self.isLoadingSnapshot = false
                return
            }

            if let selectedFileURL {
                if let matchingURL = self.matchingSidebarURL(for: selectedFileURL) {
                    self.selectedFileURL = matchingURL
                } else {
                    self.selectedFileURL = nil
                    self.text = ""
                    self.clearStoredSelectedFileURL()
                }
            } else if selectFirstFileIfNeeded, let first = self.sortedFiles.first {
                self.selectFile(first.url)
            }

            self.refreshNoteGraph()
            self.isLoadingSnapshot = false
        }
    }

    private nonisolated static func snapshotDirectory(
        at directoryURL: URL,
        sortOrder: SortOrder,
        cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata]
    ) -> DirectorySnapshot {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return DirectorySnapshot(nodes: [], files: [], markdownMetadataByPath: [:], assetLookupByFilename: [:])
        }

        var nodes: [SidebarNode] = []
        var files: [FileItem] = []
        var markdownMetadataByPath: [String: CachedMarkdownMetadata] = [:]
        var assetLookupByFilename: [String: [URL]] = [:]

        for url in contents {
            let standardizedURL = url.standardizedFileURL
            let values = try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
            let modificationDate = values?.contentModificationDate ?? .distantPast

            if values?.isDirectory == true {
                let childSnapshot = snapshotDirectory(
                    at: standardizedURL,
                    sortOrder: sortOrder,
                    cachedMarkdownMetadataByPath: cachedMarkdownMetadataByPath
                )
                let childLatestDate = childSnapshot.nodes.map(\.modificationDate).max() ?? modificationDate
                nodes.append(
                    SidebarNode(
                        id: standardizedURL,
                        url: standardizedURL,
                        name: standardizedURL.lastPathComponent,
                        kind: .folder,
                        modificationDate: max(modificationDate, childLatestDate),
                        children: childSnapshot.nodes
                    )
                )
                files.append(contentsOf: childSnapshot.files)
                markdownMetadataByPath.merge(childSnapshot.markdownMetadataByPath) { _, newest in newest }
                mergeAssetLookup(&assetLookupByFilename, with: childSnapshot.assetLookupByFilename)
            } else if Self.isMarkdownFile(standardizedURL) {
                let metadataKey = metadataCacheKey(for: standardizedURL)
                let file = makeFileItem(
                    at: standardizedURL,
                    modificationDate: modificationDate,
                    cachedMetadata: cachedMarkdownMetadataByPath[metadataKey]
                )
                nodes.append(
                    SidebarNode(
                        id: standardizedURL,
                        url: standardizedURL,
                        name: file.file.displayName,
                        kind: .file,
                        modificationDate: file.file.modificationDate
                    )
                )
                files.append(file.file)
                markdownMetadataByPath[metadataKey] = CachedMarkdownMetadata(
                    modificationDate: file.file.modificationDate,
                    noteTitle: file.file.noteTitle,
                    noteLinks: file.noteLinks,
                    noteBody: file.noteBody
                )
                addAssetLookupEntry(for: standardizedURL, to: &assetLookupByFilename)
            } else if Self.isImageFile(standardizedURL) {
                nodes.append(
                    SidebarNode(
                        id: standardizedURL,
                        url: standardizedURL,
                        name: standardizedURL.lastPathComponent,
                        kind: .file,
                        modificationDate: modificationDate
                    )
                )
                addAssetLookupEntry(for: standardizedURL, to: &assetLookupByFilename)
            } else if values?.isRegularFile == true {
                addAssetLookupEntry(for: standardizedURL, to: &assetLookupByFilename)
            }
        }

        return DirectorySnapshot(
            nodes: sortSidebarNodes(nodes, sortOrder: sortOrder),
            files: sortFileItems(files, sortOrder: sortOrder),
            markdownMetadataByPath: markdownMetadataByPath,
            assetLookupByFilename: sortAssetLookup(assetLookupByFilename)
        )
    }

    private nonisolated static func makeFileItem(
        at url: URL,
        modificationDate: Date,
        cachedMetadata: CachedMarkdownMetadata?
    ) -> (file: FileItem, noteLinks: [NoteLinkReference], noteBody: String) {
        let noteTitle: String?
        let noteLinks: [NoteLinkReference]
        let noteBody: String
        if let cachedMetadata, cachedMetadata.modificationDate == modificationDate {
            noteTitle = cachedMetadata.noteTitle
            noteLinks = cachedMetadata.noteLinks
            noteBody = cachedMetadata.noteBody
        } else if let content = readFileContents(url) {
            let normalized = normalizedContent(
                for: url,
                content: content,
                persistIfMissingTitle: false
            )
            noteTitle = Self.extractTitle(from: normalized)
            noteLinks = MarkdownNoteLinkExtractor.references(in: normalized)
            noteBody = normalized
        } else {
            noteTitle = nil
            noteLinks = []
            noteBody = ""
        }

        let file = FileItem(
            id: url,
            name: url.lastPathComponent,
            url: url,
            modificationDate: modificationDate,
            noteTitle: noteTitle
        )

        return (file, noteLinks, noteBody)
    }

    private nonisolated static func sortFileItems(_ files: [FileItem], sortOrder: SortOrder) -> [FileItem] {
        files.sorted { lhs, rhs in
            switch sortOrder {
            case .byName:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .byDate:
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private nonisolated static func metadataCacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private nonisolated static func addAssetLookupEntry(for url: URL, to lookup: inout [String: [URL]]) {
        lookup[url.lastPathComponent, default: []].append(url.standardizedFileURL)
    }

    private nonisolated static func mergeAssetLookup(_ target: inout [String: [URL]], with source: [String: [URL]]) {
        for (fileName, urls) in source {
            target[fileName, default: []].append(contentsOf: urls)
        }
    }

    private nonisolated static func sortAssetLookup(_ lookup: [String: [URL]]) -> [String: [URL]] {
        lookup.mapValues { urls in
            Array(Set(urls)).sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
        }
    }

    private func resortFiles() {
        files = Self.sortFileItems(files, sortOrder: sortOrder)
    }

    private nonisolated static func sortSidebarNodes(_ nodes: [SidebarNode], sortOrder: SortOrder) -> [SidebarNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }

            switch sortOrder {
            case .byName:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .byDate:
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private nonisolated static func normalizedContent(
        for url: URL,
        content: String,
        persistIfMissingTitle: Bool
    ) -> String {
        if Self.extractTitle(from: content) != nil {
            return content
        }

        let trimmedLeadingNewlines = String(content.drop(while: \.isNewline))
        let title = url.deletingPathExtension().lastPathComponent
        let body = trimmedLeadingNewlines.isEmpty ? "" : "\n\n\(trimmedLeadingNewlines)"
        let normalized = "# \(title)\(body)"

        if persistIfMissingTitle, normalized != content {
            try? Data(normalized.utf8).write(to: url, options: .atomic)
        }

        return normalized
    }

    private nonisolated static func readFileContents(_ url: URL) -> String? {
        if let string = decodeFileContents(url) {
            return string
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return decodeFileContents(url)
    }

    /// Decodes a text file, tolerating non-UTF-8 encodings. We try the system's
    /// BOM/heuristic detector first, then UTF-8, UTF-16, and finally ISO-Latin-1
    /// (which maps every byte to a character and so never fails). This prevents
    /// a non-UTF-8 note from appearing empty in the editor and then being
    /// silently overwritten with an empty file on the next save.
    private nonisolated static func decodeFileContents(_ url: URL) -> String? {
        var detectedEncoding = String.Encoding.utf8
        if let string = try? String(contentsOf: url, usedEncoding: &detectedEncoding) {
            return string
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        // NB: we intentionally do NOT try .utf16 here — without a BOM it
        // "succeeds" on arbitrary even-length byte runs and yields garbage.
        // BOM-tagged UTF-16 is already handled by the usedEncoding attempt
        // above; .isoLatin1 maps any byte and so is the safe final fallback.
        for encoding in [String.Encoding.utf8, .isoLatin1] {
            if let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        return nil
    }

    nonisolated static func isMarkdownFile(_ url: URL) -> Bool {
        markdownFileExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        imageFileExtensions.contains(url.pathExtension.lowercased())
    }

    private func matchingSidebarURL(for url: URL) -> URL? {
        matchingSidebarURL(for: url, in: sidebarNodes)
    }

    private func sidebarNode(for url: URL) -> SidebarNode? {
        sidebarNode(for: url, in: sidebarNodes)
    }

    private static func urlsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL == rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    private func ensureOpenedFileIsVisible(at url: URL, markdownContent: String?) {
        let standardizedURL = url.standardizedFileURL
        let modificationDate = (try? standardizedURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        if Self.isMarkdownFile(standardizedURL) {
            let noteTitle = markdownContent.flatMap(Self.extractTitle(from:))
            let noteLinks = markdownContent.map(MarkdownNoteLinkExtractor.references(in:)) ?? []
            cachedMarkdownMetadataByPath[Self.metadataCacheKey(for: standardizedURL)] = CachedMarkdownMetadata(
                modificationDate: modificationDate,
                noteTitle: noteTitle,
                noteLinks: noteLinks,
                noteBody: markdownContent ?? ""
            )

            let fileItem = FileItem(
                id: standardizedURL,
                name: standardizedURL.lastPathComponent,
                url: standardizedURL,
                modificationDate: modificationDate,
                noteTitle: noteTitle
            )

            if let index = files.firstIndex(where: { Self.urlsMatch($0.url, standardizedURL) }) {
                files[index] = fileItem
            } else {
                files.append(fileItem)
            }
            resortFiles()
        }
        updateAssetLookup(for: standardizedURL)

        guard !sidebarContainsNode(for: standardizedURL, in: sidebarNodes) else { return }

        sidebarNodes = Self.sortSidebarNodes(
            sidebarNodes + [
                SidebarNode(
                    id: standardizedURL,
                    url: standardizedURL,
                    name: Self.isMarkdownFile(standardizedURL) ? standardizedURL.deletingPathExtension().lastPathComponent : standardizedURL.lastPathComponent,
                    kind: .file,
                    modificationDate: modificationDate
                )
            ],
            sortOrder: sortOrder
        )
    }

    private func updateAssetLookup(for url: URL) {
        let fileName = url.lastPathComponent
        let standardizedURL = url.standardizedFileURL
        if assetLookupByFilename[fileName]?.contains(standardizedURL) != true {
            assetLookupByFilename[fileName, default: []].append(standardizedURL)
        }
        assetLookupByFilename[fileName]?.sort {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func sidebarContainsNode(for url: URL, in nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in
            Self.urlsMatch(node.url, url) || sidebarContainsNode(for: url, in: node.children)
        }
    }

    private func matchingSidebarURL(for url: URL, in nodes: [SidebarNode]) -> URL? {
        for node in nodes {
            if Self.urlsMatch(node.url, url) {
                return node.url
            }

            if let childMatch = matchingSidebarURL(for: url, in: node.children) {
                return childMatch
            }
        }

        return nil
    }

    private func sidebarNode(for url: URL, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if Self.urlsMatch(node.url, url) {
                return node
            }

            if let childMatch = sidebarNode(for: url, in: node.children) {
                return childMatch
            }
        }

        return nil
    }

    private func destinationDirectoryURL(for requestedDirectoryURL: URL?) -> URL? {
        guard let vaultURL else {
            return nil
        }

        let standardizedVaultURL = vaultURL.resolvingSymlinksInPath().standardizedFileURL

        guard let requestedDirectoryURL else {
            return standardizedVaultURL
        }

        let standardizedRequestedDirectoryURL = requestedDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(standardizedRequestedDirectoryURL, of: standardizedVaultURL, allowEqual: true) else {
            return nil
        }

        guard isDirectoryURL(standardizedRequestedDirectoryURL) else {
            return nil
        }

        return standardizedRequestedDirectoryURL
    }

    private func uniqueMarkdownFileURL(in directoryURL: URL) -> URL {
        let fm = FileManager.default
        var name = "Untitled"
        var counter = 1
        var fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension("md")

        while fm.fileExists(atPath: fileURL.path) {
            name = "Untitled \(counter)"
            counter += 1
            fileURL = directoryURL.appendingPathComponent(name).appendingPathExtension("md")
        }

        return fileURL
    }

    private func uniqueFolderURL(in directoryURL: URL) -> URL {
        let fm = FileManager.default
        var name = "New Folder"
        var counter = 1
        var folderURL = directoryURL.appendingPathComponent(name, isDirectory: true)

        while fm.fileExists(atPath: folderURL.path) {
            counter += 1
            name = "New Folder \(counter)"
            folderURL = directoryURL.appendingPathComponent(name, isDirectory: true)
        }

        return folderURL
    }

    private func presentStandaloneFileSavePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        try? Data("# \(name)\n\n".utf8).write(to: url, options: .atomic)
        importDroppedFile(url)
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func isDescendant(_ url: URL, of parentURL: URL, allowEqual: Bool) -> Bool {
        let standardizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let standardizedParentURL = parentURL.resolvingSymlinksInPath().standardizedFileURL

        if standardizedURL == standardizedParentURL {
            return allowEqual
        }

        let parentPath = standardizedParentURL.path.hasSuffix("/")
            ? standardizedParentURL.path
            : standardizedParentURL.path + "/"
        return standardizedURL.path.hasPrefix(parentPath)
    }

    private func persistVaultBookmark(for url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    private func persistSelectedFileURL(_ url: URL) {
        guard let storageKey = selectedFileStorageKey else { return }
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: storageKey)
    }

    private func moveStoredEditorSelection(from oldURL: URL, to newURL: URL) {
        let defaults = UserDefaults.standard
        let oldKey = editorSelectionStorageKey(for: oldURL)
        let newKey = editorSelectionStorageKey(for: newURL)
        let pendingSelection = pendingEditorSelectionsByKey.removeValue(forKey: oldKey)

        editorSelectionPersistTasksByKey[oldKey]?.cancel()
        editorSelectionPersistTasksByKey.removeValue(forKey: oldKey)
        editorSelectionPersistTasksByKey[newKey]?.cancel()
        editorSelectionPersistTasksByKey.removeValue(forKey: newKey)

        if let pendingSelection {
            pendingEditorSelectionsByKey[newKey] = pendingSelection
            defaults.set(pendingSelection, forKey: newKey)
            pendingEditorSelectionsByKey.removeValue(forKey: newKey)
            defaults.removeObject(forKey: oldKey)
            return
        }

        guard let persistedSelection = defaults.array(forKey: oldKey) else { return }

        defaults.set(persistedSelection, forKey: newKey)
        defaults.removeObject(forKey: oldKey)
    }

    private func restoreSelectedFileURL() -> URL? {
        guard let storageKey = selectedFileStorageKey,
              let path = UserDefaults.standard.string(forKey: storageKey) else {
            return nil
        }

        return URL(fileURLWithPath: path)
    }

    private func clearStoredSelectedFileURL() {
        guard let storageKey = selectedFileStorageKey else { return }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private func editorSelectionKeys(forDeletedItemAt url: URL, isDirectory: Bool) -> [String] {
        guard isDirectory else {
            return [editorSelectionStorageKey(for: url)]
        }

        let defaults = UserDefaults.standard
        let prefix = Self.editorSelectionKeyPrefix
        var keysToRemove: Set<String> = []

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            let storedURL = URL(fileURLWithPath: path)
            if deletedItem(url, isDirectory: true, contains: storedURL) {
                keysToRemove.insert(key)
            }
        }

        for key in pendingEditorSelectionsByKey.keys where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            let storedURL = URL(fileURLWithPath: path)
            if deletedItem(url, isDirectory: true, contains: storedURL) {
                keysToRemove.insert(key)
            }
        }

        return Array(keysToRemove)
    }

    private func clearStoredEditorSelections(forKeys keys: [String]) {
        let defaults = UserDefaults.standard
        for key in keys {
            editorSelectionPersistTasksByKey[key]?.cancel()
            editorSelectionPersistTasksByKey.removeValue(forKey: key)
            pendingEditorSelectionsByKey.removeValue(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    private func deletedItem(_ deletedURL: URL, isDirectory: Bool, contains candidateURL: URL) -> Bool {
        let standardizedCandidateURL = candidateURL.resolvingSymlinksInPath().standardizedFileURL

        if Self.urlsMatch(standardizedCandidateURL, deletedURL) {
            return true
        }

        guard isDirectory else {
            return false
        }

        return isDescendant(standardizedCandidateURL, of: deletedURL, allowEqual: false)
    }

    private func persistSortOrder() {
        guard let storageKey = sortOrderStorageKey else { return }
        UserDefaults.standard.set(sortOrder.rawValue, forKey: storageKey)
    }

    private func restoreSortOrder() {
        guard let storageKey = sortOrderStorageKey,
              let rawValue = UserDefaults.standard.string(forKey: storageKey),
              let restored = SortOrder(rawValue: rawValue) else {
            sortOrder = preferences.defaultSortOrder
            return
        }

        sortOrder = restored
    }

    private var selectedFileStorageKey: String? {
        guard let vaultURL else { return nil }
        return "selectedFile::" + vaultURL.standardizedFileURL.path
    }

    private var sortOrderStorageKey: String? {
        guard let vaultURL else { return nil }
        return "sortOrder::" + vaultURL.standardizedFileURL.path
    }

    private func editorSelectionStorageKey(for url: URL) -> String {
        Self.editorSelectionKeyPrefix + url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func beginAccessingVault(_ url: URL) {
        let standardizedURL = url.standardizedFileURL

        if activeSecurityScopedVaultURL?.standardizedFileURL == standardizedURL {
            return
        }

        if let activeSecurityScopedVaultURL {
            activeSecurityScopedVaultURL.stopAccessingSecurityScopedResource()
        }

        if standardizedURL.startAccessingSecurityScopedResource() {
            activeSecurityScopedVaultURL = standardizedURL
        } else {
            activeSecurityScopedVaultURL = nil
        }
    }

}

private struct DirectorySnapshot: Sendable {
    let nodes: [SidebarNode]
    let files: [FileItem]
    let markdownMetadataByPath: [String: CachedMarkdownMetadata]
    let assetLookupByFilename: [String: [URL]]
}
