import XCTest
import ViewInspector
@testable import SmithersGUI

extension UnifiedDiffView: @retroactive Inspectable {}

@MainActor
final class UnifiedDiffViewTests: XCTestCase {
    func testEmptyDiffRendersNoChangesMessage() throws {
        let view = UnifiedDiffView(diffText: " \n ")
        XCTAssertNoThrow(try view.inspect().find(text: "(no changes)"))
    }

    func testUnifiedDiffViewRendersStatsFileNameAndChangedLines() throws {
        let diff = """
        diff --git a/foo.swift b/foo.swift
        --- a/foo.swift
        +++ b/foo.swift
        @@ -1,2 +1,2 @@
        -old line
        +new line
         context
        """

        let inspected = try UnifiedDiffView(diffText: diff).inspect()
        XCTAssertNoThrow(try inspected.find(text: "1 file changed"))
        XCTAssertNoThrow(try inspected.find(text: "+1"))
        XCTAssertNoThrow(try inspected.find(text: "-1"))
        XCTAssertNoThrow(try inspected.find(text: "foo.swift"))
        XCTAssertNoThrow(try inspected.find(text: "old line"))
        XCTAssertNoThrow(try inspected.find(text: "new line"))
        XCTAssertNoThrow(try inspected.find(text: "context"))
    }
}
