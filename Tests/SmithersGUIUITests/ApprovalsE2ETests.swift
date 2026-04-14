import XCTest

final class ApprovalsE2ETests: SmithersGUIUITestCase {
    func testPendingQueueApproveDenyAndHistoryToggle() {
        navigate(to: "Approvals", expectedViewIdentifier: "view.approvals")

        XCTAssertTrue(element("approvals.pendingList").waitForExistence(timeout: 5))
        waitForElement("approval.row.ui-run-approval-001:deploy-gate").click()
        XCTAssertTrue(element("approval.approveButton").waitForExistence(timeout: 5))
        XCTAssertTrue(element("approval.denyButton").exists)

        element("approval.approveButton").click()
        XCTAssertFalse(element("approval.row.ui-run-approval-001:deploy-gate").waitForExistence(timeout: 2))

        waitForElement("approval.row.ui-run-approval-002:release-gate").click()
        waitForElement("approval.denyButton").click()
        XCTAssertFalse(element("approval.row.ui-run-approval-002:release-gate").waitForExistence(timeout: 2))

        waitForElement("approvals.historyToggle").click()
        XCTAssertTrue(element("approvals.historyList").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["APPROVED"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DENIED"].waitForExistence(timeout: 5))
    }
}
