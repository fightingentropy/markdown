import AppKit
import SwiftUI
@preconcurrency import WebKit

private let embedMessageName = "embedEvent"

struct EditorLinkPreviewCard: View {
    let preview: EditorLinkPreview
    let openURL: (URL) -> Void
    var xEmbedHeightChanged: (CGFloat) -> Void = { _ in }
    var xHoverChanged: (Bool) -> Void = { _ in }
    var youtubeHoverChanged: (Bool) -> Void = { _ in }
    var isPresented = true
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ProviderEmbedView(preview: preview, theme: colorScheme == .dark ? "dark" : "light",
                          isPresented: isPresented, openURL: openURL, heightChanged: xEmbedHeightChanged)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovering in
                switch preview.kind {
                case .xPost: xHoverChanged(hovering)
                case .youtube: youtubeHoverChanged(hovering)
                }
            }
            .help(preview.url.absoluteString)
            .accessibilityLabel(preview.title)
    }
}

struct ProviderEmbedView: NSViewRepresentable {
    let preview: EditorLinkPreview
    let theme: String
    let isPresented: Bool
    let openURL: (URL) -> Void
    let heightChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CachedEmbedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: embedMessageName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel(preview.title)
        let container = CachedEmbedWebView(webView: webView)
        update(container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CachedEmbedWebView, context: Context) {
        update(container, coordinator: context.coordinator)
    }

    private func update(_ container: CachedEmbedWebView, coordinator: Coordinator) {
        coordinator.container = container
        coordinator.preview = preview
        coordinator.theme = theme
        coordinator.openURL = openURL
        coordinator.heightChanged = heightChanged
        container.openOriginal = { [weak coordinator] in
            guard let coordinator, let preview = coordinator.preview else { return }
            coordinator.openURL?(preview.url)
        }
        container.pausePlayer = { [weak container] in
            container?.webView.evaluateJavaScript("window.embedPause && window.embedPause()", completionHandler: nil)
        }
        container.setPresented(isPresented)
        let key: String
        switch preview.kind {
        case .xPost(_, let statusID): key = "x-\(statusID)-\(theme)"
        case .youtube(let videoID): key = "youtube-\(videoID)-\(preview.youtubeStartSeconds ?? 0)-\(theme)"
        }
        container.configure(contentKey: key) { [weak coordinator] token in coordinator?.load(token: token) }
    }

