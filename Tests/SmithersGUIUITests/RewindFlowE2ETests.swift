import XCTest

final class RewindFlowE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
        ]
    }

    func testSuccessfulRewindReturnsToLiveMode() {
        openLiveRunTreeHarness()
        enterHistoricalMode()

        waitForElement("scrubber.rewind").click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Rewind"].waitForExistence(timeout: 5))

        app.buttons["Rewind"].click()

        XCTAssertTrue(waitForElementToDisappear("scrubber.historical.banner", timeout: 6))
    }

    func testDecliningRewindLeavesHistoricalStateUnchanged() {
        openLiveRunTreeHarness()
        enterHistoricalMode()

        waitForElement("scrubber.rewind").click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()

        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 2))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("scrubber.slider").waitForExistence(timeout: 5))
    }

    private func enterHistoricalMode() {
        waitForElement("scrubber.test.scrubHistorical").click()
        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 5))
    }

    private func waitForElementToDisappear(_ identifier: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element(identifier).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}

final class RewindFlowErrorE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
            "SMITHERS_GUI_UITEST_REWIND_ERROR": "network",
        ]
    }

    func testErrorBannerRetryPathRecovers() {
        openLiveRunTreeHarness()
        enterHistoricalMode()

        waitForElement("scrubber.rewind").click()
        XCTAssertTrue(app.buttons["Rewind"].waitForExistence(timeout: 5))
        app.buttons["Rewind"].click()

        XCTAssertTrue(element("scrubber.error.banner").waitForExistence(timeout: 5))
        waitForElement("scrubber.error.retry").click()

        XCTAssertTrue(app.buttons["Rewind"].waitForExistence(timeout: 5))
        app.buttons["Rewind"].click()

        XCTAssertTrue(waitForElementToDisappear("scrubber.error.banner", timeout: 6))
        XCTAssertTrue(waitForElementToDisappear("scrubber.historical.banner", timeout: 6))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("scrubber.slider").waitForExistence(timeout: 5))
    }

    private func enterHistoricalMode() {
        waitForElement("scrubber.test.scrubHistorical").click()
        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 5))
    }

    private func waitForElementToDisappear(_ identifier: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element(identifier).exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }
}

final class RewindFinishedRunE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
            "SMITHERS_GUI_UITEST_TREE_FINISHED": "1",
        ]
    }

    func testRewindButtonHiddenForFinishedRuns() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        waitForElement("scrubber.test.scrubHistorical").click()

        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 5))
        XCTAssertFalse(element("scrubber.rewind").exists)
    }
}
