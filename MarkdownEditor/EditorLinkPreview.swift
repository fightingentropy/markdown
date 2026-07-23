import AppKit
import SwiftUI
@preconcurrency import WebKit

private let xEmbedHeightMessageName = "xEmbedHeight"

private final class ScrollWheelMonitorToken: @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}

@MainActor
final class EditorEmbedCache {
    static let shared = EditorEmbedCache()

    private let userDefaults: UserDefaults
    private let heightStorageKey: String
    private let snapshotDirectoryURL: URL
    private let imageCache = NSCache<NSString, NSImage>()

    init(
        userDefaults: UserDefaults = .standard,
        heightStorageKey: String = "editorEmbedCache.xHeights",
        snapshotDirectoryURL: URL? = nil
    ) {
        self.userDefaults = userDefaults
        self.heightStorageKey = heightStorageKey
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.snapshotDirectoryURL = snapshotDirectoryURL
            ?? baseURL
                .appendingPathComponent("Markdown", isDirectory: true)
                .appendingPathComponent("EmbedSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.snapshotDirectoryURL,
            withIntermediateDirectories: true
        )
        imageCache.countLimit = 24
    }

    func xHeight(for statusID: String) -> CGFloat? {
        guard let value = storedXHeights()[statusID],
              value.isFinite,
              value > 0 else {
            return nil
        }
        return CGFloat(value)
    }

    func saveXHeight(_ height: CGFloat, for statusID: String) {
        guard height.isFinite, height > 0 else { return }
        var heights = storedXHeights()
        heights[statusID] = Double(height)
        userDefaults.set(heights, forKey: heightStorageKey)
    }

    func snapshot(for key: String) -> NSImage? {
        let cacheKey = key as NSString
        if let image = imageCache.object(forKey: cacheKey) {
            return image
        }
        guard let image = NSImage(contentsOf: snapshotURL(for: key)) else {
            return nil
        }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func saveSnapshot(_ image: NSImage, for key: String) {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: snapshotDirectoryURL,
            withIntermediateDirectories: true
        )
        try? pngData.write(to: snapshotURL(for: key), options: .atomic)
        imageCache.setObject(image, forKey: key as NSString)
    }

    private func storedXHeights() -> [String: Double] {
        userDefaults.dictionary(forKey: heightStorageKey)?.reduce(into: [:]) { result, item in
            if let value = item.value as? NSNumber {
                result[item.key] = value.doubleValue
            }
        } ?? [:]
    }

    private func snapshotURL(for key: String) -> URL {
        let allowedCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let safeKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? key
        return snapshotDirectoryURL.appendingPathComponent("\(safeKey).png")
    }
}

@MainActor
final class CachedEmbedWebView: NSView {
    let webView: WKWebView

    private let snapshotView = NSImageView()
    private var representedSnapshotKey: String?
    private var completedSnapshotKey: String?
    private var snapshotIsPending = false
    private var snapshotWaitingForLayoutKey: String?

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        addSubview(webView)
        snapshotView.imageScaling = .scaleAxesIndependently
        snapshotView.isHidden = true
        snapshotView.setAccessibilityElement(false)
        addSubview(snapshotView, positioned: .above, relativeTo: webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        snapshotView.frame = bounds
        if let snapshotWaitingForLayoutKey, bounds.width > 1, bounds.height > 1 {
            self.snapshotWaitingForLayoutKey = nil
            finishLoading(snapshotKey: snapshotWaitingForLayoutKey)
        }
    }

    func prepare(snapshotKey: String) {
        guard representedSnapshotKey != snapshotKey else { return }
        representedSnapshotKey = snapshotKey
        completedSnapshotKey = nil
        snapshotIsPending = false
        snapshotWaitingForLayoutKey = nil
        snapshotView.image = EditorEmbedCache.shared.snapshot(for: snapshotKey)
        snapshotView.isHidden = snapshotView.image == nil
    }

    func finishLoading(snapshotKey: String) {
        guard representedSnapshotKey == snapshotKey,
              completedSnapshotKey != snapshotKey,
              !snapshotIsPending else {
            return
        }
        guard bounds.width > 1, bounds.height > 1 else {
            snapshotWaitingForLayoutKey = snapshotKey
            return
        }

        snapshotWaitingForLayoutKey = nil
        snapshotIsPending = true
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let self, self.representedSnapshotKey == snapshotKey else { return }
            self.snapshotIsPending = false
            self.completedSnapshotKey = snapshotKey
            if let image {
                EditorEmbedCache.shared.saveSnapshot(image, for: snapshotKey)
            }
            self.snapshotView.isHidden = true
        }
    }
}

enum EditorLinkPreviewKind: Equatable {
    case xPost(username: String, statusID: String)
    case youtube(videoID: String)
}

