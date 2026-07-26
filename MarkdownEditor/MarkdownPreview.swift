import AppKit
import SwiftUI
import Textual
import WebKit

enum PreviewURLPolicy {
    private static let externallyOpenableSchemes: Set<String> = [
        "http", "https", "mailto"
    ]

    static func canOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return externallyOpenableSchemes.contains(scheme)
    }

    static func internalVaultFile(_ url: URL, vaultURL: URL?) -> URL? {
        guard let resolvedURL = fileInsideVault(url, vaultURL: vaultURL),
              Workspace.isMarkdownFile(resolvedURL) || Workspace.isImageFile(resolvedURL) else {
            return nil
        }
        return resolvedURL
    }

    /// Any regular file contained by the vault (or equal to the vault root).
    static func fileInsideVault(_ url: URL, vaultURL: URL?) -> URL? {
        guard url.isFileURL, let vaultURL else { return nil }
        let resolvedVault = vaultURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let isInside = resolvedURL.path == resolvedVault.path
            || resolvedURL.path.hasPrefix(resolvedVault.path + "/")
        guard isInside, FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }
        return resolvedURL
    }
}

struct MarkdownPreview: View {
    let markdown: String
    let documentURL: URL?
    let vaultURL: URL?
    let assetLookupByFilename: [String: [URL]]
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

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
            NativeMarkdownPreview(
                markdown: markdown,
                context: context,
                preferences: preferences,
                onOpenInternalFile: onOpenInternalFile
            )
        case .html:
            HTMLMarkdownPreview(
                document: document,
                preferences: preferences,
                onOpenInternalFile: onOpenInternalFile
            )
        }
    }
}

private struct NativeMarkdownPreview: View {
    let markdown: String
    let context: PreviewContext
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

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
            if let internalURL = PreviewURLPolicy.internalVaultFile(url, vaultURL: context.vaultURL) {
                onOpenInternalFile(internalURL)
                return .handled
            }
            guard PreviewURLPolicy.canOpenExternally(url) else {
                NSSound.beep()
                return .discarded
            }

            return NSWorkspace.shared.open(url) ? .handled : .discarded
        })
    }
}

private struct HTMLMarkdownPreview: View {
    let document: PreviewDocument
    let preferences: AppPreferences
    let onOpenInternalFile: (URL) -> Void

    private var fullPageHTML: String {
        PreviewStylesheet.page(
            body: HTMLPreviewRenderer.render(document: document),
            preferences: preferences
        )
    }

    var body: some View {
        HTMLPreviewWebView(
            html: fullPageHTML,
            baseURL: document.context.previewBaseURL,
            vaultURL: document.context.vaultURL,
            onOpenInternalFile: onOpenInternalFile
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

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: url.pathExtension),
                "Content-Length": "\(data.count)",
                "Cache-Control": "public, max-age=31536000, immutable",
            ]
        ) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }

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
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var lastHTML: String?
        var lastBaseURL: URL?
        var vaultURL: URL?
        var onOpenInternalFile: (URL) -> Void

        init(vaultURL: URL?, onOpenInternalFile: @escaping (URL) -> Void) {
            self.vaultURL = vaultURL
            self.onOpenInternalFile = onOpenInternalFile
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "openLink",
                  let urlString = message.body as? String,
                  let url = URL(string: urlString) else { return }
            route(url)
        }

        /// Authoritative navigation policy. The preview frame must only ever
        /// display the HTML we load programmatically; user-initiated link
        /// clicks open in the default browser (http/https/mailto) or are
        /// rejected outright. This prevents `javascript:`/`file:`/`data:`
        /// links from navigating the file:// preview in place.
        @MainActor
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            switch navigationAction.navigationType {
            case .linkActivated:
                if let url = navigationAction.request.url {
                    route(url)
                }
                decisionHandler(.cancel)
            case .other, .reload, .formSubmitted, .formResubmitted, .backForward:
                // `.other` covers our own `loadHTMLString`. Everything that is
                // not an explicit link click stays inside the (app-generated)
                // page; we still never let it leave the loaded document.
                decisionHandler(.allow)
            @unknown default:
                decisionHandler(.allow)
            }
        }

        private func route(_ url: URL) {
            if let internalURL = PreviewURLPolicy.internalVaultFile(url, vaultURL: vaultURL) {
                onOpenInternalFile(internalURL)
            } else if PreviewURLPolicy.canOpenExternally(url) {
                NSWorkspace.shared.open(url)
            }
        }

        func tearDown(_ webView: WKWebView) {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "openLink")
        }
    }

    let html: String
    let baseURL: URL?
    let vaultURL: URL?
    let onOpenInternalFile: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(vaultURL: vaultURL, onOpenInternalFile: onOpenInternalFile)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        #if DEBUG
        // Web Inspector is a developer convenience; never ship it enabled.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
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

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.vaultURL = vaultURL
        context.coordinator.onOpenInternalFile = onOpenInternalFile
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
