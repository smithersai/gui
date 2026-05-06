import XCTest

final class LogViewerE2ETests: TabmonstersUITestCase {

    func testLogViewerLoadsAndShowsToolbar() {
        navigate(to: "Smithers", expectedViewIdentifier: "view.dashboard")
    }
}
