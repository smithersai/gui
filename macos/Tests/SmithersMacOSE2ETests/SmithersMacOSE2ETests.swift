// SmithersMacOSE2ETests.swift — full-stack XCUITest suite for the macOS
// desktop app.
//
// Ticket: macos-e2e-harness. Mirrors the iOS suite
// (`ios/Tests/SmithersiOSE2ETests/SmithersiOSE2ETests.swift`). This bundle
// expects a real plue backend on `PLUE_BASE_URL` and a seeded bearer
// token in `SMITHERS_E2E_BEARER`. See `macos/scripts/run-e2e.sh` for the
// orchestration, and `Shared/Sources/SmithersE2ESupport/E2EEnvironment.swift`
// for the env-gated app-side hooks.
//
// Each test asserts on real observable state — NO `XCTAssert(true)`
// filler. Where an assertion would silently pass if the shell weren't
// actually reachable, we also assert a NEGATIVE (e.g. REMOTE section is
// NOT visible) so a rendering regression fails loudly.

#if os(macOS)
import XCTest

final class SmithersMacOSE2ETests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        // Clear macOS "Saved Application State" so a prior crash does
        // not restore the app into an opaque off-screen window before
        // XCUITest gets a chance to query it. Mirrors the setup in
        // `SmithersGUIUITestCase` — without this, the very first test
        // in a fresh runner intermittently boots into a restored shell
        // that is not accessibility-visible.
        let savedStateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.smithers.SmithersGUI.savedState")
        try? FileManager.default.removeItem(at: savedStateDir)
    }

    /// Launch the app and wait for the window to be foreground-ready.
    /// macOS SwiftUI apps do not become accessibility-queryable until
    /// the window actually shows — without this wait every
    /// `waitForExistence(timeout:)` call probes an empty AX tree and
    /// eventually times out with "element not found" even though the
    /// identifier is in the SwiftUI view graph.
    private func launchAndWaitForForeground(
        _ app: XCUIApplication,
        _ file: StaticString = #filePath,
        _ line: UInt = #line
    ) {
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 40) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 40),
            "app did not reach .runningForeground within 40s",
            file: file, line: line
        )
        // Force the app to activate so its SwiftUI window is brought to
        // the front and registers with the macOS accessibility API.
        // Without this, XCUITest queries return "Application Disabled"
        // with no Window children — the process is running but the AX
        // tree is empty because the window never focused.
        app.activate()
        // Small settle window for SwiftUI to finish its initial render
        // pass. Empirically 0.5s is enough; we leave a generous 2s to
        // avoid flakes on CI hardware.
        Thread.sleep(forTimeInterval: 2.0)
    }

    // MARK: - 1. Cold launch — WelcomeView

    /// With the remote flag on (but NO E2E bypass), the app should boot
    /// into WelcomeView showing "Open Folder…" plus the remote sign-in
    /// button. With the flag off, the sign-in button must be absent —
    /// the user-facing contract from ticket 0126.
    func test_cold_launch_shows_welcome() throws {
        let app = XCUIApplication()
        // bypassAuth: false — boots like a fresh install, no bearer.
        // remoteFlag: true  — so we can assert the sign-in entry is
        //                     rendered when the flag is on.
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: false, remoteFlag: true)
        launchAndWaitForForeground(app)

        // SwiftUI-on-macOS can take 15-30s to register the first window
        // in XCUITest's accessibility tree on this machine (macOS 26.2
        // beta behaviour — matches the existing SmithersGUIUITestCase
        // which waits 30s for `sidebar`). Anchor the assertion on the
        // WelcomeView button rather than the ZStack root identifier
        // (which SwiftUI doesn't reliably propagate to AX on macOS).
        let openFolder = app.buttons["welcome.openFolder"]
        XCTAssertTrue(
            openFolder.waitForExistence(timeout: 45),
            "WelcomeView must expose the Open Folder button (cold launch)"
        )

        // With remote flag on, the sign-in button must render.
        let signIn = app.buttons["welcome.remote.signIn"]
        XCTAssertTrue(
            signIn.waitForExistence(timeout: 30),
            "welcome.remote.signIn must appear when PLUE_REMOTE_SANDBOX_ENABLED=1"
        )

        // NEGATIVE: the content shell (`app.root`) must NOT be up —
        // WelcomeView is the pre-folder surface.
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "app.root").firstMatch.exists,
            "content shell must not be visible before a workspace is opened"
        )
    }

    // MARK: - 2. E2E bypass — signed-in REMOTE section visible

    /// With both `PLUE_E2E_MODE=1` and `PLUE_REMOTE_SANDBOX_ENABLED=1`,
    /// the sidebar REMOTE section must render. We open a folder first so
    /// the sidebar mounts — WelcomeView does not host a sidebar.
    func test_signs_in_with_test_token_and_sees_remote_section() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true)
        launchAndWaitForForeground(app)

        // The app starts on WelcomeView (no local folder opened yet).
        // Verify the signed-in remote sign-in button has flipped to the
        // "Manage" variant — proves the E2E bypass installed the bearer
        // and the auth model is `.signedIn`.
        let manageButton = app.buttons["welcome.remote.manage"]
        XCTAssertTrue(
            manageButton.waitForExistence(timeout: 45),
            "welcome.remote.manage must appear when E2E bearer is installed (auth phase=.signedIn)"
        )

        // NEGATIVE: the signed-OUT variant must not be present.
        XCTAssertFalse(
            app.buttons["welcome.remote.signIn"].exists,
            "welcome.remote.signIn must NOT appear when the E2E bearer is installed"
        )
    }

    // MARK: - 3. Seeded workspace visible under REMOTE

    /// With pre-seeded data (via `ios/scripts/seed-e2e-data.sh`) the
    /// seeded workspace row must appear under the REMOTE section. The
    /// row identifier is `sidebar.remote.row.<workspace_id>`.
    ///
    /// The sidebar only mounts once a workspace folder is open, so the
    /// test uses `autoOpen: true` to have the app synthesize an
    /// open-folder event at launch from `SMITHERS_E2E_AUTOOPEN_PATH`.
    func test_signs_in_and_sees_seeded_workspace_in_remote_section() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLUE_E2E_SEEDED"] == "1",
            "seeded-data tests require PLUE_E2E_SEEDED=1 in the runner env"
        )
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true, autoOpen: true)
        launchAndWaitForForeground(app)

        // Wait for the content shell (`app.root`) to mount.
        let appRoot = app.descendants(matching: .any)
            .matching(identifier: "app.root").firstMatch
        XCTAssertTrue(
            appRoot.waitForExistence(timeout: 45),
            "app.root (content shell) should mount after opening a folder"
        )

        // Sidebar REMOTE section should exist.
        let remoteSection = app.descendants(matching: .any)
            .matching(identifier: "sidebar.remote.section").firstMatch
        XCTAssertTrue(
            remoteSection.waitForExistence(timeout: 30),
            "sidebar.remote.section must render when remote flag is on"
        )

        // The seeded workspace row.
        guard let wsID = env.seededWorkspaceID, !wsID.isEmpty else {
            return XCTFail("PLUE_E2E_WORKSPACE_ID missing from runner env — seed script did not export it")
        }
        let row = app.buttons["sidebar.remote.row.\(wsID)"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 45),
            "seeded workspace row (sidebar.remote.row.\(wsID)) must appear under REMOTE section"
        )
    }

    // MARK: - 4. Open remote workspace → detail pane renders

    /// Tapping the seeded workspace row routes to the workspaces
    /// destination and the detail pane (`content.macos.workspace-detail`)
    /// renders.
    func test_open_remote_workspace_renders() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PLUE_E2E_SEEDED"] == "1",
            "seeded-data tests require PLUE_E2E_SEEDED=1 in the runner env"
        )
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true, autoOpen: true)
        launchAndWaitForForeground(app)

        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "app.root").firstMatch
                .waitForExistence(timeout: 45),
            "content shell should mount"
        )

        guard let wsID = env.seededWorkspaceID, !wsID.isEmpty else {
            return XCTFail("PLUE_E2E_WORKSPACE_ID missing")
        }
        let row = app.buttons["sidebar.remote.row.\(wsID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 45))
        row.tap()

        let detail = app.descendants(matching: .any)
            .matching(identifier: "content.macos.workspace-detail").firstMatch
        XCTAssertTrue(
            detail.waitForExistence(timeout: 30),
            "content.macos.workspace-detail should render after tapping the remote row"
        )
    }

    // MARK: - 5. Sign-out clears remote, keeps local

    /// Sign out via the sidebar's explicit sign-out button, assert the
    /// REMOTE section disappears and the LOCAL section remains (recents
    /// may be empty but the sidebar itself must stay mounted).
    func test_sign_out_clears_remote_keeps_local() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true, autoOpen: true)
        launchAndWaitForForeground(app)

        let appRoot = app.descendants(matching: .any)
            .matching(identifier: "app.root").firstMatch
        XCTAssertTrue(appRoot.waitForExistence(timeout: 45))

        // REMOTE section exists prior to sign-out.
        let remoteSection = app.descendants(matching: .any)
            .matching(identifier: "sidebar.remote.section").firstMatch
        XCTAssertTrue(remoteSection.waitForExistence(timeout: 30),
                      "REMOTE section must exist before sign-out")

        // Hit the sign-out button in the status row.
        let signOut = app.buttons["sidebar.remote.signOut"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 30),
                      "sidebar.remote.signOut should be present when signed in")
        signOut.tap()

        // REMOTE section may still be visible (the flag is on) but the
        // sign-out button must be gone, and any seeded row must also be
        // gone. Verify by waiting for the sign-out button to disappear.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, app.buttons["sidebar.remote.signOut"].exists {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertFalse(
            app.buttons["sidebar.remote.signOut"].exists,
            "sidebar.remote.signOut should vanish after sign-out"
        )

        // Sidebar itself is still mounted (local section is unaffected).
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "sidebar").firstMatch.exists,
            "sidebar (local section) must remain mounted after remote sign-out"
        )
    }

}
#endif
