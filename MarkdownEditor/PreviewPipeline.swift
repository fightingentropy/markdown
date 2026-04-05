import AppKit
import Down
import Foundation
import libcmark
import SwiftUI
import Textual

struct PreviewContext: Equatable {
    let documentURL: URL?
    let vaultURL: URL?
    var assetLookupByFilename: [String: [URL]] = [:]

    var documentDirectoryURL: URL? {
        documentURL?.deletingLastPathComponent()
    }

    var previewBaseURL: URL? {
        documentDirectoryURL ?? vaultURL
    }
}

struct ResolvedAsset: Equatable {
    enum Kind: Equatable {
        case image
        case file
    }

    let fileURL: URL
    let kind: Kind
    let mimeType: String

    var isImage: Bool {
        kind == .image
    }
}

enum PreviewSegment {
    case markdown(String)
    case mermaid(source: String, diagram: MermaidDiagram?)
}

enum PreviewRenderMode {
    case native
    case html
}

struct PreviewDocument {
    let source: String
    let context: PreviewContext
    let segments: [PreviewSegment]
    let requiresHTMLFallback: Bool

    var containsMermaid: Bool {
        segments.contains { segment in
            if case .mermaid = segment {
                return true
            }

            return false
        }
    }

    var preferredRenderMode: PreviewRenderMode {
        if requiresHTMLFallback || containsMermaid {
            return .html
        }

        return .native
    }

    var normalizedMarkdown: String {
        segments.compactMap { segment in
            if case .markdown(let markdown) = segment {
                return markdown
            }

            return nil
        }
        .joined(separator: "\n")
    }
}

enum PreviewPipelineError: Error {
    case unresolvedImageReference(String)
    case invalidImageData(URL)
}

struct AssetResolver {
    private enum Constants {
        static let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp",
        ]
    }

    let context: PreviewContext

    func resolve(reference: String) -> ResolvedAsset? {
        guard let fileURL = resolveFileURL(reference: reference) else {
            return nil
        }

        return ResolvedAsset(
            fileURL: fileURL,
            kind: isImageFile(fileURL) ? .image : .file,
            mimeType: mimeType(for: fileURL.pathExtension)
        )
    }

    func resolveImage(reference: String) -> ResolvedAsset? {
        guard let asset = resolve(reference: reference), asset.isImage else {
            return nil
        }

        return asset
    }

    func resolveImageURL(for markupURL: URL) -> URL? {
        if markupURL.isFileURL {
            let standardized = markupURL.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path), isImageFile(standardized) else {
                return nil
            }

            return standardized
        }

        if let scheme = markupURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return markupURL
        }

        return resolveImage(reference: markupURL.absoluteString)?.fileURL
    }

    func resolveInlineImageFileURL(forLine line: String) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let reference = PreviewMarkdownSyntax.standaloneObsidianImageReference(in: trimmed) {
            return resolveImage(reference: reference.target)?.fileURL
        }

        if let image = PreviewMarkdownSyntax.parseStandaloneMarkdownImage(in: trimmed) {
            return resolveImage(reference: image.destination)?.fileURL
        }

        return nil
    }

    private func resolveFileURL(reference: String) -> URL? {
        let normalized = normalizeReference(reference)
        guard !normalized.isEmpty else {
            return nil
        }

        if let fileSchemeURL = fileURL(from: normalized) {
            let standardized = fileSchemeURL.standardizedFileURL
            return FileManager.default.fileExists(atPath: standardized.path) ? standardized : nil
        }

        if normalized.hasPrefix("/") {
            let absoluteURL = URL(fileURLWithPath: normalized).standardizedFileURL
            return FileManager.default.fileExists(atPath: absoluteURL.path) ? absoluteURL : nil
        }

        let baseCandidates = [context.documentDirectoryURL, context.vaultURL]
        for baseURL in baseCandidates.compactMap({ $0 }) {
            let candidate = URL(fileURLWithPath: normalized, relativeTo: baseURL).standardizedFileURL
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        if let indexedMatches = context.assetLookupByFilename[normalized], !indexedMatches.isEmpty {
            return indexedMatches.count == 1 ? indexedMatches[0] : indexedMatches.first
        }

        guard !normalized.contains("/"), let vaultURL = context.vaultURL else {
            return nil
        }

        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == normalized {
            matches.append(fileURL.standardizedFileURL)
        }

        if matches.count == 1 {
            return matches[0]
        }

        return matches.first
    }

    private func fileURL(from reference: String) -> URL? {
        guard let url = URL(string: reference), url.scheme?.lowercased() == "file" else {
            return nil
        }

        return url
    }

    private func normalizeReference(_ reference: String) -> String {
        var trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
        }

        return trimmed
    }

    private func isImageFile(_ url: URL) -> Bool {
        Constants.imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "heif":
            return "image/heif"
        case "svg":
            return "image/svg+xml"
        case "tiff":
            return "image/tiff"
        case "bmp":
            return "image/bmp"
        case "pdf":
            return "application/pdf"
        default:
            return "application/octet-stream"
        }
    }
}

