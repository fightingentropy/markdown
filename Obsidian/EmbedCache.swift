import AppKit
import ImageIO
import UniformTypeIdentifiers

/// PNG encoding, decoding and disk maintenance never run on the UI thread.
actor EmbedSnapshotStore {
    let directory: URL
    let byteLimit: Int
    let maximumAge: TimeInterval

    init(directory: URL, byteLimit: Int = 64 * 1_024 * 1_024, maximumAge: TimeInterval = 7 * 24 * 3600) {
        self.directory = directory
        self.byteLimit = max(0, byteLimit)
        self.maximumAge = maximumAge
    }

    func image(for key: String) -> CGImage? {
        let url = fileURL(for: key)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let date = values.contentModificationDate,
              Date().timeIntervalSince(date) < maximumAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    func save(_ image: CGImage, for key: String) {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (data as Data).write(to: fileURL(for: key), options: .atomic)
        prune()
    }

    func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard url.pathExtension == "png", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var retainedBytes = 0
        for (url, date, size) in entries {
            if Date().timeIntervalSince(date) >= maximumAge || size > byteLimit - retainedBytes {
                try? FileManager.default.removeItem(at: url)
            } else {
                retainedBytes += size
            }
        }
    }

    func fileURL(for key: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        return directory.appendingPathComponent("\(safeKey).png")
    }
}

enum EmbedSnapshotKey {
    static func make(content: String, width: CGFloat, scale: CGFloat) -> String {
        "v2-\(content)-w\(Int(max(1, width).rounded()))-s\(Int(max(1, scale) * 100))"
    }
}

@MainActor
final class EditorEmbedCache {
    static let shared = EditorEmbedCache()
    private let userDefaults: UserDefaults
    private let heightStorageKey: String
    private var heights: [String: Double]
    private let imageCache = NSCache<NSString, NSImage>()
    private let store: EmbedSnapshotStore

    init(userDefaults: UserDefaults = .standard, heightStorageKey: String = "editorEmbedCache.xHeights.v2", snapshotDirectoryURL: URL? = nil) {
        self.userDefaults = userDefaults
        self.heightStorageKey = heightStorageKey
        self.heights = userDefaults.dictionary(forKey: heightStorageKey) as? [String: Double] ?? [:]
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        store = EmbedSnapshotStore(directory: snapshotDirectoryURL ?? base.appendingPathComponent("Markdown/EmbedSnapshots", isDirectory: true))
        imageCache.countLimit = 24
        imageCache.totalCostLimit = 32 * 1_024 * 1_024
        Task { await store.prune() }
    }

    func xHeight(for statusID: String, width: CGFloat = 550) -> CGFloat? {
        guard let height = heights[heightKey(statusID, width)], height.isFinite, height > 0 else { return nil }
        return CGFloat(height)
    }

    func saveXHeight(_ height: CGFloat, for statusID: String, width: CGFloat = 550) {
        guard height.isFinite, height > 0 else { return }
        let key = heightKey(statusID, width)
        guard heights[key] != Double(height) else { return }
        if heights[key] == nil, heights.count >= 512, let oldest = heights.keys.sorted().first {
            heights.removeValue(forKey: oldest)
        }
        heights[key] = Double(height)
        userDefaults.set(heights, forKey: heightStorageKey)
    }

    func snapshot(for key: String) async -> NSImage? {
        if let image = imageCache.object(forKey: key as NSString) { return image }
        guard let bitmap = await store.image(for: key) else { return nil }
        let image = NSImage(cgImage: bitmap, size: .zero)
        imageCache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }

    func saveSnapshot(_ image: NSImage, for key: String) async {
        guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        imageCache.setObject(image, forKey: key as NSString, cost: bitmap.bytesPerRow * bitmap.height)
        await store.save(bitmap, for: key)
    }

    private func heightKey(_ statusID: String, _ width: CGFloat) -> String {
        "\(statusID)-w\(Int(max(1, width).rounded()))"
    }
}

/// Session-only playback positions survive view eviction without autoplaying.
@MainActor
final class EmbedPlaybackStore {
    static let shared = EmbedPlaybackStore()
    private var positions: [String: Double] = [:]
    private var accessOrder: [String] = []

    func position(for key: String) -> Double? { positions[key] }

    func save(_ seconds: Double, for key: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[key] = seconds
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        if accessOrder.count > 128 { positions.removeValue(forKey: accessOrder.removeFirst()) }
    }
}
