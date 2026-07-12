import Foundation
import XCTest

@testable import Markdown

@MainActor
final class SecurityAndSearchTests: XCTestCase {

    // MARK: - HTML preview sanitization (C1 regression)

    /// Renders `markdown` through the HTML preview path. A trailing mermaid
    /// block forces the document into HTML render mode so the renderer (the XSS
    /// sink) is actually exercised.
    private func renderHTML(_ markdown: String) -> String {
        let payload = """
        \(markdown)

        ```mermaid
        graph TD
        A-->B
        ```
        """
        let context = PreviewContext(documentURL: nil, vaultURL: nil)
        let document = MarkdownPreprocessor.preprocess(payload, context: context)
        return HTMLPreviewRenderer.render(document: document)
    }

    func testRawHTMLIframeIsNeutralized() {
        // Single-line iframe containing "://" — the exact vector the old
        // hand-rolled escaper let through via its autolink whitelist.
        let html = renderHTML("<iframe src=\"https://evil.example\"></iframe>")
        XCTAssertFalse(html.contains("<iframe"), "Raw <iframe> must not survive into preview HTML; got: \(html)")
    }

    func testMultiLineRawHTMLEventHandlerIsNeutralized() {
        // Tag split across two lines — defeated the old line-scoped escaper.
        // The `<` must be escaped so no live <img> tag (and thus no live
        // onerror handler) reaches the DOM; the text may still appear inert.
        let html = renderHTML("<img src=x\nonerror=alert(document.domain)>")
        XCTAssertFalse(html.contains("<img"), "Raw <img> tag must not survive as live HTML; got: \(html)")
        XCTAssertTrue(html.contains("&lt;img"), "The opening bracket should be escaped; got: \(html)")
    }

    func testRawScriptTagIsNeutralized() {
        let html = renderHTML("<script>alert('xss')</script>")
        XCTAssertFalse(html.contains("<script>alert"), "Raw <script> must not survive; got: \(html)")
    }

    func testJavascriptLinkSchemeIsNeutralized() {
        let html = renderHTML("[click me](javascript:alert(1))")
        XCTAssertFalse(html.contains("javascript:"), "javascript: URL must be stripped; got: \(html)")
    }

    func testHTTPAutolinkStillWorks() {
        // Safe mode must not break legitimate angle autolinks.
        let html = renderHTML("<https://example.com>")
        XCTAssertTrue(html.contains("href=\"https://example.com\""), "Autolink should still render; got: \(html)")
    }

    // MARK: - Full-text search

