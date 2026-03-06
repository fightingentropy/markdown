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

enum SortOrder { case byName, byDate }

@Observable
@MainActor
final class Workspace {
    var files: [FileItem] = []
    var sidebarNodes: [SidebarNode] = []
    var selectedFileURL: URL?
    var text: String = ""
    var vaultURL: URL?
    var sortOrder: SortOrder = .byDate
    var isCommandPalettePresented = false

    var hasVault: Bool { vaultURL != nil }

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
    private var activeSecurityScopedVaultURL: URL?

    init() {
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
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        vaultURL = url
        refreshFiles()
        if let first = sortedFiles.first {
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

        if isStale, let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }

        refreshFiles()
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

        if let selectedFileURL, !files.contains(where: { $0.url == selectedFileURL }) {
            self.selectedFileURL = nil
            text = ""
        }
    }

    func selectFile(_ url: URL) {
        guard selectedFileURL != url else { return }

        saveCurrentFile()
        if let content = readFile(url) {
            selectedFileURL = url
            text = content
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
        guard let url = selectedFileURL else { return }
        guard (try? Data(text.utf8).write(to: url, options: .atomic)) != nil else { return }
        updateCachedMetadata(for: url, content: text)
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
        if selectedFileURL == url {
            text = ""
            selectedFileURL = nil
        }
        refreshFiles()
    }

    func importDroppedFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8) else { return }

        let parent = url.deletingLastPathComponent()
        beginAccessingVault(parent)

        // Try to bookmark the parent for full vault access
        if let bookmark = try? parent.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }

        vaultURL = parent
        refreshFiles()

        // If directory scan failed (sandbox), ensure the dropped file is listed
        if !files.contains(where: { $0.url == url }) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let noteTitle = Self.extractTitle(from: string)
            files.append(FileItem(id: url, name: url.lastPathComponent, url: url, modificationDate: date, noteTitle: noteTitle))
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        text = string
        selectedFileURL = url

        if !sidebarNodes.contains(where: { $0.url == url }) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            sidebarNodes = sortSidebarNodes(sidebarNodes + [
                SidebarNode(
                    id: url,
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    kind: .file,
                    modificationDate: date
                )
            ])
        }
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

    func renameFile(_ url: URL, to newName: String) {
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newName + ".md")
        try? FileManager.default.moveItem(at: url, to: newURL)
        if selectedFileURL == url {
            selectedFileURL = newURL
        }
        refreshFiles()
    }

    func title(for file: FileItem) -> String {
        if file.url == selectedFileURL,
           let liveTitle = Self.extractTitle(from: text) {
            return liveTitle
        }
        return file.sidebarTitle
    }

    func fileItem(for url: URL) -> FileItem? {
        files.first(where: { $0.url == url })
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
            }
        }

        return DirectorySnapshot(
            nodes: sortSidebarNodes(nodes),
            files: files
        )
    }

    private func makeFileItem(at url: URL, modificationDate: Date) -> FileItem {
        let noteTitle = readFile(url).flatMap(Self.extractTitle(from:))
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

    private static func isMarkdownFile(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
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
