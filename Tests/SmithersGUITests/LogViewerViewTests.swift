import XCTest
import ViewInspector
@testable import SmithersGUI

extension LogViewerView: @retroactive Inspectable {}

final class LogViewerFormattingTests: XCTestCase {
    func testFileSizeStringFormatsBytesKilobytesAndMegabytes() {
        XCTAssertEqual(LogViewerFormatting.fileSizeString(0), "0 B")
        XCTAssertEqual(LogViewerFormatting.fileSizeString(1023), "1023 B")
        XCTAssertEqual(LogViewerFormatting.fileSizeString(1024), "1 KB")
        XCTAssertEqual(LogViewerFormatting.fileSizeString(1_048_575), "1023 KB")
        XCTAssertEqual(LogViewerFormatting.fileSizeString(1_048_576), "1.0 MB")
        XCTAssertEqual(LogViewerFormatting.fileSizeString(1_572_864), "1.5 MB")
    }
}

final class LogViewerFilteringTests: XCTestCase {
    private func makeEntry(
        level: LogLevel,
        category: LogCategory,
        message: String,
        metadata: [String: String]? = nil
    ) -> LogEntry {
        LogEntry(level: level, category: category, message: message, metadata: metadata)
    }

    func testFilterByLevelAndCategory() {
        let entries = [
            makeEntry(level: .info, category: .network, message: "request completed"),
            makeEntry(level: .error, category: .network, message: "request failed"),
            makeEntry(level: .error, category: .ui, message: "render failed"),
        ]

        let filtered = LogViewerFiltering.filteredEntries(
            entries,
            levelFilter: .error,
            categoryFilter: .network,
            searchText: ""
        )

        XCTAssertEqual(filtered.map(\.message), ["request failed"])
    }

    func testSearchMatchesMessageLevelCategoryAndMetadata() {
        let entries = [
            makeEntry(level: .info, category: .network, message: "request completed"),
            makeEntry(level: .warning, category: .ui, message: "layout shifted"),
            makeEntry(level: .debug, category: .agent, message: "step finished", metadata: ["trace_id": "abc-123"]),
        ]

        XCTAssertEqual(
            LogViewerFiltering.filteredEntries(entries, levelFilter: nil, categoryFilter: nil, searchText: "LAYOUT").map(\.message),
            ["layout shifted"]
        )
        XCTAssertEqual(
            LogViewerFiltering.filteredEntries(entries, levelFilter: nil, categoryFilter: nil, searchText: "warning").map(\.message),
            ["layout shifted"]
        )
        XCTAssertEqual(
            LogViewerFiltering.filteredEntries(entries, levelFilter: nil, categoryFilter: nil, searchText: "network").map(\.message),
            ["request completed"]
        )
        XCTAssertEqual(
            LogViewerFiltering.filteredEntries(entries, levelFilter: nil, categoryFilter: nil, searchText: "abc-123").map(\.message),
            ["step finished"]
        )
        XCTAssertEqual(
            LogViewerFiltering.filteredEntries(entries, levelFilter: nil, categoryFilter: nil, searchText: "trace_id").map(\.message),
            ["step finished"]
        )
    }

    func testSearchRequiresAtLeastOneMatch() {
        let entries = [
            makeEntry(level: .info, category: .network, message: "request completed"),
            makeEntry(level: .debug, category: .agent, message: "step finished"),
        ]

        XCTAssertTrue(
            LogViewerFiltering.filteredEntries(
                entries,
                levelFilter: nil,
                categoryFilter: nil,
                searchText: "missing"
            ).isEmpty
        )
    }
}

@MainActor
final class LogViewerViewSmokeTests: XCTestCase {
    func testLogViewerViewRendersToolbarTitle() throws {
        let view = LogViewerView()
        XCTAssertNoThrow(try view.inspect().find(text: "Logs"))
    }
}
