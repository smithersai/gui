import XCTest

final class LiveRunDevToolsMemoryTests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        [
            "SMITHERS_GUI_UITEST_TREE": "1",
            "SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH": "1",
            "SMITHERS_GUI_UITEST_TREE_STREAM": "0",
        ]
    }

    func testRepeatedLiveRunScrubStaysResponsive() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))

        for _ in 0..<10 {
            waitForElement("scrubber.test.scrubHistorical", timeout: 8).click()
            XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
            XCTAssertTrue(element("scrubber.container").waitForExistence(timeout: 5))
        }
    }

    func testLiveRunScrubMemoryMetric() {
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 8))

        measure(metrics: [XCTMemoryMetric()]) {
            waitForElement("scrubber.test.scrubHistorical", timeout: 8).click()
            XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
            XCTAssertTrue(element("scrubber.container").waitForExistence(timeout: 5))
        }
    }
}
