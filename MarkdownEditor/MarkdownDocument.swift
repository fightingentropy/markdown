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

enum SortOrder { case byName, byDate }

@Observable
@MainActor
final class Workspace {
    var files: [FileItem] = []
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
        if let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        vaultURL = url
        refreshFiles()
        if let first = files.first {
            selectFile(first.url)
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

        guard url.startAccessingSecurityScopedResource() else { return }
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
        guard let vaultURL else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: vaultURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        files = contents
            .filter { ["md", "markdown", "mdown"].contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let noteTitle = readFile(url).flatMap(Self.extractTitle(from:))
                return FileItem(id: url, name: url.lastPathComponent, url: url, modificationDate: date, noteTitle: noteTitle)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
}
