#if os(iOS)
import Foundation
import XCTest

/// SmithersiOSE2EFeatureFlagsTests.swift
///
/// Real-backend feature-flag coverage for the iOS XCUITest bundle.
///
/// Scope rules for this file:
/// - Use the real plue `/api/feature-flags` endpoint via `URLSession`.
/// - Only assert on UI effects that are actually observable from the
///   current iOS product slice.
/// - Where the requested behaviour is not observable from XCUITest yet,
///   explicitly `XCTSkip` with a concrete reason instead of pretending
///   the scenario is covered.
final class SmithersiOSE2EFeatureFlagsTests: XCTestCase {
    private enum FlagName: String {
        case remoteSandboxEnabled = "remote_sandbox_enabled"
        case electricClientEnabled = "electric_client_enabled"
        case approvalsFlowEnabled = "approvals_flow_enabled"
        case devtoolsSnapshotEnabled = "devtools_snapshot_enabled"
        case runShapeEnabled = "run_shape_enabled"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_flags_http_endpoint_reachable() throws {
        let flags = try fetchFeatureFlags()

        XCTAssertFalse(flags.isEmpty, "GET /api/feature-flags should return a non-empty JSON flag map")
        XCTAssertNotNil(flags[FlagName.remoteSandboxEnabled.rawValue],
                        "response should include \(FlagName.remoteSandboxEnabled.rawValue)")
    }

    func test_flag_remote_sandbox_enabled_default() throws {
        if let override = ProcessInfo.processInfo.environment[E2ELaunchKey.remoteFlag],
           !override.isEmpty {
            throw XCTSkip(
                "Cannot assert the backend default for remote_sandbox_enabled because the runner exported \(E2ELaunchKey.remoteFlag)=\(override), which overrides the stack value."
            )
        }

        let flags = try fetchFeatureFlags()
        guard let remoteEnabled = flags[FlagName.remoteSandboxEnabled.rawValue] else {
            XCTFail("GET /api/feature-flags is missing \(FlagName.remoteSandboxEnabled.rawValue)")
            return
        }

        XCTAssertFalse(remoteEnabled, "Spec in ticket 0112 says remote_sandbox_enabled defaults to false")
        XCTAssertNotEqual(remoteEnabled, true, "default remote_sandbox_enabled must not resolve to true")
    }

