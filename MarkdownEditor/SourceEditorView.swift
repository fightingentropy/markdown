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
    private enum SearchRequest {
        case locateMatch
        case findNext
    }

    weak var textView: NSTextView? {
        didSet {
            performPendingSearchIfNeeded()
        }
    }
    weak var searchField: NSSearchField?
    var searchQuery = ""

    private var pendingSearchRequest: SearchRequest?
    private var pendingEditorFocusRequest = false

    func applyBold() { wrapSelection(prefix: "**", suffix: "**") }
    func applyItalic() { wrapSelection(prefix: "*", suffix: "*") }
    func applyCode() { wrapSelection(prefix: "`", suffix: "`") }
    func applyCodeBlock() { wrapSelection(prefix: "```\n", suffix: "\n```") }
    func applyBlockquote() { prependToCurrentLine("> ") }
    func applyUnorderedList() { prependToCurrentLine("- ") }
    func applyOrderedList() { prependToCurrentLine("1. ") }

    func toggleTask() {
        guard let textView else { return }
        let result = MarkdownTaskToggler.toggle(
            in: textView.string,
            selection: textView.selectedRange()
        )
        textView.insertText(
            result.text,
            replacementRange: NSRange(location: 0, length: (textView.string as NSString).length)
        )
        textView.setSelectedRange(result.selection)
        textView.scrollRangeToVisible(result.selection)
    }

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

    func registerSearchField(_ searchField: NSSearchField) {
        self.searchField = searchField
    }

    func activateSearch() {
        guard let searchField else { return }
        searchField.selectText(nil)

        if !searchQuery.isEmpty {
            queueSearch(.locateMatch)
        }
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            pendingSearchRequest = nil
            return
        }

        queueSearch(.locateMatch)
    }

    func findNextMatch() {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSSound.beep()
            return
        }

        queueSearch(.findNext)
    }

    func requestEditorFocus() {
        pendingEditorFocusRequest = true
        focusEditorIfPossible(queueIfUnavailable: true)
    }

    func jumpToLine(_ oneBasedLineNumber: Int) {
        guard let textView, oneBasedLineNumber > 0 else { return }
        let text = textView.string as NSString
        var location = 0
        var line = 1
        while line < oneBasedLineNumber && location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            let next = NSMaxRange(range)
            guard next > location else { break }
            location = next
            line += 1
        }
        textView.setSelectedRange(NSRange(location: min(location, text.length), length: 0))
        focusEditorIfPossible(queueIfUnavailable: false)
    }

    func consumePendingEditorFocusRequest() -> Bool {
        defer { pendingEditorFocusRequest = false }
        return pendingEditorFocusRequest
    }

    func focusEditor() {
        focusEditorIfPossible(queueIfUnavailable: false)
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

    private func queueSearch(_ request: SearchRequest) {
        guard let textView else {
            pendingSearchRequest = request
            return
        }

        performSearch(request, in: textView)
    }

    private func performPendingSearchIfNeeded() {
        guard let request = pendingSearchRequest else { return }
        pendingSearchRequest = nil
        queueSearch(request)
    }

    private func focusEditorIfPossible(queueIfUnavailable: Bool) {
        guard let textView else {
            if queueIfUnavailable {
                pendingEditorFocusRequest = true
            }
            return
        }

        DispatchQueue.main.async { [weak self, weak textView] in
            guard let textView,
                  let window = textView.window else {
                if queueIfUnavailable {
                    self?.pendingEditorFocusRequest = true
                }
                return
            }

            window.makeFirstResponder(textView)
            textView.scrollRangeToVisible(textView.selectedRange())
            self?.pendingEditorFocusRequest = false
        }
    }

    private func performSearch(_ request: SearchRequest, in textView: NSTextView) {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let document = textView.string as NSString
        let selectedRange = textView.selectedRange()
        let startLocation: Int

        switch request {
        case .locateMatch:
            startLocation = min(selectedRange.location, document.length)
        case .findNext:
            startLocation = min(selectedRange.location + max(selectedRange.length, 1), document.length)
        }

        let primaryRange = NSRange(location: startLocation, length: document.length - startLocation)
        let wrapRange = NSRange(location: 0, length: startLocation)

        if let match = findMatch(
            query: query,
            in: document,
            primaryRange: primaryRange,
            wrapRange: wrapRange
        ) {
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            flashFindIndicator(for: match, in: textView)
        } else {
            NSSound.beep()
        }
    }

    /// Shows the native yellow find indicator reliably. `showFindIndicator`
    /// silently no-ops when the range hasn't been typeset yet, so we force
    /// layout for the match range first and then defer the call to the next
    /// runloop pass so `scrollRangeToVisible`'s scroll/animation has a chance
    /// to settle before the indicator is drawn.
    private func flashFindIndicator(for range: NSRange, in textView: NSTextView) {
        guard NSMaxRange(range) <= textView.string.utf16.count else { return }

        if let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(forCharacterRange: range)
        }

        // Capture the document the match belongs to so a fast note switch
        // before the deferred call cannot flash the indicator over the wrong
        // (now unrelated) content.
        let documentAtFind = textView.string

        // Fire on the next runloop tick so any pending scroll has settled.
        // `showFindIndicator` is idempotent; calling it twice is harmless and
        // guarantees the animation even when the first call raced layout.
        textView.showFindIndicator(for: range)
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            // Re-validate: the editor may have switched documents (or the text
            // shrunk) in the interim, which would make `range` stale or
            // out-of-bounds.
            guard textView.string == documentAtFind,
                  NSMaxRange(range) <= textView.string.utf16.count else { return }
            textView.showFindIndicator(for: range)
        }
    }

    private func findMatch(
        query: String,
        in document: NSString,
        primaryRange: NSRange,
        wrapRange: NSRange
    ) -> NSRange? {
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        let primaryMatch = document.range(of: query, options: options, range: primaryRange)
        if primaryMatch.location != NSNotFound {
            return primaryMatch
        }

        guard wrapRange.length > 0 else { return nil }

        let wrappedMatch = document.range(of: query, options: options, range: wrapRange)
        return wrappedMatch.location == NSNotFound ? nil : wrappedMatch
    }
}

