import XCTest

final class NavigationE2ETests: SmithersGUIUITestCase {
    func testSidebarShowsRequestedDestinationsAndEachViewLoads() {
        let destinations: [(label: String, view: String)] = [
            ("Smithers", "view.dashboard"),
            ("VCS", "view.vcsDashboard"),
        ]

        for destination in destinations {
            let nav = app.buttons["nav.\(destination.label.replacingOccurrences(of: " ", with: ""))"]
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