struct EditorLinkPreview: Equatable, Identifiable {
    let url: URL
    let kind: EditorLinkPreviewKind
    let label: String?
    let sourceRange: NSRange
    let paragraphRange: NSRange
    var occurrence: Int = 0

    var id: String {
        "\(url.absoluteString)#\(occurrence)"
    }

    var title: String {
        switch kind {
        case .xPost(let username, _):
            return label?.nilIfEmpty ?? "@\(username) on X"
        case .youtube:
            return label?.nilIfEmpty ?? "YouTube video"
        }
    }

    var subtitle: String {
        switch kind {
        case .xPost(let username, let statusID):
            return "@\(username) · Post \(statusID)"
        case .youtube(let videoID):
            return "youtube.com · \(videoID)"
        }
    }

    var thumbnailURL: URL? {
        guard case .youtube(let videoID) = kind else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    var youtubeStartSeconds: Int? {
        guard case .youtube = kind,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?
                .first(where: { $0.name.lowercased() == "t" || $0.name.lowercased() == "start" })?
                .value else {
            return nil
        }
        return Self.parseYouTubeTime(rawValue)
    }

    private static func parseYouTubeTime(_ rawValue: String) -> Int? {
        if let seconds = Int(rawValue), seconds >= 0 {
            return seconds
        }

        let expression = try? NSRegularExpression(
            pattern: #"^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$"#,
            options: [.caseInsensitive]
        )
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        guard let match = expression?.firstMatch(in: rawValue, range: range),
              match.range == range else {
            return nil
        }

        func component(at index: Int) -> Int {
            guard match.range(at: index).location != NSNotFound,
                  let swiftRange = Range(match.range(at: index), in: rawValue) else {
                return 0
            }
            return Int(rawValue[swiftRange]) ?? 0
        }

        let seconds = component(at: 1) * 3_600 + component(at: 2) * 60 + component(at: 3)
        return seconds > 0 ? seconds : nil
    }
}

enum EditorLinkPreviewDetector {
    private static let markdownLinkRegex = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]*)\]\((https?://[^)\s]+)\)"#,
        options: [.caseInsensitive]
    )
    private static let bareLinkRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>\"]+"#,
        options: [.caseInsensitive]
    )

    static func previews(in markdown: String) -> [EditorLinkPreview] {
        let text = markdown as NSString
        guard text.length > 0 else { return [] }

        var results: [EditorLinkPreview] = []
        var occurrencesByURL: [String: Int] = [:]
        var location = 0
        var insideFence = false

        while location < text.length {
            let paragraphRange = text.paragraphRange(for: NSRange(location: location, length: 0))
            let contentRange = lineContentRange(paragraphRange, in: text)
            let line = text.substring(with: contentRange)
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                insideFence.toggle()
            } else if !insideFence,
                      var preview = firstPreview(
                        in: text,
                        contentRange: contentRange,
                        paragraphRange: paragraphRange
                      ) {
                let key = preview.url.absoluteString
                preview.occurrence = occurrencesByURL[key, default: 0]
                occurrencesByURL[key, default: 0] += 1
                results.append(preview)
            }

            let next = NSMaxRange(paragraphRange)
            guard next > location else { break }
            location = next
        }

        return results
    }

    private static func firstPreview(
        in text: NSString,
        contentRange: NSRange,
        paragraphRange: NSRange
    ) -> EditorLinkPreview? {
        let fullText = text as String
        let markdownMatches = markdownLinkRegex.matches(in: fullText, range: contentRange)

        for match in markdownMatches {
            guard match.numberOfRanges >= 4 else { continue }
            let label = text.substring(with: match.range(at: 2))
            let urlRange = match.range(at: 3)
            guard let url = normalizedURL(text.substring(with: urlRange)),
                  let kind = previewKind(for: url) else {
                continue
            }
            return EditorLinkPreview(
                url: url,
                kind: kind,
                label: label,
                sourceRange: match.range,
                paragraphRange: paragraphRange
            )
        }

        for match in bareLinkRegex.matches(in: fullText, range: contentRange) {
            if markdownMatches.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }) {
                continue
            }

            let rawURL = text.substring(with: match.range)
            let trimmedURL = rawURL.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            guard let url = normalizedURL(trimmedURL),
                  let kind = previewKind(for: url) else {
                continue
            }
            let trimmedLength = (trimmedURL as NSString).length
            return EditorLinkPreview(
                url: url,
                kind: kind,
                label: nil,
                sourceRange: NSRange(location: match.range.location, length: trimmedLength),
                paragraphRange: paragraphRange
            )
        }

        return nil
    }

    private static func normalizedURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else {
            return nil
        }
        return components.url
    }

    private static func previewKind(for url: URL) -> EditorLinkPreviewKind? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let pathComponents = url.pathComponents.filter { $0 != "/" }

        if normalizedHost == "x.com"
            || normalizedHost == "twitter.com"
            || normalizedHost == "mobile.twitter.com" {
            guard pathComponents.count >= 3,
                  pathComponents[1].lowercased() == "status",
                  !pathComponents[0].isEmpty,
                  !pathComponents[2].isEmpty,
                  pathComponents[2].allSatisfy(\.isNumber) else {
                return nil
            }
            return .xPost(username: pathComponents[0], statusID: pathComponents[2])
        }

        if normalizedHost == "youtu.be" {
            guard let videoID = pathComponents.first, isValidYouTubeID(videoID) else { return nil }
            return .youtube(videoID: videoID)
        }

        if normalizedHost == "youtube.com"
            || normalizedHost == "m.youtube.com"
            || normalizedHost == "youtube-nocookie.com" {
            if pathComponents.first?.lowercased() == "watch",
               let videoID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "v" })?.value,
               isValidYouTubeID(videoID) {
                return .youtube(videoID: videoID)
            }

            if pathComponents.count >= 2,
               ["shorts", "embed", "live"].contains(pathComponents[0].lowercased()),
               isValidYouTubeID(pathComponents[1]) {
                return .youtube(videoID: pathComponents[1])
            }
        }

        return nil
    }

    private static func isValidYouTubeID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func lineContentRange(_ paragraphRange: NSRange, in text: NSString) -> NSRange {
        var end = NSMaxRange(paragraphRange)
        while end > paragraphRange.location {
            let character = text.character(at: end - 1)
            if character == 10 || character == 13 {
                end -= 1
            } else {
                break
            }
        }
        return NSRange(location: paragraphRange.location, length: end - paragraphRange.location)
    }
}

