import AppKit
import XCTest

@testable import Markdown

final class EditorLinkPreviewTests: XCTestCase {
    @MainActor
    func testViewportAnchorKeepsCaretFixedWhenContentAboveItExpands() throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 320)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = (0..<80).map { "Line \($0)" }.joined(separator: "\n")
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        let caret = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        let anchor = try XCTUnwrap(EditorViewportAnchor.capture(in: textView))
        let originBeforeExpansion = scrollView.contentView.bounds.origin.y

        let firstParagraph = (textView.string as NSString).paragraphRange(
            for: NSRange(location: 0, length: 0)
        )
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 500
        textView.textStorage?.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
        textView.layoutManager?.ensureLayout(for: try XCTUnwrap(textView.textContainer))

        anchor.restore(in: textView)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y - originBeforeExpansion,
            500,
            accuracy: 1
        )
    }

    @MainActor
    func testViewportAnchorPinsVisibleEndCaretToDocumentBottom() throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 320)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = (0..<80).map { "Line \($0)" }.joined(separator: "\n")
        let textContainer = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let caret = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())

        // Leave the last line visible but a few points above the physical
        // bottom. A preview reflow should settle the end caret back at the
        // bottom, not preserve this small vertical wobble.
        let bottomBeforeExpansion = maximumScrollOriginY(
            for: textView,
            in: scrollView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        scrollView.contentView.scroll(
            to: CGPoint(x: 0, y: max(0, bottomBeforeExpansion - 6))
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let anchor = try XCTUnwrap(EditorViewportAnchor.capture(in: textView))

        let firstParagraph = (textView.string as NSString).paragraphRange(
            for: NSRange(location: 0, length: 0)
        )
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 500
        textView.textStorage?.addAttribute(.paragraphStyle, value: style, range: firstParagraph)
        layoutManager.ensureLayout(for: textContainer)

        anchor.restore(in: textView)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            maximumScrollOriginY(
                for: textView,
                in: scrollView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ),
            accuracy: 1
        )
    }

    @MainActor
    func testEndCaretRestoresAfterDeferredDocumentViewGrowth() async throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 320)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = (0..<80).map { "Line \($0)" }.joined(separator: "\n")
        let textContainer = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let caret = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        let anchor = try XCTUnwrap(EditorViewportAnchor.capture(in: textView))

        anchor.restoreAfterPendingLayout(in: textView)
        textView.frame.size.height += 500

        let deferredRestoreFinished = expectation(description: "Deferred bottom restore")
        DispatchQueue.main.async {
            deferredRestoreFinished.fulfill()
        }
        await fulfillment(of: [deferredRestoreFinished], timeout: 1)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            maximumScrollOriginY(
                for: textView,
                in: scrollView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ),
            accuracy: 1
        )
    }

    @MainActor
    func testRefreshDoesNotRenderOffscreenLinksOrRewriteUnchangedSpacing() throws {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 320)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = (0..<200).map { "Plain line \($0)" }.joined(separator: "\n")
            + "\nhttps://youtu.be/AVEZBy1uAk8\nAfter link\nEnd"
        let controller = EditorLinkPreviewController()

        XCTAssertEqual(controller.refresh(in: textView, openURL: { _ in }), 1)
        XCTAssertEqual(controller.visibleCardCount, 0)
        XCTAssertEqual(controller.refresh(in: textView, openURL: { _ in }), 0)
        XCTAssertEqual(controller.visibleCardCount, 0)

        let documentEnd = (textView.string as NSString).length
        textView.layoutManager?.ensureLayout(
            forCharacterRange: NSRange(location: documentEnd - 1, length: 1)
        )
        textView.setSelectedRange(NSRange(location: documentEnd, length: 0))
        let textContainer = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        scrollView.contentView.scroll(
            to: CGPoint(
                x: 0,
                y: maximumScrollOriginY(
                    for: textView,
                    in: scrollView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        controller.layoutCards(in: textView)
        XCTAssertEqual(controller.visibleCardCount, 1)
        XCTAssertEqual(controller.retainedCardCount, 1)

        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        controller.layoutCards(in: textView)
        XCTAssertEqual(controller.visibleCardCount, 0)
        XCTAssertEqual(controller.retainedCardCount, 1)

        scrollView.contentView.scroll(
            to: CGPoint(
                x: 0,
                y: maximumScrollOriginY(
                    for: textView,
                    in: scrollView,
                    layoutManager: layoutManager,
                    textContainer: textContainer
                )
            )
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        controller.layoutCards(in: textView)
        XCTAssertEqual(controller.visibleCardCount, 1)
        XCTAssertEqual(controller.retainedCardCount, 1)
    }

    @MainActor
    func testEmbedCachePersistsXHeightAndSnapshotAcrossInstances() throws {
        let suiteName = "EditorLinkPreviewTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }

        let firstCache = EditorEmbedCache(
            userDefaults: userDefaults,
            heightStorageKey: "heights",
            snapshotDirectoryURL: snapshotDirectory
        )
        firstCache.saveXHeight(438, for: "2031783721397809397")

        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 8,
                pixelsHigh: 8,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.addRepresentation(representation)
        firstCache.saveSnapshot(image, for: "x-2031783721397809397-dark")

        let restoredCache = EditorEmbedCache(
            userDefaults: userDefaults,
            heightStorageKey: "heights",
            snapshotDirectoryURL: snapshotDirectory
        )
        XCTAssertEqual(
            try XCTUnwrap(restoredCache.xHeight(for: "2031783721397809397")),
            438,
            accuracy: 0.5
        )
        XCTAssertNotNil(restoredCache.snapshot(for: "x-2031783721397809397-dark"))
    }

    @MainActor
    func testRefreshUsesPersistedXHeightBeforeRenderingOffscreenEmbed() throws {
        let suiteName = "EditorLinkPreviewTests.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }
        let cache = EditorEmbedCache(
            userDefaults: userDefaults,
            heightStorageKey: "heights",
            snapshotDirectoryURL: snapshotDirectory
        )
        cache.saveXHeight(438, for: "2031783721397809397")

        let scrollView = NSTextView.scrollableTextView()
        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 320)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: 560,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = (0..<200).map { "Plain line \($0)" }.joined(separator: "\n")
            + "\nhttps://x.com/tishray/status/2031783721397809397\nEnd"

        let controller = EditorLinkPreviewController(embedCache: cache)
        XCTAssertEqual(controller.refresh(in: textView, openURL: { _ in }), 1)
        XCTAssertEqual(controller.visibleCardCount, 0)

        let linkRange = (textView.string as NSString).range(
            of: "https://x.com/tishray/status/2031783721397809397"
        )
        let paragraphStyle = try XCTUnwrap(
            textView.textStorage?.attribute(
                .paragraphStyle,
                at: linkRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        XCTAssertEqual(paragraphStyle.paragraphSpacing, 448, accuracy: 0.5)
    }

    func testRecognizesBareXStatusAndYouTubeLinks() {
        let previews = EditorLinkPreviewDetector.previews(in: """
        https://x.com/tishray/status/2031783721397809397
        https://youtu.be/AVEZBy1uAk8?t=2299
        https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share
        """)

        XCTAssertEqual(previews.count, 3)
        XCTAssertEqual(previews[0].kind, .xPost(username: "tishray", statusID: "2031783721397809397"))
        XCTAssertEqual(previews[1].kind, .youtube(videoID: "AVEZBy1uAk8"))
        XCTAssertEqual(previews[1].youtubeStartSeconds, 2299)
        XCTAssertEqual(previews[2].kind, .youtube(videoID: "dQw4w9WgXcQ"))
        XCTAssertEqual(
            previews[1].thumbnailURL?.absoluteString,
            "https://i.ytimg.com/vi/AVEZBy1uAk8/mqdefault.jpg"
        )
    }

    func testUsesMarkdownLinkLabelAndSupportsTwitterHost() {
        let previews = EditorLinkPreviewDetector.previews(
            in: "Claire Forlani [Harvey](https://twitter.com/TheCinesthetic/status/2006003135551266961)"
        )

        XCTAssertEqual(previews.count, 1)
        XCTAssertEqual(previews[0].title, "Harvey")
        XCTAssertEqual(
            previews[0].kind,
            .xPost(username: "TheCinesthetic", statusID: "2006003135551266961")
        )
    }

    func testSupportsYouTubeShortsEmbedAndLiveURLs() {
        let previews = EditorLinkPreviewDetector.previews(in: """
        https://youtube.com/shorts/shortID_1
        https://youtube-nocookie.com/embed/embed-ID
        https://m.youtube.com/live/live_ID
        """)

        XCTAssertEqual(
            previews.map(\.kind),
            [
                .youtube(videoID: "shortID_1"),
                .youtube(videoID: "embed-ID"),
                .youtube(videoID: "live_ID")
            ]
        )
    }

    func testIgnoresGenericLinksAndFencedCode() {
        let previews = EditorLinkPreviewDetector.previews(in: """
        https://example.com/watch?v=not-youtube
        ```text
        https://x.com/hidden/status/123
        https://youtu.be/hiddenVideo
        ```
        """)

        XCTAssertTrue(previews.isEmpty)
    }

    func testBareURLDropsTrailingPunctuation() throws {
        let preview = try XCTUnwrap(
            EditorLinkPreviewDetector.previews(
                in: "Watch https://x.com/user/status/12345)."
            ).first
        )

        XCTAssertEqual(preview.url.absoluteString, "https://x.com/user/status/12345")
        XCTAssertEqual(preview.kind, .xPost(username: "user", statusID: "12345"))
    }

    func testRejectsNonNumericXStatusIDs() {
        XCTAssertTrue(
            EditorLinkPreviewDetector.previews(
                in: "https://x.com/user/status/not-a-post-id"
            ).isEmpty
        )
    }

    func testPreviewIdentitySurvivesEditsBeforeTheLink() throws {
        let url = "https://x.com/user/status/12345"
        let before = try XCTUnwrap(
            EditorLinkPreviewDetector.previews(in: "One line\n\(url)").first
        )
        let after = try XCTUnwrap(
            EditorLinkPreviewDetector.previews(in: "Several edited lines\nabove\n\(url)").first
        )

        XCTAssertNotEqual(before.sourceRange.location, after.sourceRange.location)
        XCTAssertEqual(before.id, after.id)
    }

    func testDuplicatePreviewURLsHaveDistinctStableIdentities() {
        let url = "https://x.com/user/status/12345"
        let previews = EditorLinkPreviewDetector.previews(in: "\(url)\n\(url)")

        XCTAssertEqual(previews.count, 2)
        XCTAssertNotEqual(previews[0].id, previews[1].id)
        XCTAssertEqual(previews[0].occurrence, 0)
        XCTAssertEqual(previews[1].occurrence, 1)
    }

    func testXEmbedHTMLUsesOfficialWidgetAndPrivacyMode() {
        let html = XPostEmbedHTML.document(
            postURL: URL(string: "https://x.com/TheCinesthetic/status/2006003135551266961")!,
            username: "TheCinesthetic",
            statusID: "2006003135551266961",
            theme: "dark"
        )

        XCTAssertTrue(html.contains("https://platform.x.com/widgets.js"))
        XCTAssertTrue(html.contains("createTweet('2006003135551266961'"))
        XCTAssertTrue(html.contains("dnt: true"))
        XCTAssertTrue(html.contains("theme: 'dark'"))
    }

    func testRecognizesObsidianStyleYouTubeEmbedAndIncludesBangInSourceRange() throws {
        let markdown = "![](https://youtu.be/AVEZBy1uAk8?t=1h2m3s)"
        let preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: markdown).first)

        XCTAssertEqual(preview.sourceRange, NSRange(location: 0, length: (markdown as NSString).length))
        XCTAssertEqual(preview.kind, .youtube(videoID: "AVEZBy1uAk8"))
        XCTAssertEqual(preview.youtubeStartSeconds, 3_723)
    }

    func testBuildsPrivacyEnhancedYouTubePlayerURL() throws {
        let url = try XCTUnwrap(
            YouTubeEmbedURL.url(videoID: "AVEZBy1uAk8", startSeconds: 611)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(components.host, "www.youtube-nocookie.com")
        XCTAssertEqual(components.path, "/embed/AVEZBy1uAk8")
        XCTAssertEqual(query["autoplay"], "0")
        XCTAssertEqual(query["controls"], "1")
        XCTAssertEqual(query["start"], "611")
    }

    @MainActor
    private func maximumScrollOriginY(
        for textView: NSTextView,
        in scrollView: NSScrollView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGFloat {
        layoutManager.ensureLayout(for: textContainer)
        let documentHeight = max(
            textView.frame.height,
            layoutManager.usedRect(for: textContainer).maxY + textView.textContainerInset.height
        )
        return max(0, documentHeight - scrollView.contentView.bounds.height)
    }
}
