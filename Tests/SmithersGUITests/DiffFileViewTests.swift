import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension DiffFileView: @retroactive Inspectable {}
extension DiffHunkView: @retroactive Inspectable {}

@MainActor
final class DiffFileViewTests: XCTestCase {

    private func makeLine(kind: UnifiedDiffLine.Kind, text: String, old: Int?, new: Int?) -> UnifiedDiffLine {
        UnifiedDiffLine(kind: kind, text: text, oldLineNumber: old, newLineNumber: new)
    }

    private func makeHunk(lines: [UnifiedDiffLine]) -> UnifiedDiffHunk {
        UnifiedDiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "@@ -1 +1 @@", lines: lines)
    }

    private func makeFile(
        path: String,
        status: UnifiedDiffFileStatus,
        oldPath: String? = nil,
        isBinary: Bool = false,
        binarySize: Int? = nil,
        hunks: [UnifiedDiffHunk]
    ) -> UnifiedDiffFile {
        UnifiedDiffFile(
            path: path,
            oldPath: oldPath,
            status: status,
            modeChanges: [],
            isBinary: isBinary,
            binarySizeBytes: binarySize,
            hunks: hunks,
            partialParse: false
        )
    }

    func testStatusBadgesAddedModifiedDeletedRenamed() throws {
        let added = makeFile(path: "a.txt", status: .added, hunks: [])
        let modified = makeFile(path: "m.txt", status: .modified, hunks: [])
        let deleted = makeFile(path: "d.txt", status: .deleted, hunks: [])
        let renamed = makeFile(path: "new.txt", status: .renamed, oldPath: "old.txt", hunks: [])

        XCTAssertNoThrow(try DiffFileView(file: added, isExpanded: .constant(false)).inspect().find(text: "A"))
        XCTAssertNoThrow(try DiffFileView(file: modified, isExpanded: .constant(false)).inspect().find(text: "M"))
        XCTAssertNoThrow(try DiffFileView(file: deleted, isExpanded: .constant(false)).inspect().find(text: "D"))
        XCTAssertNoThrow(try DiffFileView(file: renamed, isExpanded: .constant(false)).inspect().find(text: "R"))
    }

    func testLineCountsRenderedInHeader() throws {
        let hunk = makeHunk(lines: [
            makeLine(kind: .deletion, text: "old", old: 1, new: nil),
            makeLine(kind: .addition, text: "new", old: nil, new: 1),
        ])
        let file = makeFile(path: "count.txt", status: .modified, hunks: [hunk])
        let view = DiffFileView(file: file, isExpanded: .constant(false))
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "+1"))
        XCTAssertNoThrow(try inspected.find(text: "-1"))
    }

    func testBinaryFileShowsBinaryBadgeAndNoHunks() throws {
        let file = makeFile(
            path: "image.png",
            status: .modified,
            isBinary: true,
            binarySize: 2048,
            hunks: []
        )

        let view = DiffFileView(file: file, isExpanded: .constant(true))
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Binary"))
        XCTAssertNoThrow(try inspected.find(text: "Binary file (2 KB)"))
        XCTAssertThrowsError(try inspected.find(text: "@@ -1 +1 @@"))
    }

    func testLargeFileShowsPaginationToggle() throws {
        let lines = (0..<2_100).map { index in
            makeLine(kind: .context, text: "line \(index)", old: index + 1, new: index + 1)
        }
        let hunk = makeHunk(lines: lines)
        let file = makeFile(path: "large.txt", status: .modified, hunks: [hunk])

        let view = DiffFileView(file: file, isExpanded: .constant(true))
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(button: "Expand remaining 1100 lines"))
    }

    func testToggleExpandUpdatesPerFileBindingIndependently() throws {
        var expandedFirst = false
        var expandedSecond = true

        let first = makeFile(path: "first.txt", status: .modified, hunks: [])
        let second = makeFile(path: "second.txt", status: .modified, hunks: [])

        let firstBinding = Binding(get: { expandedFirst }, set: { expandedFirst = $0 })
        let secondBinding = Binding(get: { expandedSecond }, set: { expandedSecond = $0 })

        let firstView = DiffFileView(file: first, isExpanded: firstBinding)
        let secondView = DiffFileView(file: second, isExpanded: secondBinding)

        try firstView.inspect().find(ViewType.Button.self, where: { button in
            let id = try? button.accessibilityIdentifier()
            return id?.contains("diffFile.toggle") == true
        }).tap()

        XCTAssertTrue(expandedFirst)
        XCTAssertTrue(expandedSecond, "Toggling one file must not mutate another file's state")

        try secondView.inspect().find(ViewType.Button.self, where: { button in
            let id = try? button.accessibilityIdentifier()
            return id?.contains("diffFile.toggle") == true
        }).tap()

        XCTAssertFalse(expandedSecond)
        XCTAssertTrue(expandedFirst)
    }
}