/// Keeps the visible text line fixed while attributes above it change the
/// document's layout. Preserving the raw scroll offset is not enough here: an
/// embed growing above the viewport moves the caret even when that offset is
/// restored exactly.
@MainActor
struct EditorViewportAnchor {
    private enum VerticalPosition {
        case line(characterLocation: Int, offset: CGFloat)
        case documentBottom
    }

    private let verticalPosition: VerticalPosition
    private let horizontalOrigin: CGFloat

    static func capture(in textView: NSTextView) -> EditorViewportAnchor? {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return nil
        }

        let visibleRect = scrollView.contentView.bounds
        let textLength = textView.textStorage?.length ?? 0
        let selection = textView.selectedRange()
        let selectionLocation = min(NSMaxRange(selection), textLength)
        ensureLayout(
            at: selectionLocation,
            in: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        let anchorLocation: Int
        let anchorFrame: NSRect
        if let selectionFrame = lineFrame(
            at: selectionLocation,
            in: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        ), selectionFrame.intersects(visibleRect) {
            anchorLocation = selectionLocation
            anchorFrame = selectionFrame
        } else {
            let containerOrigin = textView.textContainerOrigin
            let pointNearVisibleTop = CGPoint(
                x: 0,
                y: max(0, visibleRect.minY - containerOrigin.y + 1)
            )
            let location = min(
                layoutManager.characterIndex(
                    for: pointNearVisibleTop,
                    in: textContainer,
                    fractionOfDistanceBetweenInsertionPoints: nil
                ),
                textLength
            )
            guard let visibleLineFrame = lineFrame(
                at: location,
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                return nil
            }
            anchorLocation = location
            anchorFrame = visibleLineFrame
        }

        let isVisibleCaretAtDocumentEnd =
            selection.length == 0
            && selection.location == textLength
            && anchorLocation == selectionLocation
            && anchorFrame.intersects(visibleRect)

        return EditorViewportAnchor(
            verticalPosition: isVisibleCaretAtDocumentEnd
                ? .documentBottom
                : .line(
                    characterLocation: anchorLocation,
                    offset: anchorFrame.minY - visibleRect.minY
                ),
            horizontalOrigin: visibleRect.minX
        )
    }

