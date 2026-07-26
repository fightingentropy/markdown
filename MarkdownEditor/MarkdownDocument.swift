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

/// The result of an explicit or automatic save. Callers that are about to
/// replace the editor buffer should only proceed when `allowsTransition` is
/// true; conflicts and I/O failures deliberately keep the current note open.
enum DocumentSaveResult: Equatable, Sendable {
    case saved
    case noChanges
    case noEditableDocument
    case conflict
    case failed(String)

    var allowsTransition: Bool {
        switch self {
        case .saved, .noChanges, .noEditableDocument:
            true
        case .conflict, .failed:
            false
        }
    }
}

enum WorkspaceFileOperationError: LocalizedError {
    case unsavedChanges(String)

    var errorDescription: String? {
        switch self {
        case .unsavedChanges(let message):
            message
        }
    }
}

struct RecoveryDraft: Codable, Equatable, Sendable {
    let sourcePath: String
    let content: String
    let baseContent: String
    let updatedAt: Date
}

/// A small, vault-independent crash-recovery store. Drafts live in Application
/// Support rather than beside notes, so vaults remain clean and an unavailable
/// iCloud container cannot take the only copy of unsaved text with it.
struct RecoveryStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL = RecoveryStore.defaultDirectoryURL()) {
        self.directoryURL = directoryURL.standardizedFileURL
    }

    func save(content: String, baseContent: String, for url: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let draft = RecoveryDraft(
            sourcePath: url.standardizedFileURL.path,
            content: content,
            baseContent: baseContent,
            updatedAt: Date()
        )
        try JSONEncoder().encode(draft).write(to: draftURL(for: url), options: .atomic)
    }

    func draft(for url: URL) -> RecoveryDraft? {
        guard let data = try? Data(contentsOf: draftURL(for: url)),
              let draft = try? JSONDecoder().decode(RecoveryDraft.self, from: data),
              draft.sourcePath == url.standardizedFileURL.path else {
            return nil
        }
        return draft
    }

    func removeDraft(for url: URL) {
        try? FileManager.default.removeItem(at: draftURL(for: url))
    }

    func moveDraft(from oldURL: URL, to newURL: URL) {
        guard let draft = draft(for: oldURL) else { return }
        do {
            try save(content: draft.content, baseContent: draft.baseContent, for: newURL)
            removeDraft(for: oldURL)
        } catch {
            // Recovery is best-effort and must never make the primary rename or
            // move fail. If this write fails, the old-path draft remains intact.
        }
    }

    private func draftURL(for url: URL) -> URL {
        directoryURL
            .appendingPathComponent(Self.stablePathKey(url.standardizedFileURL.path))
            .appendingPathExtension("json")
    }

    private static func stablePathKey(_ path: String) -> String {
        // FNV-1a is deterministic across launches (unlike Swift's Hasher) and
        // keeps filenames safely below APFS's component-length limit.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func defaultDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("com.md.MarkdownEditor", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
    }
}

