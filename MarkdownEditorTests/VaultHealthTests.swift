import Foundation
import XCTest

@testable import Markdown

final class VaultHealthTests: XCTestCase {
    func testFindsBrokenLinksMissingAttachmentsDuplicatesAndFrontmatter() throws {
        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }

        let notes = [
            VaultHealthNote(
                url: vault.appendingPathComponent("One.md"),
                title: "Same",
                body: "---\ntitle: Broken\n[[Missing]]\n![](missing.png)"
            ),
            VaultHealthNote(
                url: vault.appendingPathComponent("Two.md"),
                title: "Same",
                body: "# Two"
            ),
        ]

        let report = VaultHealthScanner.scan(vaultURL: vault, notes: notes)
        XCTAssertGreaterThanOrEqual(report.errorCount, 3)
        XCTAssertGreaterThanOrEqual(report.warningCount, 1)
        XCTAssertTrue(report.issues.contains { $0.title == "Unterminated frontmatter" })
        XCTAssertTrue(report.issues.contains { $0.title == "Duplicate note target" })
    }
}
