import XCTest

final class NavigationE2ETests: SmithersGUIUITestCase {
    func testSidebarShowsRequestedDestinationsAndEachViewLoads() {
        let destinations: [(label: String, view: String)] = [
            ("Chat", "view.chat"),
            ("Terminal", "view.terminal"),
            ("Dashboard", "view.dashboard"),
            ("Runs", "view.runs"),
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
            XCTAssertTrue(app.buttons["nav.\(destination.label)"].waitForExistence(timeout: 5), "Missing sidebar destination \(destination.label)")
        }

        for destination in destinations {
            navigate(to: destination.label, expectedViewIdentifier: destination.view)
        }
    }
}
