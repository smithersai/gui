import XCTest

final class RunInspectorE2ETests: SmithersGUIUITestCase {
    func testRunInspectorSupportsModesNodeDetailAndSnapshots() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        waitForElement("runs.inspect.ui-run-active-001").click()
        XCTAssertTrue(element("view.runinspect").waitForExistence(timeout: 5))

        waitForElement("runinspect.nodeInspect.prepare-0").click()
        XCTAssertTrue(element("view.nodeinspect").waitForExistence(timeout: 5))
        waitForElement("nodeinspect.action.close").click()
        XCTAssertFalse(element("view.nodeinspect").waitForExistence(timeout: 1.5))

        waitForElement("runinspect.mode.dagButton").click()
        XCTAssertTrue(element("runinspect.dag.root").waitForExistence(timeout: 5))

        waitForElement("runinspect.action.snapshots").click()
        XCTAssertTrue(element("view.runsnapshots").waitForExistence(timeout: 5))
        waitForElement("runsnapshots.close").click()
        XCTAssertFalse(element("view.runsnapshots").waitForExistence(timeout: 1.5))

        waitForElement("runinspect.close").click()
        XCTAssertFalse(element("view.runinspect").waitForExistence(timeout: 1.5))
    }
}
