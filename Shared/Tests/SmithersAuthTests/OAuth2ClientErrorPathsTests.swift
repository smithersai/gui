// OAuth2ClientErrorPathsTests.swift — error-path / edge-case coverage for
// `OAuth2Client.exchange`, `OAuth2Client.refresh`, the authorize-callback
// parser, the revoke endpoints, and PKCE input validation.
//
// Style mirrors `MockedServerIntegrationTests.swift` and
// `FeatureFlagsClientTests.swift` — uses the existing `MockHTTPTransport`
// helper. Where the helper cannot simulate a behavior (e.g. raw transport
// I/O failures, real HTTP redirect following) we document the gap inline
// and use the closest available approximation.
//
// Ticket 0109. FAKE-* tokens / codes are clearly labeled.

import XCTest
@testable import SmithersAuth

final class OAuth2ClientErrorPathsTests: XCTestCase {

    private func makeConfig() -> OAuth2ClientConfig {
        OAuth2ClientConfig(
            baseURL: URL(string: "https://plue.test")!,
            clientID: "FAKE-client-id",
            redirectURI: "smithers://auth/callback"
        )
    }

    private func makeClient(_ transport: HTTPTransport) -> OAuth2Client {
        OAuth2Client(config: makeConfig(), transport: transport)
    }

    // MARK: - Authorization callback parsing
    //
    // The authorize "endpoint" in this client is a URL builder; the real
    // wire round-trip is performed by `ASWebAuthenticationSession`. The
    // failure modes the user asked us to cover (4xx/5xx/network on the
    // authorize endpoint) are surfaced via `parseCallback` returning a
    // raw URL OR via the `AuthorizeSessionDriver` itself, which is out of
    // scope for the OAuth2Client. We exercise the callback-parser branches
    // that map onto those failures and DOCUMENT the rest as a gap.