// MARK: - NSViewRepresentable

struct SourceEditorView: NSViewRepresentable {
    @Binding var text: String
    let documentURL: URL?
    let vaultURL: URL?
    let noteLinkCompletions: [String]
    let controller: EditorController
    let preferences: AppPreferences
    let savedSelection: NSRange?
    let onSelectionChange: (URL?, NSRange) -> Void

    private let minimumHorizontalInset: CGFloat = 72

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let baseTextView = scrollView.documentView as? NSTextView else { return scrollView }

        let textView: SourceTextView
        if let existing = baseTextView as? SourceTextView {
            textView = existing
        } else {
            textView = SourceTextView(frame: baseTextView.frame, textContainer: baseTextView.textContainer)
            scrollView.documentView = textView
        }

        configure(textView, coordinator: context.coordinator)
        textView.string = text

        context.coordinator.parent = self
        context.coordinator.observeSizeChanges(of: scrollView)
        context.coordinator.primeContentHash(for: text)
        context.coordinator.applyTextLayout(for: scrollView, textView: textView)
        _ = context.coordinator.setCurrentDocument(documentURL)
        context.coordinator.primeAppearanceSignature()
        context.coordinator.restoreEditorState(
            in: textView,
            selection: savedSelection,
            focusEditor: controller.consumePendingEditorFocusRequest()
        )
        context.coordinator.highlight(textView, preservingViewport: false)
        context.coordinator.scheduleDeferredLayoutUpdate(for: scrollView, textView: textView)

        controller.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SourceTextView else { return }

