import Darwin
import Foundation

struct TemplateDescriptor: Equatable, Identifiable, Sendable {
    let relativePath: String
    let fileURL: URL

    var id: String { relativePath }
    var displayName: String {
        (relativePath as NSString).deletingPathExtension
    }
}

struct TemplateRenderContext: Equatable, Sendable {
    var title: String
    var date: Date
    var timeZone: TimeZone

    init(title: String, date: Date = Date(), timeZone: TimeZone = .current) {
        self.title = title
        self.date = date
        self.timeZone = timeZone
    }
}

enum NoteWorkflowFileError: LocalizedError, Equatable {
    case missingVault
    case unsafeRelativePath(String)
    case invalidDateFormat
    case templateNotFound(String)
    case unreadableTemplate(String)
    case destinationIsDirectory(String)
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .missingVault:
            "Open a vault before using note workflows."
        case .unsafeRelativePath(let path):
            "The configured path points outside the vault: \(path)"
        case .invalidDateFormat:
            "The Daily Notes date format did not produce a safe file name."
        case .templateNotFound(let path):
            "The template could not be found: \(path)"
        case .unreadableTemplate(let path):
            "The template is not a readable UTF-8 text file: \(path)"
        case .destinationIsDirectory(let path):
            "The Daily Note path is already a folder: \(path)"
        case .destinationExists(let path):
            "A note already exists at: \(path)"
        }
    }
}

struct TemplateLibraryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func availableTemplates(
        in vaultURL: URL,
        configuration: TemplateLibraryConfiguration
    ) throws -> [TemplateDescriptor] {
        let folderURL = try VaultRelativePath.directoryURL(
            root: vaultURL,
            relativePath: configuration.folderPath,
            createIfNeeded: false,
            fileManager: fileManager
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw NoteWorkflowFileError.unsafeRelativePath(configuration.folderPath)
        }

        let allowedExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        var templates: [TemplateDescriptor] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  allowedExtensions.contains(url.pathExtension.lowercased()),
                  url.standardizedFileURL.path.hasPrefix(folderPrefix) else {
                continue
            }
            templates.append(
                TemplateDescriptor(
                    relativePath: String(url.standardizedFileURL.path.dropFirst(folderPrefix.count)),
                    fileURL: url.standardizedFileURL
                )
            )
        }

        return templates.sorted {
            $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending
        }
    }

    func loadTemplate(
        relativePath: String,
        in vaultURL: URL,
        configuration: TemplateLibraryConfiguration
    ) throws -> String {
        var requestedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedPath.isEmpty else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        if (requestedPath as NSString).pathExtension.isEmpty {
            requestedPath += ".md"
        }

        let root = try VaultRelativePath.directoryURL(
            root: vaultURL,
            relativePath: configuration.folderPath,
            createIfNeeded: false,
            fileManager: fileManager
        )
        var isTemplateDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isTemplateDirectory),
              isTemplateDirectory.boolValue else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        let fileURL = try VaultRelativePath.existingFileURL(
            root: root,
            relativePath: requestedPath,
            fileManager: fileManager
        )

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            if !fileManager.fileExists(atPath: fileURL.path) {
                throw NoteWorkflowFileError.templateNotFound(relativePath)
            }
            throw NoteWorkflowFileError.unreadableTemplate(relativePath)
        }
    }

    func render(_ template: String, context: TemplateRenderContext) -> String {
        ObsidianTemplateRenderer.render(
            template,
            title: context.title,
            date: context.date,
            timeZone: context.timeZone
        )
    }
}

struct DailyNoteCreationResult: Equatable, Sendable {
    let fileURL: URL
    let wasCreated: Bool
}

struct TemplateNoteService {
    private let fileManager: FileManager
    private let templateService: TemplateLibraryService

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.templateService = TemplateLibraryService(fileManager: fileManager)
    }

    func create(
        in vaultURL: URL,
        title: String,
        template: TemplateDescriptor,
        templateConfiguration: TemplateLibraryConfiguration,
        destinationFolderPath: String = "",
        date: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> URL {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty,
              cleanTitle.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\n\r")) == nil else {
            throw NoteWorkflowFileError.unsafeRelativePath(title)
        }

        let templateText = try templateService.loadTemplate(
            relativePath: template.relativePath,
            in: vaultURL,
            configuration: templateConfiguration
        )
        let rendered = templateService.render(
            templateText,
            context: TemplateRenderContext(title: cleanTitle, date: date, timeZone: timeZone)
        )
        let relativePath = [destinationFolderPath, cleanTitle + ".md"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "/")
        let destination = try VaultRelativePath.destinationFileURL(
            root: vaultURL,
            relativePath: relativePath,
            fileManager: fileManager
        )
        guard try ExclusiveAtomicFileWriter.writeIfAbsent(
            Data(rendered.utf8),
            to: destination,
            fileManager: fileManager
        ) else {
            throw NoteWorkflowFileError.destinationExists(relativePath)
        }
        return destination
    }
}

