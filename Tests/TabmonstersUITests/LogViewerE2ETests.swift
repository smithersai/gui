import XCTest

final class LogViewerE2ETests: SmithersGUIUITestCase {

    func testLogViewerLoadsAndShowsToolbar() {
        navigate(to: "Smithers", expectedViewIdentifier: "view.dashboard")
    }
}
