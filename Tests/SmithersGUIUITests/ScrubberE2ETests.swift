import XCTest

final class ScrubberE2ETests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
        ]
    }

    func testScrubToHistoricalShowsBannerAndOverlay() {
        openLiveRunTreeHarness()

        waitForElement("scrubber.test.scrubHistorical").click()

        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 5))
        XCTAssertTrue(element("historical.overlay").waitForExistence(timeout: 5))
    }

    func testReturnToLiveClearsHistoricalBanner() {
        openLiveRunTreeHarness()

        waitForElement("scrubber.test.scrubHistorical").click()
        XCTAssertTrue(element("scrubber.historical.banner").waitForExistence(timeout: 5))

        waitForElement("scrubber.returnLive").click()

        XCTAssertTrue(waitForElementToDisappear("scrubber.historical.banner", timeout: 5))
        XCTAssertTrue(waitForElementToDisappear("historical.overlay", timeout: 5))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))
        XCTAssertTrue(element("scrubber.slider").waitForExistence(timeout: 5))
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