enum MarkdownPreprocessor {
    static func preprocess(_ markdown: String, context: PreviewContext) -> PreviewDocument {
        let normalizedSource = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let resolver = AssetResolver(context: context)
        let noteResolver = NoteReferenceResolver(
            noteURLs: context.assetLookupByFilename.values
                .flatMap { $0 }
                .filter(Workspace.isMarkdownFile),
            vaultURL: context.vaultURL
        )

        var segments: [PreviewSegment] = []
        var markdownBuffer: [String] = []
        var requiresHTMLFallback = false
        var index = 0

        func flushMarkdownBuffer() {
            guard !markdownBuffer.isEmpty else {
                return
            }

            segments.append(.markdown(markdownBuffer.joined(separator: "\n")))
            markdownBuffer.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let fence = codeFenceMarker(in: trimmed) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if language.lowercased() == "mermaid" {
                    flushMarkdownBuffer()
                    index += 1

                    var mermaidLines: [String] = []
                    while index < lines.count {
                        let candidate = lines[index]
                        if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                            index += 1
                            break
                        }

                        mermaidLines.append(candidate)
                        index += 1
                    }

                    let source = mermaidLines.joined(separator: "\n")
                    segments.append(.mermaid(source: source, diagram: MermaidParser.parse(source)))
                    continue
                }

                markdownBuffer.append(line)
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    markdownBuffer.append(candidate)
                    index += 1

                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        break
                    }
                }
                continue
            }

            markdownBuffer.append(
                rewriteInlineSyntax(
                    in: line,
                    resolver: resolver,
                    noteResolver: noteResolver,
                    documentURL: context.documentURL,
                    requiresHTMLFallback: &requiresHTMLFallback
                )
            )
            index += 1
        }

        flushMarkdownBuffer()

        if segments.isEmpty {
            segments = [.markdown("")]
        }

        return PreviewDocument(
            source: normalizedSource,
            context: context,
            segments: segments,
            requiresHTMLFallback: requiresHTMLFallback
        )
    }

    private static func codeFenceMarker(in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("```") else {
            return nil
        }

        let marker = trimmedLine.prefix { $0 == "`" }
        guard marker.count >= 3 else {
            return nil
        }

        return String(marker)
    }

    private static func rewriteInlineSyntax(
        in line: String,
        resolver: AssetResolver,
        noteResolver: NoteReferenceResolver,
        documentURL: URL?,
        requiresHTMLFallback: inout Bool
    ) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0
        var activeInlineCodeFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }

                let fenceLength = index - runStart
                result.append(contentsOf: characters[runStart..<index])

                if activeInlineCodeFenceLength == fenceLength {
                    activeInlineCodeFenceLength = nil
                } else if activeInlineCodeFenceLength == nil {
                    activeInlineCodeFenceLength = fenceLength
                }

                continue
            }

            if activeInlineCodeFenceLength == nil {
                if let rewrite = rewriteObsidianEmbed(
                    in: characters,
                    from: index,
                    resolver: resolver,
                    requiresHTMLFallback: &requiresHTMLFallback
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }

                if let rewrite = rewriteObsidianNoteLink(
                    in: characters,
                    from: index,
                    resolver: noteResolver,
                    documentURL: documentURL
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }

                if let rewrite = rewriteMarkdownImage(
                    in: characters,
                    from: index,
                    resolver: resolver
                ) {
                    result += rewrite.rendered
                    index = rewrite.nextIndex
                    continue
                }
            }

            result.append(characters[index])
            index += 1
        }

        return result
    }

    private static func rewriteObsidianEmbed(
        in characters: [Character],
        from index: Int,
        resolver: AssetResolver,
        requiresHTMLFallback: inout Bool
    ) -> (rendered: String, nextIndex: Int)? {
        guard index + 3 < characters.count,
              characters[index] == "!",
              characters[index + 1] == "[",
              characters[index + 2] == "[" else {
            return nil
        }

        var cursor = index + 3
        while cursor + 1 < characters.count {
            if characters[cursor] == "]", characters[cursor + 1] == "]" {
                let rawReference = String(characters[(index + 3)..<cursor])
                let original = String(characters[index..<(cursor + 2)])
                let descriptor = PreviewMarkdownSyntax.parseObsidianReference(rawReference)

                guard let asset = resolver.resolve(reference: descriptor.target) else {
                    return (original, cursor + 2)
                }

                if asset.isImage {
                    let title = descriptor.width.map { PreviewMarkdownSyntax.widthTitleMarker(for: $0) }
                    if descriptor.width != nil {
                        requiresHTMLFallback = true
                    }

                    return (
                        PreviewMarkdownSyntax.imageMarkdown(
                            altText: descriptor.displayName,
                            destination: asset.fileURL,
                            title: title
                        ),
                        cursor + 2
                    )
                }

                return (
                    PreviewMarkdownSyntax.linkMarkdown(
                        label: descriptor.displayName,
                        destination: asset.fileURL
                    ),
                    cursor + 2
                )
            }

            cursor += 1
        }

        return nil
    }

    private static func rewriteObsidianNoteLink(
        in characters: [Character],
        from index: Int,
        resolver: NoteReferenceResolver,
        documentURL: URL?
    ) -> (rendered: String, nextIndex: Int)? {
        guard let match = MarkdownNoteLinkExtractor.obsidianNoteLink(in: characters, from: index) else {
            return nil
        }

        let original = String(characters[index..<match.nextIndex])
        guard let destination = resolver.resolve(destination: match.destination, from: documentURL) else {
            return (original, match.nextIndex)
        }

        return (
            PreviewMarkdownSyntax.linkMarkdown(
                label: match.displayName,
                destination: destination
            ),
            match.nextIndex
        )
    }

    private static func rewriteMarkdownImage(
        in characters: [Character],
        from index: Int,
        resolver: AssetResolver
    ) -> (rendered: String, nextIndex: Int)? {
        guard let parsed = PreviewMarkdownSyntax.parseMarkdownImage(in: characters, from: index) else {
            return nil
        }

        guard let asset = resolver.resolveImage(reference: parsed.destination) else {
            return (parsed.original, parsed.nextIndex)
        }

        return (
            PreviewMarkdownSyntax.imageMarkdown(
                altText: parsed.altText,
                destination: asset.fileURL,
                title: parsed.title
            ),
            parsed.nextIndex
        )
    }
}

