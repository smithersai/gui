import XCTest

final class NavigationE2ETests: SmithersGUIUITestCase {
    func testTopLevelDashboardsAreAvailableViaPalette() {
        let dashboards: [(query: String, view: String)] = [
            ("dashboard", "view.dashboard"),
            ("vcs dashboard", "view.vcsDashboard"),
        ]

        for destination in dashboards {
            navigateViaPalette(
                query: destination.query,
                expectedViewIdentifier: destination.view
            )
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
