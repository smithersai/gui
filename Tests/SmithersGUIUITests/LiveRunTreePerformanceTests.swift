import XCTest

final class LiveRunTreePerformanceTests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        ["SMITHERS_GUI_UITEST_TREE": "1"]
    }

    func testTreeFirstPaintUnderBudget() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        let start = Date()
        waitForElement("runs.chat.ui-run-active-001").click()
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))

        let elapsedMs = Date().timeIntervalSince(start) * 1000
        XCTAssertLessThan(elapsedMs, 5_000)
    }

    func testFixtureStreamContinuesAdvancingSequence() {
        openLiveRunTreeHarness()

        let row = waitForElement("tree.row.5")
        guard let initialState = rowStateToken(for: row) else {
            XCTFail("Could not infer initial row state")
            return
        }
        XCTAssertTrue(waitForRowStateChange(row: row, from: initialState, timeout: 3.0))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tree.row.7").waitForExistence(timeout: 5))
    }

    private func rowStateToken(for row: XCUIElement) -> String? {
        let text = [row.label, (row.value as? String) ?? ""]
            .joined(separator: " ")
            .lowercased()
        for state in ["pending", "running", "finished", "failed", "blocked", "waiting approval", "cancelled"] {
            if text.contains(state) {
                return state
            }
        }
        return nil
    }

    private func waitForRowStateChange(row: XCUIElement, from initialState: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = rowStateToken(for: row), current != initialState {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }
}
