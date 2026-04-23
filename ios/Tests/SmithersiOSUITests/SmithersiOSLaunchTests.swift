// SmithersiOSLaunchTests.swift — iOS UI test scaffold (ticket 0121).
//
// Only verifies that the iOS app launches in the simulator. Real navigation
// coverage (parallel to Tests/SmithersGUIUITests) lands after 0122 ports the
// nav stack.

#if os(iOS)
import XCTest

final class SmithersiOSLaunchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()
        // The placeholder view exposes a "Smithers" static text; any launch
        // that reaches the SwiftUI root will present it.
        XCTAssertTrue(app.staticTexts["Smithers iOS"].waitForExistence(timeout: 10))
    }
}
#endif