    func test_parseCallback_rejects_mismatched_state_csrf() {
        let url = URL(string: "smithers://auth/callback?code=abc&state=ATTACKER")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-LEGIT")) { err in
            XCTAssertEqual(err as? AuthorizeSessionError, .stateMismatch)
        }
    }

    func test_parseCallback_rejects_missing_code() {
        let url = URL(string: "smithers://auth/callback?state=FAKE-S")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-S")) { err in
            XCTAssertEqual(err as? AuthorizeSessionError, .missingCode)
        }
    }

    func test_parseCallback_rejects_empty_code() {
        let url = URL(string: "smithers://auth/callback?code=&state=FAKE-S")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-S")) { err in
            XCTAssertEqual(err as? AuthorizeSessionError, .missingCode)
        }
    }

    func test_parseCallback_rejects_missing_state() {
        let url = URL(string: "smithers://auth/callback?code=abc")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-S")) { err in
            // No state present — surfaces as stateMismatch (state==nil != expected).
            XCTAssertEqual(err as? AuthorizeSessionError, .stateMismatch)
        }
    }

    func test_parseCallback_rejects_empty_query_body() {
        let url = URL(string: "smithers://auth/callback")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-S"))
    }

    func test_parseCallback_rejects_malformed_redirect_no_query() {
        // `;` after path is not a query; both code and state should be missing.
        let url = URL(string: "smithers://auth/callback;code=x")!
        XCTAssertThrowsError(try parseCallback(url: url, expectedState: "FAKE-S"))
    }

    // MARK: - Token exchange: structured error envelopes

    func test_exchange_invalid_grant_throws_invalidGrant() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_grant", description: "Authorization code expired."))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE_CODE", verifier: String(repeating: "a", count: 43))
            XCTFail("expected invalidGrant")
        } catch OAuth2Error.invalidGrant(let msg) {
            XCTAssertEqual(msg, "Authorization code expired.")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_invalid_request_also_maps_to_invalidGrant() async {
        // `invalid_request` shares the invalidGrant branch in postToken.
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_request", description: "missing code_verifier"))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidGrant")
        } catch OAuth2Error.invalidGrant(let msg) {
            XCTAssertEqual(msg, "missing code_verifier")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_invalid_client_returns_badStatus() async {
        // `invalid_client` is not in the allowlist that maps to invalidGrant —
        // it should fall through to badStatus carrying the raw payload.
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_client", description: "client_id not registered"))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected badStatus")
        } catch OAuth2Error.badStatus(let status, let snippet) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(snippet.contains("invalid_client"), "snippet should carry the wire body")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_401_maps_to_unauthorized() async {
        let transport = MockHTTPTransport()
        // 401 with no recognized structured body falls into the unauthorized branch.
        transport.responses.append(CannedResponseFactory.raw(status: 401, body: Data("not json".utf8)))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected unauthorized")
        } catch OAuth2Error.unauthorized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_5xx_maps_to_badStatus() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 503, body: Data("Service Unavailable".utf8)))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected badStatus")
        } catch OAuth2Error.badStatus(let status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_malformed_json_returns_invalidResponse() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 200, body: Data("{not json".utf8)))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_missing_access_token_returns_invalidResponse() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "refresh_token": "FAKE_R",
            "expires_in": 3600,
        ]))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_missing_refresh_token_returns_invalidResponse() async {
        // Refresh token is non-optional in the wire `Response` struct, so a
        // missing `refresh_token` must surface as invalidResponse.
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "expires_in": 3600,
        ]))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_missing_token_type_is_accepted_because_we_dont_validate_it() async throws {
        // The plue contract does not require `token_type` in the body; the
        // decoder ignores it. This documents that current behavior so any
        // future tightening is a deliberate test break.
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "refresh_token": "FAKE_R",
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        XCTAssertEqual(tokens.accessToken, "FAKE_A")
    }

    func test_exchange_expires_in_zero_makes_token_immediately_expired() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "refresh_token": "FAKE_R",
            "expires_in": 0,
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        let expiresAt = try XCTUnwrap(tokens.expiresAt)
        // expiresAt is "now + 0" — so it is at-or-before "now".
        XCTAssertLessThanOrEqual(expiresAt.timeIntervalSinceNow, 1.0)
    }

    func test_exchange_expires_in_negative_yields_past_expiresAt() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "refresh_token": "FAKE_R",
            "expires_in": -3600,
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        let expiresAt = try XCTUnwrap(tokens.expiresAt)
        XCTAssertLessThan(expiresAt.timeIntervalSinceNow, -1)
    }

    func test_exchange_expires_in_very_large_does_not_overflow() async throws {
        // Some servers send a year+ TTL (e.g. 31536000 = 1 year).
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "refresh_token": "FAKE_R",
            "expires_in": 31_536_000.0,
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        let expiresAt = try XCTUnwrap(tokens.expiresAt)
        XCTAssertGreaterThan(expiresAt.timeIntervalSinceNow, 30_000_000)
    }

    func test_exchange_missing_expires_in_yields_nil_expiresAt() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A",
            "refresh_token": "FAKE_R",
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        XCTAssertNil(tokens.expiresAt, "no `expires_in` ⇒ no expiresAt")
    }

    func test_exchange_empty_body_returns_invalidResponse() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 200, body: Data()))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_html_content_type_returns_invalidResponse() async {
        // Some hosting tiers return an HTML error page on misroute.
        let transport = MockHTTPTransport()
        let html = Data("<!doctype html><body>Bad Gateway</body>".utf8)
        transport.responses.append(CannedResponseFactory.raw(
            status: 200,
            body: html,
            headers: ["Content-Type": "text/html; charset=utf-8"]
        ))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_exchange_truncated_body_returns_invalidResponse() async {
        // Truncated mid-key — JSON decode should fail.
        let transport = MockHTTPTransport()
        let truncated = Data(#"{"access_token":"FAKE_A","refresh_to"#.utf8)
        transport.responses.append(CannedResponseFactory.raw(status: 200, body: truncated))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Token exchange: HTTP redirects

    func test_exchange_3xx_is_rejected_as_badStatus_when_transport_does_not_follow() async {
        // RFC 6749 does not mandate following redirects on the token endpoint;
        // our `URLSessionHTTPTransport` delegates the decision to URLSession's
        // default behavior. The mock does NOT follow redirects, so a bare 302
        // surfaces as `badStatus(302, …)`. That documents the wire contract:
        // a misconfigured backend returning 302 from /api/oauth2/token will be
        // treated as an outright failure rather than silently succeeding.
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(
            status: 302,
            body: Data(),
            headers: ["Location": "https://attacker.example/steal"]
        ))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected badStatus")
        } catch OAuth2Error.badStatus(let status, _) {
            XCTAssertEqual(status, 302)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Refresh-flow specifics

    func test_refresh_revoked_refresh_token_throws_invalidGrant() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_grant", description: "Refresh token revoked."))
        let client = makeClient(transport)
        do {
            _ = try await client.refresh(refreshToken: "FAKE_REVOKED")
            XCTFail("expected invalidGrant")
        } catch OAuth2Error.invalidGrant(let msg) {
            XCTAssertEqual(msg, "Refresh token revoked.")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_refresh_expired_refresh_token_throws_invalidGrant() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_grant", description: "Refresh token expired."))
        let client = makeClient(transport)
        do {
            _ = try await client.refresh(refreshToken: "FAKE_EXPIRED")
            XCTFail("expected invalidGrant")
        } catch OAuth2Error.invalidGrant(let msg) {
            XCTAssertEqual(msg, "Refresh token expired.")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_refresh_server_returns_same_access_token_no_rotation() async throws {
        // Some servers don't rotate on every refresh — verify the client
        // surfaces whatever the server sends without complaint.
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_SAME_A",
            "refresh_token": "FAKE_SAME_R",
            "expires_in": 3600,
        ]))
        let client = makeClient(transport)
        let tokens = try await client.refresh(refreshToken: "FAKE_SAME_R")
        XCTAssertEqual(tokens.accessToken, "FAKE_SAME_A")
        XCTAssertEqual(tokens.refreshToken, "FAKE_SAME_R")
    }

    func test_refresh_partial_response_missing_refresh_token_returns_invalidResponse() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: ["access_token": "FAKE_A"]))
        let client = makeClient(transport)
        do {
            _ = try await client.refresh(refreshToken: "FAKE")
            XCTFail("expected invalidResponse")
        } catch OAuth2Error.invalidResponse {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_refresh_sends_grant_type_refresh_token_and_client_id() async throws {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [
            "access_token": "FAKE_A2", "refresh_token": "FAKE_R2",
        ]))
        let client = makeClient(transport)
        _ = try await client.refresh(refreshToken: "FAKE_R1")

        let body = transport.recorded.first?.bodyString ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=FAKE_R1"))
        XCTAssertTrue(body.contains("client_id=FAKE-client-id"))
    }

    // MARK: - Concurrent refresh dedup
    //
    // Dedup of inflight refreshes is a `TokenManager` responsibility, not
    // an `OAuth2Client` one. `OAuth2Client.refresh` deliberately fires one
    // network call per invocation. We document that contract here so any
    // future change has to update the test.

    func test_concurrent_calls_to_OAuth2Client_refresh_each_hit_the_wire() async throws {
        let transport = MockHTTPTransport()
        transport.sendDelayNanoseconds = 5_000_000
        for _ in 0..<3 {
            transport.responses.append(.json(payload: [
                "access_token": "FAKE_A", "refresh_token": "FAKE_R",
            ]))
        }
        let client = makeClient(transport)

        async let a = client.refresh(refreshToken: "FAKE")
        async let b = client.refresh(refreshToken: "FAKE")
        async let c = client.refresh(refreshToken: "FAKE")
        _ = try await (a, b, c)

        XCTAssertEqual(transport.recorded.count, 3,
                       "OAuth2Client itself does not dedupe — see TokenManager for collapse")
    }

    // MARK: - PKCE edge cases

    func test_pkce_validateVerifier_rejects_too_short() {
        XCTAssertThrowsError(try PKCE.validateVerifier(String(repeating: "a", count: 42)))
    }

    func test_pkce_validateVerifier_rejects_empty_challenge_input() {
        XCTAssertThrowsError(try PKCE.validateVerifier(""))
    }

    func test_pkce_validateVerifier_rejects_too_long() {
        XCTAssertThrowsError(try PKCE.validateVerifier(String(repeating: "a", count: 129)))
    }

    func test_pkce_validateVerifier_accepts_max_length() throws {
        try PKCE.validateVerifier(String(repeating: "a", count: 128))
    }

    func test_pkce_validateVerifier_rejects_disallowed_characters() {
        // `+` and `/` are base64 (non-URL) — RFC 7636 disallows them.
        let bad = String(repeating: "a", count: 42) + "+"
        XCTAssertThrowsError(try PKCE.validateVerifier(bad))
        let bad2 = String(repeating: "a", count: 42) + "/"
        XCTAssertThrowsError(try PKCE.validateVerifier(bad2))
    }

    func test_pkce_challenge_for_empty_verifier_is_sha256_of_empty() {
        // Defensive contract: even though the spec disallows an empty
        // verifier, the bare `challenge(forVerifier:)` API must not crash.
        let challenge = PKCE.challenge(forVerifier: "")
        // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        // base64url(no pad) = 47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU
        XCTAssertEqual(challenge, "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    }

    func test_pkce_challenge_for_very_long_verifier_does_not_crash() {
        let long = String(repeating: "a", count: 4096)
        let challenge = PKCE.challenge(forVerifier: long)
        XCTAssertEqual(challenge.count, 43, "S256 challenge is always 32 bytes ⇒ 43 base64url chars")
    }

    // MARK: - Token revocation

    func test_revoke_access_token_swallows_4xx() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 400, body: Data("{}".utf8)))
        let client = makeClient(transport)
        // Per ticket 0133 threat model, revoke is best-effort. Must NOT throw.
        await client.revoke(accessToken: "FAKE_A")
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertTrue((transport.recorded[0].bodyString ?? "").contains("token_type_hint=access_token"))
    }

    func test_revoke_refresh_token_swallows_5xx() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 503, body: Data()))
        let client = makeClient(transport)
        await client.revoke(refreshToken: "FAKE_R")
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertTrue((transport.recorded[0].bodyString ?? "").contains("token_type_hint=refresh_token"))
    }

    func test_revoke_2xx_records_form_body() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [:]))
        let client = makeClient(transport)
        await client.revoke(accessToken: "FAKE_A_42")

        let recorded = transport.recorded[0]
        XCTAssertEqual(recorded.headers["Content-Type"], "application/x-www-form-urlencoded")
        let body = recorded.bodyString ?? ""
        XCTAssertTrue(body.contains("token=FAKE_A_42"))
        XCTAssertTrue(body.contains("client_id=FAKE-client-id"))
        XCTAssertTrue(body.contains("token_type_hint=access_token"))
    }

    func test_revoke_swallows_transport_error() async {
        // Best-effort revoke must not propagate. The transport queue is
        // empty so MockHTTPTransport returns 500 — still in the swallow path.
        let transport = MockHTTPTransport()
        let client = makeClient(transport)
        await client.revoke(accessToken: "FAKE")
    }

    func test_revokeAll_returns_unavailable_on_404() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 404, body: Data("{}".utf8)))
        let client = makeClient(transport)
        let result = await client.revokeAll(accessToken: "FAKE_A")
        XCTAssertEqual(result, .unavailable)
    }

    func test_revokeAll_returns_unavailable_on_405() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 405, body: Data()))
        let client = makeClient(transport)
        let result = await client.revokeAll(accessToken: "FAKE_A")
        XCTAssertEqual(result, .unavailable)
    }

    func test_revokeAll_returns_failed_on_5xx() async {
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 500, body: Data()))
        let client = makeClient(transport)
        let result = await client.revokeAll(accessToken: "FAKE_A")
        XCTAssertEqual(result, .failed)
    }

    func test_revokeAll_returns_failed_when_transport_throws() async {
        let throwing = ThrowingTransport()
        let client = makeClient(throwing)
        let result = await client.revokeAll(accessToken: "FAKE_A")
        XCTAssertEqual(result, .failed)
    }

    func test_revokeAll_returns_revoked_on_2xx() async {
        let transport = MockHTTPTransport()
        transport.responses.append(.json(payload: [:]))
        let client = makeClient(transport)
        let result = await client.revokeAll(accessToken: "FAKE_A")
        XCTAssertEqual(result, .revoked)
    }

    // MARK: - Transport-layer errors
    //
    // `MockHTTPTransport` cannot model a thrown `URLError`/network error
    // because `send()` is non-throwing in practice (returns 500 when the
    // queue is empty). We use a tiny `ThrowingTransport` to cover the
    // "transport raises" branch and document the gap.

    func test_exchange_raises_OAuth2Error_when_transport_throws() async {
        let throwing = ThrowingTransport()
        let client = makeClient(throwing)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected propagation")
        } catch OAuth2Error.transport {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_refresh_raises_OAuth2Error_when_transport_throws() async {
        let throwing = ThrowingTransport()
        let client = makeClient(throwing)
        do {
            _ = try await client.refresh(refreshToken: "FAKE")
            XCTFail("expected propagation")
        } catch OAuth2Error.transport {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Unicode / very-long payloads

    func test_unicode_in_error_description_round_trips_into_invalidGrant_message() async {
        let unicode = "アクセストークンが無効です — \u{1F510}\u{200B}"
        let transport = MockHTTPTransport()
        transport.responses.append(.error(status: 400, code: "invalid_grant", description: unicode))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected invalidGrant")
        } catch OAuth2Error.invalidGrant(let msg) {
            XCTAssertEqual(msg, unicode)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_very_long_access_token_response_is_decoded() async throws {
        let transport = MockHTTPTransport()
        let bigToken = String(repeating: "A", count: 16_384)
        transport.responses.append(.json(payload: [
            "access_token": bigToken,
            "refresh_token": "FAKE_R",
        ]))
        let client = makeClient(transport)
        let tokens = try await client.exchange(code: "FAKE", verifier: "v")
        XCTAssertEqual(tokens.accessToken.count, 16_384)
    }

    func test_very_long_error_snippet_is_truncated_to_256_bytes() async {
        let body = String(repeating: "X", count: 4096).data(using: .utf8)!
        let transport = MockHTTPTransport()
        transport.responses.append(CannedResponseFactory.raw(status: 502, body: body))
        let client = makeClient(transport)
        do {
            _ = try await client.exchange(code: "FAKE", verifier: "v")
            XCTFail("expected badStatus")
        } catch OAuth2Error.badStatus(let status, let snippet) {
            XCTAssertEqual(status, 502)
            // Implementation truncates to 256 bytes for diagnostics.
            XCTAssertEqual(snippet.count, 256)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Authorize URL: very long state / scopes

    func test_authorizeURL_handles_very_long_state_value() throws {
        let client = makeClient(MockHTTPTransport())
        let pair = try PKCE.generate()
        let bigState = String(repeating: "s", count: 2048)
        let url = client.authorizeURL(pkce: pair, state: bigState)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let state = comps.queryItems?.first { $0.name == "state" }?.value
        XCTAssertEqual(state, bigState)
    }
}

// MARK: - Local helpers

/// Small bridge that lets us build raw responses without re-declaring the
/// `MockHTTPTransport.CannedResponse` initializer in every test.
private enum CannedResponseFactory {
    static func raw(
        status: Int,
        body: Data,
        headers: [String: String] = [:]
    ) -> MockHTTPTransport.CannedResponse {
        MockHTTPTransport.CannedResponse(status: status, body: body, headers: headers)
    }
}

/// Transport that always raises — covers the "URLSession threw" path that
/// `MockHTTPTransport` cannot otherwise simulate.
private final class ThrowingTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int, [String: String]) {
        throw OAuth2Error.transport("FAKE-NETWORK-FAILURE")
    }
}
