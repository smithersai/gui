import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension TriggersView: @retroactive Inspectable {}

@MainActor
final class TriggersViewTests: XCTestCase {
    private func projectSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory.appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testTriggersViewRendersRootVStack() throws {
        let view = TriggersView(smithers: SmithersClient(cwd: "/tmp"))
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.vStack())
    }

    func testSourceIncludesLoadingEmptyAndValidationStrings() throws {
        let source = try projectSource("TriggersView.swift")
        XCTAssertTrue(source.contains("Loading triggers..."))
        XCTAssertTrue(source.contains("No cron triggers found"))
        XCTAssertTrue(source.contains("Cron pattern and workflow path are required."))
    }

    func testSourceWiresCreateToggleDeleteActions() throws {
        let source = try projectSource("TriggersView.swift")
        XCTAssertTrue(source.contains("func createCron() async"))
        XCTAssertTrue(source.contains("func toggle(_ cron: CronSchedule) async"))
        XCTAssertTrue(source.contains("func delete(_ cron: CronSchedule) async"))
    }
}
