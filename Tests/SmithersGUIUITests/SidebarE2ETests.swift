import XCTest

// NOTE: `testSidebarSessionTabsVisibleAfterChat` was removed along with the
// built-in chat feature (sidebar.newChat / view.chat no longer exist).

final class SidebarE2ETests: SmithersGUIUITestCase {

    func testSidebarShowsTopLevelDestinations() {
        XCTAssertTrue(app.buttons["nav.Smithers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nav.VCS"].waitForExistence(timeout: 5))
    }

    func testNavigateToSmithersDashboard() {
        navigate(to: "Smithers", expectedViewIdentifier: "view.dashboard")
    }

    func testNavigateToVCSDashboard() {
        navigate(to: "VCS", expectedViewIdentifier: "view.vcsDashboard")
    }
}