enum HTMLPreviewRenderer {
    private static let gfmExtensionNames = ["table", "strikethrough", "autolink"]

    static func render(document: PreviewDocument) -> String {
        document.segments.map(render).joined(separator: "\n")
    }

    private static func render(_ segment: PreviewSegment) -> String {
        switch segment {
        case .markdown(let markdown):
            guard !markdown.isEmpty else {
                return ""
            }

            let html = renderMarkdown(markdown)
            return applyAppSpecificPostProcessing(to: html)

        case .mermaid(let source, let diagram):
            guard let diagram else {
                return applyAppSpecificPostProcessing(
                    to: renderMarkdown("```mermaid\n\(source)\n```")
                )
            }

            return "<div class=\"mermaid-diagram\">\(MermaidRenderer.renderToSVG(diagram))</div>"
        }
    }

    private static func renderMarkdown(_ markdown: String) -> String {
        let sanitizedMarkdown = escapeUserHTML(in: markdown)
        let options = Int32(CMARK_OPT_UNSAFE)

        guard let parser = cmark_parser_new(options) else {
            return ""
        }
        defer { cmark_parser_free(parser) }

        for extensionName in gfmExtensionNames {
            extensionName.withCString { name in
                guard let syntaxExtension = cmark_find_syntax_extension(name) else {
                    return
                }

                _ = cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }

        sanitizedMarkdown.withCString { markdownCString in
            cmark_parser_feed(parser, markdownCString, strlen(markdownCString))
        }

        guard let document = cmark_parser_finish(parser) else {
            return ""
        }
        defer { cmark_node_free(document) }

        guard let renderedHTML = cmark_render_html(
            document,
            options,
            cmark_parser_get_syntax_extensions(parser)
        ) else {
            return ""
        }
        defer {
            cmark_get_default_mem_allocator()?.pointee.free(renderedHTML)
        }

        return String(cString: renderedHTML)
    }

    private static func applyAppSpecificPostProcessing(to html: String) -> String {
        let pattern = #"title="codex-obsidian-width-(\d+)""#
        let widthAdjustedHTML: String
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: (html as NSString).length)
            widthAdjustedHTML = regex.stringByReplacingMatches(
                in: html,
                range: range,
                withTemplate: "width=\"$1\""
            )
        } else {
            widthAdjustedHTML = html
        }

