import Foundation
import XCTest

@testable import Markdown

@MainActor
final class WorkspaceRenameTests: XCTestCase {
    func testOpenRequestedFilesOverridesRestoredSelection() throws {
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
        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[0].standardizedFileURL)

        restoredWorkspace.openRequestedFiles([fixture.fileURLs[1]])

        XCTAssertEqual(restoredWorkspace.selectedFileURL?.standardizedFileURL, fixture.fileURLs[1].standardizedFileURL)
        XCTAssertEqual(restoredWorkspace.text, "# New\n\nBody")
    }

    func testRenameFileUpdatesSelectionAndHeadingWhenTitleMatchesFilename() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        workspace.selectFile(fixture.fileURL)

        let renamedURL = try workspace.renameFile(fixture.fileURL, to: "New")

        XCTAssertEqual(renamedURL.lastPathComponent, "New.md")
        XCTAssertEqual(workspace.selectedFileURL?.standardizedFileURL, renamedURL.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamedURL.path))
        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# New\n\nBody")
    }

    func testRenameFilePreservesCustomHeading() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Custom Title\n\nBody")
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let renamedURL = try workspace.renameFile(fixture.fileURL, to: "Renamed")

        XCTAssertEqual(try String(contentsOf: renamedURL, encoding: .utf8), "# Custom Title\n\nBody")
    }

    func testRenameFileRejectsExistingDestination() throws {
        let fixture = try makeWorkspaceFixture(fileName: "Old", content: "# Old\n\nBody")
        let destinationURL = fixture.vaultURL.appendingPathComponent("Taken.md")
        try Data("# Taken\n".utf8).write(to: destinationURL, options: .atomic)

        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        XCTAssertThrowsError(try workspace.renameFile(fixture.fileURL, to: "Taken")) { error in
            XCTAssertEqual(error as? FileRenameError, .nameAlreadyExists)
        }
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
            try? FileManager.default.removeItem(at: vaultURL)
        }

        return (vaultURL, fileURLs)
    }
}
