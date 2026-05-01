import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

final class ViewLifecycleLoggerTests: XCTestCase {
    func testLogLifecycleModifierPreservesWrappedContent() throws {
        let view = Text("Lifecycle body").logLifecycle("LifecycleTestView")
        XCTAssertNoThrow(try view.inspect().find(text: "Lifecycle body"))
    }

    func testLifecycleLoggerSourceContainsAppearAndDisappearHooks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory.appendingPathComponent("ViewLifecycleLogger.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(".onAppear"))
        XCTAssertTrue(source.contains(".onDisappear"))
        XCTAssertTrue(source.contains("appeared"))
        XCTAssertTrue(source.contains("disappeared"))
    }
}
