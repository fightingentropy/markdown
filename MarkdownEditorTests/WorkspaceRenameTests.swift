import Foundation
import XCTest

@testable import Markdown

@MainActor
final class WorkspaceRenameTests: XCTestCase {
    func testOpenRequestedFilesOverridesRestoredSelection() async throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("Old", "# Old\n\nBody"),
                ("New", "# New\n\nBody")
            ]
        )

        let initialWorkspace = Workspace()
        initialWorkspace.openVault(fixture.vaultURL)
        initialWorkspace.selectFile(fixture.fileURLs[0])
        XCTAssertEqual(initialWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)

        let restoredWorkspace = Workspace()
        for _ in 0..<20 {
            if restoredWorkspace.selectedFileURL?.standardizedFileURL == fixture.fileURLs[0].standardizedFileURL {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)

        restoredWorkspace.openRequestedFiles([fixture.fileURLs[1]])

        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertEqual(restoredWorkspace.text, "# New\n\nBody")
    }

    func testRenameItemUpdatesSelectionAndHeadingWhenTitleMatchesFilename() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        let renamedURL = try workspace.renameItem(fixture.fileURL, to: "New")

        XCTAssertEqual(renamedURL.lastPathComponent, "New.md")
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, renamedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# New\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: renamedURL), NSRange(location: 7, length: 0))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testRenameItemPreservesCustomHeading() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Custom Title\n\nBody")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let renamedURL = try workspace.renameItem(fixture.fileURL, to: "Renamed")

        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# Custom Title\n\nBody")
    }

    func testRenameItemRejectsExistingDestination() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let destinationURL = fixture.vaultURL.appendingPathComponent("Taken.md")
        try Data("# Taken\n".utf8).write(to: destinationURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertThrowsError(try workspace.renameItem(fixture.fileURL, to: "Taken")) { error in
            XCTAssertEqual(error as? ItemRenameError, .nameAlreadyExists)
        }
    }

    func testRenameFolderMovesFolderAndKeepsContents() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested").appendingPathExtension("md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let renamedFolderURL = try workspace.renameItem(folderURL, to: "Archive")

        XCTAssertEqual(renamedFolderURL.lastPathComponent, "Archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedFolderURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: renamedFolderURL.appendingPathComponent("Nested.md").path
            )
        )
    }

    func testRefreshFilesDoesNotRewriteFilesWithoutHeadings() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Untitled", content: "Plain body")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL

        workspace.refreshFiles()

        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), "Plain body")
        XCTAssertEqual(workspace.files.first?.noteTitle, "Untitled")
    }

    func testEditorSelectionPersistsPerFile() throws {
        let fixture = try makeWorkspaceFixture(
            files: [
                ("First", "# First\n\nBody"),
                ("Second", "# Second\n\nBody")
            ]
        )
        let workspace = Workspace()

        workspace.persistEditorSelection(NSRange(location: 5, length: 0), for: fixture.fileURLs[0])
        workspace.persistEditorSelection(NSRange(location: 12, length: 3), for: fixture.fileURLs[1])

        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURLs[0]), NSRange(location: 5, length: 0))
        XCTAssertEqual(workspace.editorSelection(for: fixture.fileURLs[1]), NSRange(location: 12, length: 3))
    }

    func testCreateNewFileInFolderSelectsCreatedFile() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        workspace.createNewFile(in: folderURL)

        let createdURL = folderURL.appendingPathComponent("Untitled.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, createdURL.standardizedFileURL)
        XCTAssertEqual(workspace.text, "# Untitled\n\n")
    }

    func testDeleteItemRemovesSelectedMarkdownFileAndClearsSelectionState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        workspace.deleteItem(fixture.fileURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertNil(workspace.selectedFileURL)
        XCTAssertEqual(workspace.text, "")
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testDeleteItemRemovesFolderAndClearsNestedSelectionState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let nestedFileURL = folderURL.appendingPathComponent("Nested.md")
        try Data("# Nested\n\nBody".utf8).write(to: nestedFileURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(nestedFileURL)
        workspace.persistEditorSelection(NSRange(location: 10, length: 0), for: nestedFileURL)

        workspace.deleteItem(folderURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folderURL.path))
        XCTAssertNil(workspace.selectedFileURL)
        XCTAssertEqual(workspace.text, "")
        XCTAssertNil(workspace.editorSelection(for: nestedFileURL))
    }

    func testMoveMarkdownFileIntoFolderUpdatesSelectionAndEditorState() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Note", content: "# Note\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)
        workspace.persistEditorSelection(NSRange(location: 7, length: 0), for: fixture.fileURL)

        let didMove = workspace.moveItem(fixture.fileURL, toFolder: folderURL)
        let movedURL = folderURL.appendingPathComponent("Note.md")

        XCTAssertTrue(didMove)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
        XCTAssertEqual(workspace.text, "# Note\n\nBody")
        XCTAssertEqual(workspace.editorSelection(for: movedURL), NSRange(location: 7, length: 0))
        XCTAssertNil(workspace.editorSelection(for: fixture.fileURL))
    }

    func testMoveSelectedImageToVaultRootPreservesSelection() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Existing", content: "# Existing\n\nBody")
        let folderURL = fixture.vaultURL.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let imageURL = folderURL.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(imageURL)

        let didMove = workspace.moveItem(imageURL, toFolder: nil)
        let movedURL = fixture.vaultURL.appendingPathComponent("photo.png")

        XCTAssertTrue(didMove)
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, movedURL.standardizedFileURL)
        XCTAssertTrue(workspace.selectedFileIsImage)
        XCTAssertEqual(workspace.selectedFileName, "photo.png")
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
    }

    func testSidebarExpansionRestoreDefersUntilFoldersAreLoaded() {
        let folderURL = URL(fileURLWithPath: "/tmp/vault/misc", isDirectory: true)
        let storedPaths = [folderURL.path]

        let deferredResult = SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: [],
            isLoadingSnapshot: true
        )

        XCTAssertEqual(deferredResult, .deferred)

        let restoredResult = SidebarExpansionPersistence.restoreResult(
            storedPaths: storedPaths,
            validFolderURLs: [folderURL],
            isLoadingSnapshot: false
        )

        XCTAssertEqual(restoredResult, .restored([folderURL]))
    }

    private func makeWorkspaceFixture(fileName: String, content: String) throws -> (vaultURL: URL, fileURL: URL) {
        let fixture = try makeWorkspaceFixture(files: [(fileName, content)])
        return (fixture.vaultURL, fixture.fileURLs[0])
    }

    private func makeWorkspaceFixture(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)

        let fileURLs = try files.map { file in
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
            let selectionKeys = UserDefaults.standard.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("editorSelection::" + vaultURL.standardizedFileURL.path)
            }
            for key in selectionKeys {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: vaultURL)
        }

        return (vaultURL, fileURLs)
    }
}