    func restore(in textView: NSTextView) {
        guard let scrollView = textView.enclosingScrollView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let textLength = textView.textStorage?.length ?? 0
        let contentView = scrollView.contentView
        let desiredY: CGFloat

        switch verticalPosition {
        case .documentBottom:
            Self.ensureLayout(
                at: textLength,
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            desiredY = Self.documentHeight(
                for: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) - contentView.bounds.height

        case .line(let characterLocation, let verticalOffset):
            Self.ensureLayout(
                at: min(characterLocation, textLength),
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
            guard let anchorFrame = Self.lineFrame(
                at: min(characterLocation, textLength),
                in: textView,
                layoutManager: layoutManager,
                textContainer: textContainer
            ) else {
                return
            }
            desiredY = anchorFrame.minY - verticalOffset
        }

        let documentHeight = Self.documentHeight(
            for: textView,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let maxX = max(0, textView.frame.width - contentView.bounds.width)
        let maxY = max(0, documentHeight - contentView.bounds.height)
        let origin = CGPoint(
            x: min(max(horizontalOrigin, 0), maxX),
            y: min(max(desiredY, 0), maxY)
        )

        contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(contentView)
    }

    /// `NSTextView` updates its document-view height one run-loop after some
    /// paragraph-spacing changes. An end caret needs one final bottom restore
    /// after that resize; otherwise the newly measured tail embed can leave the
    /// caret just below the viewport.
    func restoreAfterPendingLayout(in textView: NSTextView) {
        restore(in: textView)
        guard case .documentBottom = verticalPosition else { return }

        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            restore(in: textView)
        }
    }

    private static func ensureLayout(
        at characterLocation: Int,
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        let textLength = textView.textStorage?.length ?? 0
        guard textLength > 0 else {
            layoutManager.ensureLayout(forBoundingRect: .zero, in: textContainer)
            return
        }

        layoutManager.ensureLayout(
            forCharacterRange: NSRange(
                location: min(characterLocation, textLength - 1),
                length: 1
            )
        )
    }

    private static func documentHeight(
        for textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> CGFloat {
        max(
            textView.frame.height,
            layoutManager.usedRect(for: textContainer).maxY + textView.textContainerInset.height
        )
    }

    private static func lineFrame(
        at characterLocation: Int,
        in textView: NSTextView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> NSRect? {
        let textLength = textView.textStorage?.length ?? 0
        let containerOrigin = textView.textContainerOrigin

        if characterLocation >= textLength,
           layoutManager.extraLineFragmentTextContainer === textContainer {
            return layoutManager.extraLineFragmentRect.offsetBy(
                dx: containerOrigin.x,
                dy: containerOrigin.y
            )
        }

        guard textLength > 0 else {
            let font = textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            return NSRect(
                x: containerOrigin.x,
                y: containerOrigin.y,
                width: 0,
                height: layoutManager.defaultLineHeight(for: font)
            )
        }

        let characterIndex = min(characterLocation, textLength - 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        return layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        ).offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
    }
}

@MainActor
final class EditorLinkPreviewController {
    private static let initialXCardHeight: CGFloat = 220
    private static let maximumXCardHeight: CGFloat = 720
    private static let cardTopSpacing: CGFloat = 2
    private static let youtubeCardWidth: CGFloat = 640
    private static let xCardWidth: CGFloat = 550

    private let embedCache: EditorEmbedCache
    private let retainedOffscreenCardLimit: Int
    private var previews: [EditorLinkPreview] = []
    private var cardViews: [String: NSHostingView<EditorLinkPreviewCard>] = [:]
    private var attachedCardIDs: Set<String> = []
    private var cardAccessOrder: [String] = []
    private var measuredXCardHeights: [String: CGFloat] = [:]
    private var hoveredPreviewIDs: Set<String> = []
    private var scrollWheelMonitor: ScrollWheelMonitorToken?
    private var openURLHandler: ((URL) -> Void)?

    var visibleCardCount: Int {
        attachedCardIDs.count
    }

    var retainedCardCount: Int {
        cardViews.count
    }

    init(
        embedCache: EditorEmbedCache = .shared,
        retainedOffscreenCardLimit: Int = 6
    ) {
        self.embedCache = embedCache
        self.retainedOffscreenCardLimit = max(0, retainedOffscreenCardLimit)
    }

    deinit {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor.value)
        }
    }

    @discardableResult
    func refresh(
        in textView: NSTextView,
        openURL: @escaping (URL) -> Void
    ) -> Int {
        let viewportAnchor = EditorViewportAnchor.capture(in: textView)
        installScrollWheelForwarding(in: textView)
        clearSourcePresentation(in: textView)
        previews = EditorLinkPreviewDetector.previews(in: textView.string)
        openURLHandler = openURL
        let activeIDs = Set(previews.map(\.id))
        pruneInactiveCards(activeIDs: activeIDs)
        measuredXCardHeights = measuredXCardHeights.filter { activeIDs.contains($0.key) }
        restoreCachedXHeights()
        hoveredPreviewIDs.formIntersection(activeIDs)
        let spacingUpdateCount = applyReservedSpacing(in: textView)
        updateSourcePresentation(in: textView)
        viewportAnchor?.restoreAfterPendingLayout(in: textView)
        layoutCards(in: textView)
        return spacingUpdateCount
    }

    func selectionDidChange(in textView: NSTextView) {
        updateSourcePresentation(in: textView)
    }

    func layoutCards(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let containerOrigin = textView.textContainerOrigin
        let availableWidth = max(0, textContainer.containerSize.width)
        let visibleRect = textView.visibleRect
        let maximumCardFootprint =
            Self.maximumXCardHeight + Self.cardTopSpacing + 8
        let candidateRect = NSRect(
            x: 0,
            y: max(0, visibleRect.minY - containerOrigin.y - maximumCardFootprint),
            width: availableWidth,
            height: visibleRect.height + maximumCardFootprint
        )
        layoutManager.ensureLayout(forBoundingRect: candidateRect, in: textContainer)
        let candidateGlyphRange = layoutManager.glyphRange(
            forBoundingRect: candidateRect,
            in: textContainer
        )
        let candidateCharacterRange = layoutManager.characterRange(
            forGlyphRange: candidateGlyphRange,
            actualGlyphRange: nil
        )
        let visiblePreviews = Array(previews.lazy.filter { preview in
            NSIntersectionRange(preview.paragraphRange, candidateCharacterRange).length > 0
        }.filter { preview in
            self.frame(
                for: preview,
                layoutManager: layoutManager,
                containerOrigin: containerOrigin,
                availableWidth: availableWidth
            )?.intersects(visibleRect) == true
        })

        synchronizeCards(for: visiblePreviews, in: textView)

        for preview in visiblePreviews {
            guard let card = cardViews[preview.id],
                  let cardFrame = frame(
                    for: preview,
                    layoutManager: layoutManager,
                    containerOrigin: containerOrigin,
                    availableWidth: availableWidth
                  ) else {
                continue
            }
            card.frame = cardFrame
        }
    }

    func removeAll() {
        if let scrollWheelMonitor {
            NSEvent.removeMonitor(scrollWheelMonitor.value)
            self.scrollWheelMonitor = nil
        }
        cardViews.values.forEach { $0.removeFromSuperview() }
        cardViews.removeAll()
        attachedCardIDs.removeAll()
        cardAccessOrder.removeAll()
        measuredXCardHeights.removeAll()
        hoveredPreviewIDs.removeAll()
        openURLHandler = nil
        previews.removeAll()
    }

    private func installScrollWheelForwarding(in textView: NSTextView) {
        guard scrollWheelMonitor == nil else { return }

        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: {
            [weak self, weak textView] event in
            guard let self,
                  let textView,
                  event.window === textView.window,
                  let scrollView = textView.enclosingScrollView else {
                return event
            }

            let point = textView.convert(event.locationInWindow, from: nil)
            let isOverEmbed = self.attachedCardIDs.contains { id in
                guard let card = self.cardViews[id] else { return false }
                return !card.isHiddenOrHasHiddenAncestor && card.frame.contains(point)
            }
            guard isOverEmbed else { return event }

            scrollView.scrollWheel(with: event)
            return nil
        }) else { return }
        scrollWheelMonitor = ScrollWheelMonitorToken(monitor)
    }

    @discardableResult
    private func applyReservedSpacing(in textView: NSTextView) -> Int {
        guard let storage = textView.textStorage, storage.length > 0 else { return 0 }
        let availableWidth = max(
            0,
            textView.textContainer?.containerSize.width ?? Self.youtubeCardWidth
        )

        var updates: [(range: NSRange, style: NSMutableParagraphStyle)] = []
        for preview in previews {
            guard preview.paragraphRange.length > 0,
                  NSMaxRange(preview.paragraphRange) <= storage.length else {
                continue
            }
            let current = storage.attribute(
                .paragraphStyle,
                at: preview.paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle
            let desiredSpacing =
                height(for: preview, availableWidth: availableWidth) + Self.cardTopSpacing + 8
            guard abs((current?.paragraphSpacing ?? 0) - desiredSpacing) > 0.5 else {
                continue
            }

            let style = (current?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacing = desiredSpacing
            updates.append((preview.paragraphRange, style))
        }

        guard !updates.isEmpty else { return 0 }

        storage.beginEditing()
        for update in updates {
            storage.addAttribute(.paragraphStyle, value: update.style, range: update.range)
        }
        storage.endEditing()
        return updates.count
    }

    private func synchronizeCards(
        for visiblePreviews: [EditorLinkPreview],
        in textView: NSTextView
    ) {
        guard let openURL = openURLHandler else { return }
        let visibleIDs = Set(visiblePreviews.map(\.id))
        let offscreenIDs = attachedCardIDs.filter { !visibleIDs.contains($0) }
        for id in offscreenIDs {
            cardViews[id]?.removeFromSuperview()
            attachedCardIDs.remove(id)
        }

        for preview in visiblePreviews {
            let card = EditorLinkPreviewCard(
                preview: preview,
                openURL: openURL,
                xEmbedHeightChanged: { [weak self, weak textView] height in
                    guard let self, let textView else { return }
                    self.updateXEmbedHeight(height, for: preview, in: textView)
                },
                xHoverChanged: { [weak self, weak textView] isHovering in
                    guard let self, let textView else { return }
                    self.setHover(isHovering, for: preview, in: textView)
                },
                youtubeHoverChanged: { [weak self, weak textView] isHovering in
                    guard let self, let textView else { return }
                    self.setHover(isHovering, for: preview, in: textView)
                }
            )
            if let existing = cardViews[preview.id] {
                existing.rootView = card
                if existing.superview !== textView {
                    textView.addSubview(existing)
                }
            } else {
                let hostingView = NSHostingView(rootView: card)
                hostingView.wantsLayer = true
                textView.addSubview(hostingView)
                cardViews[preview.id] = hostingView
            }
            attachedCardIDs.insert(preview.id)
            markCardRecentlyUsed(preview.id)
        }
        trimRetainedOffscreenCards()
    }

    private func pruneInactiveCards(activeIDs: Set<String>) {
        let inactiveIDs = cardViews.keys.filter { !activeIDs.contains($0) }
        for id in inactiveIDs {
            cardViews.removeValue(forKey: id)?.removeFromSuperview()
            attachedCardIDs.remove(id)
        }
        cardAccessOrder.removeAll { !activeIDs.contains($0) }
    }

    private func markCardRecentlyUsed(_ id: String) {
        cardAccessOrder.removeAll { $0 == id }
        cardAccessOrder.append(id)
    }

    private func trimRetainedOffscreenCards() {
        let detachedIDs = cardAccessOrder.filter { !attachedCardIDs.contains($0) }
        let removalCount = max(0, detachedIDs.count - retainedOffscreenCardLimit)
        for id in detachedIDs.prefix(removalCount) {
            cardViews.removeValue(forKey: id)?.removeFromSuperview()
            cardAccessOrder.removeAll { $0 == id }
        }
    }

    private func restoreCachedXHeights() {
        for preview in previews {
            guard measuredXCardHeights[preview.id] == nil,
                  case .xPost(_, let statusID) = preview.kind,
                  let cachedHeight = embedCache.xHeight(for: statusID) else {
                continue
            }
            measuredXCardHeights[preview.id] = min(
                Self.maximumXCardHeight,
                max(Self.initialXCardHeight, cachedHeight)
            )
        }
    }

    private func frame(
        for preview: EditorLinkPreview,
        layoutManager: NSLayoutManager,
        containerOrigin: CGPoint,
        availableWidth: CGFloat
    ) -> NSRect? {
        guard preview.sourceRange.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: preview.sourceRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        let lastGlyph = max(glyphRange.location, NSMaxRange(glyphRange) - 1)
        let lineRect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: lastGlyph,
            effectiveRange: nil
        )
        return NSRect(
            x: containerOrigin.x,
            y: containerOrigin.y + lineRect.maxY + Self.cardTopSpacing,
            width: min(width(for: preview), availableWidth),
            height: height(for: preview, availableWidth: availableWidth)
        )
    }

    private func width(for preview: EditorLinkPreview) -> CGFloat {
        switch preview.kind {
        case .xPost:
            return Self.xCardWidth
        case .youtube:
            return Self.youtubeCardWidth
        }
    }

    private func height(for preview: EditorLinkPreview, availableWidth: CGFloat) -> CGFloat {
        switch preview.kind {
        case .xPost:
            return measuredXCardHeights[preview.id] ?? Self.initialXCardHeight
        case .youtube:
            let playerWidth = min(Self.youtubeCardWidth, availableWidth)
            return playerWidth * 9 / 16
        }
    }

    private func setHover(
        _ isHovering: Bool,
        for preview: EditorLinkPreview,
        in textView: NSTextView
    ) {
        if isHovering {
            hoveredPreviewIDs.insert(preview.id)
        } else {
            hoveredPreviewIDs.remove(preview.id)
        }
        updateSourcePresentation(in: textView)
    }

    private func updateSourcePresentation(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let selection = textView.selectedRange()

        for preview in previews {
            clearTemporarySourceAttributes(for: preview, in: layoutManager)
            guard !hoveredPreviewIDs.contains(preview.id),
                  !selectionTouches(preview.paragraphRange, selection: selection) else {
                continue
            }

            layoutManager.addTemporaryAttributes(
                [
                    .foregroundColor: NSColor.clear,
                    .underlineColor: NSColor.clear,
                    .underlineStyle: 0
                ],
                forCharacterRange: preview.sourceRange
            )
        }
    }

    private func clearSourcePresentation(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        for preview in previews {
            clearTemporarySourceAttributes(for: preview, in: layoutManager)
        }
    }

    private func clearTemporarySourceAttributes(
        for preview: EditorLinkPreview,
        in layoutManager: NSLayoutManager
    ) {
        for key in [
            NSAttributedString.Key.foregroundColor,
            .underlineColor,
            .underlineStyle
        ] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: preview.sourceRange)
        }
    }

