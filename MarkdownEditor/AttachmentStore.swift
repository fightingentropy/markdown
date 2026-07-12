import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum AttachmentStoreError: LocalizedError {
    case missingVault
    case unsupportedAttachment
    case unsafeAttachmentFolder

    var errorDescription: String? {
        switch self {
        case .missingVault:
            "Open a vault before adding an attachment."
        case .unsupportedAttachment:
            "The pasted or dropped item is not a supported image or file."
        case .unsafeAttachmentFolder:
            "The configured attachment folder points outside this vault."
        }
    }
}

struct ImportedAttachment: Equatable {
    let fileURL: URL
    let vaultRelativePath: String

    var markdownEmbed: String {
        "![[\(vaultRelativePath)]]"
    }
}

enum AttachmentStore {
    private static let defaultFolderName = "attachments"
    private static let imageExtensions: Set<String> = [
        "avif", "gif", "heic", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"
    ]

    @MainActor
    static func importFirstAttachment(
        from pasteboard: NSPasteboard,
        documentURL: URL?,
        vaultURL: URL?
    ) throws -> ImportedAttachment? {
        guard let vaultURL else { throw AttachmentStoreError.missingVault }

        if let sourceURL = fileURL(from: pasteboard) {
            return try importFile(sourceURL, documentURL: documentURL, vaultURL: vaultURL)
        }

        if let pngData = pasteboard.data(forType: .png) {
            return try importImageData(
                pngData,
                suggestedFilename: pastedImageFilename(extension: "png"),
                documentURL: documentURL,
                vaultURL: vaultURL
            )
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return try importImageData(
                pngData,
                suggestedFilename: pastedImageFilename(extension: "png"),
                documentURL: documentURL,
                vaultURL: vaultURL
            )
        }

        return nil
    }

    static func importFile(
        _ sourceURL: URL,
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportedAttachment {
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        guard source.isFileURL,
              fileManager.fileExists(atPath: source.path) else {
            throw AttachmentStoreError.unsupportedAttachment
        }

        let folder = try preparedAttachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw AttachmentStoreError.unsupportedAttachment
        }

        while true {
            let destination = collisionSafeURL(
                in: folder,
                suggestedFilename: source.lastPathComponent,
                fileManager: fileManager
            )
            if try copyFileIfAbsent(source, to: destination, fileManager: fileManager) {
                return importedAttachment(at: destination, vaultURL: vaultURL)
            }
        }
    }

    static func importImageData(
        _ data: Data,
        suggestedFilename: String,
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportedAttachment {
        guard !data.isEmpty else { throw AttachmentStoreError.unsupportedAttachment }

        let folder = try preparedAttachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )

        while true {
            let destination = collisionSafeURL(
                in: folder,
                suggestedFilename: suggestedFilename,
                fileManager: fileManager
            )
            if try writeDataIfAbsent(data, to: destination, fileManager: fileManager) {
                return importedAttachment(at: destination, vaultURL: vaultURL)
            }
        }
    }

    static func attachmentFolderURL(
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let vault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        let configuredPath = obsidianAttachmentFolderPath(vaultURL: vault)

        let candidate: URL
        if let configuredPath, configuredPath == "." {
            candidate = documentURL?.deletingLastPathComponent() ?? vault
        } else if let configuredPath, !configuredPath.isEmpty {
            let relativePath = configuredPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            candidate = vault.appendingPathComponent(relativePath, isDirectory: true)
        } else if fileManager.fileExists(atPath: vault.appendingPathComponent("img", isDirectory: true).path) {
            candidate = vault.appendingPathComponent("img", isDirectory: true)
        } else {
            candidate = vault.appendingPathComponent(defaultFolderName, isDirectory: true)
        }

        return try validatedAttachmentFolder(candidate, vaultURL: vault)
    }

