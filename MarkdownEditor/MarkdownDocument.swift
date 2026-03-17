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

@Observable
@MainActor
final class Workspace {
    var files: [FileItem] = []
    var sidebarNodes: [SidebarNode] = []
    var selectedFileURL: URL?
    var text: String = ""
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

    var sortedFiles: [FileItem] {
        switch sortOrder {
        case .byName:
            files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .byDate:
            files.sorted { $0.modificationDate > $1.modificationDate }
        }
    }

    private static let bookmarkKey = "vaultBookmark"
    private static let editorSelectionKeyPrefix = "editorSelection::"
    private let preferences: AppPreferences
    private var activeSecurityScopedVaultURL: URL?
    private var autosaveTask: Task<Void, Never>?
    private var snapshotLoadTask: Task<Void, Never>?
    private var snapshotGeneration = 0

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
            return
        }

        let snapshot = Self.snapshotDirectory(at: vaultURL, sortOrder: sortOrder)
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
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        updateCachedMetadata(for: url, content: text)
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

        let sanitizedSelection = [max(0, selection.location), max(0, selection.length)]
        UserDefaults.standard.set(sanitizedSelection, forKey: editorSelectionStorageKey(for: url))
    }

    func editorSelection(for url: URL?) -> NSRange? {
        guard let url,
              let persistedSelection = UserDefaults.standard.array(forKey: editorSelectionStorageKey(for: url)) as? [Int],
              persistedSelection.count == 2 else {
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

    private nonisolated static func extractTitle(from content: String) -> String? {
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" || $0.isWhitespace })
                let result = String(title).trimmingCharacters(in: .whitespacesAndNewlines)
                return result.isEmpty ? nil : result
            }

            return nil
        }

        return nil
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
        guard let index = files.firstIndex(where: { $0.url == url }) else { return }

        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? files[index].modificationDate

        files[index] = FileItem(
            id: url,
            name: url.lastPathComponent,
            url: url,
            modificationDate: date,
            noteTitle: Self.extractTitle(from: content)
        )
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
            return
        }

        isLoadingSnapshot = true
        let generation = snapshotGeneration
        let sortOrder = sortOrder

        snapshotLoadTask = Task { [vaultURL] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.snapshotDirectory(at: vaultURL, sortOrder: sortOrder)
            }.value

            guard !Task.isCancelled else { return }
            guard generation == self.snapshotGeneration else { return }
            guard self.vaultURL?.standardizedFileURL == vaultURL.standardizedFileURL else { return }

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

            self.isLoadingSnapshot = false
        }
    }

    private nonisolated static func snapshotDirectory(at directoryURL: URL, sortOrder: SortOrder) -> DirectorySnapshot {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return DirectorySnapshot(nodes: [], files: [])
        }

        var nodes: [SidebarNode] = []
        var files: [FileItem] = []

        for url in contents {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let modificationDate = values?.contentModificationDate ?? .distantPast

            if values?.isDirectory == true {
                let childSnapshot = snapshotDirectory(at: url, sortOrder: sortOrder)
                let childLatestDate = childSnapshot.nodes.map(\.modificationDate).max() ?? modificationDate
                nodes.append(
                    SidebarNode(
                        id: url,
                        url: url,
                        name: url.lastPathComponent,
                        kind: .folder,
                        modificationDate: max(modificationDate, childLatestDate),
                        children: childSnapshot.nodes
                    )
                )
                files.append(contentsOf: childSnapshot.files)
            } else if Self.isMarkdownFile(url) {
                let file = makeFileItem(at: url, modificationDate: modificationDate)
                nodes.append(
                    SidebarNode(
                        id: url,
                        url: url,
                        name: file.displayName,
                        kind: .file,
                        modificationDate: file.modificationDate
                    )
                )
                files.append(file)
            } else if Self.isImageFile(url) {
                nodes.append(
                    SidebarNode(
                        id: url,
                        url: url,
                        name: url.lastPathComponent,
                        kind: .file,
                        modificationDate: modificationDate
                    )
                )
            }
        }

        return DirectorySnapshot(
            nodes: sortSidebarNodes(nodes, sortOrder: sortOrder),
            files: files
        )
    }

    private nonisolated static func makeFileItem(at url: URL, modificationDate: Date) -> FileItem {
        let noteTitle = readFileContents(url).flatMap { content in
            Self.extractTitle(from: normalizedContent(
                for: url,
                content: content,
                persistIfMissingTitle: false
            ))
        }
        return FileItem(
            id: url,
            name: url.lastPathComponent,
            url: url,
            modificationDate: modificationDate,
            noteTitle: noteTitle
        )
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
        if let data = try? Data(contentsOf: url),
           let string = String(data: data, encoding: .utf8) {
            return string
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
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
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        if Self.isMarkdownFile(url), !files.contains(where: { Self.urlsMatch($0.url, url) }) {
            files.append(
                FileItem(
                    id: url,
                    name: url.lastPathComponent,
                    url: url,
                    modificationDate: modificationDate,
                    noteTitle: markdownContent.flatMap(Self.extractTitle(from:))
                )
            )
        }

        guard !sidebarContainsNode(for: url, in: sidebarNodes) else { return }

        sidebarNodes = Self.sortSidebarNodes(
            sidebarNodes + [
                SidebarNode(
                    id: url,
                    url: url,
                    name: Self.isMarkdownFile(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                    kind: .file,
                    modificationDate: modificationDate
                )
            ],
            sortOrder: sortOrder
        )
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
        var keysToRemove: [String] = []

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            let path = String(key.dropFirst(prefix.count))
            let storedURL = URL(fileURLWithPath: path)
            if deletedItem(url, isDirectory: true, contains: storedURL) {
                keysToRemove.append(key)
            }
        }

        return keysToRemove
    }

    private func clearStoredEditorSelections(forKeys keys: [String]) {
        let defaults = UserDefaults.standard
        for key in keys {
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
}
