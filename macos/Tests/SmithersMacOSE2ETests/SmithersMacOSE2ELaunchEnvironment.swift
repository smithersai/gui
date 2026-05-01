// SmithersMacOSE2ELaunchEnvironment.swift — XCUITest helper that stamps
// the process launch environment used by `Shared/Sources/SmithersE2ESupport/`
// on the macOS test runner side.
//
// Ticket: macos-e2e-harness. Mirrors
// `ios/Tests/SmithersiOSE2ETests/SmithersiOSE2ELaunchEnvironment.swift`.
// Every test in this bundle is expected to call
// `applyE2ELaunchEnvironment(to:)` on its `XCUIApplication` BEFORE
// `app.launch()` so the app boots directly into the signed-in, flag-on
// shell talking to a local plue stack. The env-var contract is
// duplicated here intentionally (string constants) because the XCUITest
// bundle does not link the SmithersE2ESupport module — tests are driven
// externally and the app under test reads the same keys on its own side.

#if os(macOS)
import XCTest

/// Keys that the XCUITest runner stamps into `launchEnvironment`. Kept in
/// sync with `E2EEnvironmentKey` in `Shared/Sources/SmithersE2ESupport/`.
enum MacE2ELaunchKey {
    static let mode = "PLUE_E2E_MODE"
    static let bearer = "SMITHERS_E2E_BEARER"
    static let baseURL = "PLUE_BASE_URL"
    static let refreshToken = "SMITHERS_E2E_REFRESH"
    /// Force the `remote_sandbox_enabled` feature flag on for the app
    /// process. Without this, the macOS `RemoteSandboxFlag` reads from
    /// `UserDefaults` and the REMOTE sidebar section stays hidden.
    static let remoteFlag = "PLUE_REMOTE_SANDBOX_ENABLED"
    /// Seed marker. "1" means the seed script ran; tests that depend on
    /// seeded data assert its presence.
    static let seededData = "PLUE_E2E_SEEDED"
    /// Workspace title that `ios/scripts/seed-e2e-data.sh` inserts
    /// (reused verbatim by the macOS harness — do NOT fork the seed).
    static let seededWorkspaceTitle = "PLUE_E2E_SEEDED_WORKSPACE_TITLE"
    /// UUID of the seeded workspace. Tests match against the
    /// `sidebar.remote.row.<id>` accessibility identifier.
    static let seededWorkspaceID = "PLUE_E2E_WORKSPACE_ID"
    /// macOS-only: when set to a filesystem path, `WorkspaceManager`
    /// auto-opens that folder at process start via its existing
    /// `workspaceFromLaunch` hook. Lets the XCUITest bundle mount the
    /// content shell without driving a NSOpenPanel.
    static let autoOpenPath = "SMITHERS_OPEN_WORKSPACE"
    /// macOS-only: toggles internal UI-test affordances (disables some
    /// animations, shortens timers). Mirrors the env var the existing
    /// `SmithersGUIUITests` bundle sets.
    static let uiTestMode = "SMITHERS_GUI_UITEST"
}

/// Shape of the per-test launch environment. The harness script passes
/// these as process env vars; we forward them into the app under test.
struct MacE2ELaunchEnvironment {
    let bearer: String
    let baseURL: String
    let refreshToken: String?
    let seeded: Bool
    let seededWorkspaceTitle: String?
    let seededWorkspaceID: String?

