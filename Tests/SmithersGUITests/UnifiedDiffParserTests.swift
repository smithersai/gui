import XCTest
@testable import SmithersGUI

final class UnifiedDiffParserTests: XCTestCase {

    func testEmptyDiffStringProducesNoHunks() throws {
        let parsed = try UnifiedDiffParser.parse(diff: "", path: "empty.txt")
        XCTAssertEqual(parsed.file.hunks.count, 0)
        XCTAssertEqual(parsed.file.renderedLineCount, 0)
    }

    func testSingleHunkWithoutContextParsesLineNumbers() throws {
        let diff = """
        @@ -3,1 +3,1 @@
        -old
        +new
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "single.txt")
        XCTAssertEqual(parsed.file.hunks.count, 1)
        let hunk = try XCTUnwrap(parsed.file.hunks.first)
        XCTAssertEqual(hunk.oldStart, 3)
        XCTAssertEqual(hunk.newStart, 3)
        XCTAssertEqual(hunk.lines.count, 2)
    }

    func testMultipleHunksInSameFile() throws {
        let diff = """
        @@ -1,2 +1,2 @@
        -a
        +b
        @@ -10,2 +10,3 @@
         x
        +y
         z
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "multi.txt")
        XCTAssertEqual(parsed.file.hunks.count, 2)
        XCTAssertEqual(parsed.file.additions, 2)
        XCTAssertEqual(parsed.file.deletions, 1)
    }

    func testOnlyAdditions() throws {
        let diff = """
        @@ -0,0 +1,3 @@
        +line1
        +line2
        +line3
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "added.txt", operation: .add)
        XCTAssertEqual(parsed.file.status, .added)
        XCTAssertEqual(parsed.file.additions, 3)
        XCTAssertEqual(parsed.file.deletions, 0)
    }

    func testOnlyDeletions() throws {
        let diff = """
        @@ -7,2 +0,0 @@
        -line1
        -line2
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "deleted.txt", operation: .delete)
        XCTAssertEqual(parsed.file.status, .deleted)
        XCTAssertEqual(parsed.file.additions, 0)
        XCTAssertEqual(parsed.file.deletions, 2)
    }

    func testRenameHeadersCaptureOldAndNewPaths() throws {
        let diff = """
        diff --git a/old-name.txt b/new-name.txt
        rename from old-name.txt
        rename to new-name.txt
        @@ -1 +1 @@
        -hello
        +hello world
        """

        let parsed = try UnifiedDiffParser.parse(
            diff: diff,
            path: "new-name.txt",
            operation: .rename,
            oldPath: "old-name.txt"
        )
        XCTAssertEqual(parsed.file.status, .renamed)
        XCTAssertEqual(parsed.file.oldPath, "old-name.txt")
        XCTAssertEqual(parsed.file.path, "new-name.txt")
    }

    func testModeChangeHeaderIsRecorded() throws {
        let diff = """
        old mode 100644
        new mode 100755
        @@ -1 +1 @@
        -echo hi
        +echo hi
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "script.sh")
        XCTAssertEqual(parsed.file.modeChanges, ["old mode 100644", "new mode 100755"])
    }

    func testHunkHeaderWithoutCountsDefaultsToOne() throws {
        let diff = """
        @@ -12 +12 @@
        -old
        +new
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "default-count.txt")
        let hunk = try XCTUnwrap(parsed.file.hunks.first)
        XCTAssertEqual(hunk.oldCount, 1)
        XCTAssertEqual(hunk.newCount, 1)
    }

    func testNoNewlineMarkerIgnoredAsContent() throws {
        let diff = """
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "nonewline.txt")
        let containsMarker = parsed.file.hunks
            .flatMap(\.lines)
            .contains { $0.text.contains("No newline at end of file") }
        XCTAssertFalse(containsMarker)
    }

    func testNonASCIIContentPreserved() throws {
        let diff = """
        @@ -1 +1 @@
        -résumé 日本語
        +résumé ✓ 日本語
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "unicode.txt")
        let added = parsed.file.hunks.flatMap(\.lines).first { $0.kind == .addition }
        XCTAssertEqual(added?.text, "résumé ✓ 日本語")
    }

    func testVeryLongLinePreserved() throws {
        let longLine = String(repeating: "x", count: 8_000)
        let diff = """
        @@ -1 +1 @@
        -short
        +\(longLine)
        """

        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "long.txt")
        let added = parsed.file.hunks.flatMap(\.lines).first { $0.kind == .addition }
        XCTAssertEqual(added?.text.count, 8_000)
        XCTAssertEqual(added?.text, longLine)
    }

    func testCRLFLineEndingsNormalizeToLF() throws {
        let diff = "@@ -1,1 +1,1 @@\r\n-old\r\n+new\r\n"
        let parsed = try UnifiedDiffParser.parse(diff: diff, path: "crlf.txt")
        XCTAssertEqual(parsed.file.hunks.count, 1)
        XCTAssertEqual(parsed.file.hunks[0].lines.count, 2)
        XCTAssertEqual(parsed.file.hunks[0].lines[1].text, "new")
    }

    func testMalformedHunkHeaderThrowsWithLineNumber() {
        let diff = """
        @@ malformed header @@
        +line
        """

        XCTAssertThrowsError(try UnifiedDiffParser.parse(diff: diff, path: "bad.txt")) { error in
            guard case DiffParseError.malformedHunkHeader(let line, _) = error else {
                return XCTFail("Expected malformed hunk header error")
            }
            XCTAssertEqual(line, 1)
        }
    }
}
