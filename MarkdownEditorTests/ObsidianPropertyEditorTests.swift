import XCTest

@testable import Markdown

final class ObsidianPropertyEditorTests: XCTestCase {
    func testAddsFrontmatterWithoutChangingBody() throws {
        let updated = try ObsidianPropertyEditor.setting(
            key: "tags",
            value: .strings(["work", "deep/research"]),
            in: "# Note\nBody"
        )
        XCTAssertEqual(updated, "---\ntags: [\"work\", \"deep/research\"]\n---\n# Note\nBody")
    }

    func testReplacesListPropertyLosslesslyAroundOtherProperties() throws {
        let markdown = "---\r\ntitle: Keep\r\ntags:\r\n  - old\r\nstatus: active\r\n---\r\nBody"
        let updated = try ObsidianPropertyEditor.setting(
            key: "tags",
            value: .strings(["new"]),
            in: markdown
        )
        XCTAssertEqual(updated, "---\r\ntitle: Keep\r\ntags: [\"new\"]\r\nstatus: active\r\n---\r\nBody")
    }

    func testRemovesPropertyAndPreservesRest() throws {
        XCTAssertEqual(
            try ObsidianPropertyEditor.setting(
                key: "aliases",
                value: nil,
                in: "---\naliases: [A, B]\nstatus: active\n---\nBody"
            ),
            "---\nstatus: active\n---\nBody"
        )
    }
}
