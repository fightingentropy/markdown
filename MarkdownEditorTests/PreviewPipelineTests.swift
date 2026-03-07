import Foundation
import XCTest

@testable import Markdown

final class PreviewPipelineTests: XCTestCase {
    func testAssetResolverResolvesDocumentRelativeImage() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: "doc-image.png")

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
        XCTAssertEqual(asset?.kind, .image)
    }

    func testAssetResolverResolvesVaultRelativeImage() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: "assets/vault-image.png")

        XCTAssertEqual(asset?.fileURL, fixture.vaultImageURL)
        XCTAssertEqual(asset?.kind, .image)
    }

    func testAssetResolverResolvesAbsolutePath() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.documentImageURL.path)

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
    }

    func testAssetResolverResolvesFileURL() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.documentImageURL.absoluteString)

        XCTAssertEqual(asset?.fileURL, fixture.documentImageURL)
    }

    func testAssetResolverResolvesUniqueBareFilenameWithinVault() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.bareFilenameImageURL.lastPathComponent)

        XCTAssertEqual(asset?.fileURL, fixture.bareFilenameImageURL)
    }

    func testAssetResolverReturnsNilForMissingFiles() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        XCTAssertNil(resolver.resolve(reference: "missing-image.png"))
    }

    func testAssetResolverClassifiesNonImageFileEmbeds() throws {
        let fixture = try makeFixture()

        let resolver = AssetResolver(context: fixture.context)
        let asset = resolver.resolve(reference: fixture.pdfURL.lastPathComponent)

        XCTAssertEqual(asset?.fileURL, fixture.pdfURL)
        XCTAssertEqual(asset?.kind, .file)
        XCTAssertEqual(asset?.mimeType, "application/pdf")
    }

    func testPreprocessorLeavesPlainMarkdownUntouched() throws {
        let fixture = try makeFixture()
        let markdown = "# Title\n\nParagraph text."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertEqual(document.normalizedMarkdown, markdown)
        XCTAssertEqual(document.preferredRenderMode, .native)
    }

    func testPreprocessorConvertsObsidianImageEmbedIntoMarkdownImage() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[doc-image.png]]", context: fixture.context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "![doc-image](<\(fixture.documentImageURL.absoluteString)>)"
        )
    }

    func testPreprocessorConvertsObsidianFileEmbedIntoMarkdownLink() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[reference.pdf]]", context: fixture.context)

        XCTAssertEqual(
            document.normalizedMarkdown,
            "[reference](<\(fixture.pdfURL.absoluteString)>)"
        )
    }

    func testPreprocessorMarksWidthQualifiedObsidianImageEmbedsForHTMLFallback() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![[doc-image.png|300]]", context: fixture.context)

        XCTAssertTrue(document.requiresHTMLFallback)
        XCTAssertEqual(document.preferredRenderMode, .html)
        XCTAssertTrue(document.normalizedMarkdown.contains("codex-obsidian-width-300"))
    }

    func testPreprocessorSplitsMermaidBlocksIntoSegments() throws {
        let fixture = try makeFixture()
        let markdown = """
        Before

        ```mermaid
        graph TD
        A-->B
        ```

        After
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertEqual(document.segments.count, 3)

        if case .markdown(let leading) = document.segments[0] {
            XCTAssertTrue(leading.contains("Before"))
        } else {
            XCTFail("Expected leading markdown segment")
        }

        if case .mermaid(let source, let diagram) = document.segments[1] {
            XCTAssertEqual(source, "graph TD\nA-->B")
            XCTAssertNotNil(diagram)
        } else {
            XCTFail("Expected mermaid segment")
        }

        if case .markdown(let trailing) = document.segments[2] {
            XCTAssertTrue(trailing.contains("After"))
        } else {
            XCTFail("Expected trailing markdown segment")
        }
    }

    func testPreprocessorDoesNotRewriteObsidianEmbedsInsideCode() throws {
        let fixture = try makeFixture()
        let markdown = """
        `![[doc-image.png]]`

        ```md
        ![[doc-image.png]]
        ```
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertTrue(document.normalizedMarkdown.contains("`![[doc-image.png]]`"))
        XCTAssertTrue(document.normalizedMarkdown.contains("![[doc-image.png]]"))
        XCTAssertFalse(document.normalizedMarkdown.contains(fixture.documentImageURL.absoluteString))
    }

    func testHTMLRendererUsesDownForStandardMarkdownFeatures() throws {
        let fixture = try makeFixture()
        let markdown = """
        # Heading

        - one
        - two

        > quoted

        | A | B |
        | - | - |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        [link](https://example.com)

        https://example.com

        ~~done~~
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<table>"), html)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\">"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">https://example.com</a>"), html)
        XCTAssertTrue(html.contains("<del>done</del>"), html)
    }

    func testHTMLRendererUsesFileURLsForLocalImages() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess("![alt](doc-image.png)", context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains(fixture.documentImageURL.absoluteString))
        XCTAssertFalse(html.contains("data:image"))
    }

    func testHTMLRendererOnlyInjectsAppGeneratedMermaidSVG() throws {
        let fixture = try makeFixture()
        let markdown = """
        <script>alert('bad')</script>

        ```mermaid
        graph TD
        A-->B
        ```
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<svg"))
        XCTAssertFalse(html.contains("<script>"))
    }

    func testNativePreviewSelectionStaysNativeForSupportedDocuments() throws {
        let fixture = try makeFixture()

        let document = MarkdownPreprocessor.preprocess(
            "# Title\n\n![[doc-image.png]]",
            context: fixture.context
        )

        XCTAssertEqual(document.preferredRenderMode, .native)
    }

    func testNativeImageSourceLoaderResolvesDocumentAndVaultRelativeImages() throws {
        let fixture = try makeFixture()

        let documentRelative = PreviewImageSourceLoader.resolvedImageURL(
            for: try XCTUnwrap(URL(string: "doc-image.png")),
            context: fixture.context
        )
        let vaultRelative = PreviewImageSourceLoader.resolvedImageURL(
            for: try XCTUnwrap(URL(string: "assets/vault-image.png")),
            context: fixture.context
        )

        XCTAssertEqual(documentRelative, fixture.documentImageURL)
        XCTAssertEqual(vaultRelative, fixture.vaultImageURL)
    }

    func testNativePreviewSelectionFallsBackForMermaidAndWidthQualifiedEmbeds() throws {
        let fixture = try makeFixture()

        let mermaidDocument = MarkdownPreprocessor.preprocess(
            """
            ```mermaid
            graph TD
            A-->B
            ```
            """,
            context: fixture.context
        )
        let widthDocument = MarkdownPreprocessor.preprocess(
            "![[doc-image.png|240]]",
            context: fixture.context
        )

        XCTAssertEqual(mermaidDocument.preferredRenderMode, .html)
        XCTAssertEqual(widthDocument.preferredRenderMode, .html)
    }
}

