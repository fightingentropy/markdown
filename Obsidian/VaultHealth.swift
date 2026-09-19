import Foundation

enum VaultHealthSeverity: Int, Comparable, Sendable {
    case info
    case warning
    case error

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct VaultHealthIssue: Identifiable, Sendable {
    let severity: VaultHealthSeverity
    let title: String
    let detail: String
    let fileURL: URL?

    var id: String {
        "\(severity.rawValue):\(fileURL?.path ?? "vault"):\(title):\(detail)"
    }
}

struct VaultHealthNote: Sendable {
    let url: URL
    let title: String
    let body: String
}

struct VaultHealthReport: Sendable {
    let issues: [VaultHealthIssue]
    let noteCount: Int
    let attachmentCount: Int
    let recoveryDraftCount: Int

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }
}

enum VaultHealthScanner {
    static func scan(vaultURL: URL, notes: [VaultHealthNote]) -> VaultHealthReport {
        let fileManager = FileManager.default
        let metadata = Dictionary(uniqueKeysWithValues: notes.map {
            ($0.url.standardizedFileURL, ObsidianMetadataParser.parse($0.body))
        })
        var targetLookup: [String: [URL]] = [:]
        for note in notes {
            let parsed = metadata[note.url.standardizedFileURL]
            let names = [note.url.deletingPathExtension().lastPathComponent, note.title, parsed?.title]
                .compactMap { $0 } + (parsed?.aliases ?? [])
            for name in names {
                targetLookup[name.lowercased(), default: []].append(note.url)
            }
        }

        var issues: [VaultHealthIssue] = []
        for (name, urls) in targetLookup where urls.count > 1 {
            issues.append(VaultHealthIssue(
                severity: .warning,
                title: "Duplicate note target",
                detail: "“\(name)” resolves to \(urls.count) notes.",
                fileURL: urls.first
            ))
        }

        for note in notes {
            if hasUnterminatedFrontmatter(note.body) {
                issues.append(VaultHealthIssue(
                    severity: .error,
                    title: "Unterminated frontmatter",
                    detail: "The opening YAML delimiter has no closing delimiter.",
                    fileURL: note.url
                ))
            }

            for target in wikiTargets(in: note.body) {
                let cleanTarget = target
                    .split(separator: "#", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !cleanTarget.isEmpty else { continue }

                if cleanTarget.contains("/") || !(cleanTarget as NSString).pathExtension.isEmpty {
                    if resolveLocalReference(cleanTarget, from: note.url, vaultURL: vaultURL, fileManager: fileManager) == nil,
                       targetLookup[(cleanTarget as NSString).deletingPathExtension.lowercased()] == nil {
                        issues.append(missingIssue(target: cleanTarget, note: note))
                    }
                } else if targetLookup[cleanTarget.lowercased()] == nil {
                    issues.append(missingIssue(target: cleanTarget, note: note))
                }
            }

            for target in markdownImageTargets(in: note.body) where !isRemoteReference(target) {
                if resolveLocalReference(target, from: note.url, vaultURL: vaultURL, fileManager: fileManager) == nil {
                    issues.append(missingIssue(target: target, note: note))
                }
            }
        }

        let attachmentCount = countAttachments(in: vaultURL, fileManager: fileManager)
        let recoveryDraftCount = countRecoveryDrafts(for: vaultURL)
        if recoveryDraftCount > 0 {
            issues.append(VaultHealthIssue(
                severity: .info,
                title: "Recovery drafts available",
                detail: "\(recoveryDraftCount) crash-recovery draft(s) belong to this vault.",
                fileURL: nil
            ))
        }

        return VaultHealthReport(
            issues: issues.sorted { $0.severity > $1.severity },
            noteCount: notes.count,
            attachmentCount: attachmentCount,
            recoveryDraftCount: recoveryDraftCount
        )
    }

    private static func missingIssue(target: String, note: VaultHealthNote) -> VaultHealthIssue {
        VaultHealthIssue(
            severity: .error,
            title: "Missing link or attachment",
            detail: "\(target) referenced by \(note.title)",
            fileURL: note.url
        )
    }

    private static func wikiTargets(in body: String) -> [String] {
        regexCaptures(#"!?\[\[([^\]|]+)"#, in: body)
    }

    private static func markdownImageTargets(in body: String) -> [String] {
        regexCaptures(#"!\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#, in: body)
    }

    private static func regexCaptures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap {
            guard $0.numberOfRanges > 1, $0.range(at: 1).location != NSNotFound else { return nil }
            return nsText.substring(with: $0.range(at: 1))
        }
    }

    private static func hasUnterminatedFrontmatter(_ body: String) -> Bool {
        let lines = body.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return false }
        return !lines.dropFirst().contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "---" || trimmed == "..."
        }
    }

    private static func resolveLocalReference(
        _ reference: String,
        from noteURL: URL,
        vaultURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let decoded = reference.removingPercentEncoding ?? reference
        let candidates = [
            noteURL.deletingLastPathComponent().appendingPathComponent(decoded),
            vaultURL.appendingPathComponent(decoded),
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.standardizedFileURL.path) }
    }

    private static func isRemoteReference(_ reference: String) -> Bool {
        guard let scheme = URL(string: reference)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "data"
    }

    private static func countAttachments(in vaultURL: URL, fileManager: FileManager) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        let markdownExtensions: Set<String> = ["md", "markdown", "mdown"]
        return enumerator.compactMap { $0 as? URL }.filter {
            !markdownExtensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
    }

    private static func countRecoveryDrafts(for vaultURL: URL) -> Int {
        let directory = RecoveryStore().directoryURL
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        let prefix = vaultURL.standardizedFileURL.path + "/"
        return urls.compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? JSONDecoder().decode(RecoveryDraft.self, from: $0) }
            .filter { $0.sourcePath.hasPrefix(prefix) }
            .count
    }
}