    /// Creates the selected attachment directory, then validates its resolved
    /// location a second time. The second check matters because a pre-existing
    /// path component may be a symlink and directory creation follows it.
    private static func preparedAttachmentFolderURL(
        documentURL: URL?,
        vaultURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let candidate = try attachmentFolderURL(
            documentURL: documentURL,
            vaultURL: vaultURL,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        let vault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        return try validatedAttachmentFolder(candidate, vaultURL: vault)
    }

    private static func validatedAttachmentFolder(_ candidate: URL, vaultURL: URL) throws -> URL {
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path == vaultURL.path || resolved.path.hasPrefix(vaultURL.path + "/") else {
            throw AttachmentStoreError.unsafeAttachmentFolder
        }
        return resolved
    }

    private static func obsidianAttachmentFolderPath(vaultURL: URL) -> String? {
        let settingsURL = vaultURL
            .appendingPathComponent(".obsidian", isDirectory: true)
            .appendingPathComponent("app.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["attachmentFolderPath"] as? String
    }

    private static func collisionSafeURL(
        in folderURL: URL,
        suggestedFilename: String,
        fileManager: FileManager
    ) -> URL {
        let sanitized = sanitizedFilename(suggestedFilename)
        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        var candidate = folderURL.appendingPathComponent(sanitized)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            candidate = folderURL.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
    }

    /// Copies through a private temporary file and installs it with
    /// `RENAME_EXCL`, so an iCloud or local writer that wins the destination
    /// race is never overwritten.
    private static func copyFileIfAbsent(
        _ sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = temporaryURL(nextTo: destinationURL)
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        // Attachments are data, not launchable programs. Do not preserve an
        // executable source mode inside the vault.
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)

        let installed = try installTemporaryFileExclusively(
            temporaryURL,
            at: destinationURL
        )
        if installed {
            shouldRemoveTemporaryFile = false
        }
        return installed
    }

    static func writeDataIfAbsent(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = temporaryURL(nextTo: destinationURL)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var shouldRemoveTemporaryFile = true
        defer {
            if shouldRemoveTemporaryFile {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryURL.path)

        let installed = try installTemporaryFileExclusively(
            temporaryURL,
            at: destinationURL
        )
        if installed {
            shouldRemoveTemporaryFile = false
        }
        return installed
    }

    private static func installTemporaryFileExclusively(
        _ temporaryURL: URL,
        at destinationURL: URL
    ) throws -> Bool {
        let result = renamex_np(
            temporaryURL.path,
            destinationURL.path,
            UInt32(RENAME_EXCL)
        )
        if result == 0 {
            return true
        }

        let errorCode = errno
        if errorCode == EEXIST {
            return false
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [NSFilePathErrorKey: destinationURL.path]
        )
    }

    private static func temporaryURL(nextTo destinationURL: URL) -> URL {
        destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).attachment-tmp",
            isDirectory: false
        )
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let fallbackExtension = imageExtensions.contains((filename as NSString).pathExtension.lowercased())
            ? (filename as NSString).pathExtension.lowercased()
            : "bin"
        let rawBase = (filename as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()."))
        let base = rawBase.unicodeScalars
            .map { allowed.contains($0) ? Character(String($0)) : "-" }
            .reduce(into: "") { $0.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "Attachment" : base
        let rawExtension = (filename as NSString).pathExtension.lowercased()
        let safeExtension = rawExtension.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil
            ? rawExtension
            : fallbackExtension
        return safeExtension.isEmpty ? safeBase : "\(safeBase).\(safeExtension)"
    }

    private static func importedAttachment(at url: URL, vaultURL: URL) -> ImportedAttachment {
        let vaultPath = vaultURL.standardizedFileURL.path.hasSuffix("/")
            ? vaultURL.standardizedFileURL.path
            : vaultURL.standardizedFileURL.path + "/"
        let relativePath = String(url.standardizedFileURL.path.dropFirst(vaultPath.count))
        return ImportedAttachment(fileURL: url, vaultRelativePath: relativePath)
    }

    private static func pastedImageFilename(extension pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "Pasted image \(formatter.string(from: Date())).\(pathExtension)"
    }

    @MainActor
    private static func fileURL(from pasteboard: NSPasteboard) -> URL? {
        if let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL] {
            return objects.first
        }
        return nil
    }
}
