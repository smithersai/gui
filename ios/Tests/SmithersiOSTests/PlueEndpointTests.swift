// SmithersEndpointTests.swift — preview backend URL resolution for device builds.

#if os(iOS)
import XCTest
@testable import SmithersiOS

final class SmithersEndpointTests: XCTestCase {
    func testEnvironmentSmithersBaseURLWinsAndTrimsAPIPath() {
        let url = SmithersBackendEndpoint.configuredBaseURL(
            environment: ["SMITHERS_BASE_URL": " http://192.168.1.25:4000/api "],
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(url?.absoluteString, "http://192.168.1.25:4000")
    }

    func testPreviewURLIsAcceptedForNgrokBuilds() {
        let url = SmithersBackendEndpoint.configuredBaseURL(
            environment: ["SMITHERS_PREVIEW_URL": "https://example.ngrok-free.app"],
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(url?.absoluteString, "https://example.ngrok-free.app")
    }

    func testUnresolvedInfoPlistBuildSettingIsIgnored() {
        XCTAssertNil(SmithersBackendEndpoint.parsedURL("$(SMITHERS_BASE_URL)"))
    }

    func testLegacyBaseURLStillWorksDuringMigration() {
        let url = SmithersBackendEndpoint.configuredBaseURL(
            environment: ["PLUE_BASE_URL": "http://127.0.0.1:4000"],
            bundle: Bundle(for: Self.self)
        )

        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:4000")
    }
}
#endif