private struct PreviewFixture {
    let rootURL: URL
    let context: PreviewContext
    let documentImageURL: URL
    let vaultImageURL: URL
    let bareFilenameImageURL: URL
    let pdfURL: URL
}

private func makeFixture() throws -> PreviewFixture {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .standardizedFileURL
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let vaultURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
    let notesURL = vaultURL.appendingPathComponent("Notes", isDirectory: true)
    let assetsURL = vaultURL.appendingPathComponent("assets", isDirectory: true)
    let attachmentsURL = vaultURL.appendingPathComponent("Attachments", isDirectory: true)
    let docsURL = vaultURL.appendingPathComponent("Docs", isDirectory: true)

    for directory in [vaultURL, notesURL, assetsURL, attachmentsURL, docsURL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    let documentURL = notesURL.appendingPathComponent("Note.md")
    try "# Fixture".write(to: documentURL, atomically: true, encoding: .utf8)

    let documentImageURL = notesURL.appendingPathComponent("doc-image.png")
    let vaultImageURL = assetsURL.appendingPathComponent("vault-image.png")
    let bareFilenameImageURL = attachmentsURL.appendingPathComponent("unique-bare-image.png")
    let pdfURL = docsURL.appendingPathComponent("reference.pdf")

    try fixturePNGData().write(to: documentImageURL)
    try fixturePNGData().write(to: vaultImageURL)
    try fixturePNGData().write(to: bareFilenameImageURL)
    try Data("%PDF-1.4".utf8).write(to: pdfURL)

    return PreviewFixture(
        rootURL: rootURL,
        context: PreviewContext(documentURL: documentURL, vaultURL: vaultURL),
        documentImageURL: documentImageURL,
        vaultImageURL: vaultImageURL,
        bareFilenameImageURL: bareFilenameImageURL,
        pdfURL: pdfURL
    )
}

private func fixturePNGData() throws -> Data {
    let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO0pNzsAAAAASUVORK5CYII="
    return try XCTUnwrap(Data(base64Encoded: base64))
}
