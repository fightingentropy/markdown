import SwiftUI
import WebKit

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: .zero, configuration: config)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        let bodyHTML = MarkdownToHTML.convert(markdown)
        let fullPage = PreviewStylesheet.page(body: bodyHTML)
        nsView.loadHTMLString(fullPage, baseURL: nil)
    }
}
