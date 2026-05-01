// PlueEndpointTests.swift — preview backend URL resolution for device builds.

#if os(iOS)
import XCTest
@testable import SmithersiOS

final class PlueEndpointTests: XCTestCase {
    func testEnvironmentPLUEBaseURLWinsAndTrimsAPIPath() {
        let url = SmithersPlueEndpoint.configuredBaseURL(
            environment: ["PLUE_BASE_URL": " http://192.168.1.25:4000/api "],
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(url?.absoluteString, "http://192.168.1.25:4000")
    }

    func testPreviewURLIsAcceptedForNgrokBuilds() {
        let url = SmithersPlueEndpoint.configuredBaseURL(
            environment: ["PLUE_PREVIEW_URL": "https://example.ngrok-free.app"],
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(url?.absoluteString, "https://example.ngrok-free.app")
    }

    func testUnresolvedInfoPlistBuildSettingIsIgnored() {
        XCTAssertNil(SmithersPlueEndpoint.parsedURL("$(PLUE_BASE_URL)"))
    }
}
#endif
