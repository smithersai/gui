import XCTest

final class LiveRunTreeE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        ["SMITHERS_GUI_UITEST_TREE": "1"]
    }

    func testTreeRendersAndSelectingRowUpdatesInspector() {
        openLiveRunTreeHarness()

        let treeRow = waitForElement("tree.row.5")
        treeRow.click()

        XCTAssertTrue(element("inspector.header").waitForExistence(timeout: 5))
        XCTAssertTrue(element("inspector.header.copyNodeId").waitForExistence(timeout: 5))
    }

    func testKeyboardNavigationAndSearchShortcut() {
        openLiveRunTreeHarness()

        waitForElement("tree.row.1").click()

        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.rightArrow, modifierFlags: [])

        app.typeKey("f", modifierFlags: .command)
        app.typeText("review")

        XCTAssertTrue(app.buttons["Clear search"].waitForExistence(timeout: 2))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.buttons["Clear search"].waitForExistence(timeout: 2))
    }

    func testTreeUpdatesInRealTimeFromFixtureStream() {
        openLiveRunTreeHarness()

        Thread.sleep(forTimeInterval: 1.2)
        waitForElement("tree.row.7").click()
        XCTAssertTrue(element("inspector.header.state").waitForExistence(timeout: 5))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))
    }

}
