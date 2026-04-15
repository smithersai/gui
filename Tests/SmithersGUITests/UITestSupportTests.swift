import XCTest
@testable import SmithersGUI

final class UITestSupportTests: XCTestCase {
    func testIsEnabledWithUITestingArgument() {
        XCTAssertTrue(
            UITestSupport.isEnabled(
                arguments: ["/Applications/SmithersGUI", "--uitesting"],
                environment: [:]
            )
        )
    }

    func testIsEnabledWithEnvironmentFlag() {
        XCTAssertTrue(
            UITestSupport.isEnabled(
                arguments: ["/Applications/SmithersGUI"],
                environment: ["SMITHERS_GUI_UITEST": "1"]
            )
        )
    }

    func testIsEnabledIsFalseWithoutFlag() {
        XCTAssertFalse(
            UITestSupport.isEnabled(
                arguments: ["/Applications/SmithersGUI"],
                environment: ["SMITHERS_GUI_UITEST": "true"]
            )
        )
    }

    func testIsRunningUnitTestsWithXCTestConfigurationPath() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "SmithersGUI",
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]
            )
        )
    }

    func testIsRunningUnitTestsWithXCTestProcessName() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "xctest",
                environment: [:]
            )
        )
    }

    func testIsRunningUnitTestsWithSwiftPMTestBundleProcessName() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "SmithersGUITests",
                environment: [:]
            )
        )
    }

    func testIsRunningUnitTestsWithXCTestArgument() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "swift",
                arguments: ["/tmp/SmithersGUITests.xctest/Contents/MacOS/SmithersGUITests"],
                environment: [:]
            )
        )
    }

    func testIsRunningUnitTestsIsFalseForNormalAppProcess() {
        XCTAssertFalse(
            UITestSupport.isRunningUnitTests(
                processName: "SmithersGUI",
                environment: [:]
            )
        )
    }

    func testNowMsIsCurrentUnixTimeInMilliseconds() {
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        let now = UITestSupport.nowMs
        let after = Int64(Date().timeIntervalSince1970 * 1000)

        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThanOrEqual(now, after)
    }
}
