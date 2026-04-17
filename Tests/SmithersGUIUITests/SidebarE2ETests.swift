import XCTest

final class SidebarE2ETests: SmithersGUIUITestCase {

    func testSidebarShowsTopLevelDestinations() {
        XCTAssertTrue(app.buttons["nav.Smithers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["nav.VCS"].waitForExistence(timeout: 5))
    }

    func testSidebarSessionTabsVisibleAfterChat() {
        // Click "New Chat" button to create a chat tab
        let newChat = waitForElement("sidebar.newChat")
        newChat.click()
        XCTAssertTrue(element("view.chat").waitForExistence(timeout: 5))
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "Sidebar test")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Sidebar test"].waitForExistence(timeout: 5))

        // Verify a session tab appeared in sidebar
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "workspace.chat:")
        let tabs = app.buttons.matching(predicate)
        XCTAssertGreaterThan(tabs.count, 0)
    }

    func testNavigateToSmithersDashboard() {
        navigate(to: "Smithers", expectedViewIdentifier: "view.dashboard")
    }

    func testNavigateToVCSDashboard() {
        navigate(to: "VCS", expectedViewIdentifier: "view.vcsDashboard")
    }
}
