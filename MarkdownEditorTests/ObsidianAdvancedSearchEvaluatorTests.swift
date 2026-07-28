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

    func testPlainTextUsesFastRankedSearch() {
        let entries = [
            entry(title: "Body First", path: "Body First.md", body: "A note about markets."),
            entry(title: "Markets Archive", path: "Markets Archive.md", body: ""),
            entry(title: "Markets", path: "Markets.md", body: ""),
        ]

        let results = ObsidianAdvancedSearchEvaluator.search(entries, query: "markets")

        XCTAssertEqual(results.map(\.title), ["Markets", "Markets Archive", "Body First"])
        XCTAssertEqual(results.map(\.isBodyMatch), [false, false, true])
    }

    func testPlainTextRoutingRecognizesOnlyActualAdvancedSyntax() {
        XCTAssertEqual(
            ObsidianAdvancedSearchParser.plainTextQuery(in: "interface craft"),
            "interface craft"
        )
        XCTAssertEqual(
            ObsidianAdvancedSearchParser.plainTextQuery(in: "\"exact phrase\""),
            "exact phrase"
        )
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "tag:swift"))
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "project OR archive"))
        XCTAssertNil(ObsidianAdvancedSearchParser.plainTextQuery(in: "-draft"))
    }

    func testAdvancedSearchUsesCachedSearchMetadata() {
        let cachedMetadata = ObsidianSearchMetadata(tags: ["swift"], properties: [:])
        let entries = [
            entry(
                title: "Cached",
                path: "Cached.md",
                body: "Body deliberately contains no tag.",
                searchMetadata: cachedMetadata
            )
        ]

        XCTAssertEqual(
            ObsidianAdvancedSearchEvaluator.search(entries, query: "tag:swift").map(\.title),
            ["Cached"]
        )
    }

    private func entry(
        title: String,
        path: String,
        body: String,
        searchMetadata: ObsidianSearchMetadata? = nil
    ) -> NoteSearchEntry {
        let url = URL(fileURLWithPath: "/tmp/\(path)")
        return NoteSearchEntry(
            id: url,
            url: url,
            title: title,
            relativePath: path,
            body: body,
            foldedTitle: Workspace.foldedForSearch(title),
            foldedTitleHaystack: Workspace.foldedForSearch("\(title)\n\(path)"),
            searchMetadata: searchMetadata
        )
    }
}
