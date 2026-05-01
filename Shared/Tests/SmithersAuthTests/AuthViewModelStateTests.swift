// AuthViewModelStateTests.swift — exhaustive state-transition coverage for
// `AuthViewModel`. Complements the wire-level coverage in
// `MockedServerIntegrationTests.swift` by focusing on the @Published phase
// machine itself: every legal edge, the surfaced error messages for each
// OAuth2/AuthorizeSession failure shape, restored-session bootstrap, and
// concurrent mutation behavior.
//
// All fakes are reused from the existing test target — no production code
// is modified.

import Combine
import XCTest
@testable import SmithersAuth

@MainActor
final class AuthViewModelStateTests: XCTestCase {

    // MARK: - Fixtures

    private func makeConfig() -> OAuth2ClientConfig {
        OAuth2ClientConfig(
            baseURL: URL(string: "https://plue.test")!,
            clientID: "FAKE-client-id",
            redirectURI: "smithers://auth/callback"
        )
    }

    /// Successful `/token` body.
    private func successTokenPayload(
        access: String = "FAKE_ACCESS",
        refresh: String = "FAKE_REFRESH",
        expiresIn: Double? = 3600
    ) -> [String: Any] {
        var p: [String: Any] = [
            "access_token": access,
            "refresh_token": refresh,
            "scope": "read write",
        ]
        if let e = expiresIn { p["expires_in"] = e }
        return p
    }

    /// Build a model + dependencies with a clean store.
    private func makeFreshModel() -> (AuthViewModel, MockHTTPTransport, MockAuthorizeSessionDriver, InMemoryTokenStore, TokenManager) {
        let transport = MockHTTPTransport()
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore()
        let mgr = TokenManager(client: client, store: store)
        let driver = MockAuthorizeSessionDriver()
        let model = AuthViewModel(
            client: client,
            tokens: mgr,
            driver: driver,
            callbackScheme: "smithers"
        )
        return (model, transport, driver, store, mgr)
    }

