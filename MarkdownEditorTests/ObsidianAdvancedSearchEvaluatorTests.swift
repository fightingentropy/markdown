import Foundation
import XCTest

@testable import Markdown

final class ObsidianAdvancedSearchEvaluatorTests: XCTestCase {
    func testFiltersByTagPropertyTaskPathAndExclusion() {
        let entries = [
            entry(
                title: "Project",
                path: "work/Project.md",
                body: "---\ntags: [swift]\nstatus: active\n---\n- [ ] Ship it"
            ),
            entry(
                title: "Archive",
                path: "archive/Old.md",
                body: "---\ntags: [swift, archive]\nstatus: done\n---\n- [x] Done"
            )
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(
            entries,
            query: "tag:swift property:status=active task:open path:work -tag:archive"
        )

        XCTAssertEqual(results.map(\.title), ["Project"])
    }

    func testSupportsOrGroupsAndExactPhraseSnippet() {
        let entries = [
            entry(title: "One", path: "One.md", body: "The exact phrase is here."),
            entry(title: "Two", path: "Two.md", body: "Nothing relevant."),
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(
            entries,
            query: "\"exact phrase\" OR file:Two"
        )

        XCTAssertEqual(results.map(\.title), ["One", "Two"])
        XCTAssertTrue(results[0].subtitle?.contains("exact phrase") == true)
    }

    private func entry(title: String, path: String, body: String) -> NoteSearchEntry {
        let url = URL(fileURLWithPath: "/tmp/\(path)")
        return NoteSearchEntry(
            id: url,
            url: url,
            title: title,
            relativePath: path,
            body: body,
            foldedTitleHaystack: title.lowercased()
        )
    }
}