    func testSearchMatchesTitleAndBody() throws {
        let fixture = try makeVault(files: [
            ("Apple", "# Apple\n\nA crunchy fruit"),
            ("Banana", "# Banana\n\nA yellow fruit")
        ])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let entries = workspace.makeSearchEntries()

        let titleHit = Workspace.search(entries, query: "banana")
        XCTAssertEqual(titleHit.count, 1)
        XCTAssertEqual(titleHit.first?.url.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertFalse(titleHit.first?.isBodyMatch ?? true)

        let bodyHit = Workspace.search(entries, query: "yellow")
        XCTAssertEqual(bodyHit.count, 1)
        XCTAssertEqual(bodyHit.first?.url.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertTrue(bodyHit.first?.isBodyMatch ?? false)
        XCTAssertEqual(bodyHit.first?.subtitle, "A yellow fruit")

        XCTAssertEqual(Workspace.search(entries, query: "").count, entries.count)
        XCTAssertTrue(Workspace.search(entries, query: "zzz-nomatch").isEmpty)
    }

    func testSearchIsCaseAndDiacriticInsensitive() throws {
        let fixture = try makeVault(files: [("Cafe", "# Café\n\nEspresso résumé")])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        let entries = workspace.makeSearchEntries()

        XCTAssertEqual(Workspace.search(entries, query: "cafe").count, 1)
        XCTAssertEqual(Workspace.search(entries, query: "RESUME").count, 1)
    }

    func testSearchSnippetCentersOnMatch() throws {
        let prefix = String(repeating: "lorem ipsum ", count: 20)
        let suffix = String(repeating: " dolor sit", count: 20)
        let body = prefix + "NEEDLE" + suffix

        let snippet = try XCTUnwrap(Workspace.searchSnippet(in: body, query: "needle"))
        XCTAssertTrue(snippet.contains("NEEDLE"))
        XCTAssertTrue(snippet.hasPrefix("\u{2026}"))
        XCTAssertTrue(snippet.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(snippet.count, 142)
    }

    // MARK: - External-change conflict (H1) and write-error surfacing (H2)

    func testExternalChangeProducesConflictInsteadOfClobbering() throws {
        let fixture = try makeVault(files: [("Note", "# Note\n\noriginal")])
        let fileURL = fixture.fileURLs[0]
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)

        // User edits in the editor…
        workspace.text = "# Note\n\nmy local edits"

        // …meanwhile another process rewrites the file with a newer timestamp.
        let externalContent = "# Note\n\nchanged on disk by another app"
        try Data(externalContent.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )

        workspace.saveCurrentFile()

        // The external edits must NOT be clobbered, and a conflict surfaced.
        XCTAssertNotNil(workspace.saveConflict)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), externalContent)

        // Resolving in favor of the local buffer writes it through.
        workspace.resolveSaveConflictKeepingMine()
        XCTAssertNil(workspace.saveConflict)
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "# Note\n\nmy local edits")
    }

    func testReloadFromDiskAdoptsExternalContent() throws {
        let fixture = try makeVault(files: [("Note", "# Note\n\noriginal")])
        let fileURL = fixture.fileURLs[0]
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)
        workspace.text = "# Note\n\nmy local edits"

        let externalContent = "# Note\n\nexternal wins"
        try Data(externalContent.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: fileURL.path
        )
        workspace.saveCurrentFile()
        XCTAssertNotNil(workspace.saveConflict)

        workspace.resolveSaveConflictUsingDisk()
        XCTAssertNil(workspace.saveConflict)
        XCTAssertEqual(workspace.text, externalContent)
    }

    // MARK: - Non-UTF-8 decoding (M12)

    func testNonUTF8FileIsNotReadAsEmpty() throws {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "vaultBookmark")
            try? FileManager.default.removeItem(at: vaultURL)
        }
        let fileURL = vaultURL.appendingPathComponent("Latin1.md").standardizedFileURL
        // "# Café" with the é encoded as ISO Latin-1 (0xE9) — invalid UTF-8.
        var bytes = Array("# Caf".utf8)
        bytes.append(0xE9)
        try Data(bytes).write(to: fileURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fileURL)

        XCTAssertFalse(workspace.text.isEmpty, "Non-UTF-8 file must not load as empty (would clobber on save)")
        XCTAssertTrue(workspace.text.contains("Caf"))
    }

    // MARK: - Document safety and crash recovery

    func testOpeningFrontmatterNotePreservesBytesAndDoesNotInsertHeading() throws {
        let original = """
        ---
        title: Project Atlas
        aliases:
          - Atlas
        tags: [work, active]
        ---

        Body without an H1.
        """
        let fixture = try makeVault(files: [("Atlas", original)])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        XCTAssertEqual(workspace.text, original)
        XCTAssertEqual(try String(contentsOf: fixture.fileURLs[0], encoding: .utf8), original)
        XCTAssertEqual(workspace.saveCurrentFile(), .noChanges)
    }

    func testReadFailureKeepsCurrentSelectionAndBuffer() throws {
        let fixture = try makeVault(files: [("Current", "Current body")])
        let unreadableURL = fixture.vaultURL.appendingPathComponent("Unreadable.md", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableURL, withIntermediateDirectories: false)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        XCTAssertFalse(workspace.selectFile(unreadableURL))
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)
        XCTAssertEqual(workspace.text, "Current body")
        XCTAssertNotNil(workspace.saveError)
    }

    func testFailedSaveBlocksNoteAndVaultSwitchAndKeepsDirtyText() throws {
        let fixture = try makeVault(files: [
            ("First", "first on disk"),
            ("Second", "second on disk")
        ])
        let otherVault = try makeVault(files: [("Other", "other vault")])
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: recoveryURL) }

        let workspace = Workspace(recoveryStore: RecoveryStore(directoryURL: recoveryURL))
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "unsaved text that must survive"

        // Simulate an unavailable iCloud item after it was opened.
        try FileManager.default.removeItem(at: fixture.fileURLs[0])

        let saveResult = workspace.saveCurrentFile()
        guard case .failed(let message) = saveResult else {
            return XCTFail("Expected actionable save failure, got \(saveResult)")
        }
        XCTAssertTrue(message.contains("recovery"))
        XCTAssertNotNil(workspace.recoveryDraft(for: fixture.fileURLs[0]))

        XCTAssertFalse(workspace.selectFile(fixture.fileURLs[1]))
        XCTAssertFalse(workspace.openVault(otherVault.vaultURL))
        XCTAssertEqual(workspace.vaultURL?.standardizedFileURL, fixture.vaultURL.standardizedFileURL)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)
        XCTAssertEqual(workspace.text, "unsaved text that must survive")
        XCTAssertTrue(workspace.hasUnsavedChanges)
    }

    func testFailedSaveDoesNotClaimRecoveryWhenRecoveryWriteFails() throws {
        let fixture = try makeVault(files: [("Note", "base")])
        let blockedRecoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: blockedRecoveryURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: blockedRecoveryURL) }

        let workspace = Workspace(recoveryStore: RecoveryStore(directoryURL: blockedRecoveryURL))
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "unsaved"
        try FileManager.default.removeItem(at: fixture.fileURLs[0])

        guard case .failed(let message) = workspace.saveCurrentFile() else {
            return XCTFail("Expected the unavailable note save to fail")
        }
        XCTAssertTrue(message.contains("recovery could not be written"))
        XCTAssertNil(workspace.recoveryDraft(for: fixture.fileURLs[0]))
    }

    func testExternalChangeBatchAlwaysRechecksSelectedNote() throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))

        try Data("external".utf8).write(to: fixture.fileURLs[0], options: .atomic)
        let unrelated = fixture.vaultURL.appendingPathComponent("unrelated.png")
        workspace.handleExternalChanges([.changed(unrelated)])

        XCTAssertEqual(workspace.text, "external")
        XCTAssertNil(workspace.saveConflict)
    }

    func testUnrelatedPresenterEventDoesNotConflictWithOrdinaryUnsavedEdits() throws {
        let fixture = try makeVault(files: [("Note", "original")])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(fixture.fileURLs[0]))
        workspace.text = "local unsaved"

        workspace.handleExternalChanges([
            .changed(fixture.vaultURL.appendingPathComponent("unrelated.png"))
        ])

        XCTAssertEqual(workspace.text, "local unsaved")
        XCTAssertNil(workspace.saveConflict)
        XCTAssertTrue(workspace.hasUnsavedChanges)
    }

    func testExternalMoveRemapsSelectedNoteWithoutLosingBuffer() throws {
        let fixture = try makeVault(files: [("Old", "body")])
        let oldURL = fixture.fileURLs[0]
        let newURL = fixture.vaultURL.appendingPathComponent("New.md")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        XCTAssertTrue(workspace.selectFile(oldURL))

        try FileManager.default.moveItem(at: oldURL, to: newURL)
        workspace.handleExternalChanges([.moved(from: oldURL, to: newURL)])

        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, newURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "body")
    }

    func testRecoveryStoreRestoresDraftWhenDiskStillMatchesItsBase() throws {
        let fixture = try makeVault(files: [("Note", "base content")])
        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: recoveryURL) }
        let recoveryStore = RecoveryStore(directoryURL: recoveryURL)

        let firstWorkspace = Workspace(recoveryStore: recoveryStore)
        firstWorkspace.vaultURL = fixture.vaultURL
        firstWorkspace.refreshFiles()
        XCTAssertTrue(firstWorkspace.selectFile(fixture.fileURLs[0]))
        firstWorkspace.text = "locally recovered edit"
        firstWorkspace.persistRecoveryDraftNow()

        let restoredWorkspace = Workspace(recoveryStore: recoveryStore)
        restoredWorkspace.vaultURL = fixture.vaultURL
        restoredWorkspace.refreshFiles()
        XCTAssertTrue(restoredWorkspace.selectFile(fixture.fileURLs[0]))

        XCTAssertEqual(restoredWorkspace.text, "locally recovered edit")
        XCTAssertEqual(
            restoredWorkspace.recoveredDraftURL?.standardizedFileURL,
            fixture.fileURLs[0].standardizedFileURL
        )
        XCTAssertTrue(restoredWorkspace.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: fixture.fileURLs[0], encoding: .utf8), "base content")
    }

    // MARK: - Fixture

    private func makeVault(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let fileURLs = try files.map { file -> URL in
            let fileURL = vaultURL
                .appendingPathComponent(file.name)
                .appendingPathExtension("md")
                .standardizedFileURL
            try Data(file.content.utf8).write(to: fileURL, options: .atomic)
            return fileURL
        }

        let selectedFileKey = "selectedFile::" + vaultURL.standardizedFileURL.path
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "vaultBookmark")
            UserDefaults.standard.removeObject(forKey: selectedFileKey)
            try? FileManager.default.removeItem(at: vaultURL)
        }

        return (vaultURL, fileURLs)
    }
}
