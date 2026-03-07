import AppKit
import SwiftUI

// MARK: - FocusedValue

struct FocusedEditorControllerKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[FocusedEditorControllerKey.self] }
        set { self[FocusedEditorControllerKey.self] = newValue }
    }
}

// MARK: - Editor Controller

@Observable
@MainActor
final class EditorController {
    weak var textView: NSTextView?

    func applyBold() { wrapSelection(prefix: "**", suffix: "**") }
    func applyItalic() { wrapSelection(prefix: "*", suffix: "*") }
    func applyCode() { wrapSelection(prefix: "`", suffix: "`") }
    func applyCodeBlock() { wrapSelection(prefix: "```\n", suffix: "\n```") }
    func applyBlockquote() { prependToCurrentLine("> ") }
    func applyUnorderedList() { prependToCurrentLine("- ") }
    func applyOrderedList() { prependToCurrentLine("1. ") }

    func applyHeading(_ level: Int) {
        let prefix = String(repeating: "#", count: level) + " "
        prependToCurrentLine(prefix)
    }

    func applyLink() {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length > 0 {
            let selected = (textView.string as NSString).substring(with: range)
            textView.insertText("[\(selected)](url)", replacementRange: range)
        } else {
            textView.insertText("[link](url)", replacementRange: range)
        }
    }

    private func wrapSelection(prefix: String, suffix: String) {
        guard let textView else { return }
        let range = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: range)
        textView.insertText(prefix + selected + suffix, replacementRange: range)
    }

    private func prependToCurrentLine(_ prefix: String) {
        guard let textView else { return }
        let nsString = textView.string as NSString
        let cursorPos = textView.selectedRange().location
        let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
        textView.insertText(prefix, replacementRange: NSRange(location: lineRange.location, length: 0))
    }
}

// MARK: - NSViewRepresentable

struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    let documentURL: URL?
    let vaultURL: URL?
    let showsInlineImagePreviewsWhileEditing: Bool
    private let minimumHorizontalInset: CGFloat = 72
    private let maximumReadableWidth: CGFloat = 920
    fileprivate let inlineImageSpacing: CGFloat = 16
    fileprivate let maximumInlineImageHeight: CGFloat = 420
    fileprivate let inlineImageSourceHeaderHeight: CGFloat = 30

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let baseTextView = scrollView.documentView as? NSTextView else { return scrollView }

        let textView: InlinePreviewTextView
        if let existing = baseTextView as? InlinePreviewTextView {
            textView = existing
        } else {
            textView = InlinePreviewTextView(frame: baseTextView.frame, textContainer: baseTextView.textContainer)
            scrollView.documentView = textView
        }

        textView.isRichText = false
        textView.font = Theme.editorFont
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = NSSize(width: minimumHorizontalInset, height: 28)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: maximumReadableWidth, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.layoutManager?.delegate = context.coordinator
        textView.inlinePreviewDelegate = context.coordinator

        textView.delegate = context.coordinator
        textView.string = text

        context.coordinator.parent = self
        updateTextLayout(for: scrollView, textView: textView)
        context.coordinator.highlight(textView, preservingViewport: false)

        controller.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? InlinePreviewTextView else { return }
        context.coordinator.parent = self
        textView.layoutManager?.delegate = context.coordinator
        textView.inlinePreviewDelegate = context.coordinator
        updateTextLayout(for: nsView, textView: textView)
        context.coordinator.applyExternalTextIfNeeded(text, to: textView)
        context.coordinator.refreshInlineImagePreviews(in: textView)

        controller.textView = textView
    }

    private func updateTextLayout(for scrollView: NSScrollView, textView: NSTextView) {
        let availableWidth = max(scrollView.contentSize.width, maximumReadableWidth)
        let columnWidth = min(maximumReadableWidth, max(0, availableWidth - (minimumHorizontalInset * 2)))
        let horizontalInset = max(minimumHorizontalInset, (availableWidth - columnWidth) / 2)

        textView.textContainerInset = NSSize(width: horizontalInset, height: 28)
        textView.textContainer?.containerSize = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate, InlinePreviewTextViewDelegate {
        private struct TextSelectionAppearance {
            let insertionPointColor: NSColor
            let selectedTextAttributes: [NSAttributedString.Key: Any]
        }

        private struct InlineImagePreview {
            let lineRange: NSRange
            let sourceText: String
            let showsSource: Bool
            let image: NSImage
            let displaySize: NSSize
            let reservedHeight: CGFloat
            let sourceHeaderHeight: CGFloat
        }

        var parent: SourceEditorView
        let highlighter = SyntaxHighlighter()
        private var isApplyingExternalText = false
        private var isRefreshingInlineImagePreviews = false
        private var inlineImageViews: [NSView] = []
        private var expandedInlineSourceLines: Set<Int> = []
        private var hiddenInlinePreviewRanges: [NSRange] = []
        private var selectedInlineImageLine: Int?
        private weak var selectedInlineImageView: InlineImageBlockView?
        private weak var inlineImageSelectionTextView: NSTextView?
        private var storedTextSelectionAppearance: TextSelectionAppearance?
        private var isSelectingInlineImage = false
        nonisolated(unsafe) private var inlineImagePreviewByGlyphLocation: [Int: InlineImagePreview] = [:]
        private let imageCache = NSCache<NSURL, NSImage>()

        init(_ parent: SourceEditorView) {
            self.parent = parent
        }

        func applyExternalTextIfNeeded(_ text: String, to textView: NSTextView) {
            guard textView.string != text else { return }

            withPreservedViewport(for: textView) {
                isApplyingExternalText = true
                defer { isApplyingExternalText = false }
                textView.string = text
                highlight(textView, preservingViewport: false)
            }
        }

        func highlight(_ textView: NSTextView, preservingViewport: Bool = true) {
            if preservingViewport {
                withPreservedViewport(for: textView) {
                    guard let storage = textView.textStorage else { return }
                    self.highlighter.highlight(storage)
                    self.refreshInlineImagePreviews(in: textView, resettingTextAttributes: false)
                }
            } else {
                guard let storage = textView.textStorage else { return }
                self.highlighter.highlight(storage)
                self.refreshInlineImagePreviews(in: textView, resettingTextAttributes: false)
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else { return }
            expandedInlineSourceLines.removeAll()
            clearInlineImageSelection()
            parent.text = textView.string
            highlight(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if isSelectingInlineImage || textView.window?.firstResponder === selectedInlineImageView {
                return
            }
            clearInlineImageSelection()
            refreshInlineImagePreviews(in: textView)
        }

        func inlinePreviewTextView(_ textView: NSTextView, handleInlinePreviewClickAt point: CGPoint) -> Bool {
            guard let view = inlineImageViews
                .compactMap({ $0 as? InlineImageBlockView })
                .reversed()
                .first(where: { $0.frame.contains(point) }) else {
                return false
            }

            let localPoint = view.convert(point, from: textView)
            if view.isToggleHit(at: localPoint) {
                view.performToggleAction()
                return true
            }

            guard let lineLocation = view.lineLocation else {
                return false
            }

            selectInlineImage(atLine: lineLocation, view: view, in: textView)
            return true
        }

        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
            toCharacterRange newSelectedCharRange: NSRange
        ) -> NSRange {
            adjustedSelectionAwayFromHiddenInlinePreviews(
                newSelectedCharRange,
                previousSelection: oldSelectedCharRange,
                hiddenRanges: hiddenInlinePreviewRanges,
                textLength: (textView.string as NSString).length
            )
        }

        func refreshInlineImagePreviews(in textView: NSTextView, resettingTextAttributes: Bool = true) {
            if resettingTextAttributes, let storage = textView.textStorage {
                highlighter.highlight(storage)
            }

            let shouldRestoreSelectedInlineImageResponder = textView.window?.firstResponder === selectedInlineImageView
            isRefreshingInlineImagePreviews = true
            clearInlineImagePreviews(in: textView)
            defer { isRefreshingInlineImagePreviews = false }

            guard parent.showsInlineImagePreviewsWhileEditing,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                clearInlineImageSelection()
                return
            }

            let previews = collectInlineImagePreviews(in: textView)
            guard !previews.isEmpty else {
                clearInlineImageSelection()
                return
            }

            if let selectedInlineImageLine,
               !previews.contains(where: { $0.lineRange.location == selectedInlineImageLine }) {
                clearInlineImageSelection()
            }

            hiddenInlinePreviewRanges = previews.map(\.lineRange)
            moveSelectionOutOfHiddenInlinePreviewIfNeeded(in: textView)

            for preview in previews {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: preview.lineRange)
                layoutManager.addTemporaryAttribute(.underlineStyle, value: 0, forCharacterRange: preview.lineRange)
                layoutManager.addTemporaryAttribute(.underlineColor, value: NSColor.clear, forCharacterRange: preview.lineRange)

                let glyphRange = layoutManager.glyphRange(forCharacterRange: preview.lineRange, actualCharacterRange: nil)
                guard glyphRange.length > 0 else { continue }
                inlineImagePreviewByGlyphLocation[glyphRange.location] = preview
            }

            let invalidationRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.invalidateLayout(forCharacterRange: invalidationRange, actualCharacterRange: nil)
            layoutManager.ensureLayout(for: textContainer)

            let containerOrigin = textView.textContainerOrigin
            var restoredSelectedInlineImageResponder = false
            for preview in previews {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: preview.lineRange, actualCharacterRange: nil)
                guard glyphRange.length > 0 else { continue }

                let lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil,
                    withoutAdditionalLayout: true
                )
                let blockY = containerOrigin.y + lineRect.minY + (parent.inlineImageSpacing / 2)
                let blockHeight = preview.displaySize.height + preview.sourceHeaderHeight

                let imageView = InlineImageBlockView(frame: CGRect(
                    x: containerOrigin.x,
                    y: blockY,
                    width: preview.displaySize.width,
                    height: blockHeight
                ))
                imageView.lineLocation = preview.lineRange.location
                let isSelected = selectedInlineImageLine == preview.lineRange.location
                imageView.configure(
                    image: preview.image,
                    imageSize: preview.displaySize,
                    sourceText: preview.sourceText,
                    sourceHeaderHeight: preview.sourceHeaderHeight,
                    showsSource: preview.showsSource,
                    isSelected: isSelected,
                    hostTextView: textView,
                    onSelect: { [weak self, weak imageView, weak textView] in
                        guard let self, let imageView, let textView else { return }
                        self.selectInlineImage(atLine: preview.lineRange.location, view: imageView, in: textView)
                    },
                    onDidResignFirstResponder: { [weak self, weak imageView] in
                        guard let self else { return }
                        self.inlineImageSelectionDidResign(
                            atLine: preview.lineRange.location,
                            view: imageView
                        )
                    }
                ) { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.toggleInlineSourcePreview(forLineAt: preview.lineRange.location, in: textView)
                }
                textView.addSubview(imageView)
                inlineImageViews.append(imageView)

                if isSelected {
                    selectedInlineImageView = imageView

                    if shouldRestoreSelectedInlineImageResponder && !restoredSelectedInlineImageResponder {
                        imageView.window?.makeFirstResponder(imageView)
                        restoredSelectedInlineImageResponder = true
                    }
                }
            }
        }

        private func withPreservedViewport(
            for textView: NSTextView,
            revealSelectionAfterUpdate: Bool = true,
            updates: () -> Void
        ) {
            let selection = textView.selectedRange()
            let scrollOrigin = textView.enclosingScrollView?.contentView.bounds.origin

            updates()

            restoreSelection(selection, in: textView)
            restoreScrollOrigin(scrollOrigin, in: textView)
            if revealSelectionAfterUpdate {
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        private func restoreSelection(_ selection: NSRange, in textView: NSTextView) {
            let length = textView.string.utf16.count
            let safeLocation = min(selection.location, length)
            let safeLength = min(selection.length, max(0, length - safeLocation))
            textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
        }

        private func restoreScrollOrigin(_ origin: CGPoint?, in textView: NSTextView) {
            guard let origin, let scrollView = textView.enclosingScrollView else { return }

            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }

            let contentView = scrollView.contentView
            let maxX = max(0, textView.frame.width - contentView.bounds.width)
            let maxY = max(0, textView.frame.height - contentView.bounds.height)
            let clampedOrigin = CGPoint(
                x: min(max(origin.x, 0), maxX),
                y: min(max(origin.y, 0), maxY)
            )

            contentView.scroll(to: clampedOrigin)
            scrollView.reflectScrolledClipView(contentView)
        }

        private func collectInlineImagePreviews(in textView: NSTextView) -> [InlineImagePreview] {
            let text = textView.string as NSString
            guard text.length > 0 else { return [] }

            let maxImageWidth = max(220, textView.textContainer?.containerSize.width ?? parent.maximumReadableWidth)
            let resolver = AssetResolver(
                context: PreviewContext(
                    documentURL: parent.documentURL,
                    vaultURL: parent.vaultURL
                )
            )

            var previews: [InlineImagePreview] = []
            var location = 0
            var isInsideCodeBlock = false

            while location < text.length {
                let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
                let line = text.substring(with: lineRange)
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.hasPrefix("```") {
                    isInsideCodeBlock.toggle()
                    location = NSMaxRange(lineRange)
                    continue
                }

                defer { location = NSMaxRange(lineRange) }

                guard !isInsideCodeBlock,
                      !trimmed.isEmpty,
                      let fileURL = resolver.resolveInlineImageFileURL(forLine: trimmed),
                      let image = cachedImage(for: fileURL) else {
                    continue
                }

                let displaySize = scaledSize(
                    for: image,
                    maxWidth: maxImageWidth,
                    maxHeight: parent.maximumInlineImageHeight
                )
                let showsSource = expandedInlineSourceLines.contains(lineRange.location)
                let sourceHeaderHeight = showsSource ? parent.inlineImageSourceHeaderHeight : 0
                let reservedHeight = displaySize.height + parent.inlineImageSpacing + sourceHeaderHeight
                previews.append(
                    InlineImagePreview(
                        lineRange: lineRange,
                        sourceText: normalizedEmbedSource(for: fileURL),
                        showsSource: showsSource,
                        image: image,
                        displaySize: displaySize,
                        reservedHeight: reservedHeight,
                        sourceHeaderHeight: sourceHeaderHeight
                    )
                )
            }

            return previews
        }

        private func clearInlineImagePreviews(in textView: NSTextView) {
            inlineImageViews.forEach { $0.removeFromSuperview() }
            inlineImageViews.removeAll()
            selectedInlineImageView = nil

            hiddenInlinePreviewRanges.removeAll()
            inlineImagePreviewByGlyphLocation.removeAll()

            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            guard fullRange.length > 0 else { return }

            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        }

        private func cachedImage(for fileURL: URL) -> NSImage? {
            let cacheKey = fileURL.standardizedFileURL as NSURL
            if let cached = imageCache.object(forKey: cacheKey) {
                return cached
            }

            guard let image = NSImage(contentsOf: fileURL) else { return nil }
            imageCache.setObject(image, forKey: cacheKey)
            return image
        }

        private func scaledSize(for image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSSize {
            let imageSize = image.size
            guard imageSize.width > 0, imageSize.height > 0 else {
                return NSSize(width: maxWidth, height: maxHeight)
            }

            let widthScale = maxWidth / imageSize.width
            let heightScale = maxHeight / imageSize.height
            let scale = min(1, widthScale, heightScale)

            return NSSize(
                width: floor(imageSize.width * scale),
                height: floor(imageSize.height * scale)
            )
        }

        private func normalizedEmbedSource(for fileURL: URL) -> String {
            "![[\(fileURL.lastPathComponent)]]"
        }

        private func toggleInlineSourcePreview(forLineAt location: Int, in textView: NSTextView) {
            if expandedInlineSourceLines.contains(location) {
                expandedInlineSourceLines.remove(location)
            } else {
                expandedInlineSourceLines.insert(location)
            }

            withPreservedViewport(for: textView, revealSelectionAfterUpdate: false) {
                refreshInlineImagePreviews(in: textView, resettingTextAttributes: true)
            }
        }

        private func selectInlineImage(atLine location: Int, view: InlineImageBlockView, in textView: NSTextView) {
            isSelectingInlineImage = true
            defer {
                DispatchQueue.main.async { [weak self] in
                    self?.isSelectingInlineImage = false
                }
            }

            if selectedInlineImageView !== view {
                selectedInlineImageView?.setSelected(false)
            }

            suppressTextSelectionAppearance(in: textView)
            selectedInlineImageLine = location
            selectedInlineImageView = view
            view.setSelected(true)

            if textView.window?.firstResponder !== view {
                textView.window?.makeFirstResponder(view)
            }
        }

        private func inlineImageSelectionDidResign(atLine location: Int, view: InlineImageBlockView?) {
            guard !isRefreshingInlineImagePreviews else { return }
            guard selectedInlineImageLine == location else { return }

            if selectedInlineImageView === view {
                selectedInlineImageView?.setSelected(false)
            }

            restoreTextSelectionAppearance()
            clearStoredInlineImageSelection()
        }

        private func clearInlineImageSelection() {
            selectedInlineImageView?.setSelected(false)
            restoreTextSelectionAppearance()
            clearStoredInlineImageSelection()
        }

        private func clearStoredInlineImageSelection() {
            selectedInlineImageLine = nil
            selectedInlineImageView = nil
        }

        private func suppressTextSelectionAppearance(in textView: NSTextView) {
            if inlineImageSelectionTextView !== textView || storedTextSelectionAppearance == nil {
                inlineImageSelectionTextView = textView
                storedTextSelectionAppearance = TextSelectionAppearance(
                    insertionPointColor: textView.insertionPointColor,
                    selectedTextAttributes: textView.selectedTextAttributes
                )
            }

            var selectedTextAttributes = storedTextSelectionAppearance?.selectedTextAttributes ?? textView.selectedTextAttributes
            selectedTextAttributes[.backgroundColor] = NSColor.clear
            selectedTextAttributes[.foregroundColor] = textView.textColor ?? NSColor.textColor

            textView.insertionPointColor = .clear
            textView.selectedTextAttributes = selectedTextAttributes
            textView.needsDisplay = true
        }

        private func restoreTextSelectionAppearance() {
            guard let textView = inlineImageSelectionTextView,
                  let storedTextSelectionAppearance else {
                inlineImageSelectionTextView = nil
                storedTextSelectionAppearance = nil
                return
            }

            textView.insertionPointColor = storedTextSelectionAppearance.insertionPointColor
            textView.selectedTextAttributes = storedTextSelectionAppearance.selectedTextAttributes
            textView.needsDisplay = true

            inlineImageSelectionTextView = nil
            self.storedTextSelectionAppearance = nil
        }

        private func moveSelectionOutOfHiddenInlinePreviewIfNeeded(in textView: NSTextView) {
            let selection = textView.selectedRange()
            let adjustedSelection = adjustedSelectionAwayFromHiddenInlinePreviews(
                selection,
                previousSelection: nil,
                hiddenRanges: hiddenInlinePreviewRanges,
                textLength: (textView.string as NSString).length
            )

            guard adjustedSelection != selection else {
                return
            }
            textView.setSelectedRange(adjustedSelection)
        }

        private func adjustedSelectionAwayFromHiddenInlinePreviews(
            _ selection: NSRange,
            previousSelection: NSRange?,
            hiddenRanges: [NSRange],
            textLength: Int
        ) -> NSRange {
            var adjustedSelection = selection

            while let hiddenRange = hiddenRanges.first(where: {
                selectionIntersectsHiddenPreview(adjustedSelection, lineRange: $0)
            }) {
                let placeBefore = prefersSelectionBeforeHiddenPreview(
                    hiddenRange,
                    proposedSelection: adjustedSelection,
                    previousSelection: previousSelection
                )
                let targetLocation = placeBefore
                    ? previousVisibleLocation(before: hiddenRange, textLength: textLength)
                    : nextVisibleLocation(after: hiddenRange, textLength: textLength)

                adjustedSelection = NSRange(location: targetLocation, length: 0)
            }

            return adjustedSelection
        }

        private func prefersSelectionBeforeHiddenPreview(
            _ hiddenRange: NSRange,
            proposedSelection: NSRange,
            previousSelection: NSRange?
        ) -> Bool {
            if let previousSelection {
                if previousSelection.location >= NSMaxRange(hiddenRange) {
                    return true
                }

                if NSMaxRange(previousSelection) <= hiddenRange.location {
                    return false
                }
            }

            let midpoint = hiddenRange.location + (hiddenRange.length / 2)
            return proposedSelection.location < midpoint
        }

        private func previousVisibleLocation(before hiddenRange: NSRange, textLength: Int) -> Int {
            guard hiddenRange.location > 0 else { return 0 }
            return min(textLength, hiddenRange.location - 1)
        }

        private func nextVisibleLocation(after hiddenRange: NSRange, textLength: Int) -> Int {
            min(textLength, NSMaxRange(hiddenRange))
        }

        private func selectionIntersectsHiddenPreview(_ selection: NSRange, lineRange: NSRange) -> Bool {
            if selection.length > 0 {
                return NSIntersectionRange(selection, lineRange).length > 0
            }

            if selection.location == lineRange.location {
                return true
            }

            let upperBound = NSMaxRange(lineRange)
            return selection.location > lineRange.location && selection.location < upperBound
        }

        nonisolated func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
            lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
            baselineOffset: UnsafeMutablePointer<CGFloat>,
            in textContainer: NSTextContainer,
            forGlyphRange glyphRange: NSRange
        ) -> Bool {
            guard let preview = inlineImagePreviewByGlyphLocation[glyphRange.location] else {
                return false
            }

            let targetHeight = preview.reservedHeight
            lineFragmentRect.pointee.size.height = max(lineFragmentRect.pointee.size.height, targetHeight)
            lineFragmentUsedRect.pointee.size.height = max(lineFragmentUsedRect.pointee.size.height, targetHeight)
            return true
        }
    }
}