private let markdownFileExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
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
    let foldedTitleHaystack: String
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
            scheduleRecoveryDraft()
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
    /// The note whose unsaved buffer was safely restored from local recovery.
    /// This is observable so a future UI can show a non-blocking recovery badge.
    var recoveredDraftURL: URL?

    var hasVault: Bool { vaultURL != nil }
    var hasUnsavedChanges: Bool {
        selectedFileIsMarkdown && persistedText != nil && persistedText != text
    }
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
    private let recoveryStore: RecoveryStore
    private var activeSecurityScopedVaultURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var recoveryDraftTask: Task<Void, Never>?
    private var snapshotLoadTask: Task<Void, Never>?
    private var noteGraphRefreshTask: Task<Void, Never>?
    private var externalChangeTask: Task<Void, Never>?
    private var pendingExternalChanges: [VaultFileChange] = []
    private var vaultFilePresenter: VaultFilePresenter?
    private var snapshotGeneration = 0
    private var noteGraphGeneration = 0
    private var cachedMarkdownMetadataByPath: [String: CachedMarkdownMetadata] = [:]
    private var assetLookupByFilename: [String: [URL]] = [:]
    private var pendingEditorSelectionsByKey: [String: [Int]] = [:]
    private var editorSelectionPersistTasksByKey: [String: Task<Void, Never>] = [:]
    private var persistedText: String?
    private var isReplacingEditorBuffer = false

    init(
        preferences: AppPreferences = AppPreferences(),
        recoveryStore: RecoveryStore = RecoveryStore()
    ) {
        self.preferences = preferences
        self.recoveryStore = recoveryStore
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

    @discardableResult
    func openVault(_ url: URL) -> Bool {
        guard saveCurrentFile().allowsTransition else { return false }

        beginAccessingVault(url)
        persistVaultBookmark(for: url)
        vaultURL = url
        restoreSortOrder()
        files = []
        sidebarNodes = []
        selectedFileURL = nil
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearNoteGraph()
        cachedMarkdownMetadataByPath = [:]
        assetLookupByFilename = [:]
        refreshFilesInBackground(
            preferredSelectionURL: restoreSelectedFileURL(),
            selectFirstFileIfNeeded: true
        )
        return true
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
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearNoteGraph()
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
            clearNoteGraph()
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
                preserveDirtyBufferOrClearMissingSelection(selectedFileURL)
            }
        }

        refreshNoteGraph()
    }

    @discardableResult
    func selectFile(_ url: URL) -> Bool {
        let canonicalURL = matchingSidebarURL(for: url) ?? url
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, canonicalURL) {
            return true
        }

        guard saveCurrentFile().allowsTransition else { return false }
        if Self.isMarkdownFile(canonicalURL) {
            let diskContent: String
            do {
                diskContent = try Self.readFileContentsThrowing(canonicalURL)
            } catch {
                saveError = Self.openErrorMessage(for: canonicalURL, error: error)
                return false
            }

            selectedFileURL = canonicalURL
            let recoveredContent = recoverableContent(for: canonicalURL, diskContent: diskContent)
            replaceEditorBuffer(with: recoveredContent, persistedContent: diskContent)
            persistSelectedFileURL(canonicalURL)
            updateCachedMetadata(for: canonicalURL, content: diskContent)
        } else {
            selectedFileURL = canonicalURL
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            persistSelectedFileURL(canonicalURL)
        }
        return true
    }

    /// Closes the active document without closing the vault. The transition is
    /// refused when the current buffer cannot be saved, matching file and vault
    /// switching semantics so closing the final tab cannot discard edits.
    @discardableResult
    func clearSelection() -> Bool {
        guard saveCurrentFile().allowsTransition else { return false }
        selectedFileURL = nil
        replaceEditorBuffer(with: "", persistedContent: nil)
        recoveredDraftURL = nil
        clearStoredSelectedFileURL()
        return true
    }

    private func readFile(_ url: URL) -> String? {
        Self.readFileContents(url)
    }

    @discardableResult
    func saveCurrentFile() -> DocumentSaveResult {
        autosaveTask?.cancel()
        guard let url = selectedFileURL else { return .noEditableDocument }
        guard Self.isMarkdownFile(url) else { return .noEditableDocument }
        // While a conflict alert is pending, don't keep re-writing/re-prompting.
        guard saveConflict == nil else {
            persistRecoveryDraftNow()
            return .conflict
        }
        guard persistedText != nil else {
            let message = "Couldn’t save \(url.lastPathComponent) because its original contents were not loaded. Reopen the note before saving; the current buffer was kept unchanged."
            saveError = message
            return .failed(message)
        }
        guard persistedText != text else {
            recoveryStore.removeDraft(for: url)
            return .noChanges
        }
        return writeBuffer(text, to: url)
    }

    /// Writes `content` to `url`, but first guards against clobbering an
    /// external modification, and surfaces (rather than swallows) write errors.
    private func writeBuffer(_ content: String, to url: URL) -> DocumentSaveResult {
        guard let persistedText else {
            let message = "Couldn’t save \(url.lastPathComponent) because its original contents were not loaded."
            saveError = message
            return .failed(message)
        }
        do {
            let outcome = try Self.coordinatedConditionalWrite(
                Data(content.utf8),
                expectedContent: persistedText,
                to: url
            )
            if case .conflict(let diskContent) = outcome {
                saveConflict = SaveConflict(
                    url: url,
                    fileName: url.lastPathComponent,
                    onDiskContent: diskContent,
                    editorContent: content
                )
                _ = persistRecoveryDraftNow()
                return .conflict
            }

            saveError = nil
            self.persistedText = content
            recoveryStore.removeDraft(for: url)
            updateCachedMetadata(for: url, content: content)
            return .saved
        } catch {
            let recoverySaved = persistRecoveryDraftNow()
            let message = Self.saveErrorMessage(
                for: url,
                error: error,
                recoverySaved: recoverySaved
            )
            saveError = message
            return .failed(message)
        }
    }

    /// Conflict resolution: overwrite the on-disk file with the editor buffer.
    /// Uses the live buffer when the conflict file is still selected so edits
    /// typed while the alert was open are not discarded with the recovery draft.
    func resolveSaveConflictKeepingMine() {
        guard let conflict = saveConflict else { return }
        let contentToKeep: String
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, conflict.url) {
            contentToKeep = text
        } else {
            contentToKeep = conflict.editorContent
        }
        saveConflict = nil
        do {
            try Self.coordinatedWrite(Data(contentToKeep.utf8), to: conflict.url)
            saveError = nil
            if let selectedFileURL, Self.urlsMatch(selectedFileURL, conflict.url) {
                persistedText = contentToKeep
            }
            recoveryStore.removeDraft(for: conflict.url)
            updateCachedMetadata(for: conflict.url, content: contentToKeep)
        } catch {
            let recoverySaved = persistRecoveryDraftNow()
            saveError = Self.saveErrorMessage(
                for: conflict.url,
                error: error,
                recoverySaved: recoverySaved
            )
        }
    }

    /// Conflict resolution: discard the editor buffer and adopt the on-disk
    /// version (loading it into the editor if it is still the selected file).
    func resolveSaveConflictUsingDisk() {
        guard let conflict = saveConflict else { return }
        saveConflict = nil
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, conflict.url) {
            replaceEditorBuffer(with: conflict.onDiskContent, persistedContent: conflict.onDiskContent)
            recoveredDraftURL = nil
        }
        recoveryStore.removeDraft(for: conflict.url)
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

    private func scheduleRecoveryDraft() {
        guard !isReplacingEditorBuffer, selectedFileIsMarkdown, persistedText != nil else { return }
        recoveryDraftTask?.cancel()

        guard hasUnsavedChanges else {
            if let selectedFileURL {
                recoveryStore.removeDraft(for: selectedFileURL)
            }
            return
        }

        recoveryDraftTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.persistRecoveryDraftNow()
        }
    }

    /// Flushes the current dirty buffer to local recovery immediately. Save
    /// failure and conflict paths call this synchronously before returning.
    @discardableResult
    func persistRecoveryDraftNow() -> Bool {
        recoveryDraftTask?.cancel()
        guard let selectedFileURL,
              selectedFileIsMarkdown,
              let persistedText,
              persistedText != text else {
            return false
        }
        do {
            try recoveryStore.save(content: text, baseContent: persistedText, for: selectedFileURL)
            return true
        } catch {
            return false
        }
    }

    func recoveryDraft(for url: URL) -> RecoveryDraft? {
        recoveryStore.draft(for: url)
    }

    /// Allows a future recovery UI to restore even a draft whose base no longer
    /// matches disk. Automatic restore is intentionally stricter (see below).
    @discardableResult
    func restoreRecoveryDraft(for url: URL) -> Bool {
        guard let selectedFileURL,
              Self.urlsMatch(selectedFileURL, url),
              let draft = recoveryStore.draft(for: url) else {
            return false
        }
        isReplacingEditorBuffer = true
        text = draft.content
        isReplacingEditorBuffer = false
        recoveredDraftURL = url.standardizedFileURL
        return true
    }

    func createNewFile(in directoryURL: URL? = nil) {
        if let destinationDirectoryURL = destinationDirectoryURL(for: directoryURL) {
            for _ in 0..<32 {
                let fileURL = uniqueMarkdownFileURL(in: destinationDirectoryURL)
                let name = fileURL.deletingPathExtension().lastPathComponent
                let content = Data("# \(name)\n\n".utf8)

                do {
                    guard try ExclusiveAtomicFileWriter.writeIfAbsent(
                        content,
                        to: fileURL,
                        fileManager: .default
                    ) else {
                        continue
                    }
                    refreshFiles()
                    selectFile(fileURL)
                    return
                } catch {
                    if directoryURL == nil {
                        presentStandaloneFileSavePanel()
                    }
                    return
                }
            }

            if directoryURL == nil {
                presentStandaloneFileSavePanel()
            }
            return
        }

        presentStandaloneFileSavePanel()
    }

    /// Conditionally replaces a note body under file coordination. When the
    /// note is the selected editor buffer, updates the live buffer instead.
    @discardableResult
    func replaceNoteBody(
        at url: URL,
        expected: String,
        replacement: String
    ) -> Bool {
        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, standardized) {
            guard text == expected else { return false }
            text = replacement
            return true
        }

        do {
            return try VaultLinkRefactor.replaceIfCurrent(
                at: standardized,
                expected: expected,
                replacement: replacement
            )
        } catch {
            return false
        }
    }

    func deleteItem(_ url: URL) {
        let itemURL = matchingSidebarURL(for: url) ?? url.resolvingSymlinksInPath().standardizedFileURL
        let isDirectory = isDirectoryURL(itemURL)
        let editorSelectionKeysToClear = editorSelectionKeys(forDeletedItemAt: itemURL, isDirectory: isDirectory)
        let shouldClearSelectedFile = selectedFileURL.map {
            deletedItem(itemURL, isDirectory: isDirectory, contains: $0)
        } ?? false

        if shouldClearSelectedFile, selectedFileIsMarkdown,
           !saveCurrentFile().allowsTransition {
            return
        }

        guard (try? FileManager.default.trashItem(at: itemURL, resultingItemURL: nil)) != nil else {
            return
        }

        clearStoredEditorSelections(forKeys: editorSelectionKeysToClear)

        if shouldClearSelectedFile {
            if let selectedFileURL {
                recoveryStore.removeDraft(for: selectedFileURL)
            }
            self.selectedFileURL = nil
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            clearStoredSelectedFileURL()
        }

        refreshFiles()
    }

    func importDroppedFile(_ url: URL) {
        let sourceURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isMarkdownFile(sourceURL), let vaultURL else {
            _ = openRequestedFiles([sourceURL])
            return
        }

        if sourceURL.path.hasPrefix(vaultURL.standardizedFileURL.path + "/") {
            _ = selectFile(sourceURL)
            return
        }

        guard saveCurrentFile().allowsTransition else { return }
        let destinationURL = uniqueImportURL(
            for: sourceURL.lastPathComponent,
            in: vaultURL.standardizedFileURL
        )
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            refreshFiles()
            _ = selectFile(destinationURL)
        } catch {
            saveError = "Couldn’t import \(sourceURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func uniqueImportURL(for filename: String, in directoryURL: URL) -> URL {
        let pathExtension = (filename as NSString).pathExtension
        let baseName = (filename as NSString).deletingPathExtension
        var candidate = directoryURL.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let nextName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            candidate = directoryURL.appendingPathComponent(nextName)
            suffix += 1
        }
        return candidate
    }

    @discardableResult
    func openRequestedFiles(_ urls: [URL]) -> Bool {
        guard let url = urls
            .map({ $0.resolvingSymlinksInPath().standardizedFileURL })
            .first(where: { Self.isMarkdownFile($0) || Self.isImageFile($0) }) else {
            return false
        }

        // If the file already lives inside the open vault, just select it.
        // Replacing the whole vault (tearing down the sidebar, file index, and
        // selection) is jarring and unnecessary for an in-vault file.
        if let vaultURL,
           url.standardizedFileURL.path.hasPrefix(vaultURL.standardizedFileURL.path + "/") {
            return selectFile(url)
        }

        guard saveCurrentFile().allowsTransition else { return false }

        let diskContent: String?
        if Self.isMarkdownFile(url) {
            do {
                diskContent = try Self.readFileContentsThrowing(url)
            } catch {
                saveError = Self.openErrorMessage(for: url, error: error)
                return false
            }
        } else {
            diskContent = nil
        }

        let parentURL = url.deletingLastPathComponent()
        beginAccessingVault(parentURL)
        persistVaultBookmark(for: parentURL)

        vaultURL = parentURL
        restoreSortOrder()

        if let diskContent {
            ensureOpenedFileIsVisible(at: url, markdownContent: diskContent)
            let recoveredContent = recoverableContent(for: url, diskContent: diskContent)
            replaceEditorBuffer(with: recoveredContent, persistedContent: diskContent)
        } else {
            ensureOpenedFileIsVisible(at: url, markdownContent: nil)
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
        }

        selectedFileURL = url
        persistSelectedFileURL(url)
        refreshFilesInBackground(preferredSelectionURL: url, selectFirstFileIfNeeded: false)
        return true
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

        let sourceIsDirectory = isDirectoryURL(standardizedSourceURL)
        let selectedURLAfterMove = selectedFileURL.flatMap {
            remappedURL(
                $0,
                from: standardizedSourceURL,
                to: destinationURL,
                sourceIsDirectory: sourceIsDirectory
            )
        }
        if selectedFileIsMarkdown, !saveCurrentFile().allowsTransition {
            return false
        }

        let linkRefactorEdits = makeLinkRefactorEdits(
            moving: standardizedSourceURL,
            to: destinationURL,
            sourceIsDirectory: sourceIsDirectory
        )

        guard (try? FileManager.default.moveItem(at: standardizedSourceURL, to: destinationURL)) != nil else {
            return false
        }

        if let selectedURLAfterMove, let oldSelectedFileURL = selectedFileURL {
            selectedFileURL = selectedURLAfterMove
            persistSelectedFileURL(selectedURLAfterMove)
            recoveryStore.moveDraft(from: oldSelectedFileURL, to: selectedURLAfterMove)
        }

        moveStoredEditorSelections(
            from: standardizedSourceURL,
            to: destinationURL,
            sourceIsDirectory: sourceIsDirectory
        )
        applyLinkRefactorEdits(linkRefactorEdits, operationName: "move")
        refreshFiles()
        return true
    }

    @discardableResult
    func renameItem(_ url: URL, to newName: String) throws -> URL {
        let newURL = try validatedRenamedURL(for: url, proposedName: newName)
        guard newURL != url else { return url }

        let sourceIsDirectory = isDirectoryURL(url)
        let isSelectedFile = selectedFileURL.map { Self.urlsMatch($0, url) } ?? false
        let selectedURLAfterRename = selectedFileURL.flatMap {
            remappedURL($0, from: url, to: newURL, sourceIsDirectory: sourceIsDirectory)
        }
        let existingContent = Self.isMarkdownFile(url)
            ? (isSelectedFile ? text : readFile(url))
            : nil

        if selectedFileIsMarkdown {
            let result = saveCurrentFile()
            guard result.allowsTransition else {
                let message = saveError ?? "Resolve the unsaved changes before renaming this item."
                throw WorkspaceFileOperationError.unsavedChanges(message)
            }
        }


        let updatedContent = existingContent.map {
            contentAfterRename(oldURL: url, newURL: newURL, existingContent: $0)
        }
        let bodyOverrides = updatedContent.map { [url.standardizedFileURL: $0] } ?? [:]
        let linkRefactorEdits = makeLinkRefactorEdits(
            moving: url,
            to: newURL,
            sourceIsDirectory: sourceIsDirectory,
            bodyOverrides: bodyOverrides
        )

        try moveItemForRename(at: url, to: newURL)

        if let selectedURLAfterRename, let oldSelectedFileURL = selectedFileURL {
            selectedFileURL = selectedURLAfterRename
            persistSelectedFileURL(selectedURLAfterRename)
            recoveryStore.moveDraft(from: oldSelectedFileURL, to: selectedURLAfterRename)
        }
        moveStoredEditorSelections(
            from: url,
            to: newURL,
            sourceIsDirectory: sourceIsDirectory
        )

        if let existingContent, let updatedContent {
            if updatedContent != existingContent {
                try Self.coordinatedWrite(Data(updatedContent.utf8), to: newURL)
            }

            if isSelectedFile {
                replaceEditorBuffer(with: updatedContent, persistedContent: updatedContent)
                recoveryStore.removeDraft(for: newURL)
            }
        }

        applyLinkRefactorEdits(linkRefactorEdits, operationName: "rename")

        refreshFiles()
        return newURL
    }

    private func makeLinkRefactorEdits(
        moving oldRoot: URL,
        to newRoot: URL,
        sourceIsDirectory: Bool,
        bodyOverrides: [URL: String] = [:]
    ) -> [VaultLinkRefactorEdit] {
        guard let vaultURL else { return [] }
        let notes = files.compactMap { file -> VaultLinkNoteSnapshot? in
            let standardizedURL = file.url.standardizedFileURL
            guard let body = bodyOverrides[standardizedURL] ?? noteBody(for: standardizedURL) else {
                return nil
            }
            let aliases = ObsidianMetadataParser.parse(body).aliases
            return VaultLinkNoteSnapshot(url: standardizedURL, body: body, aliases: aliases)
        }
        let assetURLs = Set(assetLookupByFilename.values.flatMap { $0 }.map {
            $0.resolvingSymlinksInPath().standardizedFileURL
        })
        return VaultLinkRefactor.edits(
            notes: notes,
            moving: oldRoot,
            to: newRoot,
            sourceIsDirectory: sourceIsDirectory,
            vaultURL: vaultURL,
            assetURLs: assetURLs
        )
    }

    private func applyLinkRefactorEdits(
        _ edits: [VaultLinkRefactorEdit],
        operationName: String
    ) {
        guard !edits.isEmpty else { return }
        do {
            try VaultLinkRefactor.apply(edits)
            if let selectedFileURL,
               let selectedEdit = edits.first(where: {
                   Self.urlsMatch($0.destinationURL, selectedFileURL)
               }) {
                replaceEditorBuffer(
                    with: selectedEdit.updatedBody,
                    persistedContent: selectedEdit.updatedBody
                )
                recoveryStore.removeDraft(for: selectedFileURL)
            }
        } catch {
            saveError = "The item was \(operationName)d, but linked notes could not be updated safely: \(error.localizedDescription)"
        }
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

    private func clearNoteGraph() {
        noteGraphRefreshTask?.cancel()
        noteGraphGeneration += 1
        noteGraph = .empty
    }

    private func refreshNoteGraph() {
        scheduleNoteGraphRefresh(debounceNanoseconds: 0)
    }

    private func scheduleNoteGraphRefresh(debounceNanoseconds: UInt64? = nil) {
        let delay = debounceNanoseconds ?? Self.noteGraphDebounceNanoseconds
        noteGraphRefreshTask?.cancel()
        noteGraphGeneration += 1
        let generation = noteGraphGeneration
        let files = files
        let metadataByPath = cachedMarkdownMetadataByPath
        let vaultURL = vaultURL
        let selectedFileURL = selectedFileURL
        let liveSelectedMarkdown = selectedFileIsMarkdown ? text : nil

        noteGraphRefreshTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }

            let snapshot = await Task.detached(priority: .utility) {
                NoteGraphBuilder.makeSnapshot(
                    files: files,
                    metadataByPath: metadataByPath,
                    vaultURL: vaultURL,
                    selectedFileURL: selectedFileURL,
                    liveSelectedMarkdown: liveSelectedMarkdown
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, generation == self.noteGraphGeneration else { return }
                self.noteGraph = snapshot
            }
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


    private func replaceEditorBuffer(with content: String, persistedContent: String?) {
        recoveryDraftTask?.cancel()
        persistedText = persistedContent
        isReplacingEditorBuffer = true
        text = content
        isReplacingEditorBuffer = false
    }

    private func recoverableContent(for url: URL, diskContent: String) -> String {
        guard let draft = recoveryStore.draft(for: url) else {
            recoveredDraftURL = nil
            return diskContent
        }

        if draft.content == diskContent {
            recoveryStore.removeDraft(for: url)
            recoveredDraftURL = nil
            return diskContent
        }

        // Automatic recovery is safe only if the file is still the exact base
        // the unsaved edits were made against. A divergent draft remains on
        // disk for explicit recovery instead of overwriting external changes.
        guard draft.baseContent == diskContent else {
            recoveredDraftURL = nil
            return diskContent
        }

        recoveredDraftURL = url.standardizedFileURL
        return draft.content
    }

    private func preserveDirtyBufferOrClearMissingSelection(_ missingURL: URL) {
        guard hasUnsavedChanges else {
            selectedFileURL = nil
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            clearStoredSelectedFileURL()
            return
        }

        let recoverySaved = persistRecoveryDraftNow()
        let recoveryStatus = recoverySaved
            ? "A recovery draft was kept."
            : "The recovery draft could not be written, so keep this window open and copy your text somewhere safe."
        saveError = "Couldn’t find \(missingURL.lastPathComponent). Your unsaved text is still open. \(recoveryStatus) Restore the file or use Save again after making it available."
    }

    private nonisolated static func openErrorMessage(for url: URL, error: Error) -> String {
        "Couldn’t open \(url.lastPathComponent): \(error.localizedDescription). The current note was kept unchanged."
    }

    private nonisolated static func saveErrorMessage(
        for url: URL,
        error: Error,
        recoverySaved: Bool
    ) -> String {
        let recoveryStatus = recoverySaved
            ? "Your text is still open and was copied to local recovery."
            : "Your text is still open, but local recovery could not be written; copy it somewhere safe before closing the app."
        return "Couldn’t save \(url.lastPathComponent): \(error.localizedDescription). \(recoveryStatus)"
    }

    private func remappedURL(
        _ candidateURL: URL,
        from sourceURL: URL,
        to destinationURL: URL,
        sourceIsDirectory: Bool
    ) -> URL? {
        let candidate = candidateURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        if Self.urlsMatch(candidate, source) {
            return destinationURL.standardizedFileURL
        }

        guard sourceIsDirectory else { return nil }
        let sourcePrefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        guard candidate.path.hasPrefix(sourcePrefix) else { return nil }
        let relativePath = String(candidate.path.dropFirst(sourcePrefix.count))
        return destinationURL.appendingPathComponent(relativePath).standardizedFileURL
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
            ?? standardizedURL.deletingPathExtension().lastPathComponent
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
            replaceEditorBuffer(with: "", persistedContent: nil)
            recoveredDraftURL = nil
            cachedMarkdownMetadataByPath = [:]
            assetLookupByFilename = [:]
            clearNoteGraph()
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
                    self.preserveDirtyBufferOrClearMissingSelection(selectedFileURL)
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
            // Filename fallback is presentation metadata only. Opening/indexing
            // a note must never inject an H1 or otherwise rewrite its bytes.
            noteTitle = Self.extractTitle(from: content)
                ?? url.deletingPathExtension().lastPathComponent
            noteLinks = MarkdownNoteLinkExtractor.references(in: content)
            noteBody = content
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

    private nonisolated static func readFileContents(_ url: URL) -> String? {
        try? readFileContentsThrowing(url)
    }

    /// Coordinated reads are important for iCloud/ubiquitous documents: a read
    /// either returns a complete version or throws. A thrown read never becomes
    /// an empty editor buffer that autosave could later write over the note.
    private nonisolated static func readFileContentsThrowing(_ url: URL) throws -> String {
        let data: Data
        do {
            data = try coordinatedRead(from: url)
        } catch {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            data = try coordinatedRead(from: url)
        }

        if let string = String(data: data, encoding: .utf8) {
            return string
        }

        // Only try UTF-16 when a byte-order mark proves the encoding. Blindly
        // decoding arbitrary even-length data as UTF-16 can silently produce
        // garbage. ISO Latin-1 is the lossless final fallback for every byte.
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF],
           let string = String(data: data, encoding: .utf16) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    private nonisolated static func coordinatedRead(from url: URL) throws -> Data {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorError: Error?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                accessorError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let accessorError { throw accessorError }
    }

    private enum CoordinatedConditionalWriteOutcome {
        case written
        case conflict(String)
    }

    /// Reads the current version and replaces it inside one file-coordination
    /// accessor. iCloud and other coordinated writers therefore cannot land a
    /// new version between our conflict check and write.
    private nonisolated static func coordinatedConditionalWrite(
        _ data: Data,
        expectedContent: String,
        to url: URL
    ) throws -> CoordinatedConditionalWriteOutcome {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var accessorResult: Result<CoordinatedConditionalWriteOutcome, Error>?

        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            accessorResult = Result {
                let diskData = try Data(contentsOf: coordinatedURL)
                let diskContent = try decodeTextData(diskData)
                let proposedContent = String(decoding: data, as: UTF8.self)
                if diskContent != expectedContent, diskContent != proposedContent {
                    return .conflict(diskContent)
                }
                try data.write(to: coordinatedURL, options: .atomic)
                return .written
            }
        }

        if let coordinationError { throw coordinationError }
        guard let accessorResult else { throw CocoaError(.fileWriteUnknown) }
        return try accessorResult.get()
    }

    private nonisolated static func decodeTextData(_ data: Data) throws -> String {
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        let bytes = [UInt8](data.prefix(2))
        if bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF],
           let string = String(data: data, encoding: .utf16) {
            return string
        }
        if let string = String(data: data, encoding: .isoLatin1) {
            return string
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
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

    private func moveStoredEditorSelections(
        from oldRootURL: URL,
        to newRootURL: URL,
        sourceIsDirectory: Bool
    ) {
        let defaults = UserDefaults.standard
        var storedURLs: Set<URL> = []

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.editorSelectionKeyPrefix) {
            let path = String(key.dropFirst(Self.editorSelectionKeyPrefix.count))
            storedURLs.insert(URL(fileURLWithPath: path).standardizedFileURL)
        }
        for key in pendingEditorSelectionsByKey.keys where key.hasPrefix(Self.editorSelectionKeyPrefix) {
            let path = String(key.dropFirst(Self.editorSelectionKeyPrefix.count))
            storedURLs.insert(URL(fileURLWithPath: path).standardizedFileURL)
        }

        // Include the exact root even if no cursor state currently exists; the
        // helper is a no-op in that case and this keeps file moves simple.
        storedURLs.insert(oldRootURL.standardizedFileURL)

        for oldURL in storedURLs {
            guard let newURL = remappedURL(
                oldURL,
                from: oldRootURL,
                to: newRootURL,
                sourceIsDirectory: sourceIsDirectory
            ) else { continue }
            moveStoredEditorSelectionExactly(from: oldURL, to: newURL)
        }
    }

    private func moveStoredEditorSelectionExactly(from oldURL: URL, to newURL: URL) {
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

        if vaultFilePresenter?.presentedItemURL?.standardizedFileURL != standardizedURL {
            vaultFilePresenter?.stop()
            let presenter = VaultFilePresenter(vaultURL: standardizedURL) { [weak self] change in
                Task { @MainActor [weak self] in
                    self?.scheduleExternalChangeHandling(change)
                }
            }
            vaultFilePresenter = presenter
            presenter.start()
        }

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

    private func scheduleExternalChangeHandling(_ change: VaultFileChange) {
        pendingExternalChanges.append(change)
        externalChangeTask?.cancel()
        externalChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard let self, !Task.isCancelled else { return }
            let changes = self.pendingExternalChanges
            self.pendingExternalChanges.removeAll(keepingCapacity: true)
            self.handleExternalChanges(changes)
        }
    }

    /// Applies the entire debounced change batch. Keeping move pairs intact and
    /// checking the selected file for every batch prevents a later, unrelated
    /// iCloud notification from hiding an earlier note update.
    func handleExternalChanges(_ changes: [VaultFileChange]) {
        remapSelectionForExternalMoves(in: changes)

        if let selectedFileURL,
           selectedFileIsMarkdown,
           let diskContent = try? Self.readFileContentsThrowing(selectedFileURL),
           diskContent != text {
            if hasUnsavedChanges {
                // A file-presenter callback for another item must not turn a
                // normal dirty buffer into a conflict merely because disk is
                // still at our known base version.
                if diskContent != persistedText {
                    _ = persistRecoveryDraftNow()
                    saveConflict = SaveConflict(
                        url: selectedFileURL,
                        fileName: selectedFileURL.lastPathComponent,
                        onDiskContent: diskContent,
                        editorContent: text
                    )
                }
            } else {
                replaceEditorBuffer(with: diskContent, persistedContent: diskContent)
                recoveryStore.removeDraft(for: selectedFileURL)
                updateCachedMetadata(for: selectedFileURL, content: diskContent)
            }
        }

        // File-presenter callbacks arrive on save and in iCloud bursts. Build
        // the recursive inventory off the main actor so those bursts cannot
        // freeze editing in a large vault.
        refreshFilesInBackground(
            preferredSelectionURL: nil,
            selectFirstFileIfNeeded: false
        )
    }

    private func remapSelectionForExternalMoves(in changes: [VaultFileChange]) {
        guard let selectedFileURL else { return }
        let selectedPath = selectedFileURL.standardizedFileURL.path

        for change in changes {
            guard case .moved(let oldURL, let newURL) = change else { continue }
            let oldPath = oldURL.standardizedFileURL.path
            let suffix: String
            if selectedPath == oldPath {
                suffix = ""
            } else if selectedPath.hasPrefix(oldPath + "/") {
                suffix = String(selectedPath.dropFirst(oldPath.count))
            } else {
                continue
            }

            let remappedURL = URL(fileURLWithPath: newURL.standardizedFileURL.path + suffix)
                .standardizedFileURL
            guard let vaultURL,
                  isDescendant(remappedURL, of: vaultURL, allowEqual: false) else {
                continue
            }

            self.selectedFileURL = remappedURL
            persistSelectedFileURL(remappedURL)
            recoveryStore.moveDraft(from: selectedFileURL, to: remappedURL)
            moveStoredEditorSelections(
                from: oldURL,
                to: newURL,
                sourceIsDirectory: selectedPath != oldPath
            )
            return
        }
    }

}

private struct DirectorySnapshot: Sendable {
    let nodes: [SidebarNode]
    let files: [FileItem]
    let markdownMetadataByPath: [String: CachedMarkdownMetadata]
    let assetLookupByFilename: [String: [URL]]
}