        return transformParagraphBlocks(in: widthAdjustedHTML)
    }

    private static func transformParagraphBlocks(in html: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"<p>((?s:.*?))</p>"#) else {
            return html
        }

        let nsHTML = html as NSString
        let range = NSRange(location: 0, length: nsHTML.length)
        var transformed = html
        let matches = regex.matches(in: html, range: range)

        for match in matches.reversed() {
            let contentRange = match.range(at: 1)
            guard contentRange.location != NSNotFound else {
                continue
            }

            let originalContent = nsHTML.substring(with: contentRange)
            let replacement: String
            if let tableHTML = renderTableParagraphIfNeeded(from: originalContent) {
                replacement = tableHTML
            } else {
                replacement = "<p>\(replaceStrikethrough(in: autolinkBareURLs(in: originalContent)))</p>"
            }

            transformed = (transformed as NSString).replacingCharacters(
                in: match.range,
                with: replacement
            )
        }

        return transformed
    }

    private static func renderTableParagraphIfNeeded(from paragraphContent: String) -> String? {
        let lines = paragraphContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2,
              lines[0].contains("|"),
              lines[1].range(of: #"^[\s|:\-]+$"#, options: .regularExpression) != nil else {
            return nil
        }

        let headers = parseTableRow(lines[0])
        let alignments = parseTableAlignments(lines[1])
        guard !headers.isEmpty else {
            return nil
        }

        var html = "<table>\n<thead>\n<tr>\n"
        for (index, header) in headers.enumerated() {
            let alignment = alignments.count > index ? alignments[index] : nil
            let attribute = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
            html += "<th\(attribute)>\(escapeHTML(unescapeHTML(header)))</th>\n"
        }
        html += "</tr>\n</thead>\n<tbody>\n"

        for rowLine in lines.dropFirst(2) where !rowLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cells = parseTableRow(rowLine)
            html += "<tr>\n"
            for (index, cell) in cells.enumerated() {
                let alignment = alignments.count > index ? alignments[index] : nil
                let attribute = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
                html += "<td\(attribute)>\(escapeHTML(unescapeHTML(cell)))</td>\n"
            }
            html += "</tr>\n"
        }

        html += "</tbody>\n</table>"
        return html
    }

    private static func autolinkBareURLs(in string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![=\"'])https?://[^\s<\"]+"#) else {
            return string
        }

        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var result = string

        for match in regex.matches(in: string, range: range).reversed() {
            let url = nsString.substring(with: match.range)
            let replacement = "<a href=\"\(url)\">\(url)</a>"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    private static func replaceStrikethrough(in string: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"~~(.+?)~~"#) else {
            return string
        }

        let nsString = string as NSString
        let range = NSRange(location: 0, length: nsString.length)
        var result = string

        for match in regex.matches(in: string, range: range).reversed() {
            let innerRange = match.range(at: 1)
            guard innerRange.location != NSNotFound else {
                continue
            }

            let content = nsString.substring(with: innerRange)
            let replacement = "<del>\(content)</del>"
            result = (result as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return result
    }

    private static func parseTableRow(_ line: String) -> [String] {
        line.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func parseTableAlignments(_ line: String) -> [String] {
        parseTableRow(line).map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
                return "center"
            }

            if trimmed.hasSuffix(":") {
                return "right"
            }

            if trimmed.hasPrefix(":") {
                return "left"
            }

            return ""
        }
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func unescapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escapeUserHTML(in markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sanitizedLines: [String] = []
        var isInsideCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                isInsideCodeBlock.toggle()
                sanitizedLines.append(line)
                continue
            }

            if isInsideCodeBlock {
                sanitizedLines.append(line)
            } else {
                sanitizedLines.append(escapeHTMLTagsOutsideCodeSpans(in: line))
            }
        }

        return sanitizedLines.joined(separator: "\n")
    }

    private static func escapeHTMLTagsOutsideCodeSpans(in line: String) -> String {
        let characters = Array(line)
        var result = ""
        var index = 0
        var activeInlineCodeFenceLength: Int?

        while index < characters.count {
            if characters[index] == "`" {
                let runStart = index
                while index < characters.count, characters[index] == "`" {
                    index += 1
                }

                let fenceLength = index - runStart
                result.append(contentsOf: characters[runStart..<index])

                if activeInlineCodeFenceLength == fenceLength {
                    activeInlineCodeFenceLength = nil
                } else if activeInlineCodeFenceLength == nil {
                    activeInlineCodeFenceLength = fenceLength
                }

                continue
            }

            if activeInlineCodeFenceLength == nil,
               characters[index] == "<",
               let closeIndex = characters[index...].firstIndex(of: ">") {
                let content = String(characters[(index + 1)..<closeIndex])
                if shouldEscapeAngleBracketContent(content) {
                    result += "&lt;\(content)&gt;"
                    index = closeIndex + 1
                    continue
                }
            }

            result.append(characters[index])
            index += 1
        }

        return result
    }

    private static func shouldEscapeAngleBracketContent(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        if trimmed.contains("://") || trimmed.lowercased().hasPrefix("file:") {
            return false
        }

        if trimmed.contains("@"), !trimmed.contains(" ") {
            return false
        }

        guard let firstCharacter = trimmed.first else {
            return false
        }

        return firstCharacter == "/" || firstCharacter == "!" || firstCharacter == "?" || firstCharacter.isLetter
    }
}