@MainActor
private protocol InlinePreviewTextViewDelegate: AnyObject {
    func inlinePreviewTextView(_ textView: NSTextView, handleInlinePreviewClickAt point: CGPoint) -> Bool
}

private final class InlinePreviewTextView: NSTextView {
    weak var inlinePreviewDelegate: InlinePreviewTextViewDelegate?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if inlinePreviewDelegate?.inlinePreviewTextView(self, handleInlinePreviewClickAt: point) == true {
            return
        }

        super.mouseDown(with: event)
    }
}

private final class InlineImageBlockView: NSView {
    private let imageView = NSImageView()
    private let sourceLabel = NSTextField(labelWithString: "")
    private let selectionHandleView = NSView()
    private let toggleButton = NSButton()
    private weak var hostTextView: NSTextView?
    private var onSelect: (() -> Void)?
    private var onDidResignFirstResponder: (() -> Void)?
    private var onToggle: (() -> Void)?
    private var isSelected = false
    private var sourceHeaderHeight: CGFloat = 0
    private let buttonSize: CGFloat = 32
    private let headerTrailingInset: CGFloat = 44
    private let headerHorizontalInset: CGFloat = 8
    private let headerTopInset: CGFloat = 2
    private let selectionHandleSize: CGFloat = 12
    private let selectionColor = NSColor.systemPurple
    var lineLocation: Int?

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.masksToBounds = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignLeft
        imageView.setAccessibilityElement(false)
        addSubview(imageView)