    private func selectionTouches(_ paragraphRange: NSRange, selection: NSRange) -> Bool {
        if selection.length > 0 {
            return NSIntersectionRange(paragraphRange, selection).length > 0
        }
        return selection.location >= paragraphRange.location
            && selection.location < NSMaxRange(paragraphRange)
    }

    private func updateXEmbedHeight(
        _ reportedHeight: CGFloat,
        for preview: EditorLinkPreview,
        in textView: NSTextView
    ) {
        guard case .xPost = preview.kind, reportedHeight.isFinite, reportedHeight > 0 else { return }
        let height = min(
            Self.maximumXCardHeight,
            max(Self.initialXCardHeight, ceil(reportedHeight) + 4)
        )
        guard abs((measuredXCardHeights[preview.id] ?? 0) - height) > 2 else { return }

        let viewportAnchor = EditorViewportAnchor.capture(in: textView)
        measuredXCardHeights[preview.id] = height
        if case .xPost(_, let statusID) = preview.kind {
            embedCache.saveXHeight(height, for: statusID)
        }
        applyReservedSpacing(in: textView)
        viewportAnchor?.restoreAfterPendingLayout(in: textView)
        layoutCards(in: textView)
    }
}

struct EditorLinkPreviewCard: View {
    let preview: EditorLinkPreview
    let openURL: (URL) -> Void
    let xEmbedHeightChanged: (CGFloat) -> Void
    let xHoverChanged: (Bool) -> Void
    let youtubeHoverChanged: (Bool) -> Void

