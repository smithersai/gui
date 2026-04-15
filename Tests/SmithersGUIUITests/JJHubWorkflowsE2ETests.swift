import XCTest

final class JJHubWorkflowsE2ETests: SmithersGUIUITestCase {
    func testJJHubWorkflowsListAndRunFlow() {
        navigate(to: "JJHub Workflows", expectedViewIdentifier: "view.jjhubWorkflows")

        XCTAssertTrue(element("jjhubWorkflows.list").waitForExistence(timeout: 5))

        let firstWorkflow = waitForElement("jjhubWorkflows.row.301")
        firstWorkflow.click()

        let runButton = waitForElement("jjhubWorkflows.runButton")
        runButton.click()

        XCTAssertTrue(element("jjhubWorkflows.runPrompt").waitForExistence(timeout: 5))
        let refInput = waitForElement("jjhubWorkflows.refInput")
        refInput.click()
        app.typeText("feature/ui-test")

        let runConfirm = waitForElement("jjhubWorkflows.runConfirmButton")
        runConfirm.click()

        XCTAssertTrue(element("jjhubWorkflows.actionMessage").waitForExistence(timeout: 5))
    }
}
