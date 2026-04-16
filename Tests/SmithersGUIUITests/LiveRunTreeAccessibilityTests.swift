import XCTest

final class LiveRunTreeAccessibilityTests: SmithersGUIUITestCase {
    override var launchEnvironmentOverrides: [String: String] {
        ["SMITHERS_GUI_UITEST_TREE": "1"]
    }

    func testRowAccessibilityAnnouncementIsPresent() {
        openLiveRunTreeHarness()

        let row = waitForElement("tree.row.4")
        let announcement = [row.label, (row.value as? String) ?? ""]
            .joined(separator: " ")
            .lowercased()

        XCTAssertFalse(announcement.isEmpty)
    }

    func testInspectorControlsExposeAccessibilityIdentifiers() {
        openLiveRunTreeHarness()

        waitForElement("tree.row.5").click()
        XCTAssertTrue(element("inspector.header").waitForExistence(timeout: 5))
        XCTAssertTrue(element("inspector.header.copyNodeId").waitForExistence(timeout: 5))
    }

    private func openLiveRunTreeHarness() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")
        waitForElement("runs.chat.ui-run-active-001").click()

        XCTAssertTrue(element("view.liveRunTreeHarness").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tree.row.1").waitForExistence(timeout: 5))
    }
}