    /// Pull every relevant key from `ProcessInfo.processInfo.environment`
    /// (set by `macos/scripts/run-e2e.sh`), with loud fatalErrors on
    /// missing required keys so test failures are obvious, not silent.
    static func fromProcess(_ file: StaticString = #filePath, _ line: UInt = #line) -> MacE2ELaunchEnvironment {
        let env = ProcessInfo.processInfo.environment
        guard let bearer = env[MacE2ELaunchKey.bearer], !bearer.isEmpty else {
            fatalError("\(MacE2ELaunchKey.bearer) missing from test-runner env — did you invoke via macos/scripts/run-e2e.sh?", file: file, line: line)
        }
        let baseURL = env[MacE2ELaunchKey.baseURL] ?? "http://localhost:4000"
        let refresh = env[MacE2ELaunchKey.refreshToken]
        let seeded = env[MacE2ELaunchKey.seededData] == "1"
        let title = env[MacE2ELaunchKey.seededWorkspaceTitle]
        let wsID = env[MacE2ELaunchKey.seededWorkspaceID]
        return MacE2ELaunchEnvironment(
            bearer: bearer,
            baseURL: baseURL,
            refreshToken: refresh,
            seeded: seeded,
            seededWorkspaceTitle: title,
            seededWorkspaceID: wsID
        )
    }

    /// Stamp our keys onto `app.launchEnvironment`. Existing entries are
    /// preserved (so a test can override a subset before calling this).
    func apply(to app: XCUIApplication, bypassAuth: Bool = true, remoteFlag: Bool = true, autoOpen: Bool = false) {
        // Always set the UI-test affordance knob so the shell picks up
        // the same "disable animations / shorten timers" behaviour the
        // existing `SmithersGUIUITests` bundle relies on.
        app.launchEnvironment[MacE2ELaunchKey.uiTestMode] = "1"
        app.launchArguments = ["--uitesting"]
        if bypassAuth {
            app.launchEnvironment[MacE2ELaunchKey.mode] = "1"
            app.launchEnvironment[MacE2ELaunchKey.bearer] = bearer
        } else {
            // Explicitly DO NOT set the mode/bearer — lets us exercise
            // the cold-launch path against the same backend config.
            app.launchEnvironment.removeValue(forKey: MacE2ELaunchKey.mode)
            app.launchEnvironment.removeValue(forKey: MacE2ELaunchKey.bearer)
        }
        if remoteFlag {
            app.launchEnvironment[MacE2ELaunchKey.remoteFlag] = "1"
        } else {
            app.launchEnvironment.removeValue(forKey: MacE2ELaunchKey.remoteFlag)
        }
        app.launchEnvironment[MacE2ELaunchKey.baseURL] = baseURL
        if let refresh = refreshToken {
            app.launchEnvironment[MacE2ELaunchKey.refreshToken] = refresh
        }
        if seeded {
            app.launchEnvironment[MacE2ELaunchKey.seededData] = "1"
            if let title = seededWorkspaceTitle {
                app.launchEnvironment[MacE2ELaunchKey.seededWorkspaceTitle] = title
            }
            if let wsID = seededWorkspaceID, !wsID.isEmpty {
                app.launchEnvironment[MacE2ELaunchKey.seededWorkspaceID] = wsID
            }
        }
        // Only auto-open a dummy folder when the test explicitly opts
        // in — tests that assert on the WelcomeView surface leave this
        // false so the content shell does not race past them.
        if autoOpen {
            let openPath = ProcessInfo.processInfo.environment[MacE2ELaunchKey.autoOpenPath]
                ?? NSTemporaryDirectory()
            app.launchEnvironment[MacE2ELaunchKey.autoOpenPath] = openPath
        } else {
            app.launchEnvironment.removeValue(forKey: MacE2ELaunchKey.autoOpenPath)
        }
    }
}

/// Small convenience so tests don't each write out the ProcessInfo dance.
@discardableResult
func applyE2ELaunchEnvironment(
    to app: XCUIApplication,
    bypassAuth: Bool = true,
    remoteFlag: Bool = true,
    autoOpen: Bool = false
) -> MacE2ELaunchEnvironment {
    let env = MacE2ELaunchEnvironment.fromProcess()
    env.apply(to: app, bypassAuth: bypassAuth, remoteFlag: remoteFlag, autoOpen: autoOpen)
    return env
}
#endif
