import AppKit
import XCTest

@testable import Markdown

@MainActor
final class SyntaxHighlighterTests: XCTestCase {
    func testHighlightsHeadingAndInlineBold() {
        let storage = makeStorage("# Title with **bold**")

        let headingIndex = index(of: "Title", in: storage)
        let boldIndex = index(of: "bold", in: storage)

        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: headingIndex, effectiveRange: nil) as? NSColor,
            Theme.headingColor
        )
        XCTAssertTrue(
            (storage.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont)?
                .fontDescriptor
                .symbolicTraits
                .contains(.bold) == true
        )
    }

    func testHighlightsMarkdownAndBareLinks() {
        let storage = makeStorage("[link](https://example.com)\nhttps://example.com")

        let markdownLinkIndex = index(of: "link", in: storage)
        let bareLinkIndex = index(of: "https://example.com", in: storage, occurrence: 2)

        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: markdownLinkIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            storage.attribute(.underlineStyle, at: bareLinkIndex, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testHighlightsInlineCodeAndCodeBlocks() {
        let storage = makeStorage("`code`\n\n```swift\nlet value = 1\n```")

        let inlineCodeIndex = index(of: "code", in: storage)
        let codeBlockIndex = index(of: "let value = 1", in: storage)

        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: inlineCodeIndex, effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
        XCTAssertEqual(
            storage.attribute(.backgroundColor, at: codeBlockIndex, effectiveRange: nil) as? NSColor,
            Theme.codeBackground
        )
    }

    func testHighlightsQuotesListsAndHorizontalRules() {
        let storage = makeStorage("> Quote\n  - item\n12. numbered\n---")

        let quoteIndex = index(of: "Quote", in: storage)
        let unorderedMarkerIndex = index(of: "-", in: storage)
        let orderedMarkerIndex = index(of: "12.", in: storage)
        let horizontalRuleIndex = index(of: "---", in: storage)

        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: quoteIndex, effectiveRange: nil) as? NSColor,
            Theme.quoteColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: unorderedMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: orderedMarkerIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: horizontalRuleIndex, effectiveRange: nil) as? NSColor,
            Theme.metaColor
        )
    }

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(preferences: AppPreferences()).highlight(storage)
        return storage
    }

    private func index(of substring: String, in storage: NSTextStorage, occurrence: Int = 1) -> Int {
        let nsText = storage.string as NSString
        var searchRange = NSRange(location: 0, length: nsText.length)

        for _ in 1..<occurrence {
            let found = nsText.range(of: substring, options: [], range: searchRange)
            XCTAssertNotEqual(found.location, NSNotFound)
            let nextLocation = NSMaxRange(found)
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }

        let range = nsText.range(of: substring, options: [], range: searchRange)
        XCTAssertNotEqual(range.location, NSNotFound)
        return range.location
    }
}
