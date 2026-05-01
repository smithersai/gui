import XCTest

final class LogsTabE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
        ]
    }

    func testLogsStreamAppearsAndNoiseToggleRevealsFilteredStderr() {
        openLiveRunTreeHarness()

        waitForElement("inspector.tab.logs").click()

        XCTAssertTrue(app.staticTexts["Assistant fixture message."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["warning: foo"].exists)

        waitForElement("logs.noiseToggle").click()

        XCTAssertTrue(app.staticTexts["warning: foo"].waitForExistence(timeout: 5))
    }

    func testLogsControlsAreVisible() {
        openLiveRunTreeHarness()

        waitForElement("inspector.tab.logs").click()

        XCTAssertTrue(element("logs.followToggle").waitForExistence(timeout: 3))
        XCTAssertTrue(element("logs.copyTranscript").waitForExistence(timeout: 3))
    }

    private func openLiveRunTreeHarness() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))
        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 8))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))
    }

}
