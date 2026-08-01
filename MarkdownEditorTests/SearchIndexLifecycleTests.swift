import Foundation
import XCTest

@testable import Markdown

@MainActor
final class SearchIndexLifecycleTests: XCTestCase {
    func testIndexIncrementallyReusesUnchangedBodiesAcrossAddChangeRenameAndDelete() throws {
        let fixture = try makeVault(files: [
            ("Alpha", "# Alpha\n\nfirst body"),
            ("Beta", "# Beta\n\nsecond body")
        ])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let initialEntries = workspace.makeSearchEntries()
        let alphaStorage = try XCTUnwrap(initialEntries.first(where: { $0.title == "Alpha" })?.bodyStorage)
        let initialRevision = workspace.searchIndexRevision

        let gammaURL = fixture.vaultURL.appendingPathComponent("Gamma.md")
        try "# Gamma\n\nthird body".write(to: gammaURL, atomically: true, encoding: .utf8)
        workspace.refreshFiles()

        XCTAssertGreaterThan(workspace.searchIndexRevision, initialRevision)
        XCTAssertEqual(workspace.makeSearchEntries().count, 3)
        XCTAssertTrue(
            try XCTUnwrap(workspace.makeSearchEntries().first(where: { $0.title == "Alpha" })?.bodyStorage)
                === alphaStorage
        )

        try "# Beta\n\nchanged searchable body".write(
            to: fixture.fileURLs[1],
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(30)],
            ofItemAtPath: fixture.fileURLs[1].path
        )
        workspace.refreshFiles()
        XCTAssertEqual(Workspace.search(workspace.makeSearchEntries(), query: "searchable").map(\.title), ["Beta"])

        let renamedURL = try workspace.renameItem(gammaURL, to: "Delta")
        let renamedEntries = workspace.makeSearchEntries()
        XCTAssertFalse(renamedEntries.contains(where: { $0.url == gammaURL }))
        XCTAssertTrue(renamedEntries.contains(where: { $0.url == renamedURL }))

        workspace.deleteItem(renamedURL)
        XCTAssertFalse(workspace.makeSearchEntries().contains(where: { $0.url == renamedURL }))
        XCTAssertEqual(workspace.makeSearchEntries().count, 2)
    }

    func testSearchSnapshotRemainsSafeDuringSimultaneousRename() async throws {
        let fixture = try makeVault(files: [
            ("Old", "# Old\n\nconcurrent needle"),
            ("Other", "# Other\n\nbody")
        ])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()
        let snapshot = workspace.makeSearchEntries()

        let inFlightSearch = Task.detached {
            (0..<100).flatMap { _ in Workspace.search(snapshot, query: "needle") }
        }
        let renamedURL = try workspace.renameItem(fixture.fileURLs[0], to: "Renamed")
        let oldSnapshotResults = await inFlightSearch.value

        XCTAssertFalse(oldSnapshotResults.isEmpty)
        XCTAssertTrue(oldSnapshotResults.allSatisfy { $0.url == fixture.fileURLs[0] })
        XCTAssertEqual(
            Workspace.search(workspace.makeSearchEntries(), query: "needle").map(\.url),
            [renamedURL]
        )
    }

    func testICloudConflictCopiesRemainDistinctSearchableNotes() throws {
        let fixture = try makeVault(files: [
            ("Plan", "# Plan\n\ncanonical copy"),
            ("Plan (Erlin's conflicted copy 2026-08-01)", "# Plan conflict\n\nconflict-only-token")
        ])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        let results = Workspace.search(workspace.makeSearchEntries(), query: "conflict-only-token")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, fixture.fileURLs[1])
        XCTAssertEqual(workspace.makeSearchEntries().count, 2)
    }

    func testLatestConcurrentVaultRefreshWinsWithoutDroppingChanges() async throws {
        let fixture = try makeVault(files: [
            ("First", "# First\n\nold token"),
            ("DeleteMe", "# DeleteMe\n\nremove me")
        ])
        let workspace = Workspace()
        workspace.vaultURL = fixture.vaultURL
        workspace.refreshFiles()

        try "# First\n\nnew token".write(to: fixture.fileURLs[0], atomically: true, encoding: .utf8)
        // Presenter events must invalidate by path even when a provider keeps
        // the previous timestamp, as some iCloud conflict resolutions do.
        let originalDate = workspace.files.first(where: { $0.url == fixture.fileURLs[0] })?.modificationDate
        if let originalDate {
            try FileManager.default.setAttributes(
                [.modificationDate: originalDate],
                ofItemAtPath: fixture.fileURLs[0].path
            )
        }
        workspace.handleExternalChanges([.changed(fixture.fileURLs[0])])

        let addedURL = fixture.vaultURL.appendingPathComponent("Added.md")
        try "# Added\n\nadded token".write(to: addedURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.fileURLs[1])
        workspace.handleExternalChanges([
            .changed(addedURL),
            .changed(fixture.fileURLs[1])
        ])

        for _ in 0..<200 {
            let entries = workspace.makeSearchEntries()
            if !workspace.isLoadingSnapshot,
               Workspace.search(entries, query: "new token").count == 1,
               Workspace.search(entries, query: "added token").count == 1,
               !entries.contains(where: { $0.url == fixture.fileURLs[1] }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let finalEntries = workspace.makeSearchEntries()
        XCTAssertEqual(Workspace.search(finalEntries, query: "new token").count, 1)
        XCTAssertEqual(Workspace.search(finalEntries, query: "added token").count, 1)
        XCTAssertFalse(finalEntries.contains(where: { $0.url == fixture.fileURLs[1] }))
    }

    private func makeVault(files: [(name: String, content: String)]) throws -> (vaultURL: URL, fileURLs: [URL]) {
        let vaultURL = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        let fileURLs = try files.map { file -> URL in
            let fileURL = vaultURL.appendingPathComponent(file.name).appendingPathExtension("md")
            try file.content.write(to: fileURL, atomically: true, encoding: .utf8)
            return fileURL.standardizedFileURL
        }
        addTeardownBlock {
            UserDefaults.standard.removeObject(forKey: "vaultBookmark")
            try? FileManager.default.removeItem(at: vaultURL)
        }
        return (vaultURL, fileURLs)
    }
}
