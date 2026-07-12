import Foundation
import XCTest

@testable import Markdown

final class ObsidianMetadataCoreTests: XCTestCase {
    func testParsesCommonPropertiesAndPreservesFrontmatterExactly() throws {
        let expectedFrontmatter = """
        ---
        title: "Project Atlas"
        aliases:
          - Atlas
          - "Project A"
        tags: [work, "deep/research"]
        status: active
        score: 4.5
        published: false
        ---

        """
        let markdown = expectedFrontmatter + """
        # Body
        Text #Swift and #deep/research.
        """

        let metadata = ObsidianMetadataParser.parse(markdown)
        let frontmatter = try XCTUnwrap(metadata.frontmatter)

        XCTAssertEqual(metadata.title, "Project Atlas")
        XCTAssertEqual(metadata.aliases, ["Atlas", "Project A"])
        XCTAssertEqual(metadata.frontmatterTags, ["work", "deep/research"])
        XCTAssertEqual(metadata.inlineTags, ["Swift", "deep/research"])
        XCTAssertEqual(metadata.tags, ["work", "deep/research", "Swift"])
        XCTAssertEqual(metadata.properties["status"], .string("active"))
        XCTAssertEqual(metadata.properties["score"], .number(4.5))
        XCTAssertEqual(metadata.properties["published"], .boolean(false))
        XCTAssertEqual(String(markdown[Range(frontmatter.sourceRange, in: markdown)!]), frontmatter.rawBlock)
        XCTAssertEqual(frontmatter.rawBlock, expectedFrontmatter)
    }

    func testFrontmatterKeepsCRLFAndUnsupportedYamlRaw() throws {
        let markdown = "---\r\ntitle: Note\r\ncomplex:\r\n  nested: value\r\n---\r\nBody"
        let metadata = ObsidianMetadataParser.parse(markdown)
        let frontmatter = try XCTUnwrap(metadata.frontmatter)

        XCTAssertTrue(frontmatter.rawBlock.contains("\r\n"))
        XCTAssertEqual(frontmatter.value(forKey: "TITLE"), .string("Note"))
        XCTAssertEqual(frontmatter.value(forKey: "complex"), .raw("\n  nested: value"))
    }

    func testUnterminatedFrontmatterIsNotGuessed() {
        let markdown = "---\ntitle: Not metadata\n# Heading"
        let metadata = ObsidianMetadataParser.parse(markdown)

        XCTAssertNil(metadata.frontmatter)
        XCTAssertNil(metadata.title)
    }

    func testInlineTagsIgnoreCodeEscapesUrlsAndNumericOnlyTags() {
        let markdown = """
        # Heading, not a tag
        Keep #alpha and #nested/topic plus #café.
        Ignore `#inline` and \\#escaped and https://example.com/#fragment and #2026.
        ```swift
        let tag = "#fenced"
        ```
        """

        let metadata = ObsidianMetadataParser.parse(markdown)
        XCTAssertEqual(metadata.inlineTags, ["alpha", "nested/topic", "café"])
    }

    func testBuildsNestedOutlineAndIgnoresCodeFences() {
        let markdown = """
        # One
        ## Child ###
        ```md
        # Not a heading
        ```
        ### Grandchild
        ## Sibling
        Setext
        ------
        # Two
        """

        let outline = ObsidianMetadataParser.parse(markdown).outline
        XCTAssertEqual(outline.map(\.title), ["One", "Two"])
        XCTAssertEqual(outline[0].children.map(\.title), ["Child", "Sibling", "Setext"])
        XCTAssertEqual(outline[0].children[0].children.map(\.title), ["Grandchild"])
        XCTAssertEqual(outline[0].lineNumber, 1)
    }

    func testRendersBuiltInTemplateVariablesDeterministically() throws {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2026
        components.month = 7
        components.day = 12
        components.hour = 21
        components.minute = 7
        let date = try XCTUnwrap(components.date)

        let rendered = ObsidianTemplateRenderer.render(
            "# {{title}}\nCreated {{date}} at {{time}}",
            title: "Daily Note",
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(rendered, "# Daily Note\nCreated 2026-07-12 at 21:07")
    }

    func testParsesAdvancedSearchIntoAndOrGroups() {
        let query = ObsidianAdvancedSearchParser.parse(
            "file:\"Project Plan\" path:work tag:#swift property:status=active task:todo \"exact phrase\" -tag:archive -draft OR property:priority=high"
        )

        XCTAssertEqual(query.groups.count, 2)
        XCTAssertEqual(
            query.groups[0].terms,
            [
                ObsidianSearchTerm(predicate: .file(value: "Project Plan", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .path(value: "work", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .tag(value: "swift", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .property(name: "status", value: "active", quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.open), isExcluded: false),
                ObsidianSearchTerm(predicate: .text(value: "exact phrase", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .tag(value: "archive", quoted: false), isExcluded: true),
                ObsidianSearchTerm(predicate: .text(value: "draft", quoted: false), isExcluded: true),
            ]
        )
        XCTAssertEqual(
            query.groups[1].terms,
            [ObsidianSearchTerm(predicate: .property(name: "priority", value: "high", quoted: false), isExcluded: false)]
        )
    }

    func testSearchKeepsQuotedOrAndModelsTaskAndPropertyPresence() {
        let query = ObsidianAdvancedSearchParser.parse("\"OR\" property:status task:done task:custom")

        XCTAssertEqual(query.groups.count, 1)
        XCTAssertEqual(
            query.groups[0].terms,
            [
                ObsidianSearchTerm(predicate: .text(value: "OR", quoted: true), isExcluded: false),
                ObsidianSearchTerm(predicate: .property(name: "status", value: nil, quoted: false), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.done), isExcluded: false),
                ObsidianSearchTerm(predicate: .task(.text("custom")), isExcluded: false),
            ]
        )
    }
}
