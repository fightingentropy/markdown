import Foundation
import XCTest

@testable import Markdown

final class MarkdownTaskTogglerTests: XCTestCase {
    func testTogglesOpenAndCompletedTasks() {
        let text = "- [ ] One\n- [x] Two"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )
        XCTAssertEqual(result.text, "- [x] One\n- [ ] Two")
    }

    func testTurnsPlainLineIntoTaskPreservingIndentation() {
        let text = "  Remember this"
        let result = MarkdownTaskToggler.toggle(
            in: text,
            selection: NSRange(location: 4, length: 0)
        )
        XCTAssertEqual(result.text, "  - [ ] Remember this")
    }
}