@MainActor
struct NativePreviewMarkupParser: MarkupParser {
    let context: PreviewContext

    func attributedString(for input: String) throws -> AttributedString {
        let document = MarkdownPreprocessor.preprocess(input, context: context)
        guard document.preferredRenderMode == .native else {
            return AttributedString()
        }

        let parser = AttributedStringMarkdownParser.markdown(baseURL: context.previewBaseURL)
        return try parser.attributedString(for: document.normalizedMarkdown)
    }
}

struct PreviewImageAttachmentLoader: AttachmentLoader {
    typealias Attachment = PreviewImageAttachment

    let context: PreviewContext

    func attachment(
        for url: URL,
        text: String,
        environment _: ColorEnvironmentValues
    ) async throws -> PreviewImageAttachment {
        let loaded = try await PreviewImageSourceLoader.loadImageData(for: url, context: context)
        let size = try PreviewImageSourceLoader.imageSize(for: loaded.data, url: loaded.resolvedURL)

        return PreviewImageAttachment(
            id: loaded.resolvedURL.absoluteString,
            text: text,
            data: loaded.data,
            intrinsicSize: size
        )
    }
}

enum PreviewImageSourceLoader {
    static func resolvedImageURL(for url: URL, context: PreviewContext) -> URL? {
        let resolver = AssetResolver(context: context)
        return resolver.resolveImageURL(for: url)
    }

    static func loadImageData(for url: URL, context: PreviewContext) async throws -> (data: Data, resolvedURL: URL) {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            let (data, _) = try await URLSession.shared.data(from: url)
            return (data, url)
        }

        guard let resolvedURL = resolvedImageURL(for: url, context: context) else {
            throw PreviewPipelineError.unresolvedImageReference(url.absoluteString)
        }

        return (try Data(contentsOf: resolvedURL), resolvedURL)
    }

    static func imageSize(for data: Data, url: URL) throws -> CGSize {
        guard let image = NSImage(data: data) else {
            throw PreviewPipelineError.invalidImageData(url)
        }

        if let representation = image.representations.first,
           representation.pixelsWide > 0,
           representation.pixelsHigh > 0 {
            return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
        }

        return image.size
    }
}

struct PreviewImageAttachment: Attachment {
    let id: String
    let text: String
    let data: Data
    let intrinsicSize: CGSize

    var description: String {
        text
    }

    @MainActor
    var body: some View {
        Group {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(text)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else {
            return CGSize(width: proposal.width ?? 320, height: 180)
        }

        let proposedWidth = proposal.width ?? intrinsicSize.width
        let width = min(proposedWidth, intrinsicSize.width)
        let aspectRatio = intrinsicSize.height / intrinsicSize.width
        return CGSize(width: width, height: width * aspectRatio)
    }

    static func == (lhs: PreviewImageAttachment, rhs: PreviewImageAttachment) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
    }
}

enum PreviewMarkdownSyntax {
    struct ObsidianReference {
        let target: String
        let displayName: String
        let width: Int?
    }

    struct ParsedMarkdownImage {
        let original: String
        let altText: String
        let destination: String
        let title: String?
        let nextIndex: Int
    }

