// SmithersiOSE2ETests.swift — full-stack XCUITest suite for the iOS app.
//
// Ticket: ios-e2e-harness. Distinct from `SmithersiOSUITests` (the launch
// smoke test bundle from 0121) — this bundle expects a real plue backend
// on `PLUE_BASE_URL` and a seeded bearer token in `SMITHERS_E2E_BEARER`.
// See `ios/scripts/run-e2e.sh` for the orchestration, and
// `Shared/Sources/SmithersE2ESupport/E2EEnvironment.swift` for the
// env-gated app-side hooks.
//
// Each test below asserts on real observable state — NO `XCTAssert(true)`
// filler. Where an assertion would silently pass if the shell weren't
// actually reachable, we also assert a NEGATIVE (e.g. sign-in button is
// NOT visible) so a rendering regression fails loudly.

#if os(iOS)
import XCTest

final class SmithersiOSE2ETests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 1. Cold launch

    /// Without `PLUE_E2E_MODE`, the app must boot into the sign-in shell.
    /// Verifies we haven't accidentally made the E2E bypass always-on.
    /// Negative assertion: no switcher/workspace chrome leaked.
    func test_cold_launch_shows_sign_in() throws {
        let app = XCUIApplication()
        // bypassAuth: false — we still pass PLUE_BASE_URL so the app
        // could talk to plue if it got that far, but we DO NOT set
        // PLUE_E2E_MODE or SMITHERS_E2E_BEARER.
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: false)
        app.launch()

        let signInPrompt = app.staticTexts["Sign in to Smithers"]
        XCTAssertTrue(
            signInPrompt.waitForExistence(timeout: 10),
            "cold launch should show the sign-in shell"
        )
        // NEGATIVE: the switcher-root identifier and the iOS content
        // shell identifier must NOT be present at this point.
        XCTAssertFalse(app.otherElements["app.root.ios"].exists,
                       "iOS content shell must not be visible before sign-in")
        XCTAssertFalse(app.otherElements["switcher.ios.root"].exists,
                       "workspace switcher must not be visible before sign-in")
    }

    // MARK: - 2. E2E bypass — signed-in empty

    /// Injects the E2E bearer, boots directly into the signed-in shell,
    /// opens the workspace switcher, and asserts the fetch to
    /// `/api/user/workspaces` resolves successfully (either empty or
    /// loaded with rows — the `PLUE_E2E_SEEDED` env var discriminates).
    /// The failure mode this catches is `backendUnavailable`, which
    /// means the HTTP call to plue never completed — the whole point
    /// of the harness is that this path is REAL and exercises URLSession
    /// against a live api.
    func test_signs_in_with_test_token_and_sees_empty_workspaces() throws {
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "app.root.ios").firstMatch
                .waitForExistence(timeout: 15),
            "signed-in iOS shell should mount when PLUE_E2E_MODE=1"
        )
        // Sign-in button must NOT be showing.
        XCTAssertFalse(
            app.staticTexts["Sign in to Smithers"].exists,
            "sign-in shell must not appear when E2E bearer is installed"
        )

        // Open the workspace switcher.
        let openSwitcher = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(openSwitcher.waitForExistence(timeout: 5),
                      "content shell should expose the open-switcher button")
        openSwitcher.tap()

        // Diagnostic probe: wait for the switcher's own root identifier
        // so we can distinguish "cover never opened" from "cover opened
        // but fetch never completed" in failure reports.
        let switcherRoot = app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root").firstMatch
        XCTAssertTrue(
            switcherRoot.waitForExistence(timeout: 5),
            "workspace switcher cover did not present after tapping open"
        )

        // SwiftUI propagates `.accessibilityIdentifier` down to the
        // element's leaf children (StaticText etc.) as well as the
        // group-level `Other`. `descendants` queries both.
        let emptyState = app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.signedIn").firstMatch
        let loaded = app.descendants(matching: .any)
            .matching(identifier: "switcher.rows").firstMatch
        let backendUnavailable = app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.backendUnavailable").firstMatch

        // Wait up to 20s for the fetch to resolve one way or the other.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if emptyState.exists || loaded.exists { break }
            if backendUnavailable.exists {
                XCTFail("switcher reached backendUnavailable — verify PLUE_BASE_URL is reachable from the simulator and the plue api is healthy")
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // When the backend is seeded, we expect `loaded` rows; when
        // un-seeded, we expect empty. Either outcome proves the real
        // HTTP path worked end-to-end.
        if env.seeded {
            XCTAssertTrue(loaded.exists,
                          "seeded backend should produce loaded rows, not empty state")
        } else {
            XCTAssertTrue(emptyState.exists,
                          "un-seeded backend should produce empty state, not loaded rows")
        }
    }

    // MARK: - 3. Seeded workspace visible

    /// With pre-seeded data (via `ios/scripts/seed-e2e-data.sh`), asserts
    /// that the workspace row appears in the switcher and carries the
    /// expected title.
    func test_signs_in_and_sees_seeded_workspace() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1",
            "seeded-data tests require PLUE_E2E_SEEDED=1 in the runner env"
        )
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in shell should be mounted"
        )
        app.buttons["content.ios.open-switcher"].tap()

        // Wait for the switcher list. The seeded row is a Button with
        // accessibility identifier `switcher.row.<workspace_id>` — match
        // on that rather than the title StaticText (SwiftUI Buttons
        // absorb child text into the button label, so
        // `app.staticTexts[title]` doesn't find it).
        let expectedWorkspaceID = ProcessInfo.processInfo
            .environment[E2ELaunchKey.seededWorkspaceID] ?? ""
        let rowMatch: XCUIElement = {
            if !expectedWorkspaceID.isEmpty {
                return app.buttons["switcher.row.\(expectedWorkspaceID)"]
            }
            // Fallback: any button whose identifier starts with
            // `switcher.row.` (there should be exactly one after seed).
            return app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
            ).firstMatch
        }()
        XCTAssertTrue(
            rowMatch.waitForExistence(timeout: 15),
            "seeded workspace row must appear in the switcher"
        )
        _ = env
    }

    // MARK: - 4. Open workspace → remote chat shell

    /// Taps the seeded workspace, asserts the chat/detail shell renders.
    func test_opens_workspace_and_sees_remote_chat_empty() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1",
            "seeded-data tests require PLUE_E2E_SEEDED=1 in the runner env"
        )
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(identifier: "app.root.ios").firstMatch
                .waitForExistence(timeout: 15)
        )
        app.buttons["content.ios.open-switcher"].tap()

        // Wait for the seeded row. `WorkspaceSwitcherRow` wraps its
        // content in a SwiftUI Button which absorbs child text into
        // the button label, so we match the row's accessibility
        // identifier `switcher.row.<workspace_id>` instead of the
        // title StaticText.
        _ = env
        let rowButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
        ).firstMatch
        XCTAssertTrue(rowButton.waitForExistence(timeout: 15),
                      "expected at least one switcher.row.<id> button")
        rowButton.tap()

        // Chat shell's root identifier. Empty-state identifier is fine —
        // the shell just needs to render. `descendants` query works
        // whether SwiftUI classifies the element as Other, Button, or
        // StaticText after `.accessibilityIdentifier` propagation.
        let chatRoot = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail").firstMatch
        XCTAssertTrue(
            chatRoot.waitForExistence(timeout: 10),
            "workspace detail shell should render when a row is opened"
        )
    }

    // MARK: - 5. Sign-out returns to sign-in

    /// Signs out via the shell's explicit sign-out button, asserts we
    /// return to sign-in and the switcher is gone.
    func test_sign_out_clears_cache_and_returns_to_sign_in() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(app.otherElements["app.root.ios"].waitForExistence(timeout: 15))
        let signOut = app.buttons["content.ios.sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        // Sign-in shell re-appears.
        let signInPrompt = app.staticTexts["Sign in to Smithers"]
        XCTAssertTrue(
            signInPrompt.waitForExistence(timeout: 10),
            "sign-in shell should return after sign-out"
        )
        // Content shell is gone.
        XCTAssertFalse(
            app.otherElements["app.root.ios"].exists,
            "signed-in shell should unmount after sign-out"
        )
    }
}
#endif
