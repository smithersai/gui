import XCTest

// NOTE: `testNewChatCreatesSessionAndSessionSearchFindsIt` and
// `testCommandNCreatesNewChat` were removed along with the built-in chat
// feature (sidebar.newChat / workspace.chat: session tabs no longer exist).

final class WorkspacesSessionKeyboardE2ETests: SmithersGUIUITestCase {
    func testWorkspacesTabsAndCreateWorkspaceForm() {
        navigate(to: "Workspaces", expectedViewIdentifier: "view.workspaces")

        XCTAssertTrue(app.buttons["workspaces.mode.Workspaces"].exists)
        XCTAssertTrue(app.buttons["workspaces.mode.Snapshots"].exists)
        XCTAssertTrue(app.staticTexts["Main Workspace"].waitForExistence(timeout: 5))

        waitForElement("workspaces.newButton").click()
        XCTAssertTrue(element("workspaces.create.form").waitForExistence(timeout: 5))
        typeInto("workspaces.create.name", "UI Test Workspace")
        waitForElement("workspaces.create.submit").click()
        XCTAssertTrue(app.staticTexts["UI Test Workspace"].waitForExistence(timeout: 5))

        app.buttons["workspaces.mode.Snapshots"].click()
        XCTAssertTrue(element("workspace.snapshot.ui-snapshot-1").waitForExistence(timeout: 5))
    }
}
