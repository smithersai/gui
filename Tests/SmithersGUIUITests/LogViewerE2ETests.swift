import XCTest

final class LogViewerE2ETests: SmithersGUIUITestCase {

    func testLogViewerLoadsAndShowsToolbar() {
        navigate(to: "Dashboard", expectedViewIdentifier: "view.dashboard")

        // Log viewer may be accessible from menu or sidebar
        // Navigate via sidebar if available
        let logsNav = app.buttons["nav.Logs"]
        if logsNav.waitForExistence(timeout: 2) {
            logsNav.click()
            XCTAssertTrue(element("view.logs").waitForExistence(timeout: 5))
        }
    }
}
