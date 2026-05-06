import XCTest
@testable import Tabmonsters

final class UITestSupportTests: XCTestCase {
    func testIsEnabledWithUITestingArgument() {
        XCTAssertTrue(
            UITestSupport.isEnabled(
                arguments: ["/Applications/Tabmonsters", "--uitesting"],
                environment: [:]
            )
        )
    }

    func testIsEnabledWithEnvironmentFlag() {
        XCTAssertTrue(
            UITestSupport.isEnabled(
                arguments: ["/Applications/Tabmonsters"],
                environment: ["TABMONSTERS_UITEST": "1"]
            )
        )
    }

    func testIsEnabledIsFalseWithoutFlag() {
        XCTAssertFalse(
            UITestSupport.isEnabled(
                arguments: ["/Applications/Tabmonsters"],
                environment: ["TABMONSTERS_UITEST": "true"]
            )
        )
    }

    func testIsRunningUnitTestsWithXCTestConfigurationPath() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "Tabmonsters",
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
                processName: "TabmonstersTests",
                environment: [:]
            )
        )
    }

    func testIsRunningUnitTestsWithXCTestArgument() {
        XCTAssertTrue(
            UITestSupport.isRunningUnitTests(
                processName: "swift",
                arguments: ["/tmp/TabmonstersTests.xctest/Contents/MacOS/TabmonstersTests"],
                environment: [:]
            )
        )
    }

    func testIsRunningUnitTestsIsFalseForNormalAppProcess() {
        XCTAssertFalse(
            UITestSupport.isRunningUnitTests(
                processName: "Tabmonsters",
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
