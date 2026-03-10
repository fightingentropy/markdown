import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
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

struct SidebarNode: Identifiable, Hashable {
    enum Kind: Hashable {
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

enum SortOrder: String {
    case byName
    case byDate
}

enum FileRenameError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case nameAlreadyExists

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "Enter a file name."
        case .invalidName:
            "File names can't contain slashes, colons, or line breaks."
        case .nameAlreadyExists:
            "A file with that name already exists."
        }
    }
}

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
        if let selected = files.first(where: { $0.url == selectedFileURL }) {
            return title(for: selected)
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
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp"]
    private let preferences: AppPreferences
    private var activeSecurityScopedVaultURL: URL?
    private var autosaveTask: Task<Void, Never>?

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
        refreshFiles()
        if let restoredURL = restoreSelectedFileURL(), let matchingURL = matchingFileURL(for: restoredURL) {
            selectFile(matchingURL)
        } else if let first = sortedFiles.first {
            selectFile(first.url)
        } else {
            selectedFileURL = nil
            text = ""
        }
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

        refreshFiles()

        if let restoredURL = restoreSelectedFileURL(), let matchingURL = matchingFileURL(for: restoredURL) {
            selectFile(matchingURL)
        }
    }

    // MARK: - File Operations

    func refreshFiles() {
        guard let vaultURL else {
            files = []
            sidebarNodes = []
            return
        }

        let snapshot = snapshotDirectory(at: vaultURL)
        files = snapshot.files
        sidebarNodes = snapshot.nodes

        if let selectedFileURL {
            if let matchingURL = matchingFileURL(for: selectedFileURL) {
                self.selectedFileURL = matchingURL
            } else {
                self.selectedFileURL = nil
                text = ""
                clearStoredSelectedFileURL()
            }
        }
    }

    func selectFile(_ url: URL) {
        let canonicalURL = matchingFileURL(for: url) ?? url
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, canonicalURL) {
            return
        }

        saveCurrentFile()
        if Self.isMarkdownFile(canonicalURL), let content = readFile(canonicalURL) {
            let normalizedContent = normalizedContent(for: canonicalURL, content: content)
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
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8) { return s }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
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

    func createNewFile() {
        if let vaultURL {
            var name = "Untitled"
            var counter = 1
            let fm = FileManager.default
            var fileURL = vaultURL.appendingPathComponent("\(name).md")
            while fm.fileExists(atPath: fileURL.path) {
                name = "Untitled \(counter)"
                counter += 1
                fileURL = vaultURL.appendingPathComponent("\(name).md")
            }
            let content = Data("# \(name)\n\n".utf8)
            if (try? content.write(to: fileURL, options: .atomic)) != nil {
                refreshFiles()
                selectFile(fileURL)
                return
            }
        }
        // Fallback: use a save panel if vault write fails or no vault set
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        try? Data("# \(name)\n\n".utf8).write(to: url, options: .atomic)
        importDroppedFile(url)
    }

    func deleteFile(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        if let selectedFileURL, Self.urlsMatch(selectedFileURL, url) {
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
        refreshFiles()

        if Self.isMarkdownFile(url), let content = readFile(url) {
            let normalizedContent = normalizedContent(for: url, content: content)
            ensureOpenedFileIsVisible(at: url, markdownContent: normalizedContent)
            text = normalizedContent
        } else {
            ensureOpenedFileIsVisible(at: url, markdownContent: nil)
            text = ""
        }

        selectedFileURL = url
        persistSelectedFileURL(url)
    }

    func createNewFolder() {
        guard let vaultURL else {
            pickVault()
            return
        }

        let fm = FileManager.default
        var name = "New Folder"
        var counter = 1
        var folderURL = vaultURL.appendingPathComponent(name, isDirectory: true)

        while fm.fileExists(atPath: folderURL.path) {
            counter += 1
            name = "New Folder \(counter)"
            folderURL = vaultURL.appendingPathComponent(name, isDirectory: true)
        }

        guard (try? fm.createDirectory(at: folderURL, withIntermediateDirectories: false)) != nil else {
            return
        }

        refreshFiles()
    }

    @discardableResult
    func renameFile(_ url: URL, to newName: String) throws -> URL {
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

        refreshFiles()
        return newURL
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

    private static func extractTitle(from content: String) -> String? {
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
            throw FileRenameError.emptyName
        }

        guard trimmedName.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else {
            throw FileRenameError.invalidName
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
            throw FileRenameError.emptyName
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
            throw FileRenameError.nameAlreadyExists
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

    private func snapshotDirectory(at directoryURL: URL) -> DirectorySnapshot {
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
                let childSnapshot = snapshotDirectory(at: url)
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
            nodes: sortSidebarNodes(nodes),
            files: files
        )
    }

    private func makeFileItem(at url: URL, modificationDate: Date) -> FileItem {
        let noteTitle = readFile(url).flatMap { content in
            Self.extractTitle(from: normalizedContent(for: url, content: content))
        }
        return FileItem(
            id: url,
            name: url.lastPathComponent,
            url: url,
            modificationDate: modificationDate,
            noteTitle: noteTitle
        )
    }

    private func sortSidebarNodes(_ nodes: [SidebarNode]) -> [SidebarNode] {
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

    private func normalizedContent(for url: URL, content: String) -> String {
        if Self.extractTitle(from: content) != nil {
            return content
        }

        let trimmedLeadingNewlines = String(content.drop(while: \.isNewline))
        let title = url.deletingPathExtension().lastPathComponent
        let body = trimmedLeadingNewlines.isEmpty ? "" : "\n\n\(trimmedLeadingNewlines)"
        let normalized = "# \(title)\(body)"

        if normalized != content {
            try? Data(normalized.utf8).write(to: url, options: .atomic)
        }

        return normalized
    }

    static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func matchingFileURL(for url: URL) -> URL? {
        files.first(where: { Self.urlsMatch($0.url, url) })?.url
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

        sidebarNodes = sortSidebarNodes(
            sidebarNodes + [
                SidebarNode(
                    id: url,
                    url: url,
                    name: Self.isMarkdownFile(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                    kind: .file,
                    modificationDate: modificationDate
                )
            ]
        )
    }

    private func sidebarContainsNode(for url: URL, in nodes: [SidebarNode]) -> Bool {
        nodes.contains { node in
            Self.urlsMatch(node.url, url) || sidebarContainsNode(for: url, in: node.children)
        }
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

private struct DirectorySnapshot {
    let nodes: [SidebarNode]
    let files: [FileItem]
}