    /// Build a model whose store already has a session — the
    /// "restore on launch" entry point.
    private func makeRestoredModel(
        validator: (() async -> AccessTokenValidationResult)? = nil,
        cached: OAuth2Tokens = OAuth2Tokens(accessToken: "CACHED_A", refreshToken: "CACHED_R")
    ) -> (AuthViewModel, MockHTTPTransport, MockAuthorizeSessionDriver, InMemoryTokenStore, TokenManager) {
        let transport = MockHTTPTransport()
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: cached)
        let mgr = TokenManager(client: client, store: store)
        let driver = MockAuthorizeSessionDriver()
        let model = AuthViewModel(
            client: client,
            tokens: mgr,
            driver: driver,
            callbackScheme: "smithers",
            startupSessionValidator: validator
        )
        return (model, transport, driver, store, mgr)
    }

    /// Capture every emitted phase via Combine. Returns a snapshot closure
    /// the test can read after exercising the model. The published value
    /// emits the current value synchronously on subscription, so the first
    /// recorded entry is always the initial phase.
    private func recordPhases(_ model: AuthViewModel) -> (snapshot: () -> [AuthViewModel.Phase], cancel: () -> Void) {
        var captured: [AuthViewModel.Phase] = []
        let lock = NSLock()
        let cancellable = model.$phase.sink { phase in
            lock.lock()
            captured.append(phase)
            lock.unlock()
        }
        return (
            snapshot: {
                lock.lock(); defer { lock.unlock() }
                return captured
            },
            cancel: { cancellable.cancel() }
        )
    }

    // MARK: - 1. Idle → signing in → success → signed in

    func test_signedOut_to_signingIn_to_signedIn_on_success() async throws {
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        XCTAssertEqual(model.phase, .signedOut)
        await model.signIn()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(try store.load()?.accessToken, "FAKE_ACCESS")
    }

    // MARK: - 2. Idle → signing in → failure → error → retry → signing in

    func test_error_phase_then_retry_returns_to_signingIn_then_signedIn() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        // First attempt: bad status surfaces .error
        transport.responses.append(.error(status: 500, code: "server_error"))
        // Second attempt (retry): success
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error = model.phase else {
            return XCTFail("expected .error after first failure, got \(model.phase)")
        }

        // Retry: .error is an allowed re-entry into .signingIn.
        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
    }

    func test_invalid_grant_error_message_surface() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.error(
            status: 400,
            code: "invalid_grant",
            description: "PKCE verifier rejected"
        ))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("Sign-in rejected"), "got: \(msg)")
        XCTAssertTrue(msg.contains("PKCE verifier rejected"), "got: \(msg)")
    }

    func test_unauthorized_error_surfaces_friendly_message() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.error(status: 401, code: "unauthorized"))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertEqual(msg, "Authentication failed. Please try again.")
    }

    func test_bad_status_error_includes_status_code() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.error(status: 502, code: "bad_gateway"))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("502"), "got: \(msg)")
    }

    func test_invalid_response_surfaces_error_message() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        // 200 OK but body cannot decode as the expected token shape.
        transport.responses.append(.json(payload: ["unexpected": "shape"]))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(
            msg.contains("unexpected response") || msg.contains("Server returned"),
            "got: \(msg)"
        )
    }

    // MARK: - 3. AuthorizeSessionError surfaces

    func test_user_cancellation_returns_to_signedOut_not_error() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        driver.behavior = .cancel

        await model.signIn()
        XCTAssertEqual(model.phase, .signedOut)
    }

    func test_state_mismatch_surfaces_csrf_message() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        driver.behavior = .stateMismatch

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("CSRF"), "got: \(msg)")
    }

    func test_missing_code_surfaces_clear_message() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        driver.behavior = .error(.missingCode)

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("authorization code"), "got: \(msg)")
    }

    func test_presenter_unavailable_surfaces_no_window_message() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        driver.behavior = .error(.presenterUnavailable)

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("window"), "got: \(msg)")
    }

    func test_underlying_authorize_error_passes_message_through() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        driver.behavior = .error(.underlying("simulator unavailable"))

        await model.signIn()
        guard case .error(let msg) = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }
        XCTAssertEqual(msg, "simulator unavailable")
    }

    // MARK: - 4. Whitelist denied is terminal

    func test_whitelist_denied_phase_is_terminal_no_retry() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.error(
            status: 403,
            code: "access_not_yet_granted",
            description: "Pending approval."
        ))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .whitelistDenied(let msg) = model.phase else {
            return XCTFail("expected .whitelistDenied, got \(model.phase)")
        }
        XCTAssertTrue(msg.contains("Pending approval"), "got: \(msg)")

        // Re-invoking signIn from whitelistDenied is a no-op.
        let recordedBefore = transport.recorded.count
        await model.signIn()
        XCTAssertEqual(transport.recorded.count, recordedBefore)
        if case .whitelistDenied = model.phase { /* still terminal */ } else {
            XCTFail("phase should remain whitelistDenied, got \(model.phase)")
        }
    }

    // MARK: - 5. Sign out

    func test_signOut_from_signedIn_clears_session_and_returns_to_signedOut() async throws {
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.responses.append(.json(payload: successTokenPayload()))
        // signOut may try revoke-all and per-token revoke as fallback.
        transport.responses.append(.json(payload: [:]))
        transport.responses.append(.json(payload: [:]))
        transport.responses.append(.json(payload: [:]))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    func test_signOut_from_signedOut_is_idempotent() async throws {
        let (model, _, _, store, _) = makeFreshModel()
        XCTAssertEqual(model.phase, .signedOut)

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    func test_signOut_from_error_returns_to_signedOut() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.error(status: 500, code: "server_error"))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        guard case .error = model.phase else {
            return XCTFail("expected .error, got \(model.phase)")
        }

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
    }

    // MARK: - 6. Re-entry guards (debounce / dedup)

    func test_signIn_is_noop_while_signingIn_in_flight() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        // Slow exchange so we can race a second tap against the first.
        transport.sendDelayNanoseconds = 50_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        async let first: Void = model.signIn()
        // Briefly yield so the first call has flipped the phase to signingIn.
        try? await Task.sleep(nanoseconds: 5_000_000)
        await model.signIn() // should be a no-op
        await first

        XCTAssertEqual(model.phase, .signedIn)
        // Only one /token request was recorded — the second tap was rejected.
        let tokenCalls = transport.recorded.filter {
            $0.url.absoluteString.hasSuffix("/api/oauth2/token")
        }
        XCTAssertEqual(tokenCalls.count, 1)
    }

    func test_signIn_is_noop_when_already_signedIn() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)

        let recordedBefore = transport.recorded.count
        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(transport.recorded.count, recordedBefore)
    }

    func test_signIn_is_noop_during_restoringSession() async throws {
        let validator: () async -> AccessTokenValidationResult = {
            // Slow validator to widen the window.
            try? await Task.sleep(nanoseconds: 30_000_000)
            return .valid
        }
        let (model, transport, _, _, _) = makeRestoredModel(validator: validator)
        XCTAssertEqual(model.phase, .restoringSession)

        // Starting a sign-in here MUST NOT bump the phase or hit the wire.
        let recordedBefore = transport.recorded.count
        await model.signIn()
        XCTAssertEqual(transport.recorded.count, recordedBefore)
        XCTAssertEqual(model.phase, .restoringSession)

        // Drain the validator so the test exits cleanly.
        await model.resolveRestoredSessionIfNeeded()
        XCTAssertEqual(model.phase, .signedIn)
    }

    // MARK: - 7. Restore session on launch

    func test_restore_with_no_session_starts_signedOut() {
        let (model, _, _, _, _) = makeFreshModel()
        XCTAssertEqual(model.phase, .signedOut)
    }

    func test_restore_with_valid_token_no_validator_starts_signedIn() {
        let transport = MockHTTPTransport()
        let client = OAuth2Client(config: makeConfig(), transport: transport)
        let store = InMemoryTokenStore(initial: OAuth2Tokens(accessToken: "A", refreshToken: "R"))
        let mgr = TokenManager(client: client, store: store)
        let model = AuthViewModel(
            client: client,
            tokens: mgr,
            driver: MockAuthorizeSessionDriver(),
            callbackScheme: "smithers"
        )
        XCTAssertEqual(model.phase, .signedIn)
    }

    func test_restore_with_valid_validator_resolves_to_signedIn() async {
        let (model, _, _, _, _) = makeRestoredModel(validator: { .valid })
        XCTAssertEqual(model.phase, .restoringSession)

        await model.resolveRestoredSessionIfNeeded()
        XCTAssertEqual(model.phase, .signedIn)
    }

    func test_restore_with_indeterminate_validator_resolves_to_signedIn() async {
        let (model, _, _, _, _) = makeRestoredModel(validator: { .indeterminate })
        XCTAssertEqual(model.phase, .restoringSession)

        await model.resolveRestoredSessionIfNeeded()
        XCTAssertEqual(model.phase, .signedIn)
    }

    func test_restore_with_invalid_validator_signs_out_and_clears_store() async throws {
        let (model, _, _, store, _) = makeRestoredModel(validator: { .invalid })
        XCTAssertEqual(model.phase, .restoringSession)

        await model.resolveRestoredSessionIfNeeded()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    func test_resolve_restored_session_runs_at_most_once() async {
        actor Counter {
            var count = 0
            func bump() { count += 1 }
            func get() -> Int { count }
        }
        let counter = Counter()
        let (model, _, _, _, _) = makeRestoredModel(validator: {
            await counter.bump()
            return .valid
        })

        await model.resolveRestoredSessionIfNeeded()
        await model.resolveRestoredSessionIfNeeded()
        await model.resolveRestoredSessionIfNeeded()

        let n = await counter.get()
        XCTAssertEqual(n, 1)
        XCTAssertEqual(model.phase, .signedIn)
    }

    func test_resolve_when_not_restoring_is_a_noop() async {
        let (model, _, _, _, _) = makeFreshModel()
        XCTAssertEqual(model.phase, .signedOut)
        await model.resolveRestoredSessionIfNeeded()
        XCTAssertEqual(model.phase, .signedOut)
    }

    // MARK: - 8. Concurrent state mutations

    func test_concurrent_signIn_taps_collapse_to_one_flow() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 30_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in await model.signIn() }
            }
            await group.waitForAll()
        }

        XCTAssertEqual(model.phase, .signedIn)
        let tokenCalls = transport.recorded.filter {
            $0.url.absoluteString.hasSuffix("/api/oauth2/token")
        }
        XCTAssertEqual(tokenCalls.count, 1)
    }

    func test_signOut_while_signingIn_cancels_inflight_signIn_and_no_tokens_installed() async throws {
        // The view model is @MainActor — `signOut` runs on the main actor while
        // an in-flight `signIn` is suspended awaiting the network. After the
        // cancellation fix, signOut MUST cancel the in-flight signIn task so
        // its post-await tail cannot resurrect the session by installing
        // tokens or republishing `.signedIn`. This is a security/correctness
        // invariant: an explicit signOut must always win.
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 50_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        // One revoke-all response is enough — signOut won't fall back to per-token
        // revokes when revoke-all returns 2xx.
        transport.responses.append(.json(payload: [:]))
        driver.behavior = .success(code: "CODE")

        async let signing: Void = model.signIn()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(model.phase, .signingIn, "signOut must race against an in-flight signingIn")

        await model.signOut()
        // The instant signOut returns: store is empty, phase is signedOut.
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())

        // Drain the (now cancelled) signIn task and re-assert: phase must
        // STILL be .signedOut and the store STILL empty. The cancellation
        // gates in `runSignIn` short-circuit token install.
        await signing
        XCTAssertEqual(model.phase, .signedOut, "cancelled signIn must not republish .signedIn")
        XCTAssertNil(try store.load(), "cancelled signIn must not install tokens after signOut")
    }

    func test_signOut_then_signIn_cancellation_does_not_surface_user_visible_error() async throws {
        // Cancelling an in-flight signIn must NOT leave the model in
        // `.error(...)` — the user explicitly asked to sign out, so a
        // cancellation-derived error message would be both confusing and
        // wrong. Final state is .signedOut with no error surface.
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 50_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        transport.responses.append(.json(payload: [:]))
        driver.behavior = .success(code: "CODE")

        let recorder = recordPhases(model)
        defer { recorder.cancel() }

        async let signing: Void = model.signIn()
        try? await Task.sleep(nanoseconds: 10_000_000)
        await model.signOut()
        await signing

        // Final phase: signedOut, no .error emission.
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
        let phases = recorder.snapshot()
        for p in phases {
            if case .error(let msg) = p {
                XCTFail("cancellation must not surface .error, got: \(msg)")
            }
        }
        XCTAssertEqual(phases.last, .signedOut)
    }

    func test_signOut_after_signIn_already_succeeded_still_works() async throws {
        // Sanity guard: the cancellation plumbing must not break the
        // common path where signIn fully completes before signOut runs.
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.responses.append(.json(payload: successTokenPayload()))
        transport.responses.append(.json(payload: [:]))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(try store.load()?.accessToken, "FAKE_ACCESS")

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    func test_rapid_signIn_signOut_cycles_converge_to_signedOut() async throws {
        // Hammer the model with alternating in-flight signIn / signOut
        // taps. Each signOut MUST cancel the in-flight signIn so the
        // final settled state is deterministically .signedOut with an
        // empty store — no resurrected session.
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 20_000_000
        // Generously seed tokens + revoke responses for up to N cycles.
        for i in 0..<8 {
            transport.responses.append(.json(payload: successTokenPayload(
                access: "A\(i)", refresh: "R\(i)"
            )))
            transport.responses.append(.json(payload: [:]))
        }
        driver.behavior = .success(code: "CODE")

        // 4 cycles of signIn → signOut → signIn → signOut, each signIn
        // started without awaiting so signOut races against the suspended
        // network call.
        for _ in 0..<4 {
            async let signing: Void = model.signIn()
            try? await Task.sleep(nanoseconds: 5_000_000)
            await model.signOut()
            await signing
            // Per cycle invariant: signOut wins.
            XCTAssertEqual(model.phase, .signedOut)
            XCTAssertNil(try store.load())
        }

        // Final convergence.
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    func test_taskgroup_many_signIn_taps_collapse_then_signOut_settles() async throws {
        // Many concurrent UI taps + a background sign-out. We don't assert the
        // *final* phase (the trailing un-cancelled signIn can race past
        // signOut — see test above). We DO assert that across the storm we
        // never burn more than one token exchange and signOut wipes the store
        // at least once.
        let (model, transport, driver, store, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 20_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        for _ in 0..<6 {
            transport.responses.append(.json(payload: [:]))
        }
        driver.behavior = .success(code: "CODE")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { @MainActor in await model.signIn() }
            }
            await group.waitForAll()
        }
        // De-dup invariant.
        let tokenCalls = transport.recorded.filter {
            $0.url.absoluteString.hasSuffix("/api/oauth2/token")
                && ($0.bodyString ?? "").contains("grant_type=authorization_code")
        }
        XCTAssertEqual(tokenCalls.count, 1, "duplicate signIn taps must collapse")
        XCTAssertEqual(model.phase, .signedIn)

        // Now wipe — final settled state is deterministic when no signIn is
        // still in-flight.
        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(try store.load())
    }

    // MARK: - 9. @Published emission counts

    func test_emission_count_signedOut_to_signedIn_is_two_steps() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        let recorder = recordPhases(model)
        defer { recorder.cancel() }
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        await model.signIn()

        // Sequence: initial .signedOut, then .signingIn, then .signedIn.
        let phases = recorder.snapshot()
        XCTAssertGreaterThanOrEqual(phases.count, 3, "got \(phases)")
        XCTAssertEqual(phases.first, .signedOut)
        XCTAssertEqual(phases.last, .signedIn)
        XCTAssertTrue(phases.contains(.signingIn), "got \(phases)")
    }

    func test_emission_count_failure_path_includes_signingIn_then_error() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        let recorder = recordPhases(model)
        defer { recorder.cancel() }
        transport.responses.append(.error(status: 401, code: "unauthorized"))
        driver.behavior = .success(code: "CODE")

        await model.signIn()

        let phases = recorder.snapshot()
        XCTAssertEqual(phases.first, .signedOut)
        XCTAssertTrue(phases.contains(.signingIn))
        if case .error = phases.last {
            // ok
        } else {
            XCTFail("last phase should be .error, got \(String(describing: phases.last))")
        }
    }

    func test_user_cancel_emits_signingIn_then_back_to_signedOut() async throws {
        let (model, _, driver, _, _) = makeFreshModel()
        let recorder = recordPhases(model)
        defer { recorder.cancel() }
        driver.behavior = .cancel

        await model.signIn()

        let phases = recorder.snapshot()
        XCTAssertEqual(phases.first, .signedOut)
        XCTAssertTrue(phases.contains(.signingIn), "got \(phases)")
        XCTAssertEqual(phases.last, .signedOut)
    }

    func test_no_extra_emissions_when_signIn_rejected_during_signingIn() async throws {
        let (model, transport, driver, _, _) = makeFreshModel()
        transport.sendDelayNanoseconds = 30_000_000
        transport.responses.append(.json(payload: successTokenPayload()))
        driver.behavior = .success(code: "CODE")

        let recorder = recordPhases(model)
        defer { recorder.cancel() }

        async let first: Void = model.signIn()
        try? await Task.sleep(nanoseconds: 5_000_000)
        await model.signIn() // ignored — no extra emission expected
        await first

        let phases = recorder.snapshot()
        // initial .signedOut + .signingIn + .signedIn = 3 distinct emissions.
        // Allow exactly that — the rejected second call must not republish.
        XCTAssertEqual(phases.count, 3, "got \(phases)")
        XCTAssertEqual(phases, [.signedOut, .signingIn, .signedIn])
    }

    func test_emission_count_restore_invalid_validator_signedOut_terminal() async throws {
        let (model, _, _, _, _) = makeRestoredModel(validator: { .invalid })
        let recorder = recordPhases(model)
        defer { recorder.cancel() }

        await model.resolveRestoredSessionIfNeeded()

        let phases = recorder.snapshot()
        // Initial subscription captured .restoringSession (not .signedOut)
        // because the cached session bumped the constructor branch.
        XCTAssertEqual(phases.first, .restoringSession)
        XCTAssertEqual(phases.last, .signedOut)
    }

    // MARK: - 10. Recovery / round-trip after sign-out

    func test_sign_back_in_after_sign_out_works_end_to_end() async throws {
        let (model, transport, driver, store, _) = makeFreshModel()
        // First sign-in
        transport.responses.append(.json(payload: successTokenPayload(access: "A1", refresh: "R1")))
        // Sign-out: revoke-all responds 200 → no fallback per-token revoke calls.
        transport.responses.append(.json(payload: [:]))
        // Second sign-in
        transport.responses.append(.json(payload: successTokenPayload(access: "A2", refresh: "R2")))
        driver.behavior = .success(code: "CODE")

        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(try store.load()?.accessToken, "A1")

        await model.signOut()
        XCTAssertEqual(model.phase, .signedOut)

        await model.signIn()
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(try store.load()?.accessToken, "A2")
    }

    func test_random_state_helper_produces_unique_values() throws {
        var seen = Set<String>()
        for _ in 0..<32 {
            let s = try AuthViewModel.randomState()
            XCTAssertFalse(s.isEmpty)
            XCTAssertTrue(seen.insert(s).inserted, "randomState() collision: \(s)")
        }
    }
}
