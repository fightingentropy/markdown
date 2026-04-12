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
            textView.showFindIndicator(for: match)
        } else {
            NSSound.beep()
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
        updateTextLayout(for: scrollView, textView: textView)
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
        updateTextLayout(for: nsView, textView: textView)
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
        textView.textStorage?.delegate = coordinator
    }

    private func updateTextLayout(for scrollView: NSScrollView, textView: NSTextView) {
        let readableWidth = preferences.editorReadableWidthCGFloat
        let availableWidth = max(scrollView.contentSize.width, readableWidth)
        let columnWidth = min(readableWidth, max(0, availableWidth - (minimumHorizontalInset * 2)))
        let horizontalInset = max(minimumHorizontalInset, (availableWidth - columnWidth) / 2)

        let baseAttributes = Theme.defaultAttributes(using: preferences)
        textView.typingAttributes = baseAttributes
        textView.defaultParagraphStyle = Theme.defaultParagraphStyle(using: preferences)
        textView.textContainerInset = NSSize(width: horizontalInset, height: 28)
        textView.textContainer?.containerSize = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, SourceTextViewDelegate {
        private struct AppearanceSignature: Equatable {
            let fontChoice: MonospacedFontChoice
            let fontSize: Double
            let lineSpacing: Double
            let readableWidth: Double
        }

        var parent: SourceEditorView
        private var isApplyingExternalText = false
        private var lastAppearanceSignature: AppearanceSignature?
        private let highlighter: SyntaxHighlighter
        private var pendingEditedRange: NSRange?
        private weak var observedClipView: NSClipView?
        private var currentDocumentIdentity: String?
        private var lastSelectionRange: NSRange?

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

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(clipViewFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
        }

        func scheduleDeferredLayoutUpdate(for scrollView: NSScrollView, textView: NSTextView) {
            DispatchQueue.main.async { [weak self, weak scrollView, weak textView] in
                guard let self, let scrollView, let textView else { return }
                self.parent.updateTextLayout(for: scrollView, textView: textView)
            }
        }

        private func stopObservingSizeChanges() {
            guard let observedClipView else { return }

            NotificationCenter.default.removeObserver(
                self,
                name: NSView.frameDidChangeNotification,
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
            guard documentChanged || textView.string != text else { return }

            if documentChanged {
                isApplyingExternalText = true
                defer { isApplyingExternalText = false }

                if textView.string != text {
                    textView.string = text
                }
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
                highlight(textView, preservingViewport: false)
            }
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
            let applyHighlighting = {
                guard let storage = textView.textStorage else { return }
                self.highlighter.highlight(storage, editedRange: editedRange)
            }

            if preservingViewport {
                withPreservedViewport(for: textView, updates: applyHighlighting)
            } else {
                applyHighlighting()
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

            parent.text = textView.string
            highlight(
                textView,
                preservingViewport: false,
                editedRange: editedRange
            )
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else { return }
            let selection = textView.selectedRange()
            guard lastSelectionRange != selection else { return }

            lastSelectionRange = selection
            parent.onSelectionChange(parent.documentURL, selection)
        }

        func sourceTextView(_ textView: NSTextView, handleModifiedLinkClickAt point: CGPoint, with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  let url = linkURL(at: point, in: textView) else {
                return false
            }

            NSWorkspace.shared.open(url)
            return true
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

            parent.updateTextLayout(for: scrollView, textView: textView)
        }
    }
}

@MainActor
private protocol SourceTextViewDelegate: AnyObject {
    func sourceTextView(_ textView: NSTextView, handleModifiedLinkClickAt point: CGPoint, with event: NSEvent) -> Bool
}

private final class SourceTextView: NSTextView {
    weak var modifiedLinkDelegate: SourceTextViewDelegate?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if modifiedLinkDelegate?.sourceTextView(self, handleModifiedLinkClickAt: point, with: event) == true {
            return
        }

        super.mouseDown(with: event)
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
