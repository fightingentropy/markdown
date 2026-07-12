import XCTest

@testable import Markdown

final class EditorLinkPreviewTests: XCTestCase {
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
}
