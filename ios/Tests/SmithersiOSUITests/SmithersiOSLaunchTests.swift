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
        // The sign-in view (0109) is the first surface the iOS app presents
        // when the user has no Keychain session. Tests previously asserted
        // on a placeholder "Smithers iOS" text (0121); now we assert the
        // sign-in prompt renders.
        XCTAssertTrue(app.staticTexts["Sign in to Smithers"].waitForExistence(timeout: 10))
    }
}
#endif