        sourceLabel.font = Theme.codeFont
        sourceLabel.textColor = Theme.linkColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.maximumNumberOfLines = 1
        sourceLabel.isHidden = true
        addSubview(sourceLabel)

        toggleButton.title = ""
        toggleButton.isBordered = false
        toggleButton.image = NSImage(
            systemSymbolName: "chevron.left.forwardslash.chevron.right",
            accessibilityDescription: "Show embedded markdown source"
        )
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.bezelStyle = .regularSquare
        toggleButton.focusRingType = .none
        toggleButton.target = self
        toggleButton.action = #selector(handleToggle)
        toggleButton.wantsLayer = true
        toggleButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        toggleButton.layer?.cornerRadius = 8
        addSubview(toggleButton)

        selectionHandleView.wantsLayer = true
        selectionHandleView.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        selectionHandleView.layer?.borderColor = selectionColor.cgColor
        selectionHandleView.layer?.borderWidth = 2
        selectionHandleView.layer?.cornerRadius = selectionHandleSize / 2
        selectionHandleView.isHidden = true
        addSubview(selectionHandleView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        image: NSImage,
        imageSize: NSSize,
        sourceText: String,
        sourceHeaderHeight: CGFloat,
        showsSource: Bool,
        isSelected: Bool,
        hostTextView: NSTextView,
        onSelect: @escaping () -> Void,
        onDidResignFirstResponder: @escaping () -> Void,
        onToggle: @escaping () -> Void
    ) {
        self.hostTextView = hostTextView
        self.onSelect = onSelect
        self.onDidResignFirstResponder = onDidResignFirstResponder
        self.onToggle = onToggle
        self.sourceHeaderHeight = sourceHeaderHeight
        imageView.image = image
        sourceLabel.stringValue = sourceText
        sourceLabel.isHidden = !showsSource
        imageView.frame = CGRect(
            origin: CGPoint(x: 0, y: sourceHeaderHeight),
            size: imageSize
        )

        toggleButton.frame = CGRect(
            x: bounds.width - buttonSize,
            y: 0,
            width: buttonSize,
            height: buttonSize
        )

        if showsSource {
            sourceLabel.frame = CGRect(
                x: headerHorizontalInset,
                y: headerTopInset,
                width: max(120, bounds.width - headerTrailingInset - headerHorizontalInset),
                height: sourceHeaderHeight - (headerTopInset * 2)
            )
        }

        setSelected(isSelected)
    }

