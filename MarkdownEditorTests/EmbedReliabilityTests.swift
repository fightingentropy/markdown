import AppKit
import WebKit
import XCTest
@testable import Markdown

@MainActor
final class EmbedReliabilityTests: XCTestCase {
    func testRetryIgnoresCallbacksFromPreviousLoadAndRequiresProviderReadiness() throws {
        let container = CachedEmbedWebView(webView: WKWebView())
        defer { container.tearDown() }
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.container = container
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://youtu.be/AVEZBy1uAk8").first)
        var loads = 0
        container.configure(contentKey: "video") { _ in loads += 1 }
        let firstToken = container.loadToken
        XCTAssertEqual(container.loadState, .loading)
        coordinator.receive(["token": firstToken, "type": "error", "code": 100])
        XCTAssertEqual(container.loadState, .failed("This video is unavailable or private."))
        container.retry()
        let secondToken = container.loadToken
        XCTAssertNotEqual(firstToken, secondToken)
        coordinator.receive(["token": firstToken, "type": "ready"])
        XCTAssertEqual(container.loadState, .loading)
        coordinator.receive(["token": secondToken, "type": "ready"])
        XCTAssertEqual(container.loadState, .ready)
        XCTAssertEqual(loads, 2)
        coordinator.webViewWebContentProcessDidTerminate(container.webView)
        if case .failed = container.loadState {} else { XCTFail("Process exit must expose retry") }
    }

    func testOffscreenReadinessPausesAndReattachingDoesNotAutoplay() async {
        let container = CachedEmbedWebView(webView: WKWebView())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        defer { container.tearDown(); window.contentView = nil }
        var pauses = 0
        container.pausePlayer = { pauses += 1 }
        container.configure(contentKey: "video") { _ in }
        container.setPresented(false)
        XCTAssertFalse(container.isMediaActive)
        let beforeReady = pauses
        container.markReady()
        XCTAssertGreaterThan(pauses, beforeReady)
        let pausedAfterReattach = expectation(description: "Pause after WebKit lifts suspension")
        var shouldFulfill = true
        container.pausePlayer = {
            if shouldFulfill { shouldFulfill = false; pausedAfterReattach.fulfill() }
        }
        container.setPresented(true)
        XCTAssertTrue(container.isMediaActive)
        await fulfillment(of: [pausedAfterReattach], timeout: 5)
        container.removeFromSuperview()
        XCTAssertFalse(container.isMediaActive)
    }

    func testTimeoutIsRecoverableAndCannotReplaceReadyState() async throws {
        let container = CachedEmbedWebView(webView: WKWebView(), loadTimeout: .milliseconds(10))
        defer { container.tearDown() }
        container.configure(contentKey: "never-finishes") { _ in }
        try await Task.sleep(for: .milliseconds(100))
        if case .failed = container.loadState {} else { XCTFail("Loading must time out") }
        container.retry()
        container.markReady()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(container.loadState, .ready)
    }

    func testTallTweetHeightPassesThroughButInvalidMeasurementsAreRejected() throws {
        let container = CachedEmbedWebView(webView: WKWebView())
        defer { container.tearDown() }
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.container = container
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://x.com/user/status/12345").first)
        var heights: [CGFloat] = []
        coordinator.heightChanged = { heights.append($0) }
        container.configure(contentKey: "tweet") { _ in }
        let token = container.loadToken
        for height in [1400.0, -10, Double.infinity, Double.nan, 100_001] {
            coordinator.receive(["token": token, "type": "height", "height": height])
        }
        XCTAssertEqual(heights, [1400])
        XCTAssertEqual(container.loadState, .ready)
    }

    func testWidgetReportsLateIframeResizeThroughTheRealScriptBridge() async throws {
        let coordinator = ProviderEmbedView.Coordinator()
        coordinator.preview = try XCTUnwrap(EditorLinkPreviewDetector.previews(in: "https://x.com/user/status/12345").first)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(coordinator, name: "embedEvent")
        let container = CachedEmbedWebView(webView: WKWebView(frame: .zero, configuration: configuration))
        container.frame = NSRect(x: 0, y: 0, width: 550, height: 1500)
        container.layoutSubtreeIfNeeded()
        coordinator.container = container
        defer { container.tearDown() }
        let resized = expectation(description: "Late iframe size reaches the native card")
        var fulfilled = false
        coordinator.heightChanged = { height in
            if height >= 1400, !fulfilled { fulfilled = true; resized.fulfill() }
        }
        container.configure(contentKey: "late-resize") { token in
            let html = XPostEmbedHTML.document(postURL: URL(string: "https://x.com/user/status/12345")!,
                username: "user", statusID: "12345", theme: "light", token: token)
            let prefix = html.components(separatedBy: "<script async src=\"https://platform.x.com/widgets.js\"")[0]
            let fixture = prefix + """
            <script>
            window.twttr = {ready: function(callback) { callback({widgets: {createTweet: function(id, parent) {
              const frame = document.createElement('iframe');
              frame.style.cssText = 'position:absolute;width:550px;height:900px;border:0';
              parent.appendChild(frame);
              setTimeout(function() { frame.style.height = '1400px'; }, 100);
              return Promise.resolve(frame);
            }}}); }};
            loadTweet();
            </script></body></html>
            """
            container.webView.loadHTMLString(fixture, baseURL: EmbedHTML.appOrigin())
        }
        await fulfillment(of: [resized], timeout: 8)
        XCTAssertEqual(container.loadState, .ready)
    }