        context.coordinator.parent = self
        context.coordinator.observeSizeChanges(of: nsView)
        configure(textView, coordinator: context.coordinator)
        context.coordinator.applyTextLayout(for: nsView, textView: textView)
        let documentChanged = context.coordinator.setCurrentDocument(documentURL)
        context.coordinator.applyExternalTextIfNeeded(
            text,
            documentChanged: documentChanged,
            savedSelection: savedSelection,
            focusEditor: controller.consumePendingEditorFocusRequest(),
            to: textView
        )
        context.coordinator.refreshAppearanceIfNeeded(on: textView)

        controller.textView = textView
    }

    private func configure(_ textView: SourceTextView, coordinator: Coordinator) {
        textView.isRichText = false
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
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.delegate = coordinator
        textView.modifiedLinkDelegate = coordinator
        textView.attachmentDelegate = coordinator
        textView.textStorage?.delegate = coordinator

        textView.setAccessibilityLabel("Markdown source editor")
        if let documentName = documentURL?.deletingPathExtension().lastPathComponent, !documentName.isEmpty {
            textView.setAccessibilityHelp("Editing \(documentName). Press Command-Return to open a link under the cursor.")
        } else {
            textView.setAccessibilityHelp("Press Command-Return to open a link under the cursor.")
        }
    }

    /// Pure geometry for the current scroll width; the actual (memoized)
    /// application happens in `Coordinator.applyTextLayout` so repeated
    /// scroll/resize notifications don't reassign identical attributes.
    fileprivate func textLayout(for scrollView: NSScrollView) -> Coordinator.LayoutSignature {
        let readableWidth = preferences.editorReadableWidthCGFloat
        let availableWidth = max(scrollView.contentSize.width, readableWidth)
        let columnWidth = min(readableWidth, max(0, availableWidth - (minimumHorizontalInset * 2)))
        let horizontalInset = max(minimumHorizontalInset, (availableWidth - columnWidth) / 2)

        return Coordinator.LayoutSignature(
            fontChoice: preferences.editorFontChoice,
            fontSize: preferences.editorFontSize,
            lineSpacing: preferences.editorLineSpacing,
            horizontalInset: horizontalInset,
            columnWidth: columnWidth
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, SourceTextViewDelegate {
        private struct AppearanceSignature: Equatable {
            let fontChoice: MonospacedFontChoice
            let fontSize: Double
            let lineSpacing: Double
            let readableWidth: Double
        }

        struct LayoutSignature: Equatable {
            let fontChoice: MonospacedFontChoice
            let fontSize: Double
            let lineSpacing: Double
            let horizontalInset: CGFloat
            let columnWidth: CGFloat

            /// The portion of the signature that drives typingAttributes /
            /// defaultParagraphStyle. Only these need reassigning when changed;
            /// inset/column width are container geometry.
            func attributesMatch(_ other: LayoutSignature) -> Bool {
                fontChoice == other.fontChoice
                    && fontSize == other.fontSize
                    && lineSpacing == other.lineSpacing
            }
        }

        var parent: SourceEditorView
        private var isApplyingExternalText = false
        private var lastAppearanceSignature: AppearanceSignature?
        private let highlighter: SyntaxHighlighter
        private var pendingEditedRange: NSRange?
        private weak var observedClipView: NSClipView?
        private var currentDocumentIdentity: String?
        private var lastSelectionRange: NSRange?
        private var pendingFullHighlight: DispatchWorkItem?
        private var pendingLinkPreviewRefresh: DispatchWorkItem?
        private var lastAppliedLayoutSignature: LayoutSignature?
        private let linkPreviewController = EditorLinkPreviewController()
        /// Hash of the text currently shown in the editor, refreshed whenever the
        /// editor content changes (user edit or applied external text). Lets
        /// `updateNSView` skip the O(n) `textView.string != text` comparison when
        /// the incoming binding hashes identically.
        private var editorContentHash: Int?

        func sourceTextView(_ textView: NSTextView, importAttachmentFrom pasteboard: NSPasteboard) -> Bool {
            do {
                guard let attachment = try AttachmentStore.importFirstAttachment(
                    from: pasteboard,
                    documentURL: parent.documentURL,
                    vaultURL: parent.vaultURL
                ) else {
                    return false
                }

                textView.insertText(attachment.markdownEmbed, replacementRange: textView.selectedRange())
                return true
            } catch {
                NSSound.beep()
                return false
            }
        }

        init(_ parent: SourceEditorView) {
            self.parent = parent
            self.highlighter = SyntaxHighlighter(preferences: parent.preferences)
        }

        deinit {
            if let observedClipView {
                NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedClipView)
            }
        }

        func observeSizeChanges(of scrollView: NSScrollView) {
            let clipView = scrollView.contentView
            guard observedClipView !== clipView else { return }

            stopObservingSizeChanges()
            observedClipView = clipView
            clipView.postsFrameChangedNotifications = true
            clipView.postsBoundsChangedNotifications = true

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewBoundsDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        func scheduleDeferredLayoutUpdate(for scrollView: NSScrollView, textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak scrollView, weak textView] in
                guard let self, let scrollView, let textView else { return }
                self.applyTextLayout(for: scrollView, textView: textView)
            }
        }

        /// Applies the container geometry derived from the current scroll width,
        /// skipping work when nothing changed since the last application. A live
        /// window resize fires `frameDidChange` repeatedly; without this guard
        /// each tick reassigned typingAttributes / defaultParagraphStyle and
        /// re-set the container size, thrashing layout on large documents.
        func applyTextLayout(for scrollView: NSScrollView, textView: NSTextView) {
            let signature = parent.textLayout(for: scrollView)
            guard signature != lastAppliedLayoutSignature else { return }

            // Only reassign the attribute-bearing properties when an appearance
            // input actually changed, not when only the width shifted.
            if lastAppliedLayoutSignature.map({ !signature.attributesMatch($0) }) ?? true {
                textView.typingAttributes = Theme.defaultAttributes(using: parent.preferences)
                textView.defaultParagraphStyle = Theme.defaultParagraphStyle(using: parent.preferences)
            }

            textView.textContainerInset = NSSize(width: signature.horizontalInset, height: 28)
            textView.textContainer?.containerSize = NSSize(
                width: signature.columnWidth,
                height: CGFloat.greatestFiniteMagnitude
            )

            lastAppliedLayoutSignature = signature
            linkPreviewController.layoutCards(in: textView)
        }

        private func stopObservingSizeChanges() {
            guard let observedClipView else { return }

            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
                object: observedClipView
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: observedClipView
            )
            self.observedClipView = nil
        }

        func setCurrentDocument(_ url: URL?) -> Bool {
            let nextIdentity = documentIdentity(for: url)
            let didChange = currentDocumentIdentity != nextIdentity
            currentDocumentIdentity = nextIdentity
            return didChange
        }

        func applyExternalTextIfNeeded(
            _ text: String,
            documentChanged: Bool,
            savedSelection: NSRange?,
            focusEditor: Bool,
            to textView: NSTextView
        ) {
            guard documentChanged || contentDiffersFromExternalText(text, in: textView) else { return }

            // Any deferred full re-highlight is for the outgoing content; the
            // synchronous full pass below supersedes it.
            cancelPendingFullHighlight()

            if documentChanged {
                isApplyingExternalText = true
                defer { isApplyingExternalText = false }

                if textView.string != text {
                    textView.string = text
                }
                noteEditorContent(text)
                restoreEditorState(
                    in: textView,
                    selection: savedSelection,
                    focusEditor: focusEditor
                )
                highlight(textView, preservingViewport: false)
                return
            }

            withPreservedViewport(for: textView) {
                isApplyingExternalText = true
                defer { isApplyingExternalText = false }
                textView.string = text
                noteEditorContent(text)
                highlight(textView, preservingViewport: false)
            }
        }

        /// Cheap pre-check for whether the parent binding differs from what the
        /// editor currently shows. Compares a cached content hash first and only
        /// falls back to the O(n) string comparison when the hashes disagree (or
        /// no hash is cached yet), avoiding a full-document compare on every
        /// unrelated SwiftUI `updateNSView`.
        private func contentDiffersFromExternalText(_ text: String, in textView: NSTextView) -> Bool {
            if let editorContentHash, editorContentHash == text.hashValue {
                return false
            }
            return textView.string != text
        }

        private func noteEditorContent(_ text: String) {
            editorContentHash = text.hashValue
        }

        func primeContentHash(for text: String) {
            noteEditorContent(text)
        }

        func restoreEditorState(
            in textView: NSTextView,
            selection: NSRange?,
            focusEditor: Bool
        ) {
            let restoredSelection = selection ?? NSRange(location: 0, length: 0)
            restoreSelection(restoredSelection, in: textView)
            lastSelectionRange = textView.selectedRange()
            textView.scrollRangeToVisible(textView.selectedRange())

            guard focusEditor else { return }

            DispatchQueue.main.async { [weak textView] in
                guard let textView,
                      let window = textView.window else { return }

                window.makeFirstResponder(textView)
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func refreshAppearanceIfNeeded(on textView: NSTextView) {
            let nextSignature = AppearanceSignature(
                fontChoice: parent.preferences.editorFontChoice,
                fontSize: parent.preferences.editorFontSize,
                lineSpacing: parent.preferences.editorLineSpacing,
                readableWidth: parent.preferences.editorReadableWidth
            )
            guard lastAppearanceSignature != nextSignature else { return }

            lastAppearanceSignature = nextSignature
            highlight(textView)
        }

        func primeAppearanceSignature() {
            lastAppearanceSignature = AppearanceSignature(
                fontChoice: parent.preferences.editorFontChoice,
                fontSize: parent.preferences.editorFontSize,
                lineSpacing: parent.preferences.editorLineSpacing,
                readableWidth: parent.preferences.editorReadableWidth
            )
        }

        func highlight(
            _ textView: NSTextView,
            preservingViewport: Bool = true,
            editedRange: NSRange? = nil
        ) {
            // A full pass resets paragraph styles before link previews reserve
            // their space again, so anchor across both halves of that reflow.
            let fullRefreshAnchor = editedRange == nil
                ? EditorViewportAnchor.capture(in: textView)
                : nil
            let applyHighlighting = {
                guard let storage = textView.textStorage else { return }
                self.highlighter.highlight(storage, editedRange: editedRange)
            }

            if preservingViewport {
                withPreservedViewport(for: textView, updates: applyHighlighting)
            } else {
                applyHighlighting()
            }

            if editedRange == nil {
                cancelPendingLinkPreviewRefresh()
                refreshLinkPreviews(in: textView)
                fullRefreshAnchor?.restore(in: textView)
            } else {
                scheduleLinkPreviewRefresh(for: textView)
            }
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                pendingEditedRange = editedRange
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else { return }

            let editedRange = pendingEditedRange
            pendingEditedRange = nil

            let updatedString = textView.string
            parent.text = updatedString
            noteEditorContent(updatedString)
            offerWikiLinkCompletionsIfNeeded(in: textView)

            // A cheap incremental edit (paragraph/inline-only) is highlighted
            // synchronously so the keystroke stays crisp. Fence-affecting edits
            // force a full-document rescan whose cost scales with document
            // length; coalesce those off the per-keystroke path so a burst of
            // typing inside/around a code fence collapses into a single pass.
            let needsFull = textView.textStorage.map {
                highlighter.requiresFullRehighlight(for: editedRange, in: $0)
            } ?? true

            if needsFull {
                scheduleFullHighlight(for: textView)
                return
            }

            // Always run the cheap incremental pass for immediate feedback.
            highlight(
                textView,
                preservingViewport: false,
                editedRange: editedRange
            )

            // If a fence-affecting edit is still awaiting its coalesced
            // full-document pass, keep it scheduled: this cheap edit only
            // recolored its own paragraph and must not drop the pending
            // document-wide code-block recolor.
            if pendingFullHighlight != nil {
                scheduleFullHighlight(for: textView)
            }

        }

        func textView(
            _ textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>?
        ) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange)
            let suggestions = WikiLinkCompletion.suggestions(
                for: partial,
                candidates: parent.noteLinkCompletions
            )
            index?.pointee = suggestions.isEmpty ? -1 : 0
            return suggestions
        }

        private func offerWikiLinkCompletionsIfNeeded(in textView: NSTextView) {
            guard WikiLinkCompletion.partialRange(
                in: textView.string,
                selection: textView.selectedRange()
            ) != nil else { return }

            DispatchQueue.main.async { [weak textView] in
                textView?.complete(nil)
            }
        }

        private func scheduleFullHighlight(for textView: NSTextView) {
            cancelPendingFullHighlight()

            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingFullHighlight = nil
                self.highlight(textView, preservingViewport: false)
            }
            pendingFullHighlight = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        }

        private func cancelPendingFullHighlight() {
            pendingFullHighlight?.cancel()
            pendingFullHighlight = nil
        }

        private func scheduleLinkPreviewRefresh(for textView: NSTextView) {
            cancelPendingLinkPreviewRefresh()

            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.pendingLinkPreviewRefresh = nil
                self.refreshLinkPreviews(in: textView)
            }
            pendingLinkPreviewRefresh = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
        }

        private func cancelPendingLinkPreviewRefresh() {
            pendingLinkPreviewRefresh?.cancel()
            pendingLinkPreviewRefresh = nil
        }

        private func refreshLinkPreviews(in textView: NSTextView) {
            linkPreviewController.refresh(in: textView) { [weak self] url in
                self?.openLink(url)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else { return }
            let selection = textView.selectedRange()
            guard lastSelectionRange != selection else { return }

            lastSelectionRange = selection
            linkPreviewController.selectionDidChange(in: textView)
            parent.onSelectionChange(parent.documentURL, selection)
        }

        func sourceTextView(_ textView: NSTextView, handleModifiedLinkClickAt point: CGPoint, with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  let url = linkURL(at: point, in: textView) else {
                return false
            }

            openLink(url)
            return true
        }

        @discardableResult
        func sourceTextViewOpenLinkAtCaret(_ textView: NSTextView) -> Bool {
            guard let url = EditorLinkDetector.url(
                near: textView.selectedRange().location,
                in: textView.string
            ) else {
                NSSound.beep()
                return false
            }

            openLink(url)
            return true
        }

        private func openLink(_ url: URL) {
            guard PreviewURLPolicy.canOpenExternally(url) else {
                NSSound.beep()
                return
            }

            NSWorkspace.shared.open(url)
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

        private func linkURL(at point: CGPoint, in textView: NSTextView) -> URL? {
            guard let location = insertionLocation(for: point, in: textView) else {
                return nil
            }

            return EditorLinkDetector.url(near: location, in: textView.string)
        }

        private func insertionLocation(for point: CGPoint, in textView: NSTextView) -> Int? {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else {
                return nil
            }

            let containerOrigin = textView.textContainerOrigin
            let containerPoint = CGPoint(
                x: max(0, point.x - containerOrigin.x),
                y: max(0, point.y - containerOrigin.y)
            )

            let rawLocation = layoutManager.characterIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )

            return min(rawLocation, textView.string.utf16.count)
        }

        private func documentIdentity(for url: URL?) -> String? {
            url?.resolvingSymlinksInPath().standardizedFileURL.path
        }

        @objc
        private func clipViewFrameDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.superview as? NSScrollView,
                  let textView = scrollView.documentView as? NSTextView else {
                return
            }

            applyTextLayout(for: scrollView, textView: textView)
        }

        @objc
        private func clipViewBoundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView,
                  let scrollView = clipView.superview as? NSScrollView,
                  let textView = scrollView.documentView as? NSTextView else {
                return
            }

            linkPreviewController.layoutCards(in: textView)
        }
    }
}

