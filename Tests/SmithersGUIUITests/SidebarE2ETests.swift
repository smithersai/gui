import XCTest

// NOTE: `testSidebarSessionTabsVisibleAfterChat` was removed along with the
// built-in chat feature (sidebar.newChat / view.chat no longer exist).

final class SidebarE2ETests: SmithersGUIUITestCase {

    func testSidebarHidesSmithersAndVCSButtons() {
        XCTAssertFalse(app.buttons["nav.Smithers"].exists)
        XCTAssertFalse(app.buttons["nav.VCS"].exists)
    }

    func testCommandPaletteNavigatesToSmithersDashboard() {
        navigateViaPalette(
            query: "dashboard",
            expectedViewIdentifier: "view.dashboard"
        )
    }

    func testCommandPaletteNavigatesToVCSDashboard() {
        navigateViaPalette(
            query: "vcs dashboard",
            expectedViewIdentifier: "view.vcsDashboard"
        )
    }

    func testSidebarPlusOpensCommandPaletteWithNewTabItems() {
        waitForElement("sidebar.newTabPlus").click()

        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))
        XCTAssertFalse(element("newTabPicker.root").exists)
        XCTAssertTrue(element("commandPalette.item.new-tab.terminal").waitForExistence(timeout: 3))
        XCTAssertTrue(element("commandPalette.item.new-tab.browser").waitForExistence(timeout: 3))
    }

    func testCommandPaletteNewEntryExpandsInPlaceToNewTabItems() {
        app.typeKey("p", modifierFlags: .command)

        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))
        let newItem = waitForElement("commandPalette.item.command.new", timeout: 3)
        newItem.click()

        XCTAssertTrue(element("commandPalette.root").waitForExistence(timeout: 3))
        XCTAssertFalse(element("newTabPicker.root").exists)
        XCTAssertTrue(element("commandPalette.item.new-tab.terminal").waitForExistence(timeout: 3))
        XCTAssertTrue(element("commandPalette.item.new-tab.browser").waitForExistence(timeout: 3))
    }
}
