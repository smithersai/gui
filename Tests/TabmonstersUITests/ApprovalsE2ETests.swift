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
        cancelDenyApproval()
        XCTAssertTrue(element("approval.row.ui-run-approval-002:release-gate").waitForExistence(timeout: 2))

        waitForElement("approval.denyButton").click()
        confirmDenyApproval()
        XCTAssertFalse(element("approval.row.ui-run-approval-002:release-gate").waitForExistence(timeout: 2))

        waitForElement("approvals.historyToggle").click()
        XCTAssertTrue(element("approvals.historyList").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["APPROVED"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["DENIED"].waitForExistence(timeout: 5))
    }

    private func confirmDenyApproval() {
        let confirmByID = element("approval.confirmDenyButton")
        if confirmByID.waitForExistence(timeout: 2) {
            confirmByID.click()
            return
        }

        let confirmByLabel = app.buttons["Deny Approval"]
        XCTAssertTrue(confirmByLabel.waitForExistence(timeout: 5))
        confirmByLabel.click()
    }

    private func cancelDenyApproval() {
        let cancelByID = element("approval.cancelDenyButton")
        if cancelByID.waitForExistence(timeout: 2) {
            cancelByID.click()
            return
        }

        let cancelByLabel = app.buttons["Cancel"]
        XCTAssertTrue(cancelByLabel.waitForExistence(timeout: 5))
        cancelByLabel.click()
    }
}