    static func dismantleNSView(_ container: CachedEmbedWebView, coordinator: Coordinator) {
        container.tearDown()
        coordinator.container = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var container: CachedEmbedWebView?
        var preview: EditorLinkPreview?
        var theme = "light"
        var openURL: ((URL) -> Void)?
        var heightChanged: ((CGFloat) -> Void)?

        func load(token: String) {
            guard let container, let preview else { return }
            let html: String
            switch preview.kind {
            case .xPost(let username, let statusID):
                html = XPostEmbedHTML.document(postURL: preview.url, username: username, statusID: statusID, theme: theme, token: token)
            case .youtube(let videoID):
                let seconds = EmbedPlaybackStore.shared.position(for: preview.id) ?? Double(preview.youtubeStartSeconds ?? 0)
                html = YouTubeEmbedHTML.document(videoID: videoID, startSeconds: seconds, token: token)
            }
            container.webView.loadHTMLString(html, baseURL: EmbedHTML.appOrigin())
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == embedMessageName, message.frameInfo.isMainFrame,
                  let payload = message.body as? [String: Any] else { return }
            receive(payload)
        }

        func receive(_ payload: [String: Any]) {
            guard let container, let preview, let token = payload["token"] as? String,
                  token == container.loadToken, !token.isEmpty,
                  let type = payload["type"] as? String else { return }
            switch type {
            case "ready":
                container.markReady()
            case "height":
                guard case .xPost = preview.kind,
                      container.loadState == .loading || container.loadState == .ready,
                      let value = payload["height"] as? Double, value.isFinite, value > 0, value <= 100_000 else { return }
                heightChanged?(CGFloat(value))
                container.markReady()
            case "position":
                guard case .youtube = preview.kind, let seconds = payload["seconds"] as? Double else { return }
                EmbedPlaybackStore.shared.save(seconds, for: preview.id)
            case "error":
                let message: String
                if case .youtube = preview.kind {
                    switch payload["code"] as? Int {
                    case 100: message = "This video is unavailable or private."
                    case 101, 150: message = "This video can only be watched on YouTube."
                    default: message = "YouTube couldn’t load this video. Try again or open the original."
                    }
                } else {
                    message = "This post is unavailable, or X couldn’t be reached."
                }
                container.fail(message)
            default: break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            container?.fail("The embed stopped responding. Try loading it again.")
        }
        private func navigationFailed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            container?.fail("Couldn’t connect. Check your connection and try again.")
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, PreviewURLPolicy.canOpenExternally(url) { openURL?(url) }
                decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
    }
}

enum EmbedHTML {
    static func appOrigin(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> URL {
        URL(string: "https://\((bundleIdentifier ?? "com.md.MarkdownEditor").lowercased())")!
    }

    static func js(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
    }

    static func bridge(token: String) -> String {
        """
        function emit(type, values = {}) {
          window.webkit.messageHandlers.\(embedMessageName).postMessage(Object.assign({type, token: \(js(token))}, values));
        }
        function embedFail(code) { emit('error', {code: code || 0}); }
        """
    }
}

enum YouTubeEmbedHTML {
    static func document(videoID: String, startSeconds: Double, token: String) -> String {
        let seconds = startSeconds.isFinite ? max(0, min(startSeconds, Double(Int32.max))) : 0
        let url = YouTubeEmbedURL.url(videoID: videoID, startSeconds: Int(seconds), origin: EmbedHTML.appOrigin())!
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body,#player{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{border:0}</style>
        </head><body><div id="player"></div><script>
        \(EmbedHTML.bridge(token: token))
        let player, timer;
        function savePosition() {
          if (player && player.getCurrentTime) emit('position', {seconds: player.getCurrentTime()});
        }
        window.embedPause = function() {
          clearInterval(timer); savePosition();
          if (player && player.pauseVideo) player.pauseVideo();
        };
        window.onYouTubeIframeAPIReady = function() {
          const frame = document.createElement('iframe');
          frame.id = 'player'; frame.src = \(EmbedHTML.js(url.absoluteString));
          frame.allow = 'accelerometer; encrypted-media; gyroscope; picture-in-picture; fullscreen';
          frame.setAttribute('allowfullscreen', ''); frame.title = 'YouTube video player';
          document.getElementById('player').replaceWith(frame);
          player = new YT.Player(frame, {events: {
            onReady: function() { emit('ready'); },
            onError: function(event) { clearInterval(timer); embedFail(event.data); },
            onStateChange: function(event) {
              clearInterval(timer);
              if (event.data === 0) { emit('position', {seconds: 0}); }
              else if (event.data === 1 || event.data === 2) { savePosition(); }
              if (event.data === 1) timer = setInterval(savePosition, 1000);
            }
          }});
        };
        window.addEventListener('pagehide', window.embedPause);
        </script><script async src="https://www.youtube.com/iframe_api" onerror="embedFail()"></script></body></html>
        """
    }
}

enum XPostEmbedHTML {
    static func document(postURL: URL, username: String, statusID: String, theme: String, token: String = "") -> String {
        let safeStatusID = statusID.filter { $0.isASCII && $0.isNumber }
        let safeTheme = theme == "dark" ? "dark" : "light"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>:root{color-scheme:\(safeTheme)}html,body{margin:0;padding:0;width:100%;background:transparent;overflow:hidden}
        #tweet{width:100%;min-height:220px}#tweet iframe{margin:0!important}</style></head>
        <body><div id="tweet"></div><script>
        \(EmbedHTML.bridge(token: token))
        let tweetReady = false;
        function reportHeight() {
          const frame = document.querySelector('#tweet iframe');
          if (tweetReady && frame) emit('height', {height: Math.ceil(frame.getBoundingClientRect().height)});
        }
        new ResizeObserver(reportHeight).observe(document.getElementById('tweet'));
        function loadTweet() {
          if (!window.twttr) { embedFail(); return; }
          twttr.ready(function(api) {
            api.widgets.createTweet('\(safeStatusID)', document.getElementById('tweet'), {
              theme: '\(safeTheme)', dnt: true, conversation: 'none', align: 'left'
            }).then(function(element) {
              if (!element) { embedFail(); return; }
              tweetReady = true;
              // X can resize the iframe after its factory promise resolves,
              // including when a quoted post or media finishes loading.
              new ResizeObserver(reportHeight).observe(element);
              reportHeight();
            }).catch(function() { embedFail(); });
          });
        }
        </script><script async src="https://platform.x.com/widgets.js" onload="loadTweet()" onerror="embedFail()" charset="utf-8"></script>
        </body></html>
        """
    }
}
