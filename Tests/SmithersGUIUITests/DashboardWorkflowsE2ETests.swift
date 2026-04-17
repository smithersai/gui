import XCTest

final class DashboardWorkflowsE2ETests: SmithersGUIUITestCase {
    func testDashboardStatsAndTabs() {
        navigate(to: "Dashboard", expectedViewIdentifier: "view.dashboard")

        XCTAssertTrue(element("dashboard.stat.ActiveRuns").waitForExistence(timeout: 5))
        XCTAssertTrue(element("dashboard.stat.PendingApprovals").exists)
        XCTAssertTrue(element("dashboard.stat.Workflows").exists)
        XCTAssertTrue(element("dashboard.stat.FailedRuns").exists)

        for tab in ["Overview", "Runs", "Workflows", "Approvals", "Sessions", "Landings", "Issues", "Workspaces"] {
            let button = app.buttons["dashboard.tab.\(tab)"]
            XCTAssertTrue(button.exists, "Missing dashboard tab \(tab)")
            button.click()
        }
    }

    func testWorkflowsSplitSelectionAndLaunchForm() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")

        XCTAssertTrue(element("workflows.list").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.detail.placeholder").waitForExistence(timeout: 5))

        waitForElement("workflow.row.deploy-preview").click()
        XCTAssertTrue(app.staticTexts["Deploy Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.runButton").waitForExistence(timeout: 5))

        element("workflows.runButton").click()
        XCTAssertTrue(element("workflows.launchForm").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.launchField.prompt").exists)
        XCTAssertTrue(element("workflows.launchField.environment").exists)

        element("workflows.launchButton").click()
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5), "Launching a workflow should open a live run tab")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.run:")).count >= 1)
    }
}
