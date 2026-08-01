import Foundation
import XCTest

@testable import Markdown

final class AttachmentStoreTests: XCTestCase {
    func testUsesObsidianAttachmentFolderAndCreatesCollisionSafeEmbed() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        let sourceURL = fixture.vaultURL.deletingLastPathComponent().appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let first = try AttachmentStore.importFile(
            sourceURL,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        let second = try AttachmentStore.importFile(
            sourceURL,
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )

        XCTAssertEqual(first.vaultRelativePath, "media/photo.png")
        XCTAssertEqual(first.markdownEmbed, "![[media/photo.png]]")
        XCTAssertEqual(second.vaultRelativePath, "media/photo 2.png")
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data([1, 2, 3]))
    }

    func testFallsBackToExistingImgFolder() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        try FileManager.default.createDirectory(
            at: fixture.vaultURL.appendingPathComponent("img", isDirectory: true),
            withIntermediateDirectories: true
        )

        let folder = try AttachmentStore.attachmentFolderURL(
            documentURL: fixture.documentURL,
            vaultURL: fixture.vaultURL
        )
        XCTAssertEqual(folder.lastPathComponent, "img")
    }

    func testRejectsAttachmentFolderTraversal() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"../Outside"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }

        XCTAssertThrowsError(
            try AttachmentStore.attachmentFolderURL(
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        )
    }

    func testRejectsAttachmentFolderSymlinkOutsideVault() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"media"}"#)
        let outsideURL = fixture.vaultURL.deletingLastPathComponent()
            .appendingPathComponent("AttachmentStoreOutside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.vaultURL.appendingPathComponent("media", isDirectory: true),
            withDestinationURL: outsideURL
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertThrowsError(
            try AttachmentStore.importImageData(
                Data([1, 2, 3]),
                suggestedFilename: "escape.png",
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        ) { error in
            guard case AttachmentStoreError.unsafeAttachmentFolder = error else {
                return XCTFail("Expected unsafeAttachmentFolder, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("escape.png").path)
        )
    }

    func testRejectsNestedAttachmentFolderSymlinkOutsideVault() throws {
        let fixture = try makeFixture(appJSON: #"{"attachmentFolderPath":"safe/media"}"#)
        let outsideURL = fixture.vaultURL.deletingLastPathComponent()
            .appendingPathComponent("NestedAttachmentOutside-\(UUID().uuidString)", isDirectory: true)
        let safeURL = fixture.vaultURL.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: safeURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: safeURL.appendingPathComponent("media", isDirectory: true),
            withDestinationURL: outsideURL
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.vaultURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        XCTAssertThrowsError(
            try AttachmentStore.importImageData(
                Data([1, 2, 3]),
                suggestedFilename: "escape.png",
                documentURL: fixture.documentURL,
                vaultURL: fixture.vaultURL
            )
        ) { error in
            guard case AttachmentStoreError.unsafeAttachmentFolder = error else {
                return XCTFail("Expected unsafeAttachmentFolder, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outsideURL.appendingPathComponent("escape.png").path)
        )
    }

    func testExclusiveImageInstallNeverReplacesExistingFile() throws {
        let fixture = try makeFixture(appJSON: nil)
        defer { try? FileManager.default.removeItem(at: fixture.vaultURL) }
        let folderURL = fixture.vaultURL.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destinationURL = folderURL.appendingPathComponent("same.png")
        let original = Data("original".utf8)
        try original.write(to: destinationURL)

        XCTAssertFalse(
            try AttachmentStore.writeDataIfAbsent(
                Data("replacement".utf8),
                to: destinationURL,
                fileManager: .default
            )
        )
        XCTAssertEqual(try Data(contentsOf: destinationURL), original)
    }

    private func makeFixture(appJSON: String?) throws -> (vaultURL: URL, documentURL: URL) {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachmentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let documentURL = vaultURL.appendingPathComponent("Notes/Note.md")
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "# Note".write(to: documentURL, atomically: true, encoding: .utf8)

        if let appJSON {
            let obsidianURL = vaultURL.appendingPathComponent(".obsidian", isDirectory: true)
            try FileManager.default.createDirectory(at: obsidianURL, withIntermediateDirectories: true)
            try appJSON.write(
                to: obsidianURL.appendingPathComponent("app.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return (vaultURL, documentURL)
    }
}
