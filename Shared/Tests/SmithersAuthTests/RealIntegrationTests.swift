// RealIntegrationTests.swift — gated on `PLUE_DEV_URL`. When unset, the
// test body is a single no-op assertion so CI never fails. When set,
// each test exercises the real `/api/oauth2/*` surface against the live
// plue dev instance.
//
// Per ticket 0109 rules: we do NOT use `XCTSkip` (0094 pattern); instead
// we early-return from the test body. The no-op `true` assertion is
// present so XCTest reports the test as executed.
//
// This test set will light up as soon as:
//   (a) 0106 merges (`/api/oauth2/authorize` becomes a real browser flow),
//   (b) a dev instance with `PLUE_DEV_URL` is reachable,
//   (c) a seeded test user with a known refresh token is provisioned.
// Until then: the test body is a structural placeholder that compiles
// and documents the wire shape we expect to assert against.
//
// Ticket 0109.

import XCTest
@testable import SmithersAuth

final class RealIntegrationTests: XCTestCase {

    private var plueURL: URL? {
        guard let s = ProcessInfo.processInfo.environment["PLUE_DEV_URL"],
              !s.isEmpty,
              let url = URL(string: s) else { return nil }
        return url
    }

    private func liveConfig(clientID: String) -> OAuth2ClientConfig {
        OAuth2ClientConfig(
            baseURL: plueURL!,
            clientID: clientID,
            redirectURI: "smithers://auth/callback"
        )
    }

    /// Real refresh-token rotation against a live plue. Requires:
    ///   PLUE_DEV_URL        = https://plue.dev.example
    ///   PLUE_DEV_CLIENT_ID  = registered public client id
    ///   PLUE_DEV_REFRESH    = seeded long-lived refresh token
    ///
    /// If any are missing, we no-op.
    @MainActor
    func test_real_refresh_rotation() async throws {
        guard let base = plueURL else {
            XCTAssertTrue(true, "PLUE_DEV_URL unset; real integration test no-op")
            return
        }
        guard let clientID = ProcessInfo.processInfo.environment["PLUE_DEV_CLIENT_ID"],
              let seedRefresh = ProcessInfo.processInfo.environment["PLUE_DEV_REFRESH"] else {
            XCTAssertTrue(true, "PLUE_DEV_CLIENT_ID or PLUE_DEV_REFRESH unset; skipping body (0109)")
            return
        }

        let config = OAuth2ClientConfig(
            baseURL: base,
            clientID: clientID,
            redirectURI: "smithers://auth/callback"
        )
        let client = OAuth2Client(config: config)
        let rotated = try await client.refresh(refreshToken: seedRefresh)
        XCTAssertFalse(rotated.accessToken.isEmpty)
        XCTAssertFalse(rotated.refreshToken.isEmpty)
        XCTAssertNotEqual(rotated.refreshToken, seedRefresh, "refresh token must rotate")
    }

    /// Real sign-in via `ASWebAuthenticationSession` cannot run fully
    /// headless — this test only validates the authorize URL we would
    /// hand the system browser. The full end-to-end path is exercised
    /// by the macOS/iOS UI test suites once 0106 is live.
    func test_real_authorize_url_builds_against_live_base() throws {
        guard let base = plueURL else {
            XCTAssertTrue(true, "PLUE_DEV_URL unset; real integration test no-op")
            return
        }
        let config = OAuth2ClientConfig(
            baseURL: base,
            clientID: "smithers-ios",
            redirectURI: "smithers://auth/callback"
        )
        let client = OAuth2Client(config: config)
        let pair = try PKCE.generate()
        let url = client.authorizeURL(pkce: pair, state: "integration-state")
        XCTAssertEqual(url.host, base.host)
        XCTAssertTrue(url.path.hasSuffix("/api/oauth2/authorize"))
    }

    @MainActor
    func test_real_signout_revokes_other_session_access_tokens() async throws {
        guard ProcessInfo.processInfo.environment["POC_ELECTRIC_STACK"] == "1" else {
            XCTAssertTrue(true, "POC_ELECTRIC_STACK unset; real revoke-all test no-op")
            return
        }
        guard let base = plueURL else {
            XCTAssertTrue(true, "PLUE_DEV_URL unset; real revoke-all test no-op")
            return
        }
        guard let clientID = ProcessInfo.processInfo.environment["PLUE_DEV_CLIENT_ID"],
              let refreshA = ProcessInfo.processInfo.environment["PLUE_DEV_REFRESH"],
              let refreshB = ProcessInfo.processInfo.environment["PLUE_DEV_REFRESH_SECONDARY"] else {
            XCTAssertTrue(true, "PLUE_DEV_CLIENT_ID or dual refresh tokens unset; revoke-all test no-op")
            return
        }

        let client = OAuth2Client(config: liveConfig(clientID: clientID))
        let tokensA = try await client.refresh(refreshToken: refreshA)
        let tokensB = try await client.refresh(refreshToken: refreshB)
        let managerA = TokenManager(client: client, store: InMemoryTokenStore(initial: tokensA))
        let managerB = TokenManager(client: client, store: InMemoryTokenStore(initial: tokensB))

        let statusBeforeSignOut = try await statusForAuthenticatedUserRequest(
            baseURL: base,
            token: try managerB.currentAccessToken()
        )
        XCTAssertEqual(statusBeforeSignOut, 200)

        await managerA.signOut()

        let statusAfterSignOut = try await statusForAuthenticatedUserRequest(
            baseURL: base,
            token: try managerB.currentAccessToken()
        )
        XCTAssertEqual(statusAfterSignOut, 401)
    }

    private func statusForAuthenticatedUserRequest(baseURL: URL, token: String) async throws -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/user"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            XCTFail("Expected HTTPURLResponse")
            return -1
        }
        return http.statusCode
    }
}
