import Foundation

enum MarkdownToHTML {
    static func resolveInlineImageFileURL(
        forLine line: String,
        documentURL: URL? = nil,
        vaultURL: URL? = nil
    ) -> URL? {
        AssetResolver(
            context: PreviewContext(
                documentURL: documentURL,
                vaultURL: vaultURL
            )
        )
        .resolveInlineImageFileURL(forLine: line)
    }

    static func convert(
        _ markdown: String,
        documentURL: URL? = nil,
        vaultURL: URL? = nil
    ) -> String {
        let context = PreviewContext(documentURL: documentURL, vaultURL: vaultURL)
        let document = MarkdownPreprocessor.preprocess(markdown, context: context)
        return HTMLPreviewRenderer.render(document: document)
    }
}
