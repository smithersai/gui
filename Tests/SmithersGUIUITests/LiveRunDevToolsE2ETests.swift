import XCTest

final class LiveRunDevToolsE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
        ]
    }

    func testLiveRunRendersTreeInspectorAndScrubber() {
        openLiveRunHarness()

        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 8))
        XCTAssertTrue(element("view.node.inspector").waitForExistence(timeout: 8))
        XCTAssertTrue(element("scrubber.container").waitForExistence(timeout: 8))
    }

    func testSelectingTaskRowShowsInspectorTabs() {
        openLiveRunHarness()

        let treeRow = waitForElement("tree.row.5", timeout: 8)
        treeRow.click()

        XCTAssertTrue(element("inspector.tab.switcher").waitForExistence(timeout: 8))
        XCTAssertTrue(element("inspector.tab.output").exists)
        XCTAssertTrue(element("inspector.tab.diff").exists)
        XCTAssertTrue(element("inspector.tab.logs").exists)
    }

    func testScrubToHistoricalAndReturnToLive() {
        openLiveRunHarness()

        waitForElement("scrubber.test.scrubHistorical", timeout: 8).click()
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("scrubber.container").waitForExistence(timeout: 8))

        if element("scrubber.returnLive").waitForExistence(timeout: 2) {
            element("scrubber.returnLive").click()
            XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
        }
    }

    private func openLiveRunHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001", timeout: 8).click()

        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 8))
    }
}
