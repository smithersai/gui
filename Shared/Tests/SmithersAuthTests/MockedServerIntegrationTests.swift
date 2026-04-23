// MockedServerIntegrationTests.swift — end-to-end sign-in → authenticated
// call → simulated 401 → refresh → retry → sign-out → revoked.
//
// Does NOT depend on 0106. Exercises the full client state machine with
// mocked `/api/oauth2/token` + `/api/oauth2/revoke` and a mock
// `ASWebAuthenticationSession` driver.
//
// Ticket 0109. Test-only credentials are clearly labeled FAKE.

import XCTest
@testable import SmithersAuth

final class MockedServerIntegrationTests: XCTestCase {

    private func makeConfig() -> OAuth2ClientConfig {
        OAuth2ClientConfig(
            baseURL: URL(string: "https://plue.test")!,
            clientID: "FAKE-client-id",
            redirectURI: "smithers://auth/callback"
        )
    }

    // MARK: - Authorize URL shape

    func test_authorize_url_contains_pkce_and_state() throws {
        let client = OAuth2Client(config: makeConfig(), transport: MockHTTPTransport())
        let pair = try PKCE.generate()
        let state = "FAKE-STATE-abc"
        let url = client.authorizeURL(pkce: pair, state: state)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "FAKE-client-id")
        XCTAssertEqual(items["redirect_uri"], "smithers://auth/callback")
        XCTAssertEqual(items["code_challenge"], pair.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], state)
    }

    // MARK: - Full happy-path sign-in + 401 refresh + sign-out

    @MainActor
    func test_full_signin_401_refresh_retry_signout() async throws {
        let transport = MockHTTPTransport()
        // First response: /token exchange
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_ACCESS_1",
            "refresh_token": "FAKE_REFRESH_1",
            "expires_in": 3600,
            "scope": "read write",
        ]))
        // Second response: refresh /token
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_ACCESS_2",
            "refresh_token": "FAKE_REFRESH_2",
            "expires_in": 3600,
        ]))
        // Third response: revoke
        transport.responses.append(.json(payload: [:]))

        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore()
        let wipe = CountingWipeHandler()
        let mgr = TokenManager(client: client, store: store, wipeHandler: wipe)
        let driver = MockAuthorizeSessionDriver()
        driver.behavior = .success(code: "FAKE_AUTH_CODE")
        let model = AuthViewModel(
            client: client,
            tokens: mgr,
            driver: driver,
            callbackScheme: "smithers"
        )

        // Sign-in.
        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(try store.load()?.accessToken, "FAKE_ACCESS_1")
        XCTAssertEqual(try store.load()?.refreshToken, "FAKE_REFRESH_1")

        // Inspect the exchange body.
        let exchange = transport.recorded.first!
        XCTAssertEqual(exchange.method, "POST")
        XCTAssertTrue(exchange.url.absoluteString.hasSuffix("/api/oauth2/token"))
        let body = exchange.bodyString ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=FAKE_AUTH_CODE"))
        XCTAssertTrue(body.contains("code_verifier="))

        // Simulate a 401 on an authenticated call that triggers a refresh.
        var attemptCount = 0
        let out: String = try await mgr.performWithRetry { token in
            attemptCount += 1
            if attemptCount == 1 {
                XCTAssertEqual(token, "FAKE_ACCESS_1")
                return nil // simulate 401
            } else {
                XCTAssertEqual(token, "FAKE_ACCESS_2", "Retry must use freshly-persisted token")
                return "OK"
            }
        }
        XCTAssertEqual(out, "OK")
        XCTAssertEqual(attemptCount, 2)

        // Atomicity: after refresh, the store MUST hold the new tokens
        // before the retry closure ran. We can prove this by observing
        // the store directly — the retry asserts .access_2 was served.
        XCTAssertEqual(try store.load()?.accessToken, "FAKE_ACCESS_2")
        XCTAssertEqual(try store.load()?.refreshToken, "FAKE_REFRESH_2")

        // Sign-out: revoke + wipe.
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
        XCTAssertEqual(wipe.wipeCount, 1)

        // Ensure /api/oauth2/revoke was actually hit.
        let revokeHit = transport.recorded.last!
        XCTAssertTrue(revokeHit.url.absoluteString.hasSuffix("/api/oauth2/revoke"))
        XCTAssertTrue((revokeHit.bodyString ?? "").contains("token=FAKE_REFRESH_2"))
    }

    // MARK: - Atomicity: Keychain write fails mid-rotation

    @MainActor
    func test_refresh_keychain_write_failure_logs_out_rather_than_keeps_stale() async throws {
        let transport = MockHTTPTransport()
        // /token refresh returns new tokens...
        transport.responses.append(.json(payload: [
            "access_token": "NEW_ACCESS",
            "refresh_token": "NEW_REFRESH",
        ]))
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "OLD_A", refreshToken: "OLD_R"))
        let wipe = CountingWipeHandler()
        let mgr = TokenManager(client: client, store: store, wipeHandler: wipe)

        // ...but the Keychain write fails.
        store.failureMode = .onSave(.keychainWriteFailed(-1))

        do {
            _ = try await mgr.refresh()
            XCTFail("Expected refresh to throw on persistence failure")
        } catch TokenManagerError.persistenceFailed {
            // ok
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        // User is now signed out (wipe was invoked, in-memory cache empty).
        // The old refresh token is invalidated server-side at this point;
        // keeping it would lock the user out worse.
        XCTAssertFalse(mgr.hasSession)
        XCTAssertEqual(wipe.wipeCount, 1)
    }

    // MARK: - Whitelist-denied surfaces static page

    @MainActor
    func test_whitelist_denied_renders_static_screen_no_retry_loop() async throws {
        let transport = MockHTTPTransport()
        // /token exchange returns access_not_yet_granted structured error.
        transport.responses.append(.error(
            status: 403,
            code: "access_not_yet_granted",
            description: "Your access request is pending administrator approval."
        ))

        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore()
        let mgr = TokenManager(client: client, store: store)
        let driver = MockAuthorizeSessionDriver()
        driver.behavior = .success(code: "FAKE_CODE")
        let model = AuthViewModel(
            client: client,
            tokens: mgr,
            driver: driver,
            callbackScheme: "smithers"
        )

        await model.signIn()

        guard case .whitelistDenied(let msg) = model.phase else {
            return XCTFail("Expected whitelistDenied phase, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("pending administrator approval"))

        // Invoking signIn again must NOT attempt another network call —
        // the static page is terminal per ticket.
        let preCount = transport.recorded.count
        await model.signIn()
        XCTAssertEqual(transport.recorded.count, preCount, "whitelist-denied state must not retry")
    }

    // MARK: - Concurrent 401s collapse into one refresh

    @MainActor
    func test_concurrent_refreshes_deduplicate() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "A2", "refresh_token": "R2",
        ]))
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "A1", refreshToken: "R1"))
        let mgr = TokenManager(client: client, store: store)

        async let a = mgr.refresh()
        async let b = mgr.refresh()
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta.accessToken, "A2")
        XCTAssertEqual(tb.accessToken, "A2")
        // Only ONE refresh hit the wire.
        XCTAssertEqual(transport.recorded.count, 1)
    }

    // MARK: - CSRF state mismatch is rejected

    func test_parseCallback_rejects_state_mismatch() {
        let url = URL(string: "smithers://auth/callback?code=abc&state=attacker")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "legit"))
    }

    func test_parseCallback_rejects_missing_code() {
        let url = URL(string: "smithers://auth/callback?state=s")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "s"))
    }
}

// MARK: - helpers

private final class CountingWipeHandler: SessionWipeHandler {
    var wipeCount = 0
    func wipeAfterSignOut() { wipeCount += 1 }
}