struct DailyNoteService {
    private let fileManager: FileManager
    private let templateService: TemplateLibraryService

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.templateService = TemplateLibraryService(fileManager: fileManager)
    }

    /// Creates today's note exactly once. If the note already exists (or a
    /// competing process wins the creation race), its URL is returned without
    /// altering a byte of the existing file.
    func createOrOpen(
        in vaultURL: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        configuration: DailyNoteConfiguration,
        templateConfiguration: TemplateLibraryConfiguration = .default
    ) throws -> DailyNoteCreationResult {
        let datedPath = try Self.relativeDatedPath(
            for: date,
            dateFormat: configuration.dateFormat,
            timeZone: timeZone
        )
        let combinedPath = [configuration.folderPath, datedPath]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "/")
        let destinationURL = try VaultRelativePath.destinationFileURL(
            root: vaultURL,
            relativePath: combinedPath,
            fileManager: fileManager
        )

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw NoteWorkflowFileError.destinationIsDirectory(destinationURL.path)
            }
            return DailyNoteCreationResult(fileURL: destinationURL, wasCreated: false)
        }

        let content: String
        if let templatePath = configuration.templateRelativePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !templatePath.isEmpty {
            let template = try templateService.loadTemplate(
                relativePath: templatePath,
                in: vaultURL,
                configuration: templateConfiguration
            )
            let title = destinationURL.deletingPathExtension().lastPathComponent
            content = templateService.render(
                template,
                context: TemplateRenderContext(title: title, date: date, timeZone: timeZone)
            )
        } else {
            content = ""
        }

        let created = try ExclusiveAtomicFileWriter.writeIfAbsent(
            Data(content.utf8),
            to: destinationURL,
            fileManager: fileManager
        )
        let verifiedURL: URL
        if created {
            verifiedURL = destinationURL
        } else {
            // Revalidate after an exclusive-rename race. A path swapped to an
            // out-of-vault symlink must never be handed back to the caller.
            verifiedURL = try VaultRelativePath.destinationFileURL(
                root: vaultURL,
                relativePath: combinedPath,
                fileManager: fileManager
            )
        }
        return DailyNoteCreationResult(fileURL: verifiedURL, wasCreated: created)
    }

    static func relativeDatedPath(
        for date: Date,
        dateFormat: String,
        timeZone: TimeZone
    ) throws -> String {
        let trimmedFormat = dateFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFormat.isEmpty else { throw NoteWorkflowFileError.invalidDateFormat }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = ObsidianDateFormat.foundationFormat(from: trimmedFormat)

        var path = formatter.string(from: date)
        guard !path.isEmpty else { throw NoteWorkflowFileError.invalidDateFormat }
        if !path.lowercased().hasSuffix(".md")
            && !path.lowercased().hasSuffix(".markdown") {
            path += ".md"
        }
        guard VaultRelativePath.isSafe(path) else {
            throw NoteWorkflowFileError.invalidDateFormat
        }
        return path
    }
}

private enum ObsidianDateFormat {
    /// Obsidian's default `YYYY-MM-DD` uses Moment tokens, while DateFormatter
    /// interprets capital Y/D as week-year/day-of-year. Translate the common
    /// tokens so copied Daily Notes settings retain their intended dates.
    static func foundationFormat(from source: String) -> String {
        let replacements: [(String, String)] = [
            ("dddd", "EEEE"),
            ("ddd", "EEE"),
            ("YYYY", "yyyy"),
            ("YY", "yy"),
            ("DD", "dd"),
            ("D", "d")
        ]
        return replacements.reduce(source) { value, replacement in
            value.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }
}

private enum VaultRelativePath {
    static func isSafe(_ relativePath: String) -> Bool {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func directoryURL(
        root: URL,
        relativePath: String,
        createIfNeeded: Bool,
        fileManager: FileManager
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return try verifiedRoot(root, fileManager: fileManager)
        }
        guard isSafe(trimmed) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }

        var current = try verifiedRoot(root, fileManager: fileManager)
        let components = trimmed.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            let candidate = current.appendingPathComponent(component, isDirectory: true)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
                }
                let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
                guard isInside(resolved, root: try verifiedRoot(root, fileManager: fileManager)) else {
                    throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
                }
                current = resolved
            } else {
                guard createIfNeeded else {
                    return components[(index + 1)...].reduce(candidate) { partial, remaining in
                        partial.appendingPathComponent(remaining, isDirectory: true)
                    }.standardizedFileURL
                }
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                current = candidate.standardizedFileURL
            }
        }
        return current
    }

    static func destinationFileURL(
        root: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> URL {
        guard isSafe(relativePath) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let directoryPath = components.dropLast().joined(separator: "/")
        let directory = try directoryURL(
            root: root,
            relativePath: directoryPath,
            createIfNeeded: true,
            fileManager: fileManager
        )
        let candidate = directory.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        if fileManager.fileExists(atPath: candidate.path) {
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            let verifiedVault = try verifiedRoot(root, fileManager: fileManager)
            guard isInside(resolved, root: verifiedVault) else {
                throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
            }
        }
        return candidate
    }

    static func existingFileURL(
        root: URL,
        relativePath: String,
        fileManager: FileManager
    ) throws -> URL {
        guard isSafe(relativePath) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        let rootURL = try verifiedRoot(root, fileManager: fileManager)
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: rootURL) else {
            throw NoteWorkflowFileError.unsafeRelativePath(relativePath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NoteWorkflowFileError.templateNotFound(relativePath)
        }
        return resolved
    }

    private static func verifiedRoot(_ root: URL, fileManager: FileManager) throws -> URL {
        guard root.isFileURL else { throw NoteWorkflowFileError.missingVault }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NoteWorkflowFileError.missingVault
        }
        return resolved
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }
}

enum ExclusiveAtomicFileWriter {
    /// Writes a complete temporary file, flushes it, then atomically links it
    /// into place with RENAME_EXCL. Unlike a check-then-write sequence, this
    /// cannot replace a Daily Note created by another process in the interim.
    static func writeIfAbsent(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
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

        let result = renamex_np(temporaryURL.path, destinationURL.path, UInt32(RENAME_EXCL))
        if result == 0 {
            shouldRemoveTemporaryFile = false
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
}
