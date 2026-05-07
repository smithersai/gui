import XCTest

final class FreshProjectE2ETests: SmithersGUIUITestCase {

    // MARK: - Dashboard

    func testDashboardLoadsAndShowsStatCards() {
        navigate(to: "Dashboard", expectedViewIdentifier: "view.dashboard")

        // The dashboard root and overview tab should be visible
        XCTAssertTrue(element("dashboard.root").waitForExistence(timeout: 5))
        XCTAssertTrue(element("dashboard.tab.Overview").waitForExistence(timeout: 5))

        // Stat cards should exist (Active Runs, Pending Approvals, Workflows, Failed Runs)
        XCTAssertTrue(element("dashboard.stat.ActiveRuns").waitForExistence(timeout: 5))
        XCTAssertTrue(element("dashboard.stat.PendingApprovals").exists)
        XCTAssertTrue(element("dashboard.stat.Workflows").exists)
        XCTAssertTrue(element("dashboard.stat.FailedRuns").exists)
    }

    func testDashboardTabsAreNavigable() {
        navigate(to: "Dashboard", expectedViewIdentifier: "view.dashboard")

        let tabs = ["Overview", "Runs", "Workflows", "Approvals", "Sessions", "Landings", "Issues", "Workspaces"]
        for tab in tabs {
            let button = element("dashboard.tab.\(tab)")
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Dashboard tab '\(tab)' should exist")
            button.click()
        }

        // Return to overview
        element("dashboard.tab.Overview").click()
        XCTAssertTrue(element("dashboard.stat.ActiveRuns").waitForExistence(timeout: 5))
    }

    // MARK: - Workflows

    func testWorkflowsViewLoadsWithListAndDetail() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")

        XCTAssertTrue(element("workflows.root").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.list").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.detail").waitForExistence(timeout: 5))
    }

    func testWorkflowsViewShowsWorkflowRows() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")

        // UI test fixtures provide "deploy-preview" and "release-gate" workflows
        XCTAssertTrue(element("workflow.row.deploy-preview").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflow.row.release-gate").waitForExistence(timeout: 5))
    }

    func testWorkflowSelectionShowsDetailWithRunButton() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")

        let row = waitForElement("workflow.row.deploy-preview")
        row.click()

        XCTAssertTrue(app.staticTexts["Deploy Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.runButton").waitForExistence(timeout: 5))
    }

    // MARK: - Runs

    func testRunsViewLoads() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // The runs view should be visible
        XCTAssertTrue(element("view.runs").exists)
    }

    // MARK: - Approvals

    func testApprovalsViewLoads() {
        navigate(to: "Approvals", expectedViewIdentifier: "view.approvals")

        XCTAssertTrue(element("view.approvals").exists)
    }

    // NOTE: `testChatWorksFromSidebar` was removed — the built-in chat feature
    // (nav.Chat / view.chat) no longer exists in production.

    // MARK: - Navigation completeness

    func testAllSidebarDestinationsExist() {
        let destinations: [(label: String, view: String)] = [
            ("Terminal", "view.terminal"),
            ("Dashboard", "view.dashboard"),
            ("Runs", "view.runs"),
            ("Snapshots", "view.snapshots"),
            ("Workflows", "view.workflows"),
            ("Approvals", "view.approvals"),
            ("Prompts", "view.prompts"),
            ("Scores", "view.scores"),
            ("Memory", "view.memory"),
            ("Search", "view.search"),
            ("Landings", "view.landings"),
            ("Issues", "view.issues"),
            ("Workspaces", "view.workspaces"),
        ]

        for destination in destinations {
            let nav = app.buttons["nav.\(destination.label.replacingOccurrences(of: " ", with: ""))"]
            XCTAssertTrue(nav.waitForExistence(timeout: 5), "Sidebar should contain '\(destination.label)' even in a fresh project")
        }
    }

    func testNavigatingToEveryDestinationLoadsView() {
        let destinations: [(label: String, view: String)] = [
            ("Dashboard", "view.dashboard"),
            ("Terminal", "view.terminal"),
            ("Workflows", "view.workflows"),
            ("Runs", "view.runs"),
            ("Snapshots", "view.snapshots"),
            ("Approvals", "view.approvals"),
            ("Prompts", "view.prompts"),
            ("Scores", "view.scores"),
            ("Memory", "view.memory"),
            ("Search", "view.search"),
            ("Landings", "view.landings"),
            ("Issues", "view.issues"),
            ("Workspaces", "view.workspaces"),
        ]

        for destination in destinations {
            navigate(to: destination.label, expectedViewIdentifier: destination.view)
        }
    }
}