    func test_flag_kill_switch_disables_ws_pty() throws {
        try requireSeededWorkspaceSession()

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launchEnvironment[E2ELaunchKey.remoteFlag] = "0"
        app.launch()

        let disabledSurface = app.otherElements["access.disabled.ios"]
        XCTAssertTrue(
            disabledSurface.waitForExistence(timeout: 15),
            "PLUE_REMOTE_SANDBOX_ENABLED=0 should force the disabled remote-access surface"
        )
        XCTAssertFalse(app.otherElements["app.root.ios"].exists,
                       "signed-in shell must not mount when the remote sandbox kill switch is off")
        XCTAssertFalse(app.buttons["content.ios.open-switcher"].exists,
                       "workspace switcher must not be reachable when the remote sandbox gate is off")
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "terminal.ios.surface").firstMatch.exists,
            "terminal surface must not mount when the remote sandbox gate is off, even with seeded workspace_session data"
        )
    }

    func test_flag_electric_client_gates_shape_subscribe() throws {
        try requireSeededWorkspace()

        let flags = try fetchFeatureFlags()
        guard let electricEnabled = flags[FlagName.electricClientEnabled.rawValue] else {
            XCTFail("GET /api/feature-flags is missing \(FlagName.electricClientEnabled.rawValue)")
            return
        }
        if electricEnabled {
            throw XCTSkip(
                "Cannot force electric_client_enabled=false from XCUITest: plue exposes only read-only GET /api/feature-flags, and the iOS workspace switcher does not expose a runtime transport marker to distinguish REST fallback from its baseline URLSession path."
            )
        }

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launchEnvironment[E2ELaunchKey.remoteFlag] = "1"
        app.launch()

        XCTAssertTrue(app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
                      "signed-in shell should still mount when electric_client_enabled is off")
        XCTAssertFalse(app.staticTexts["Sign in to Smithers"].exists,
                       "switcher fallback scenario must stay in the signed-in shell")

        let openSwitcher = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(openSwitcher.waitForExistence(timeout: 5),
                      "content shell should expose the open-switcher button")
        openSwitcher.tap()
        let switcherRoot = app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root").firstMatch
        XCTAssertTrue(switcherRoot.waitForExistence(timeout: 5),
                      "workspace switcher should open")

        let row = seededWorkspaceRow(in: app)
        let emptyState = app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.signedIn").firstMatch
        let backendUnavailable = app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.backendUnavailable").firstMatch

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if row.exists { break }
            if backendUnavailable.exists {
                XCTFail("switcher hit backendUnavailable with electric_client_enabled=false; expected REST-backed rows to still load")
                return
            }
            if emptyState.exists {
                XCTFail("seeded backend should not collapse to the signed-in empty state when electric_client_enabled=false")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        XCTAssertTrue(row.exists,
                      "seeded workspace row should still load when electric_client_enabled=false")
        XCTAssertFalse(backendUnavailable.exists,
                       "REST fallback scenario must not surface backendUnavailable")
    }

    func test_flag_approvals_flow_hides_ui_when_disabled() throws {
        throw XCTSkip(
            "approvals_flow_enabled is not observable from iOS XCUITest yet: the current iOS shell does not mount an approvals inbox or `approvals.root` surface regardless of flag state. Follow-up: ship the iOS approvals surface with a stable accessibility identifier."
        )
    }

    func test_flag_devtools_snapshot_gates_surface() throws {
        throw XCTSkip(
            "devtools_snapshot_enabled is not observable from iOS XCUITest yet: the current iOS app does not expose a devtools snapshot surface or stable accessibility identifier. Follow-up: add an iOS-visible devtools surface and gate marker."
        )
    }

    func test_flag_run_shape_gates_workflow_run_shape() throws {
        throw XCTSkip(
            "run_shape_enabled is not observable from iOS XCUITest yet: the current iOS product slice does not expose workflow_runs subscription attempts, related logs, or a run-shape UI surface. Follow-up: add a runtime debug marker or a stable UI state tied to workflow_runs."
        )
    }

    func test_flag_ttl_cache_respected() throws {
        throw XCTSkip(
            "Feature flag TTL caching is internal to FeatureFlagsClient and is not surfaced through a stable iOS XCUITest-observable UI marker or timing hook. Follow-up: expose last-refresh/cache-hit diagnostics for E2E."
        )
    }

    func test_flag_unknown_flag_returns_default() throws {
        let flags = try fetchFeatureFlags()
        let unknownFlag = "xcuitest_unknown_flag_e2e"

        XCTAssertNil(flags[unknownFlag],
                     "GET /api/feature-flags should not materialize unknown keys")
        XCTAssertFalse(flags[unknownFlag] ?? false,
                       "unknown flags must resolve to false by client-default semantics, not an error")
    }

    func test_flag_changes_propagate_within_ttl() throws {
        throw XCTSkip(
            "Cannot mutate feature flags from this XCUITest bundle today: plue exposes read-only GET /api/feature-flags in this checkout, and no E2E-only admin mutation hook is available. Follow-up: add a real admin/E2E mutation path for flag flips."
        )
    }

    // MARK: - Helpers

    private func requireSeededWorkspace() throws {
        guard ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1" else {
            let message = "seeded workspace scenarios require PLUE_E2E_SEEDED=1"
            XCTFail(message)
            throw NSError(
                domain: "feature-flags-e2e",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func requireSeededWorkspaceSession() throws {
        try requireSeededWorkspace()
        guard let sessionID = ProcessInfo.processInfo.environment[E2ELaunchKey.seededWorkspaceSessionID],
              !sessionID.isEmpty else {
            let message = "terminal-gating scenario requires \(E2ELaunchKey.seededWorkspaceSessionID)"
            XCTFail(message)
            throw NSError(
                domain: "feature-flags-e2e",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func seededWorkspaceRow(in app: XCUIApplication) -> XCUIElement {
        if let expectedWorkspaceID = ProcessInfo.processInfo.environment[E2ELaunchKey.seededWorkspaceID],
           !expectedWorkspaceID.isEmpty {
            return app.buttons["switcher.row.\(expectedWorkspaceID)"]
        }

        return app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
        ).firstMatch
    }

    private func fetchFeatureFlags() throws -> [String: Bool] {
        let baseURL = try requiredBaseURL()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/feature-flags"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try syncRequest(request)
        guard status == 200 else {
            throw NSError(
                domain: "feature-flags-e2e",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: "GET /api/feature-flags returned HTTP \(status)"]
            )
        }
        return try decodeFlags(from: data)
    }

    private func requiredBaseURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment[E2ELaunchKey.baseURL] ?? "http://localhost:4000"
        guard let baseURL = URL(string: raw) else {
            throw NSError(
                domain: "feature-flags-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid \(E2ELaunchKey.baseURL)=\(raw)"]
            )
        }
        return baseURL
    }

    private func decodeFlags(from data: Data) throws -> [String: Bool] {
        if let envelope = try? JSONDecoder().decode(FeatureFlagsEnvelope.self, from: data) {
            return envelope.flags
        }
        if let direct = try? JSONDecoder().decode([String: Bool].self, from: data) {
            return direct
        }

        let snippet = String(data: data.prefix(256), encoding: .utf8) ?? "<non-utf8>"
        throw NSError(
            domain: "feature-flags-e2e",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid feature-flags JSON body: \(snippet)"]
        )
    }

    private func syncRequest(
        _ request: URLRequest,
        timeout: TimeInterval = 15
    ) throws -> (Data, Int) {
        var result: (Data, Int)?
        var resultError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 1
        let session = URLSession(configuration: configuration)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error {
                resultError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                resultError = NSError(
                    domain: "feature-flags-e2e",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Missing HTTPURLResponse for \(request.url?.absoluteString ?? "?")"]
                )
                return
            }
            result = (data ?? Data(), http.statusCode)
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 2)
        if let resultError {
            throw resultError
        }
        guard let result else {
            throw NSError(
                domain: "feature-flags-e2e",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(request.url?.absoluteString ?? "?")"]
            )
        }
        return result
    }
}

private struct FeatureFlagsEnvelope: Decodable {
    let flags: [String: Bool]
}
#endif
