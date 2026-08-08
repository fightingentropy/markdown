import AppKit
import Foundation
import XCTest

@testable import Markdown

final class PreviewPipelineTests: XCTestCase {
    func testPreviewURLPolicyAllowsOnlySafeExternalSchemes() throws {
        XCTAssertTrue(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "https://example.com"))))
        XCTAssertTrue(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "mailto:hello@example.com"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(URL(fileURLWithPath: "/tmp/note.md")))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "shortcuts://run-shortcut?name=Unsafe"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "javascript:alert(1)"))))
        XCTAssertFalse(PreviewURLPolicy.canOpenExternally(try XCTUnwrap(URL(string: "data:text/html,hello"))))
    }

    func testPreviewURLPolicyRoutesOnlyExistingVaultNotesAndImagesInternally() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: vault) }
        let note = vault.appendingPathComponent("Note.md")
        let image = vault.appendingPathComponent("Image.png")
        let other = vault.appendingPathComponent("File.pdf")
        try Data("note".utf8).write(to: note)
        try Data([0]).write(to: image)
        try Data([0]).write(to: other)

        XCTAssertEqual(PreviewURLPolicy.internalVaultFile(note, vaultURL: vault), note.standardizedFileURL)
        XCTAssertEqual(PreviewURLPolicy.internalVaultFile(image, vaultURL: vault), image.standardizedFileURL)
        XCTAssertNil(PreviewURLPolicy.internalVaultFile(other, vaultURL: vault))
        XCTAssertNil(PreviewURLPolicy.internalVaultFile(URL(fileURLWithPath: "/tmp/outside.md"), vaultURL: vault))
    }

    func testRemotePreviewImageResponseRequiresImageMIMEAndSizeLimit() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/image.png"))
        let valid = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png", "Content-Length": "1024"]
        ))
        let html = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html", "Content-Length": "1024"]
        ))
        let oversized = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/png",
                "Content-Length": "\(PreviewImageSourceLoader.maximumRemoteImageBytes + 1)"
            ]
        ))

        XCTAssertTrue(PreviewImageSourceLoader.isValidRemoteImageResponse(valid, for: url))
        XCTAssertFalse(PreviewImageSourceLoader.isValidRemoteImageResponse(html, for: url))
        XCTAssertFalse(PreviewImageSourceLoader.isValidRemoteImageResponse(oversized, for: url))
    }

    func testEditorLinkDetectorFindsBareURLAtCharacterIndex() {
        let text = "Visit https://21st.dev/community/components for components."
        let index = (text as NSString).range(of: "21st.dev").location

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertEqual(url?.absoluteString, "https://21st.dev/community/components")
    }

    func testEditorLinkDetectorFindsMarkdownLinkAtCharacterIndex() {
        let text = "[Componentful](https://www.componentful.com/)"
        let index = (text as NSString).range(of: "Componentful").location + 2

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertEqual(url?.absoluteString, "https://www.componentful.com/")
    }

    func testEditorLinkDetectorIgnoresMarkdownImages() {
        let text = "![Preview](https://example.com/image.png)"
        let index = (text as NSString).range(of: "Preview").location

        let url = EditorLinkDetector.url(near: index, in: text)

        XCTAssertNil(url)
    }

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

    func testAssetResolverRejectsPathsOutsideVault() throws {
        let fixture = try makeFixture()
        let outsideURL = fixture.rootURL.appendingPathComponent("secret.png")
        try fixturePNGData().write(to: outsideURL)

        let resolver = AssetResolver(context: fixture.context)
        XCTAssertNil(resolver.resolve(reference: outsideURL.path))
        XCTAssertNil(resolver.resolve(reference: outsideURL.absoluteString))
        XCTAssertNil(resolver.resolve(reference: "../../secret.png"))
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

    func testPreprocessorEncodesInlineAndBlockMathAsTokens() throws {
        let fixture = try makeFixture()
        let markdown = """
        Inline $$a^2 + b^2 = c^2$$ example.

        $$
        \\int_0^\\infty e^{-x} dx = 1
        $$

        Also \\(\\alpha + \\beta\\) and \\[\\sum_i i\\].
        """

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertTrue(document.requiresHTMLFallback, "Math requires HTML fallback for KaTeX")
        let body = document.normalizedMarkdown
        XCTAssertTrue(body.contains(MathTokenCoder.displayPrefix), "Expected display math token")
        XCTAssertTrue(body.contains(MathTokenCoder.inlinePrefix), "Expected inline math token")
        XCTAssertFalse(body.contains("$$a^2"), "Original delimiters should be replaced")
        XCTAssertFalse(body.contains("\\("), "Inline LaTeX delimiters should be replaced")
    }

    func testPreprocessorPreservesMathInsideCodeSpans() throws {
        let fixture = try makeFixture()
        let markdown = "Code `$$a^2$$` stays as literal."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)

        XCTAssertFalse(document.requiresHTMLFallback, "Math tokens inside code must not trigger fallback")
        XCTAssertTrue(document.normalizedMarkdown.contains("`$$a^2$$`"))
    }

    func testHTMLRendererSubstitutesMathTokensWithSpans() throws {
        let fixture = try makeFixture()
        let markdown = "Inline $$x + y$$ example."

        let document = MarkdownPreprocessor.preprocess(markdown, context: fixture.context)
        let html = HTMLPreviewRenderer.render(document: document)

        XCTAssertTrue(html.contains("<span class=\"math-display\">x + y</span>"),
                      "Expected KaTeX target span; got: \(html)")
        XCTAssertFalse(html.contains(MathTokenCoder.displayPrefix),
                       "All tokens should be substituted in final HTML")
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

/// Cross-checks that the four link/image consumers — the editor syntax
/// highlighter and Cmd-click resolver (both backed by the NSString-based
/// `EditorLinkScanner`), the note-graph extractor, and the preview rewriter
/// (both backed by the Character-based `MarkdownNoteLinkExtractor`) — agree
/// on what counts as a link or image for the representative syntax forms, so
/// the two underlying tokenizers cannot silently diverge.
@MainActor
final class LinkParserParityTests: XCTestCase {
    func testConsumersAgreeOnMarkdownLink() {
        let text = "See [Docs](https://example.com/docs) for details"
        let linkRange = (text as NSString).range(of: "[Docs](https://example.com/docs)")
        let labelRange = (text as NSString).range(of: "Docs")

        assertMarkdownLinkStyling(in: text, range: linkRange, labelRange: labelRange)

        // The detector resolves a click anywhere inside the link span, and
        // nowhere outside it.
        for index in linkRange.location..<NSMaxRange(linkRange) {
            XCTAssertEqual(
                EditorLinkDetector.url(near: index, in: text)?.absoluteString,
                "https://example.com/docs",
                "index \(index)"
            )
        }
        XCTAssertNil(EditorLinkDetector.url(near: 0, in: text))
        XCTAssertNil(EditorLinkDetector.url(near: NSMaxRange(linkRange) + 1, in: text))

        // The graph extractor sees the same destination.
        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: text).map(\.destination),
            ["https://example.com/docs"]
        )
    }

    func testConsumersAgreeOnBareURL() {
        let text = "Visit https://example.com/page today"
        let linkRange = (text as NSString).range(of: "https://example.com/page")

        assertLinkUnderline(in: text, range: linkRange)

        for index in linkRange.location..<NSMaxRange(linkRange) {
            XCTAssertEqual(
                EditorLinkDetector.url(near: index, in: text)?.absoluteString,
                "https://example.com/page",
                "index \(index)"
            )
        }

        // Bare URLs never reference a vault note, so the graph extractor
        // intentionally produces no reference for them.
        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    func testConsumersAgreeOnObsidianNoteLink() {
        let text = "See [[Project Plan]] and [[2024-report|Q4 Results]]"
        let plainRange = (text as NSString).range(of: "[[Project Plan]]")
        let aliasRange = (text as NSString).range(of: "[[2024-report|Q4 Results]]")

        assertLinkUnderline(in: text, range: plainRange)
        assertLinkUnderline(in: text, range: aliasRange)

        XCTAssertEqual(
            MarkdownNoteLinkExtractor.references(in: text).map(\.destination),
            ["Project Plan", "2024-report"]
        )

        let aliasMatch = MarkdownNoteLinkExtractor.obsidianNoteLink(
            in: Array(text),
            from: aliasRange.location
        )
        XCTAssertEqual(aliasMatch?.displayName, "Q4 Results")
        XCTAssertEqual(aliasMatch?.nextIndex, NSMaxRange(aliasRange))

        // Wiki links are highlighted for navigation but intentionally do not
        // resolve to an external URL on Cmd-click.
        XCTAssertNil(EditorLinkDetector.url(near: plainRange.location + 3, in: text))
    }

    func testConsumersAgreeOnMarkdownImage() throws {
        let text = "![Alt text](images/photo.png \"Caption\")"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let labelRange = (text as NSString).range(of: "Alt text")

        assertMarkdownLinkStyling(in: text, range: fullRange, labelRange: labelRange)

        let match = try XCTUnwrap(MarkdownNoteLinkExtractor.markdownImage(in: Array(text), from: 0))
        XCTAssertEqual(match.original, text)
        XCTAssertEqual(match.altText, "Alt text")
        XCTAssertEqual(match.destination, "images/photo.png")
        XCTAssertEqual(match.title, "Caption")
        XCTAssertEqual(match.nextIndex, fullRange.length)

        // The preview adapter observes the very same parse.
        XCTAssertEqual(
            PreviewMarkdownSyntax.parseStandaloneMarkdownImage(in: text)?.destination,
            "images/photo.png"
        )

        // Images are highlighted but never resolve to an openable editor URL,
        // and produce no graph edge.
        XCTAssertNil(EditorLinkDetector.url(near: 3, in: text))
        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    func testConsumersAgreeOnObsidianEmbed() throws {
        let text = "![[diagram.png|300]]"
        let fullRange = NSRange(location: 0, length: (text as NSString).length)

        assertLinkUnderline(in: text, range: fullRange)

        let embed = try XCTUnwrap(MarkdownNoteLinkExtractor.obsidianEmbed(in: Array(text), from: 0))
        XCTAssertEqual(embed.original, text)
        XCTAssertEqual(embed.rawReference, "diagram.png|300")
        XCTAssertEqual(embed.nextIndex, fullRange.length)

        // One shared reference parse feeds the note-link view (alias as
        // display text) and the embed view (alias as pixel width).
        let descriptor = MarkdownNoteLinkExtractor.parseObsidianReference(embed.rawReference)
        XCTAssertEqual(descriptor.destination, "diagram.png")
        XCTAssertEqual(descriptor.alias, "300")
        XCTAssertEqual(descriptor.width, 300)
        XCTAssertEqual(descriptor.fileName, "diagram")

        let previewReference = PreviewMarkdownSyntax.parseObsidianReference(embed.rawReference)
        XCTAssertEqual(previewReference.target, "diagram.png")
        XCTAssertEqual(previewReference.width, 300)
        XCTAssertEqual(previewReference.displayName, "diagram")

        let noteReference = MarkdownNoteLinkExtractor.parseObsidianNoteReference(embed.rawReference)
        XCTAssertEqual(noteReference.destination, "diagram.png")
        XCTAssertEqual(noteReference.displayName, "300")

        XCTAssertTrue(MarkdownNoteLinkExtractor.references(in: text).isEmpty)
    }

    /// Asserts the highlighter marks every character of `range` as a link.
    private func assertLinkUnderline(
        in text: String,
        range: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)

        for index in range.location..<NSMaxRange(range) {
            XCTAssertEqual(
                storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                NSUnderlineStyle.single.rawValue,
                "expected link underline at index \(index)",
                file: file,
                line: line
            )
        }
    }

    /// Markdown keeps the reader-facing label prominent while treating the
    /// punctuation and destination as quiet authoring metadata.
    private func assertMarkdownLinkStyling(
        in text: String,
        range: NSRange,
        labelRange: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)

        for index in range.location..<NSMaxRange(range) {
            if NSLocationInRange(index, labelRange) {
                XCTAssertEqual(
                    storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                    Theme.linkColor,
                    "expected reader-facing label color at index \(index)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                    NSUnderlineStyle.single.rawValue,
                    "expected reader-facing label underline at index \(index)",
                    file: file,
                    line: line
                )
            } else {
                XCTAssertEqual(
                    storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor,
                    Theme.metaColor,
                    "expected muted Markdown syntax at index \(index)",
                    file: file,
                    line: line
                )
                XCTAssertEqual(
                    storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int,
                    0,
                    "expected unadorned Markdown syntax at index \(index)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
