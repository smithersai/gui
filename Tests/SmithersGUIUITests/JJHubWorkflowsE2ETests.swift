import XCTest

final class JJHubWorkflowsE2ETests: SmithersGUIUITestCase {

    // MARK: - Happy Path

    func testListLoadsAndSelectingWorkflowShowsDetail() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        XCTAssertTrue(element("jjhubWorkflows.root").waitForExistence(timeout: 5))
        XCTAssertTrue(element("jjhubWorkflows.list").waitForExistence(timeout: 5))

        // Select first workflow row (fixture ID 1)
        let row = waitForElement("jjhubWorkflows.row.1")
        row.click()

        XCTAssertTrue(element("jjhubWorkflows.detail").waitForExistence(timeout: 5))
        XCTAssertTrue(element("jjhubWorkflows.runButton").waitForExistence(timeout: 5))
    }

    func testRunWorkflowPromptAndCancel() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        waitForElement("jjhubWorkflows.row.1").click()
        waitForElement("jjhubWorkflows.runButton").click()

        XCTAssertTrue(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 5))
        XCTAssertTrue(element("jjhubWorkflows.refInput").exists)
        XCTAssertTrue(element("jjhubWorkflows.runConfirmButton").exists)
        XCTAssertTrue(element("jjhubWorkflows.cancelButton").exists)

        // Cancel the prompt
        element("jjhubWorkflows.cancelButton").click()
        XCTAssertFalse(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 2))
        XCTAssertTrue(element("jjhubWorkflows.runButton").waitForExistence(timeout: 5))
    }

    func testTriggerWorkflowShowsSuccessMessage() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        waitForElement("jjhubWorkflows.row.1").click()
        waitForElement("jjhubWorkflows.runButton").click()
        XCTAssertTrue(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 5))

        // Clear existing ref and type a custom one
        let refInput = waitForElement("jjhubWorkflows.refInput")
        refInput.click()
        refInput.typeKey("a", modifierFlags: .command)
        refInput.typeText("develop")

        waitForElement("jjhubWorkflows.runConfirmButton").click()

        // After successful trigger, prompt closes and action message appears
        XCTAssertTrue(element("jjhubWorkflows.actionMessage").waitForExistence(timeout: 10))
        XCTAssertFalse(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 2))
    }

    func testSelectingDifferentWorkflowClosesRunPrompt() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        waitForElement("jjhubWorkflows.row.1").click()
        waitForElement("jjhubWorkflows.runButton").click()
        XCTAssertTrue(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 5))

        // Select a different workflow
        let row2 = element("jjhubWorkflows.row.2")
        if row2.waitForExistence(timeout: 3) {
            row2.click()
            // Run prompt should close when switching workflows
            XCTAssertFalse(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 2))
        }
    }

    func testPlaceholderShownWhenNoWorkflowSelected() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        // Before selecting anything, detail shows placeholder
        XCTAssertTrue(app.staticTexts["Select a workflow"].waitForExistence(timeout: 5))
    }
}
