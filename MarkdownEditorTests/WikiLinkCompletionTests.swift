import Foundation
import XCTest

@testable import Markdown

final class WikiLinkCompletionTests: XCTestCase {
    func testFindsPartialRangeAfterLastOpeningWikiLink() throws {
        let text = "See [[Pro"
        let range = try XCTUnwrap(WikiLinkCompletion.partialRange(
            in: text,
            selection: NSRange(location: (text as NSString).length, length: 0)
        ))
        XCTAssertEqual((text as NSString).substring(with: range), "Pro")
    }

    func testSuppressesCompletionAfterClosingBracketOrOnAnotherLine() {
        let closed = "[[Project]]"
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: closed,
            selection: NSRange(location: (closed as NSString).length, length: 0)
        ))

        let anotherLine = "[[Project\nNext"
        XCTAssertNil(WikiLinkCompletion.partialRange(
            in: anotherLine,
            selection: NSRange(location: (anotherLine as NSString).length, length: 0)
        ))
    }

    func testRanksPrefixMatchesAndAddsClosingBrackets() {
        XCTAssertEqual(
            WikiLinkCompletion.suggestions(
                for: "pro",
                candidates: ["Work Project", "Profile", "Projects"]
            ),
            ["Profile]]", "Projects]]", "Work Project]]"]
        )
    }
}