    static func standaloneObsidianImageReference(in line: String) -> ObsidianReference? {
        guard line.hasPrefix("![["), line.hasSuffix("]]"), line.count >= 5 else {
            return nil
        }

        let start = line.index(line.startIndex, offsetBy: 3)
        let end = line.index(line.endIndex, offsetBy: -2)
        return parseObsidianReference(String(line[start..<end]))
    }

    static func parseObsidianReference(_ rawReference: String) -> ObsidianReference {
        let trimmed = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "|", maxSplits: 1).map(String.init)
        let targetWithFragment = parts.first ?? trimmed
        let target = targetWithFragment.split(separator: "#", maxSplits: 1).first.map(String.init) ?? targetWithFragment
        let width = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let fileName = URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent
        let displayName = fileName.isEmpty ? target : fileName

        return ObsidianReference(
            target: target,
            displayName: displayName,
            width: width
        )
    }

    static func parseStandaloneMarkdownImage(in line: String) -> ParsedMarkdownImage? {
        let characters = Array(line)
        guard let parsed = parseMarkdownImage(in: characters, from: 0), parsed.nextIndex == characters.count else {
            return nil
        }

        return parsed
    }

    static func parseMarkdownImage(in characters: [Character], from startIndex: Int) -> ParsedMarkdownImage? {
        guard startIndex + 3 < characters.count,
              characters[startIndex] == "!",
              characters[startIndex + 1] == "[" else {
            return nil
        }

        var cursor = startIndex + 2
        while cursor < characters.count {
            if characters[cursor] == "]" {
                break
            }

            cursor += 1
        }

        guard cursor < characters.count,
              cursor + 1 < characters.count,
              characters[cursor] == "]",
              characters[cursor + 1] == "(" else {
            return nil
        }

        let altText = String(characters[(startIndex + 2)..<cursor])
        cursor += 2
        cursor = skipWhitespace(in: characters, from: cursor)

        let destination: String
        if cursor < characters.count, characters[cursor] == "<" {
            cursor += 1
            let destinationStart = cursor
            while cursor < characters.count, characters[cursor] != ">" {
                cursor += 1
            }

            guard cursor < characters.count else {
                return nil
            }

            destination = String(characters[destinationStart..<cursor])
            cursor += 1
        } else {
            let destinationStart = cursor
            while cursor < characters.count,
                  characters[cursor] != ")",
                  !characters[cursor].isWhitespace {
                cursor += 1
            }

            destination = String(characters[destinationStart..<cursor])
        }

        guard !destination.isEmpty else {
            return nil
        }

        cursor = skipWhitespace(in: characters, from: cursor)

        var title: String?
        if cursor < characters.count, characters[cursor] != ")" {
            let quote = characters[cursor]
            guard quote == "\"" || quote == "'" else {
                return nil
            }

            cursor += 1
            let titleStart = cursor
            while cursor < characters.count, characters[cursor] != quote {
                cursor += 1
            }

            guard cursor < characters.count else {
                return nil
            }

            title = String(characters[titleStart..<cursor])
            cursor += 1
            cursor = skipWhitespace(in: characters, from: cursor)
        }

        guard cursor < characters.count, characters[cursor] == ")" else {
            return nil
        }

        let nextIndex = cursor + 1
        return ParsedMarkdownImage(
            original: String(characters[startIndex..<nextIndex]),
            altText: altText,
            destination: destination,
            title: title,
            nextIndex: nextIndex
        )
    }

    static func imageMarkdown(altText: String, destination: URL, title: String? = nil) -> String {
        let escapedAlt = escapeMarkdownLabel(altText)
        let escapedDestination = "<\(destination.absoluteString)>"

        if let title, !title.isEmpty {
            return "![\(escapedAlt)](\(escapedDestination) \"\(escapeMarkdownTitle(title))\")"
        }

        return "![\(escapedAlt)](\(escapedDestination))"
    }

    static func linkMarkdown(label: String, destination: URL) -> String {
        "[\(escapeMarkdownLabel(label))](<\(destination.absoluteString)>)"
    }

    static func widthTitleMarker(for width: Int) -> String {
        "codex-obsidian-width-\(width)"
    }

    private static func skipWhitespace(in characters: [Character], from startIndex: Int) -> Int {
        var cursor = startIndex
        while cursor < characters.count, characters[cursor].isWhitespace {
            cursor += 1
        }

        return cursor
    }

    private static func escapeMarkdownLabel(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    private static func escapeMarkdownTitle(_ string: String) -> String {
        string.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