    override func layout() {
        super.layout()

        toggleButton.frame.origin = CGPoint(x: bounds.width - buttonSize, y: 0)

        if !sourceLabel.isHidden {
            sourceLabel.frame = CGRect(
                x: headerHorizontalInset,
                y: headerTopInset,
                width: max(120, bounds.width - headerTrailingInset - headerHorizontalInset),
                height: sourceHeaderHeight - (headerTopInset * 2)
            )
        }

        selectionHandleView.frame = CGRect(
            x: bounds.width - (selectionHandleSize / 2),
            y: bounds.height - (selectionHandleSize / 2),
            width: selectionHandleSize,
            height: selectionHandleSize
        )
    }

    override func resetCursorRects() {
        addCursorRect(imageView.frame, cursor: .arrow)
        addCursorRect(toggleButton.frame, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point), !toggleButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }

        onSelect?()
    }

    override func keyDown(with event: NSEvent) {
        guard let hostTextView else {
            super.keyDown(with: event)
            return
        }

        if window?.firstResponder !== hostTextView {
            window?.makeFirstResponder(hostTextView)
        }
        hostTextView.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let didResign = super.resignFirstResponder()
        if didResign {
            onDidResignFirstResponder?()
        }
        return didResign
    }

    @objc
    private func handleToggle() {
        onToggle?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        let converted = convert(point, to: toggleButton)
        if let hitView = toggleButton.hitTest(converted) {
            return hitView
        }
        return self
    }

    func isToggleHit(at point: CGPoint) -> Bool {
        toggleButton.frame.contains(point)
    }

    func performToggleAction() {
        handleToggle()
    }

    func setSelected(_ isSelected: Bool) {
        self.isSelected = isSelected
        layer?.borderColor = selectionColor.cgColor
        layer?.borderWidth = isSelected ? 2 : 0
        selectionHandleView.isHidden = !isSelected
    }
}
