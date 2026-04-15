import XCTest

final class SidebarE2ETests: SmithersGUIUITestCase {

    func testSidebarSectionsExpandCollapse() {
        // Try to expand/collapse Smithers section
        let smithersSection = app.buttons["sidebar.section.SMITHERS"]
        if smithersSection.waitForExistence(timeout: 3) {
            smithersSection.click()
            // Click again to toggle
            smithersSection.click()
        }

        // VCS section
        let vcsSection = app.buttons["sidebar.section.VCS"]
        if vcsSection.waitForExistence(timeout: 3) {
            vcsSection.click()
            vcsSection.click()
        }
    }

    func testSidebarSessionTabsVisibleAfterChat() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "Sidebar test")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Sidebar test"].waitForExistence(timeout: 5))

        // Verify a session tab appeared in sidebar
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "tab.chat:")
        let tabs = app.buttons.matching(predicate)
        XCTAssertGreaterThan(tabs.count, 0)
    }

    func testNavigateToAllVCSViews() {
        let vcsDestinations: [(label: String, view: String)] = [
            ("Changes", "view.changes"),
            ("JJHub Workflows", "view.jjhubWorkflows"),
            ("Landings", "view.landings"),
            ("Issues", "view.issues"),
        ]

        for dest in vcsDestinations {
            navigate(to: dest.label, expectedViewIdentifier: dest.view)
        }
    }

    func testNavigateToSmithersViews() {
        let destinations: [(label: String, view: String)] = [
            ("Agents", "view.agents"),
            ("Triggers", "view.triggers"),
            ("SQL Browser", "view.sql"),
        ]

        for dest in destinations {
            navigate(to: dest.label, expectedViewIdentifier: dest.view)
        }
    }
}