    func testCacheSeparatesWidthsAndDisplayScales() throws {
        let suite = "EmbedReliabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = EditorEmbedCache(userDefaults: defaults)
        cache.saveXHeight(1400, for: "123", width: 320)
        cache.saveXHeight(750, for: "123", width: 550)
        XCTAssertEqual(cache.xHeight(for: "123", width: 320), 1400)
        XCTAssertEqual(cache.xHeight(for: "123", width: 550), 750)
        XCTAssertNil(cache.xHeight(for: "123", width: 480))
        let key = EmbedSnapshotKey.make(content: "x-123-dark", width: 550, scale: 2)
        XCTAssertNotEqual(key, EmbedSnapshotKey.make(content: "x-123-dark", width: 320, scale: 2))
        XCTAssertNotEqual(key, EmbedSnapshotKey.make(content: "x-123-dark", width: 550, scale: 1))
    }

    func testDiskCacheEvictsExpiredAndOldestOverBudgetFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EmbedSnapshotStore(directory: directory, byteLimit: 12, maximumAge: 100)
        for (key, age) in [("expired", 200.0), ("old", 50), ("recent", 10)] {
            let url = await store.fileURL(for: key)
            try Data(repeating: 0, count: 8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        await store.prune()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["recent.png"])
    }

    func testPlaybackStoreRejectsInvalidPositionsAndKeepsURLTimestampIndependent() {
        let store = EmbedPlaybackStore()
        store.save(123.5, for: "video?t=60")
        store.save(.nan, for: "video?t=60")
        store.save(-1, for: "video?t=60")
        XCTAssertEqual(store.position(for: "video?t=60"), 123.5)
        XCTAssertNil(store.position(for: "video?t=120"))
        for index in 0..<128 { store.save(Double(index), for: "other-\(index)") }
        XCTAssertNil(store.position(for: "video?t=60"))
    }

    func testYouTubeUsesApplicationIdentityAndDoesNotAutoplay() throws {
        let origin = EmbedHTML.appOrigin(bundleIdentifier: "com.md.MarkdownEditor")
        XCTAssertEqual(origin.absoluteString, "https://com.md.markdowneditor")
        let url = try XCTUnwrap(YouTubeEmbedURL.url(videoID: "AVEZBy1uAk8", startSeconds: 123, origin: origin))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "origin" })?.value, origin.absoluteString)
        XCTAssertEqual(items.first(where: { $0.name == "autoplay" })?.value, "0")
        XCTAssertEqual(items.first(where: { $0.name == "enablejsapi" })?.value, "1")
        XCTAssertEqual(items.first(where: { $0.name == "start" })?.value, "123")
    }

    func testReferenceLinksRemainResolvedAcrossEmbeds() {
        let document = MarkdownPreprocessor.preprocess("""
        Read [the guide][guide].

        https://youtu.be/AVEZBy1uAk8

        [guide]: https://example.com/guide
        """, context: PreviewContext(documentURL: nil, vaultURL: nil))
        let html = HTMLPreviewRenderer.render(document: document)
        XCTAssertTrue(html.contains("<a href=\"https://example.com/guide\">the guide</a>"))
    }

    func testEditorAndReadingPreviewDetectTheSameEmbedsIncludingMixedMarkdown() {
        let source = """
        # Before 😀

        https://x.com/user/status/12345

        Commentary with https://youtu.be/AVEZBy1uAk8 stays inline.

        ![](https://youtube.com/shorts/AVEZBy1uAk8?t=1m2s)

        ```text
        https://x.com/user/status/99999
        ```

        $$
        E = mc^2
        $$

        ```mermaid
        graph TD
        A --> B
        ```
        """
        let context = PreviewContext(documentURL: nil, vaultURL: nil)
        let document = MarkdownPreprocessor.preprocess(source, context: context)
        let embeds = document.segments.compactMap { segment -> EditorLinkPreview? in
            if case .embed(let preview) = segment { return preview }; return nil
        }
        XCTAssertEqual(embeds, EditorLinkPreviewDetector.presentationPreviews(in: source))
        XCTAssertEqual(embeds.count, 2)
        XCTAssertEqual(embeds.last?.youtubeStartSeconds, 62)
        XCTAssertEqual(document.preferredRenderMode, .embedded)
        XCTAssertTrue(document.requiresHTMLFallback)
        XCTAssertTrue(document.containsMermaid)
        let html = HTMLPreviewRenderer.render(document: document)
        XCTAssertTrue(html.contains("Commentary with"))
        XCTAssertFalse(html.contains("youtube-card"))
        XCTAssertTrue(html.contains("math-display"))
    }
}
