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
    let preferences: AppPreferences

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
        updateTextLayout(for: scrollView, textView: textView)
        context.coordinator.primeAppearanceSignature()
        context.coordinator.highlight(textView, preservingViewport: false)

        controller.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? SourceTextView else { return }

        context.coordinator.parent = self
        configure(textView, coordinator: context.coordinator)
        updateTextLayout(for: nsView, textView: textView)
        context.coordinator.applyExternalTextIfNeeded(text, to: textView)
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
    final class Coordinator: NSObject, NSTextViewDelegate, SourceTextViewDelegate {
        private struct AppearanceSignature: Equatable {
            let fontChoice: MonospacedFontChoice
            let fontSize: Double
            let lineSpacing: Double
            let readableWidth: Double
        }

        var parent: SourceEditorView
        private var isApplyingExternalText = false
        private var lastAppearanceSignature: AppearanceSignature?

        init(_ parent: SourceEditorView) {
            self.parent = parent
        }

        private var highlighter: SyntaxHighlighter {
            SyntaxHighlighter(preferences: parent.preferences)
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

        func highlight(_ textView: NSTextView, preservingViewport: Bool = true) {
            let applyHighlighting = {
                guard let storage = textView.textStorage else { return }
                self.highlighter.highlight(storage)
            }

            if preservingViewport {
                withPreservedViewport(for: textView, updates: applyHighlighting)
            } else {
                applyHighlighting()
                textView.scrollRangeToVisible(textView.selectedRange())
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isApplyingExternalText else { return }

            parent.text = textView.string
            highlight(textView)
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
