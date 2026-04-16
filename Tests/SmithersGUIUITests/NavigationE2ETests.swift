import XCTest

final class NavigationE2ETests: SmithersGUIUITestCase {
    func testSidebarShowsRequestedDestinationsAndEachViewLoads() {
        let destinations: [(label: String, view: String)] = [
            ("Dashboard", "view.dashboard"),
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
            let nav = app.buttons["nav.\(destination.label.replacingOccurrences(of: " ", with: ""))"]
            if !nav.waitForExistence(timeout: 1.5) {
                expandSidebarSectionIfNeeded(for: destination.label)
            }
            XCTAssertTrue(
                nav.waitForExistence(timeout: 5),
                "Missing sidebar destination \(destination.label)"
            )
        }

        for destination in destinations {
            navigate(to: destination.label, expectedViewIdentifier: destination.view)
        }
    }
}
