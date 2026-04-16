import XCTest

final class NavigationE2ETests: SmithersGUIUITestCase {
    func testSidebarShowsTopLevelDestinations() {
        let topLevel: [(label: String, view: String)] = [
            ("Smithers", "view.dashboard"),
            ("VCS", "view.vcsDashboard"),
        ]

        for destination in topLevel {
            let nav = app.buttons["nav.\(destination.label)"]
            XCTAssertTrue(
                nav.waitForExistence(timeout: 5),
                "Missing sidebar destination \(destination.label)"
            )
        }

        for destination in topLevel {
            navigate(to: destination.label, expectedViewIdentifier: destination.view)
        }
    }

    func testEveryNavDestinationLoadsView() {
        let destinations: [(label: String, view: String)] = [
            ("Dashboard", "view.dashboard"),
            ("VCSDashboard", "view.vcsDashboard"),
            ("Agents", "view.agents"),
            ("Runs", "view.runs"),
            ("Snapshots", "view.snapshots"),
            ("Workflows", "view.workflows"),
            ("Triggers", "view.triggers"),
            ("Approvals", "view.approvals"),
            ("Prompts", "view.prompts"),
            ("Scores", "view.scores"),
            ("Memory", "view.memory"),
            ("Search", "view.search"),
            ("SQL Browser", "view.sql"),
            ("Workspaces", "view.workspaces"),
            ("Logs", "view.logs"),
            ("Changes", "view.changes"),
            ("JJHub Workflows", "view.jjhubWorkflows"),
            ("Landings", "view.landings"),
            ("Tickets", "view.tickets"),
            ("Issues", "view.issues"),
        ]

        for destination in destinations {
            navigate(to: destination.label, expectedViewIdentifier: destination.view)
        }
    }
}
