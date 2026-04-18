import AppKit
import SwiftUI
import Textual
import WebKit

struct MarkdownPreview: View {
    let markdown: String
    let documentURL: URL?
    let vaultURL: URL?
    let assetLookupByFilename: [String: [URL]]
    let preferences: AppPreferences

    private var context: PreviewContext {
        PreviewContext(
            documentURL: documentURL,
            vaultURL: vaultURL,
            assetLookupByFilename: assetLookupByFilename
        )
    }

    var body: some View {
        let document = MarkdownPreprocessor.preprocessCached(markdown, context: context)
        switch document.preferredRenderMode {
        case .native:
            NativeMarkdownPreview(markdown: markdown, context: context, preferences: preferences)
        case .html:
            HTMLMarkdownPreview(document: document, preferences: preferences)
        }
    }
}

private struct NativeMarkdownPreview: View {
    let markdown: String
    let context: PreviewContext
    let preferences: AppPreferences

    private var inlineStyle: InlineStyle {
        InlineStyle.gitHub.code(
            .font(preferences.previewCodeFontChoice.swiftUIFont(size: preferences.previewCodeFontSizeCGFloat)),
            .backgroundColor(Color(nsColor: .quaternaryLabelColor).opacity(0.22))
        )
    }

    var body: some View {
        ScrollView {
            StructuredText(markdown, parser: NativePreviewMarkupParser(context: context))
                .font(preferences.previewFontChoice.swiftUIFont(size: preferences.previewFontSizeCGFloat))
                .textual.structuredTextStyle(.gitHub)
                .textual.inlineStyle(inlineStyle)
                .textual.codeBlockStyle(ConfigurablePreviewCodeBlockStyle(preferences: preferences))
                .textual.imageAttachmentLoader(PreviewImageAttachmentLoader(context: context))
                .textual.overflowMode(.wrap)
                .padding(.horizontal, 72)
                .padding(.top, 48)
                .padding(.bottom, 120)
                .frame(maxWidth: preferences.previewPageWidthCGFloat, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
}

private struct HTMLMarkdownPreview: View {
    let document: PreviewDocument
    let preferences: AppPreferences

    private var fullPageHTML: String {
        PreviewStylesheet.page(
            body: HTMLPreviewRenderer.render(document: document),
            preferences: preferences
        )
    }

    var body: some View {
        HTMLPreviewWebView(
            html: fullPageHTML,
            baseURL: document.context.previewBaseURL
        )
    }
}

private struct ConfigurablePreviewCodeBlockStyle: StructuredText.CodeBlockStyle {
    let preferences: AppPreferences

    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.225))
                .textual.fontScale(0.85)
                .fixedSize(horizontal: false, vertical: true)
                .font(preferences.previewCodeFontChoice.swiftUIFont(size: preferences.previewCodeFontSizeCGFloat))
                .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .textual.blockSpacing(.init(top: 0, bottom: 16))
    }
}

/// Serves bundled KaTeX assets to the preview WKWebView via a custom URL
/// scheme so LaTeX rendering works completely offline. Resources live under
/// `MarkdownEditor/Resources/katex/` in the app bundle.
final class KaTeXBundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "katex-asset"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Path component is of the form `/katex.min.css` or `/fonts/XYZ.woff2`.
        let trimmedPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedPath.isEmpty,
              !trimmedPath.contains(".."),
              let resourceURL = Bundle.main.url(forResource: "katex/\(trimmedPath)", withExtension: nil),
              let data = try? Data(contentsOf: resourceURL) else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: url.pathExtension),
                "Content-Length": "\(data.count)",
                "Cache-Control": "public, max-age=31536000, immutable",
            ]
        )!

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // No async work to cancel.
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}

private struct HTMLPreviewWebView: NSViewRepresentable {
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var lastHTML: String?
        var lastBaseURL: URL?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "openLink",
                  let urlString = message.body as? String,
                  let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        }

        func tearDown(_ webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "openLink")
        }
    }

    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.setURLSchemeHandler(
            KaTeXBundleSchemeHandler(),
            forURLScheme: KaTeXBundleSchemeHandler.scheme
        )

        let script = WKUserScript(
            source: """
            document.addEventListener('click', function(e) {
                var target = e.target;
                while (target && target.tagName !== 'A') {
                    target = target.parentElement;
                }
                if (target && target.href && target.href.startsWith('http')) {
                    e.preventDefault();
                    e.stopPropagation();
                    window.webkit.messageHandlers.openLink.postMessage(target.href);
                }
            }, true);
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(context.coordinator, name: "openLink")

        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html || context.coordinator.lastBaseURL != baseURL else {
            return
        }

        context.coordinator.lastHTML = html
        context.coordinator.lastBaseURL = baseURL
        nsView.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown(nsView)
    }
}