@MainActor
private protocol SourceTextViewDelegate: AnyObject {
    func sourceTextView(_ textView: NSTextView, handleModifiedLinkClickAt point: CGPoint, with event: NSEvent) -> Bool
    /// Resolves and opens the link under the caret (keyboard / accessibility
    /// entry point). Returns `true` if a link was found and opening was
    /// attempted, `false` if there is no link at the caret.
    @discardableResult
    func sourceTextViewOpenLinkAtCaret(_ textView: NSTextView) -> Bool
    func sourceTextView(_ textView: NSTextView, importAttachmentFrom pasteboard: NSPasteboard) -> Bool
}

private final class SourceTextView: NSTextView {
    weak var modifiedLinkDelegate: SourceTextViewDelegate?
    weak var attachmentDelegate: SourceTextViewDelegate?

    override var rangeForUserCompletion: NSRange {
        WikiLinkCompletion.partialRange(in: string, selection: selectedRange())
            ?? NSRange(location: NSNotFound, length: 0)
    }

    override func paste(_ sender: Any?) {
        if attachmentDelegate?.sourceTextView(self, importAttachmentFrom: .general) == true {
            return
        }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attachmentDelegate?.sourceTextView(self, importAttachmentFrom: sender.draggingPasteboard) == true {
            return true
        }
        return super.performDragOperation(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if modifiedLinkDelegate?.sourceTextView(self, handleModifiedLinkClickAt: point, with: event) == true {
            return
        }

        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Command-Return opens the link under the caret — a keyboard equivalent
        // for the ⌘-click affordance so the feature is reachable without a
        // mouse (and for VoiceOver users via the custom action below).
        if event.modifierFlags.contains(.command),
           let characters = event.charactersIgnoringModifiers,
           characters == "\r" || characters == "\n" {
            if modifiedLinkDelegate?.sourceTextViewOpenLinkAtCaret(self) == true {
                return
            }
        }

        super.keyDown(with: event)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        let openLink = NSAccessibilityCustomAction(name: "Open link under cursor") { [weak self] in
            guard let self else { return false }
            return self.modifiedLinkDelegate?.sourceTextViewOpenLinkAtCaret(self) ?? false
        }
        actions.append(openLink)
        return actions
    }
}

struct EditorSearchToolbarField: NSViewRepresentable {
    let query: String
    let controller: EditorController
    let isEnabled: Bool
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.delegate = context.coordinator
        searchField.controlSize = .small
        searchField.placeholderString = "Search ⌘F"
        searchField.sendsWholeSearchString = true
        searchField.focusRingType = .default
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submitSearch(_:))
        controller.registerSearchField(searchField)
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        searchField.isEnabled = isEnabled
        if searchField.stringValue != query {
            searchField.stringValue = query
        }
        controller.registerSearchField(searchField)
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate, NSControlTextEditingDelegate {
        var parent: EditorSearchToolbarField

        init(parent: EditorSearchToolbarField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onActivate()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            parent.onActivate()
            parent.controller.updateSearchQuery(searchField.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onActivate()
                parent.controller.findNextMatch()
                return true
            }

            return false
        }

        @objc
        func submitSearch(_ sender: NSSearchField) {
            parent.onActivate()
            if sender.stringValue.isEmpty {
                parent.controller.updateSearchQuery("")
            } else {
                parent.controller.findNextMatch()
            }
        }
    }
}
