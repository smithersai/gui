import Foundation
import XCTest
@testable import SmithersE2ESupport

final class E2EEnvironmentTests: XCTestCase {
    func testParseReturnsNilWhenModeIsMissingOrDisabled() {
        XCTAssertNil(E2EEnvironment.parse(DictionaryEnvironmentSource([:])))
        XCTAssertNil(E2EEnvironment.parse(DictionaryEnvironmentSource([
            E2EEnvironmentKey.mode: "0",
            E2EEnvironmentKey.bearer: "token",
            E2EEnvironmentKey.baseURL: "http://localhost:4000",
        ])))
    }

    func testParseRequiresBearerAndValidBaseURL() {
        XCTAssertNil(E2EEnvironment.parse(DictionaryEnvironmentSource([
            E2EEnvironmentKey.mode: "1",
            E2EEnvironmentKey.baseURL: "http://localhost:4000",
        ])))
        XCTAssertNil(E2EEnvironment.parse(DictionaryEnvironmentSource([
            E2EEnvironmentKey.mode: "1",
            E2EEnvironmentKey.bearer: "",
            E2EEnvironmentKey.baseURL: "http://localhost:4000",
        ])))
        XCTAssertNil(E2EEnvironment.parse(DictionaryEnvironmentSource([
            E2EEnvironmentKey.mode: "1",
            E2EEnvironmentKey.bearer: "token",
            E2EEnvironmentKey.baseURL: "not a url",
        ])))
    }

    func testParseReturnsConfigWithOptionalRefreshToken() throws {
        let config = try XCTUnwrap(E2EEnvironment.parse(DictionaryEnvironmentSource([
            E2EEnvironmentKey.mode: "1",
            E2EEnvironmentKey.bearer: "jjhub_e2e_abc",
            E2EEnvironmentKey.baseURL: "http://localhost:4000",
            E2EEnvironmentKey.refreshToken: "refresh-abc",
        ])))

        XCTAssertEqual(config.bearer, "jjhub_e2e_abc")
        XCTAssertEqual(config.baseURL.absoluteString, "http://localhost:4000")
        XCTAssertEqual(config.refreshToken, "refresh-abc")
    }

    func testSyntheticTokensUseBearerAndRefreshFallback() {
        let withRefresh = E2EEnvironment.syntheticTokens(from: E2EConfig(
            bearer: "access",
            baseURL: URL(string: "http://localhost:4000")!,
            refreshToken: "refresh"
        ))
        let withoutRefresh = E2EEnvironment.syntheticTokens(from: E2EConfig(
            bearer: "access",
            baseURL: URL(string: "http://localhost:4000")!
        ))

        XCTAssertEqual(withRefresh.accessToken, "access")
        XCTAssertEqual(withRefresh.refreshToken, "refresh")
        XCTAssertEqual(withoutRefresh.refreshToken, "e2e-refresh-placeholder")
        XCTAssertEqual(withoutRefresh.scope, "read:workspace,write:workspace")
    }
}
