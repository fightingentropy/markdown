import Foundation
import XCTest

@testable import Markdown

final class NoteGraphTests: XCTestCase {
    func testMarkdownNoteLinkExtractorIgnoresEmbedsAndCode() {
        let markdown = """
        [[Alpha]]
        [Beta](Beta.md)
        ![[hero.png]]
        ![Image](hero.png)
        `[[Inline]]`

        ```md
        [[Fenced]]
        [Also fenced](Gamma.md)
        ```
        """

        let references = MarkdownNoteLinkExtractor.references(in: markdown).map(\.destination)

        XCTAssertEqual(references, ["Alpha", "Beta.md"])
    }

    func testNoteGraphBuilderResolvesWikiLinksAndRelativeMarkdownLinks() throws {
        let vaultURL = try makeVault()
        let journalDirectoryURL = vaultURL.appendingPathComponent("Daily", isDirectory: true)
        let projectsDirectoryURL = vaultURL.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDirectoryURL, withIntermediateDirectories: true)

        let homeURL = vaultURL.appendingPathComponent("Home.md")
        let journalURL = journalDirectoryURL.appendingPathComponent("Journal.md")
        let activeURL = projectsDirectoryURL.appendingPathComponent("Active.md")

        try Data(
            """
            # Home

            [[Daily/Journal]]
            [Project](Projects/Active.md)
            [[Missing]]
            """.utf8
        ).write(to: homeURL, options: .atomic)
        try Data("# Journal\n\n[[Home]]".utf8).write(to: journalURL, options: .atomic)
        try Data("# Active".utf8).write(to: activeURL, options: .atomic)

        let files = [homeURL, journalURL, activeURL].map(makeFileItem)
        let metadata = Dictionary(uniqueKeysWithValues: try [homeURL, journalURL, activeURL].map { url in
            let content = try String(contentsOf: url, encoding: .utf8)
            let normalizedURL = url.standardizedFileURL
            return (
                normalizedURL.path,
                CachedMarkdownMetadata(
                    modificationDate: Date(),
                    noteTitle: Workspace.extractTitle(from: content),
                    noteLinks: MarkdownNoteLinkExtractor.references(in: content),
                    noteBody: content
                )
            )
        })

        let snapshot = NoteGraphBuilder.makeSnapshot(
            files: files,
            metadataByPath: metadata,
            vaultURL: vaultURL,
            selectedFileURL: homeURL,
            liveSelectedMarkdown: nil
        )

        XCTAssertEqual(snapshot.nodes.count, 3)
        XCTAssertEqual(snapshot.edges.count, 3)
        XCTAssertEqual(snapshot.selectedNodeID?.standardizedFileURL, homeURL.standardizedFileURL)
        XCTAssertEqual(snapshot.connectedNodeIDs, Set([journalURL.standardizedFileURL, activeURL.standardizedFileURL]))

        let homeNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == homeURL.standardizedFileURL }))
        let journalNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == journalURL.standardizedFileURL }))
        let activeNode = try XCTUnwrap(snapshot.nodes.first(where: { $0.id == activeURL.standardizedFileURL }))

        XCTAssertEqual(homeNode.incomingCount, 1)
        XCTAssertEqual(homeNode.outgoingCount, 2)
        XCTAssertEqual(journalNode.incomingCount, 1)
        XCTAssertEqual(journalNode.outgoingCount, 1)
        XCTAssertEqual(activeNode.incomingCount, 1)
        XCTAssertEqual(activeNode.outgoingCount, 0)
    }

    func testPreviewPreprocessorRewritesObsidianNoteLinksToFileURLs() throws {
        let vaultURL = try makeVault()
        let sourceURL = vaultURL.appendingPathComponent("Source.md")
        let targetURL = vaultURL.appendingPathComponent("Target.md")

        try Data("# Source\n".utf8).write(to: sourceURL, options: .atomic)
        try Data("# Target\n".utf8).write(to: targetURL, options: .atomic)

        let context = PreviewContext(
            documentURL: sourceURL,
            vaultURL: vaultURL,
            assetLookupByFilename: [
                sourceURL.lastPathComponent: [sourceURL],
                targetURL.lastPathComponent: [targetURL]
            ]
        )

        let document = MarkdownPreprocessor.preprocess("[[Target|Open Target]]", context: context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "[Open Target](<\(targetURL.absoluteString)>)"
        )
    }

    private func makeVault() throws -> URL {
        let vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: vaultURL)
        }
        return vaultURL
    }

    private func makeFileItem(_ url: URL) -> FileItem {
        FileItem(
            id: url.standardizedFileURL,
            name: url.lastPathComponent,
            url: url.standardizedFileURL,
            modificationDate: Date(),
            noteTitle: url.deletingPathExtension().lastPathComponent
        )
    }
}
