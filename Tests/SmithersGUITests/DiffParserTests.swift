import XCTest
@testable import SmithersGUI

final class DiffParserTests: XCTestCase {

    // MARK: - Empty / Whitespace

    func testParseEmptyString() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }

    func testParseWhitespaceOnly() {
        XCTAssertTrue(DiffParser.parse("   \n\n  ").isEmpty)
    }

    // MARK: - Basic diff parsing

    func testParseSingleFileModified() {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,3 +1,4 @@
         line1
        +added line
         line2
         line3
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].fileName, "foo.swift")
        XCTAssertEqual(sections[0].status, .modified)
    }

    func testParseNewFile() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].status, .added)
        XCTAssertEqual(sections[0].fileName, "new.txt")
    }

    func testParseDeletedFile() {
        let diff = """
        diff --git a/old.txt b/old.txt
        deleted file mode 100644
        --- a/old.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -goodbye
        -world
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].status, .deleted)
    }

    func testParseRenamedFile() {
        let diff = """
        diff --git a/old.swift b/new.swift
        rename from old.swift
        rename to new.swift
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].status, .renamed)
    }

    // MARK: - Multi-file diffs

    func testParseMultipleFiles() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,2 @@
         existing
        +new
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].fileName, "a.swift")
        XCTAssertEqual(sections[1].fileName, "b.swift")
    }

    // MARK: - Line numbers

    func testHunkLineNumbersParsed() {
        let diff = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -10,3 +10,4 @@
         context
        +addition
         context2
         context3
        """
        let sections = DiffParser.parse(diff)
        let lines = sections[0].lines

        // First line after hunk is context at oldNum=10, newNum=10
        let contextLine = lines.first(where: { $0.kind == .context })!
        XCTAssertEqual(contextLine.oldLineNum, 10)
        XCTAssertEqual(contextLine.newLineNum, 10)

        let addLine = lines.first(where: { $0.kind == .addition })!
        XCTAssertNil(addLine.oldLineNum)
        XCTAssertEqual(addLine.newLineNum, 11)
    }

    func testDeletionLineNumbers() {
        let diff = """
        diff --git a/x.swift b/x.swift
        --- a/x.swift
        +++ b/x.swift
        @@ -5,3 +5,2 @@
         context
        -removed
         context2
        """
        let sections = DiffParser.parse(diff)
        let delLine = sections[0].lines.first(where: { $0.kind == .deletion })!
        XCTAssertEqual(delLine.oldLineNum, 6)
        XCTAssertNil(delLine.newLineNum)
    }

    // MARK: - Line kinds

    func testAllLineKindsPresent() {
        let diff = """
        diff --git a/f.swift b/f.swift
        --- a/f.swift
        +++ b/f.swift
        @@ -1,3 +1,3 @@
         context
        -old
        +new
        """
        let sections = DiffParser.parse(diff)
        let kinds = Set(sections[0].lines.map(\.kind))
        XCTAssertTrue(kinds.contains(.hunk))
        XCTAssertTrue(kinds.contains(.context))
        XCTAssertTrue(kinds.contains(.addition))
        XCTAssertTrue(kinds.contains(.deletion))
    }

    func testNoNewlineAtEndOfFileSkipped() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let sections = DiffParser.parse(diff)
        // "\ No newline..." lines should be skipped
        let backslashLines = sections[0].lines.filter { $0.text.contains("No newline") }
        XCTAssertTrue(backslashLines.isEmpty)
    }

    // MARK: - File name extraction

    func testFileNameFromPlusPlusB() {
        let diff = """
        diff --git a/old_name.swift b/src/new_name.swift
        --- a/old_name.swift
        +++ b/src/new_name.swift
        @@ -1,1 +1,1 @@
        -old
        +new
        """
        let sections = DiffParser.parse(diff)
        XCTAssertEqual(sections[0].fileName, "src/new_name.swift")
    }

    // MARK: - DiffLine identity

    func testDiffLineIdsAreUnique() {
        let diff = """
        diff --git a/f.swift b/f.swift
        --- a/f.swift
        +++ b/f.swift
        @@ -1,2 +1,2 @@
        -a
        +b
        """
        let sections = DiffParser.parse(diff)
        let ids = sections[0].lines.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // MARK: - DiffFileSection identity

    func testDiffFileSectionIdsAreUnique() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,1 +1,1 @@
        -x
        +y
        diff --git a/b.swift b/b.swift
        --- a/b.swift
        +++ b/b.swift
        @@ -1,1 +1,1 @@
        -x
        +y
        """
        let sections = DiffParser.parse(diff)
        XCTAssertNotEqual(sections[0].id, sections[1].id)
    }

    func testFileStatusRawValues() {
        XCTAssertEqual(DiffFileSection.FileStatus.modified.rawValue, "M")
        XCTAssertEqual(DiffFileSection.FileStatus.added.rawValue, "A")
        XCTAssertEqual(DiffFileSection.FileStatus.deleted.rawValue, "D")
        XCTAssertEqual(DiffFileSection.FileStatus.renamed.rawValue, "R")
        XCTAssertEqual(DiffFileSection.FileStatus.unknown.rawValue, "?")
    }
}