    @ViewBuilder
    var body: some View {
        switch preview.kind {
        case .xPost(let username, let statusID):
            XPostEmbedView(
                postURL: preview.url,
                username: username,
                statusID: statusID,
                openURL: openURL,
                heightChanged: xEmbedHeightChanged
            )
            .onHover(perform: xHoverChanged)
            .help(preview.url.absoluteString)
            .accessibilityLabel("Post by @\(username) on X")

        case .youtube(let videoID):
            YouTubeEmbedView(
                videoID: videoID,
                startSeconds: preview.youtubeStartSeconds,
                openURL: openURL
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(0.10))
            }
            .onHover(perform: youtubeHoverChanged)
            .help("Hover to reveal the Markdown link")
            .accessibilityLabel("YouTube video player")
        }
    }
}

struct YouTubeEmbedView: NSViewRepresentable {
    let videoID: String
    let startSeconds: Int?
    let openURL: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL)
    }

    func makeNSView(context: Context) -> CachedEmbedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel("YouTube video player")
        let container = CachedEmbedWebView(webView: webView)
        context.coordinator.container = container
        loadVideo(in: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CachedEmbedWebView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.container = container
        loadVideo(in: container, coordinator: context.coordinator)
    }

    private func loadVideo(in container: CachedEmbedWebView, coordinator: Coordinator) {
        guard let embedURL = YouTubeEmbedURL.url(
            videoID: videoID,
            startSeconds: startSeconds
        ) else {
            return
        }
        let signature = embedURL.absoluteString
        let snapshotKey = "youtube-\(videoID)-\(startSeconds ?? 0)"
        container.prepare(snapshotKey: snapshotKey)
        coordinator.snapshotKey = snapshotKey
        guard coordinator.loadedSignature != signature else { return }

        coordinator.loadedSignature = signature
        var request = URLRequest(url: embedURL)
        request.setValue("https://markdown.local/", forHTTPHeaderField: "Referer")
        container.webView.load(request)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var openURL: (URL) -> Void
        var loadedSignature: String?
        var snapshotKey: String?
        weak var container: CachedEmbedWebView?

        init(openURL: @escaping (URL) -> Void) {
            self.openURL = openURL
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            guard let snapshotKey else { return }
            container?.finishLoading(snapshotKey: snapshotKey)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "https" || url.scheme == "http" {
                openURL(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum YouTubeEmbedURL {
    static func url(videoID: String, startSeconds: Int?) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !videoID.isEmpty, videoID.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube-nocookie.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "autoplay", value: "0"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "rel", value: "0")
        ]
        if let startSeconds, startSeconds > 0 {
            components.queryItems?.append(
                URLQueryItem(name: "start", value: String(startSeconds))
            )
        }
        return components.url
    }
}

struct XPostEmbedView: NSViewRepresentable {
    let postURL: URL
    let username: String
    let statusID: String
    let openURL: (URL) -> Void
    let heightChanged: (CGFloat) -> Void

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: openURL, heightChanged: heightChanged)
    }

    func makeNSView(context: Context) -> CachedEmbedWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: xEmbedHeightMessageName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel("Embedded X post by @\(username)")
        let container = CachedEmbedWebView(webView: webView)
        context.coordinator.container = container
        loadPost(in: container, coordinator: context.coordinator)
        return container
    }

    func updateNSView(_ container: CachedEmbedWebView, context: Context) {
        context.coordinator.openURL = openURL
        context.coordinator.heightChanged = heightChanged
        context.coordinator.container = container
        loadPost(in: container, coordinator: context.coordinator)
    }

    private func loadPost(in container: CachedEmbedWebView, coordinator: Coordinator) {
        let theme = colorScheme == .dark ? "dark" : "light"
        let signature = "\(statusID):\(theme)"
        let snapshotKey = "x-\(statusID)-\(theme)"
        container.prepare(snapshotKey: snapshotKey)
        coordinator.snapshotKey = snapshotKey
        guard coordinator.loadedSignature != signature else { return }

        coordinator.loadedSignature = signature
        let html = XPostEmbedHTML.document(
            postURL: postURL,
            username: username,
            statusID: statusID,
            theme: theme
        )
        container.webView.loadHTMLString(html, baseURL: URL(string: "https://platform.x.com"))
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var openURL: (URL) -> Void
        var heightChanged: (CGFloat) -> Void
        var loadedSignature: String?
        var snapshotKey: String?
        weak var container: CachedEmbedWebView?

        init(openURL: @escaping (URL) -> Void, heightChanged: @escaping (CGFloat) -> Void) {
            self.openURL = openURL
            self.heightChanged = heightChanged
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == xEmbedHeightMessageName else {
                return
            }
            if let payload = message.body as? [String: Any],
               let height = payload["height"] as? NSNumber {
                if payload["ready"] as? Bool == true {
                    heightChanged(CGFloat(truncating: height))
                }
                if payload["ready"] as? Bool == true, let snapshotKey {
                    container?.finishLoading(snapshotKey: snapshotKey)
                }
            } else if let height = message.body as? NSNumber {
                heightChanged(CGFloat(truncating: height))
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "https" || url.scheme == "http" {
                openURL(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum XPostEmbedHTML {
    static func document(
        postURL: URL,
        username: String,
        statusID: String,
        theme: String
    ) -> String {
        let safeTheme = theme == "light" ? "light" : "dark"
        let safeStatusID = statusID.filter(\.isNumber)
        let fallbackURL = escapeHTML(postURL.absoluteString)
        let fallbackUsername = escapeHTML(username)

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { color-scheme: \(safeTheme); }
            html, body { margin: 0; padding: 0; width: 100%; background: transparent; overflow: hidden; }
            #tweet { width: 100%; min-height: 220px; }
            #tweet iframe { margin: 0 !important; }
            #fallback {
              box-sizing: border-box; min-height: 220px; padding: 18px; border-radius: 14px;
              border: 1px solid \(safeTheme == "dark" ? "#333639" : "#cfd9de");
              color: \(safeTheme == "dark" ? "#e7e9ea" : "#0f1419");
              background: \(safeTheme == "dark" ? "#000" : "#fff");
              font: 15px -apple-system, BlinkMacSystemFont, sans-serif;
            }
            #fallback a { color: #1d9bf0; text-decoration: none; }
          </style>
        </head>
        <body>
          <div id="tweet"></div>
          <div id="fallback">Loading the post by <a href="\(fallbackURL)">@\(fallbackUsername)</a>…</div>
          <script>
            function reportHeight() {
              const frame = document.querySelector('#tweet iframe');
              const height = frame ? frame.getBoundingClientRect().height : document.documentElement.scrollHeight;
              if (height > 0) {
                window.webkit.messageHandlers.\(xEmbedHeightMessageName).postMessage({
                  height: Math.ceil(height),
                  ready: Boolean(frame)
                });
              }
            }
            new ResizeObserver(reportHeight).observe(document.body);
            setTimeout(reportHeight, 250);
            setTimeout(reportHeight, 1000);
            setTimeout(reportHeight, 2500);
          </script>
          <script src="https://platform.x.com/widgets.js" charset="utf-8"></script>
          <script>
            twttr.ready(function(api) {
              api.widgets.createTweet('\(safeStatusID)', document.getElementById('tweet'), {
                theme: '\(safeTheme)',
                dnt: true,
                conversation: 'none',
                align: 'left'
              }).then(function(element) {
                const fallback = document.getElementById('fallback');
                if (element) fallback.remove();
                else fallback.firstChild.textContent = 'Post unavailable from X: ';
                reportHeight();
                setTimeout(reportHeight, 500);
              });
            });
          </script>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
