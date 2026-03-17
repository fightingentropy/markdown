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

    private var document: PreviewDocument {
        MarkdownPreprocessor.preprocess(markdown, context: context)
    }

    var body: some View {
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

private struct HTMLPreviewWebView: NSViewRepresentable {
    final class Coordinator {
        var lastHTML: String?
        var lastBaseURL: URL?
    }

    let html: String
    let baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
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
}
