import AppKit
import SwiftUI
import Textual
import WebKit

struct MarkdownPreview: View {
    let markdown: String
    let documentURL: URL?
    let vaultURL: URL?

    private var context: PreviewContext {
        PreviewContext(documentURL: documentURL, vaultURL: vaultURL)
    }

    private var document: PreviewDocument {
        MarkdownPreprocessor.preprocess(markdown, context: context)
    }

    var body: some View {
        switch document.preferredRenderMode {
        case .native:
            NativeMarkdownPreview(markdown: markdown, context: context)
        case .html:
            HTMLMarkdownPreview(document: document)
        }
    }
}

private struct NativeMarkdownPreview: View {
    let markdown: String
    let context: PreviewContext

    var body: some View {
        ScrollView {
            StructuredText(markdown, parser: NativePreviewMarkupParser(context: context))
                .textual.structuredTextStyle(.gitHub)
                .textual.imageAttachmentLoader(PreviewImageAttachmentLoader(context: context))
                .textual.overflowMode(.wrap)
                .padding(.horizontal, 72)
                .padding(.top, 48)
                .padding(.bottom, 120)
                .frame(maxWidth: 920, alignment: .leading)
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

    private var fullPageHTML: String {
        PreviewStylesheet.page(body: HTMLPreviewRenderer.render(document: document))
    }

    var body: some View {
        HTMLPreviewWebView(
            html: fullPageHTML,
            baseURL: document.context.previewBaseURL
        )
    }
}

private struct HTMLPreviewWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        return WKWebView(frame: .zero, configuration: configuration)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(html, baseURL: baseURL)
    }
}
