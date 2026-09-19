import Foundation

struct WorkspaceSessionSnapshot: Codable, Equatable {
    var openRelativePaths: [String]
    var pinnedRelativePaths: [String]
    var splitPreview: Bool
}

@Observable
@MainActor
final class WorkspaceSession {
    private(set) var tabs: [URL] = []
    private(set) var pinnedTabs: Set<URL> = []
    var splitPreview = false {
        didSet {
            if !isRestoring { persist() }
        }
    }

    private var vaultURL: URL?
    private let userDefaults: UserDefaults
    private let maximumUnpinnedTabs = 12
    private var isRestoring = false

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Restores the session only after the vault inventory is ready. During an
    /// asynchronous vault switch `availableFiles` is temporarily empty; treating
    /// that transient state as authoritative would discard every saved tab and
    /// pin before the snapshot finishes loading.
    @discardableResult
    func load(
        for vaultURL: URL?,
        availableFiles: Set<URL>,
        inventoryReady: Bool = true
    ) -> Bool {
        guard inventoryReady else { return false }

        isRestoring = true
        defer { isRestoring = false }
        self.vaultURL = vaultURL?.standardizedFileURL
        tabs = []
        pinnedTabs = []
        splitPreview = false

        guard let vaultURL = self.vaultURL,
              let data = userDefaults.data(forKey: storageKey(for: vaultURL)),
              let snapshot = try? JSONDecoder().decode(WorkspaceSessionSnapshot.self, from: data) else {
            return true
        }

        let standardizedFiles = Set(availableFiles.map { $0.standardizedFileURL })
        tabs = snapshot.openRelativePaths
            .map { vaultURL.appendingPathComponent($0).standardizedFileURL }
            .filter { standardizedFiles.contains($0) }
        pinnedTabs = Set(snapshot.pinnedRelativePaths
            .map { vaultURL.appendingPathComponent($0).standardizedFileURL }
            .filter { standardizedFiles.contains($0) })
        splitPreview = snapshot.splitPreview
        return true
    }

    func isLoaded(for vaultURL: URL?) -> Bool {
        self.vaultURL == vaultURL?.standardizedFileURL
    }

    func noteSelected(_ url: URL?) {
        guard let url else { return }
        let standardized = url.standardizedFileURL
        guard isInsideVault(standardized) else { return }

        if !tabs.contains(standardized) {
            tabs.append(standardized)
        }
        trimUnpinnedTabs(keeping: standardized)
        persist()
    }

    func close(_ url: URL, selectedURL: URL?) -> URL? {
        let standardized = url.standardizedFileURL
        guard let index = tabs.firstIndex(of: standardized) else { return selectedURL }

        tabs.remove(at: index)
        pinnedTabs.remove(standardized)
        persist()

        guard selectedURL?.standardizedFileURL == standardized else { return selectedURL }
        guard !tabs.isEmpty else { return nil }
        return tabs[min(index, tabs.count - 1)]
    }

    func togglePinned(_ url: URL) {
        let standardized = url.standardizedFileURL
        if pinnedTabs.contains(standardized) {
            pinnedTabs.remove(standardized)
        } else {
            if !tabs.contains(standardized) {
                tabs.append(standardized)
            }
            pinnedTabs.insert(standardized)
        }
        persist()
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedTabs.contains(url.standardizedFileURL)
    }

    func prune(availableFiles: Set<URL>) {
        let standardized = Set(availableFiles.map { $0.standardizedFileURL })
        tabs.removeAll { !standardized.contains($0) }
        pinnedTabs = pinnedTabs.filter { standardized.contains($0) }
        persist()
    }

    private func trimUnpinnedTabs(keeping selectedURL: URL) {
        while tabs.filter({ !pinnedTabs.contains($0) }).count > maximumUnpinnedTabs {
            guard let removableIndex = tabs.firstIndex(where: {
                $0 != selectedURL && !pinnedTabs.contains($0)
            }) else { break }
            tabs.remove(at: removableIndex)
        }
    }

    private func persist() {
        guard let vaultURL else { return }
        let snapshot = WorkspaceSessionSnapshot(
            openRelativePaths: tabs.compactMap { relativePath(for: $0, vaultURL: vaultURL) },
            pinnedRelativePaths: pinnedTabs.compactMap { relativePath(for: $0, vaultURL: vaultURL) }.sorted(),
            splitPreview: splitPreview
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey(for: vaultURL))
    }

    private func isInsideVault(_ url: URL) -> Bool {
        guard let vaultURL else { return false }
        return url.path.hasPrefix(vaultURL.path + "/")
    }

    private func relativePath(for url: URL, vaultURL: URL) -> String? {
        let prefix = vaultURL.path.hasSuffix("/") ? vaultURL.path : vaultURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        return String(url.standardizedFileURL.path.dropFirst(prefix.count))
    }

    private func storageKey(for vaultURL: URL) -> String {
        "workspaceSession::" + vaultURL.standardizedFileURL.path
    }
}
