import XCTest

final class LiveRunDevToolsAccessibilityE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
        ]
    }

    func testPrimaryControlsExposeAccessibilityIdentifiers() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 8))
        XCTAssertTrue(element("scrubber.slider").waitForExistence(timeout: 8))
        XCTAssertTrue(element("inspector.tab.switcher").waitForExistence(timeout: 8))
    }

    func testTreeRowsAndInspectorAreKeyboardReachable() {
        let row = waitForElement("tree.row.5", timeout: 8)
        row.click()

        app.typeKey(.rightArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(element("view.node.inspector").waitForExistence(timeout: 8))
        XCTAssertTrue(element("inspector.tab.logs").exists)
    }
}
