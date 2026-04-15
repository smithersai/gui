import XCTest

final class WorkspacesSessionKeyboardE2ETests: SmithersGUIUITestCase {
    func testWorkspacesTabsAndCreateWorkspaceForm() {
        navigate(to: "Workspaces", expectedViewIdentifier: "view.workspaces")

        XCTAssertTrue(app.buttons["workspaces.tab.Workspaces"].exists)
        XCTAssertTrue(app.buttons["workspaces.tab.Snapshots"].exists)
        XCTAssertTrue(app.staticTexts["Main Workspace"].waitForExistence(timeout: 5))

        waitForElement("workspaces.newButton").click()
        XCTAssertTrue(element("workspaces.create.form").waitForExistence(timeout: 5))
        typeInto("workspaces.create.name", "UI Test Workspace")
        waitForElement("workspaces.create.submit").click()
        XCTAssertTrue(app.staticTexts["UI Test Workspace"].waitForExistence(timeout: 5))

        app.buttons["workspaces.tab.Snapshots"].click()
        XCTAssertTrue(element("workspace.snapshot.ui-snapshot-1").waitForExistence(timeout: 5))
    }

    func testNewChatCreatesSessionAndSessionSearchFindsIt() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")
        chooseSmithersChatTargetIfNeeded()

        typeInto("chat.input", "Session Search Needle")
        waitForElement("chat.sendButton").click()
        XCTAssertTrue(app.staticTexts["Session Search Needle"].waitForExistence(timeout: 5))

        let before = sessionButtonCount()
        waitForElement("sidebar.newChat").click()
        XCTAssertGreaterThanOrEqual(sessionButtonCount(), before + 1)

        typeInto("sidebar.sessionSearch", "Session Search Needle")
        XCTAssertTrue(app.staticTexts["Session Search Needle"].waitForExistence(timeout: 5))
    }

    func testCommandNCreatesNewChat() {
        navigate(to: "Chat", expectedViewIdentifier: "view.chat")

        let before = sessionButtonCount()
        app.typeKey("n", modifierFlags: .command)

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.sessionButtonCount() >= before + 1
            },
            object: nil
        )
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(element("view.chat").exists)
    }
}
