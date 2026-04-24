// MockedServerIntegrationTests.swift — end-to-end sign-in → authenticated
// call → simulated 401 → refresh → retry → sign-out → revoked.
//
// Does NOT depend on 0106. Exercises the full client state machine with
// mocked `/api/oauth2/token`, `/api/oauth2/revoke`, `/api/oauth2/revoke-all`,
// and a mock `ASWebAuthenticationSession` driver.
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
        // Third response: revoke-all
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

        let revokeAllHits = transport.recorded.filter { $0.url.absoluteString.hasSuffix("/api/oauth2/revoke-all") }
        XCTAssertEqual(revokeAllHits.count, 1, "sign-out should prefer revoke-all when the route exists")
        XCTAssertEqual(revokeAllHits[0].headers["Authorization"], "Bearer FAKE_ACCESS_2")
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

    func test_concurrent_refreshes_deduplicate() async throws {
        let transport = MockHTTPTransport()
        transport.sendDelayNanoseconds = 25_000_000
        for _ in 0..<2 {
            transport.responses.append(.json(payload: [
                "access_token": "A2", "refresh_token": "R2",
            ]))
        }
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "A1", refreshToken: "R1"))
        let mgr = TokenManager(client: client, store: store)

        let a = Task { try await mgr.refresh() }
        let b = Task { try await mgr.refresh() }

        let ta = try await a.value
        let tb = try await b.value

        XCTAssertEqual(ta, tb)
        XCTAssertEqual(ta.accessToken, "A2")
        XCTAssertEqual(refreshRequests(in: transport).count, 1)
    }

    func test_concurrent_refreshes_stress_deduplicate() async throws {
        let transport = MockHTTPTransport()
        transport.sendDelayNanoseconds = 25_000_000
        for _ in 0..<20 {
            transport.responses.append(.json(payload: [
                "access_token": "A2", "refresh_token": "R2",
            ]))
        }
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "A1", refreshToken: "R1"))
        let mgr = TokenManager(client: client, store: store)

        let tasks = (0..<20).map { _ in
            Task { try await mgr.refresh() }
        }
        let results = try await tasks.asyncMap { try await $0.value }
        let first = try XCTUnwrap(results.first)

        XCTAssertTrue(results.allSatisfy { $0 == first })
        XCTAssertEqual(refreshRequests(in: transport).count, 1)
    }

    @MainActor
    func test_signout_falls_back_to_access_and_refresh_revoke_when_revoke_all_missing() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 404, code: "not_found"))
        transport.responses.append(.json(payload: [:]))
        transport.responses.append(.json(payload: [:]))

        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "ACCESS_A", refreshToken: "REFRESH_A"))
        let wipe = CountingWipeHandler()
        let mgr = TokenManager(client: client, store: store, wipeHandler: wipe)

        await mgr.signOut()

        XCTAssertNil(try store.load())
        XCTAssertEqual(wipe.wipeCount, 1)

        let revokeAllHits = transport.recorded.filter { $0.url.absoluteString.hasSuffix("/api/oauth2/revoke-all") }
        XCTAssertEqual(revokeAllHits.count, 1)

        let revokeHits = transport.recorded.filter { $0.url.absoluteString.hasSuffix("/api/oauth2/revoke") }
        XCTAssertEqual(revokeHits.count, 2)
        XCTAssertTrue((revokeHits[0].bodyString ?? "").contains("token=ACCESS_A"))
        XCTAssertTrue((revokeHits[0].bodyString ?? "").contains("token_type_hint=access_token"))
        XCTAssertTrue((revokeHits[1].bodyString ?? "").contains("token=REFRESH_A"))
        XCTAssertTrue((revokeHits[1].bodyString ?? "").contains("token_type_hint=refresh_token"))
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

private func refreshRequests(in transport: MockHTTPTransport) -> [MockHTTPTransport.Recorded] {
    transport.recorded.filter {
        $0.url.absoluteString.hasSuffix("/api/oauth2/token")
            && ($0.bodyString ?? "").contains("grant_type=refresh_token")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self {
            let value = try await transform(element)
            results.append(value)
        }
        return results
    }
}
