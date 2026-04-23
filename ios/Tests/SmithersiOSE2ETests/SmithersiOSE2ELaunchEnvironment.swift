// SmithersiOSE2ELaunchEnvironment.swift — XCUITest helper that stamps the
// process launch environment used by `Shared/Sources/SmithersE2ESupport/`.
//
// Ticket: ios-e2e-harness. Every test in this bundle is expected to call
// `applyE2ELaunchEnvironment(to:)` on its `XCUIApplication` BEFORE
// `app.launch()` so the app boots directly into its signed-in shell
// talking to a local plue stack. The env-var contract is duplicated here
// intentionally (string constants) because the XCUITest bundle does not
// link the SmithersE2ESupport module — tests are driven externally and
// the app under test reads the same keys on its own side.

#if os(iOS)
import XCTest

/// Keys that the XCUITest runner stamps into `launchEnvironment`. Kept in
/// sync with `E2EEnvironmentKey` in `Shared/Sources/SmithersE2ESupport/`.
enum E2ELaunchKey {
    static let mode = "PLUE_E2E_MODE"
    static let bearer = "SMITHERS_E2E_BEARER"
    static let baseURL = "PLUE_BASE_URL"
    static let refreshToken = "SMITHERS_E2E_REFRESH"
    /// Seed marker. When set to "1", tests that expect a pre-seeded
    /// workspace row (`test_signs_in_and_sees_seeded_workspace`) will
    /// assert its presence; when "0", tests assert the empty state.
    static let seededData = "PLUE_E2E_SEEDED"
    /// Workspace title that `ios/scripts/seed-e2e-data.sh` inserts. The
    /// test harness asserts this exact string appears in the switcher.
    static let seededWorkspaceTitle = "PLUE_E2E_SEEDED_WORKSPACE_TITLE"
    /// UUID of the seeded workspace. Tests match against the
    /// `switcher.row.<id>` accessibility identifier rather than the
    /// title text (SwiftUI Button absorbs child StaticText into its
    /// label, so the title is not separately accessible).
    static let seededWorkspaceID = "PLUE_E2E_WORKSPACE_ID"
    /// UUID of the seeded `workspace_sessions` row (terminal scenario).
    /// Forwarded into the app so `WorkspaceDetailPlaceholder` knows to
    /// mount `TerminalSurface` when the row exists.
    static let seededWorkspaceSessionID = "PLUE_E2E_WORKSPACE_SESSION_ID"
    /// UUID of the seeded `agent_sessions` row. Approval rows foreign-
    /// key on this, so the approvals scenario asserts on it as proof
    /// the seed succeeded.
    static let seededAgentSessionID = "PLUE_E2E_AGENT_SESSION_ID"
    /// UUID of the seeded pending approval. Approvals scenario asserts
    /// the DB row exists + exercises the HTTP decide path against it.
    static let seededApprovalID = "PLUE_E2E_APPROVAL_ID"
    /// Owner/name pair for the approvals `/api/repos/{owner}/{repo}/…`
    /// route. Seeded by the script for idempotency.
    static let seededRepoOwner = "PLUE_E2E_REPO_OWNER"
    static let seededRepoName = "PLUE_E2E_REPO_NAME"
    /// Name of the docker container backing plue's api. The reconnect
    /// scenario uses `docker pause` / `docker unpause` on it.
    static let dockerAPIContainer = "PLUE_E2E_DOCKER_API_CONTAINER"
}

/// Shape of the per-test launch environment. The harness script passes
/// these as process env vars; we forward them into the app under test.
struct E2ELaunchEnvironment {
    let bearer: String
    let baseURL: String
    let refreshToken: String?
    let seeded: Bool
    let seededWorkspaceTitle: String?

    /// Pull every relevant key from `ProcessInfo.processInfo.environment`
    /// (set by `ios/scripts/run-e2e.sh`), with loud fatalErrors on missing
    /// required keys so test failures are obvious, not silent.
    static func fromProcess(_ file: StaticString = #filePath, _ line: UInt = #line) -> E2ELaunchEnvironment {
        let env = ProcessInfo.processInfo.environment
        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            fatalError("\(E2ELaunchKey.bearer) missing from test-runner env — did you invoke via ios/scripts/run-e2e.sh?", file: file, line: line)
        }
        let baseURL = env[E2ELaunchKey.baseURL] ?? "http://localhost:4000"
        let refresh = env[E2ELaunchKey.refreshToken]
        let seeded = env[E2ELaunchKey.seededData] == "1"
        let title = env[E2ELaunchKey.seededWorkspaceTitle]
        return E2ELaunchEnvironment(
            bearer: bearer,
            baseURL: baseURL,
            refreshToken: refresh,
            seeded: seeded,
            seededWorkspaceTitle: title
        )
    }

    /// Stamp our keys onto `app.launchEnvironment`. Existing entries are
    /// preserved (so a test can override a subset before calling this).
    func apply(to app: XCUIApplication, bypassAuth: Bool = true) {
        if bypassAuth {
            app.launchEnvironment[E2ELaunchKey.mode] = "1"
            app.launchEnvironment[E2ELaunchKey.bearer] = bearer
        } else {
            // Explicitly DO NOT set the mode/bearer — lets us exercise
            // the "cold launch shows sign-in" path against the same
            // backend config.
            app.launchEnvironment.removeValue(forKey: E2ELaunchKey.mode)
            app.launchEnvironment.removeValue(forKey: E2ELaunchKey.bearer)
        }
        app.launchEnvironment[E2ELaunchKey.baseURL] = baseURL
        if let refresh = refreshToken {
            app.launchEnvironment[E2ELaunchKey.refreshToken] = refresh
        }
        if seeded {
            app.launchEnvironment[E2ELaunchKey.seededData] = "1"
            if let title = seededWorkspaceTitle {
                app.launchEnvironment[E2ELaunchKey.seededWorkspaceTitle] = title
            }
            // Forward every seeded UUID so tests and the app under test
            // share the same view of what's in Postgres. Keys that the
            // app also reads (e.g. seededWorkspaceSessionID — gates the
            // TerminalSurface mount in `WorkspaceDetailPlaceholder`) are
            // stamped into `launchEnvironment`; keys only the test side
            // uses (approval id, repo owner/name, docker container)
            // stay in the process environment where the test itself
            // reads them via ProcessInfo.
            let procEnv = ProcessInfo.processInfo.environment
            let forwardedKeys: [String] = [
                E2ELaunchKey.seededWorkspaceID,
                E2ELaunchKey.seededWorkspaceSessionID,
                E2ELaunchKey.seededAgentSessionID,
                E2ELaunchKey.seededApprovalID,
                E2ELaunchKey.seededRepoOwner,
                E2ELaunchKey.seededRepoName,
            ]
            for k in forwardedKeys {
                if let v = procEnv[k], !v.isEmpty {
                    app.launchEnvironment[k] = v
                }
            }
        }
    }
}

/// Small convenience so tests don't each write out the ProcessInfo dance.
func applyE2ELaunchEnvironment(to app: XCUIApplication, bypassAuth: Bool = true) -> E2ELaunchEnvironment {
    let env = E2ELaunchEnvironment.fromProcess()
    env.apply(to: app, bypassAuth: bypassAuth)
    return env
}
#endif
