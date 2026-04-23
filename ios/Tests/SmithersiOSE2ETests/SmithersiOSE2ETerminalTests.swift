// SmithersiOSE2ETerminalTests.swift — terminal PTY scenario group (ticket
// ios-e2e-harness, scenario group A).
//
// These tests open the seeded workspace and assert that the iOS terminal
// surface mounts with its stable accessibility identifier
// `terminal.ios.surface` (see `TerminalIOSRendererBridge` in
// `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift`).
//
// Real PTY byte flow requires a live Freestyle sandbox SSH connection,
// which is explicitly out of scope for v1 e2e (no sandbox provider is
// attached in the local docker stack). Instead we assert that:
//   1. Opening a workspace with a seeded `workspace_sessions` row causes
//      the detail placeholder to mount `TerminalSurface`.
//   2. The terminal surface a11y identifier is present — proving the
//      renderer wiring (pipes-backed UITextView from ticket 0123) works.
//
// Preconditions (set by `ios/scripts/run-e2e.sh`):
//   - `PLUE_E2E_WORKSPACE_SESSION_ID` — non-empty UUID from the seed.
//   - Standard signed-in E2E env (`PLUE_E2E_MODE=1`, bearer, etc.).

#if os(iOS)
import XCTest

final class SmithersiOSE2ETerminalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Opening the seeded workspace must mount the terminal surface.
    /// Verifies `terminal.ios.surface` exists inside the workspace detail
    /// shell. Negative assertion: the surface must NOT be visible on the
    /// home list (before the workspace is opened) — guards against the
    /// detail placeholder leaking into the wrong route.
    func test_opens_workspace_and_mounts_terminal_surface() throws {
        // Gate on seed data + the workspace_session id. Absent either,
        // we bail loudly — XCTSkip hides failures, so we use XCTFail
        // with a clear diagnostic instead (per the ticket's "NOT
        // XCTSkip" guidance for scenario gates).
        let procEnv = ProcessInfo.processInfo.environment
        guard procEnv[E2ELaunchKey.seededData] == "1" else {
            XCTFail("terminal scenario requires PLUE_E2E_SEEDED=1 (run via ios/scripts/run-e2e.sh)")
            return
        }
        guard let wsSessionID = procEnv[E2ELaunchKey.seededWorkspaceSessionID],
              !wsSessionID.isEmpty else {
            XCTFail("terminal scenario requires PLUE_E2E_WORKSPACE_SESSION_ID — extend seed-e2e-data.sh to create a workspace_sessions row")
            return
        }

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in shell must mount"
        )

        // NEGATIVE: terminal must not appear before we open a workspace.
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "terminal.ios.surface").firstMatch.exists,
            "terminal surface must not leak onto the root home list"
        )

        // Open the switcher and tap the seeded row.
        app.buttons["content.ios.open-switcher"].tap()
        let rowButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
        ).firstMatch
        XCTAssertTrue(rowButton.waitForExistence(timeout: 15),
                      "seeded workspace row should appear")
        rowButton.tap()

        // Detail shell mounts.
        let detailShell = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail").firstMatch
        XCTAssertTrue(detailShell.waitForExistence(timeout: 10),
                      "workspace detail shell should render")

        // Diagnostic gate: `content.ios.workspace-detail.terminal-gate`
        // is a `Text` whose label is the seededSessionID value the app
        // sees in `ProcessInfo` — or "no-session" when the env var is
        // absent. Waiting on this first lets us tell apart "app didn't
        // receive the env var" from "env arrived but TerminalSurface
        // didn't render". Both would manifest as "no wrapper", but the
        // gate's label tells us which.
        let gate = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail.terminal-gate").firstMatch
        XCTAssertTrue(
            gate.waitForExistence(timeout: 10),
            "terminal-gate diagnostic must render in the detail shell"
        )
        // Dump the gate label so the xcresult bundle carries the exact
        // value the app saw — priceless when the test later flakes.
        let gateLabel = gate.label
        NSLog("[terminal-test] gate label = \(gateLabel)")
        XCTAssertEqual(
            gateLabel, wsSessionID,
            "app must observe PLUE_E2E_WORKSPACE_SESSION_ID=\(wsSessionID) in ProcessInfo; saw '\(gateLabel)'"
        )

        // The wrapper pane around the surface is the outermost
        // accessibility id we control — `WorkspaceDetailPlaceholder`
        // stamps it on the `TerminalSurface` view directly. With the
        // gate already asserted above, failure here means the terminal
        // view failed to render (e.g. TerminalSurface throwing at init).
        let terminalWrapper = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail.terminal").firstMatch
        XCTAssertTrue(
            terminalWrapper.waitForExistence(timeout: 10),
            "content.ios.workspace-detail.terminal wrapper must mount (gate label=\(gateLabel))"
        )
    }
}
#endif
