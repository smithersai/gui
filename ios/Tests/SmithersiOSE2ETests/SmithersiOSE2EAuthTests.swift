// SmithersiOSE2EAuthTests.swift — authentication scenario group for the
// iOS app against a real plue backend.
//
// These tests stay intentionally narrow: observable auth shell state only.
// Every scenario includes a NEGATIVE assertion so a silent rendering
// regression fails loudly instead of drifting into a false-positive pass.

#if os(iOS)
import XCTest

final class SmithersiOSE2EAuthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 1. Cold launch

    /// No bypass env -> sign-in shell, not the signed-in iOS shell.
    func test_cold_launch_shows_sign_in() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: false)
        app.launch()

        XCTAssertTrue(
            waitForSignInShell(in: app, timeout: 10),
            "cold launch should show the sign-in shell"
        )
        XCTAssertFalse(
            appRoot(in: app).exists,
            "signed-in iOS shell must not mount on cold launch"
        )
    }

    // MARK: - 2. Valid bearer

    /// The seeded E2E bearer should boot directly into the signed-in shell.
    func test_signed_in_with_valid_bearer_mounts_shell() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            appRoot(in: app).waitForExistence(timeout: 15),
            "signed-in iOS shell should mount with the seeded E2E bearer"
        )
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible with a valid bearer"
        )
    }

    // MARK: - 3. Invalid bearer

    /// An invalid bearer must fall back to sign-in and never mount the shell.
    func test_invalid_bearer_shows_sign_in_not_shell() throws {
        let app = XCUIApplication()
        // The helper currently re-stamps the runner bearer, so override
        // again after apply to keep this scenario honest.
        app.launchEnvironment[E2ELaunchKey.bearer] = "jjhub_0000000000000000000000000000000000000000"
        _ = applyE2ELaunchEnvironment(to: app)
        app.launchEnvironment[E2ELaunchKey.bearer] = "jjhub_0000000000000000000000000000000000000000"
        app.launch()

        XCTAssertTrue(
            waitForSignInShell(in: app, timeout: 10),
            "invalid bearer should return the app to the sign-in shell"
        )
        assertNeverAppears(
            appRoot(in: app),
            timeout: 10,
            message: "signed-in iOS shell must never mount with an invalid bearer"
        )
    }

    // MARK: - 4. Malformed bearer

    /// A malformed bearer must be rejected before the shell is reachable.
    func test_malformed_bearer_rejected() throws {
        let app = XCUIApplication()
        // The helper currently re-stamps the runner bearer, so override
        // again after apply to keep this scenario honest.
        app.launchEnvironment[E2ELaunchKey.bearer] = "not_a_jjhub_token"
        _ = applyE2ELaunchEnvironment(to: app)
        app.launchEnvironment[E2ELaunchKey.bearer] = "not_a_jjhub_token"
        app.launch()

        XCTAssertTrue(
            waitForSignInShell(in: app, timeout: 10),
            "malformed bearer should leave the sign-in shell visible"
        )
        assertNeverAppears(
            appRoot(in: app),
            timeout: 10,
            message: "signed-in iOS shell must never mount with a malformed bearer"
        )
    }

    // MARK: - 5. Sign-out

    /// Sign-out should drop the shell and return to the sign-in surface.
    func test_sign_out_returns_to_sign_in_and_clears_shell() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(appRoot(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible before sign-out"
        )

        let signOut = signOutButton(in: app)
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        signOut.tap()

        XCTAssertTrue(
            waitForSignInShell(in: app, timeout: 10),
            "sign-in shell should return after sign-out"
        )
        XCTAssertFalse(
            appRoot(in: app).exists,
            "signed-in iOS shell should unmount after sign-out"
        )
    }

    // MARK: - 6. Sign-out + relaunch

    /// Sign-out must survive termination; no stale in-memory/session bypass.
    func test_sign_out_then_relaunch_still_signed_out() throws {
        let first = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: first)
        first.launch()

        XCTAssertTrue(appRoot(in: first).waitForExistence(timeout: 15))
        XCTAssertTrue(signOutButton(in: first).waitForExistence(timeout: 5))
        signOutButton(in: first).tap()
        XCTAssertTrue(waitForSignInShell(in: first, timeout: 10))
        XCTAssertFalse(
            appRoot(in: first).exists,
            "signed-in shell should be gone before relaunch"
        )

        first.terminate()

        let relaunched = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: relaunched, bypassAuth: false)
        relaunched.launchEnvironment.removeValue(forKey: E2ELaunchKey.bearer)
        relaunched.launch()

        XCTAssertTrue(
            waitForSignInShell(in: relaunched, timeout: 10),
            "relaunch after sign-out should stay on the sign-in shell"
        )
        assertNeverAppears(
            appRoot(in: relaunched),
            timeout: 10,
            message: "signed-in iOS shell must not remount after sign-out + relaunch"
        )
    }

    // MARK: - 7. Refresh token forwarding

    /// Optional smoke: forwarding a refresh token must not break shell mount.
    func test_refresh_token_forwarded_when_provided() throws {
        let refresh = ProcessInfo.processInfo.environment[E2ELaunchKey.refreshToken] ?? ""
        try XCTSkipUnless(
            !refresh.isEmpty,
            "refresh-token smoke requires SMITHERS_E2E_REFRESH in the runner env"
        )

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        XCTAssertEqual(
            app.launchEnvironment[E2ELaunchKey.refreshToken],
            refresh,
            "refresh token should be forwarded into the app launch environment"
        )
        app.launch()

        XCTAssertTrue(
            appRoot(in: app).waitForExistence(timeout: 15),
            "shell should still mount when a refresh token is also forwarded"
        )
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible when bearer + refresh token are forwarded"
        )
    }

    // MARK: - 8. Background / foreground

    /// Shell should survive a home-button background / foreground cycle.
    func test_shell_survives_background_foreground_cycle() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(appRoot(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible before backgrounding"
        )

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(
            appRoot(in: app).waitForExistence(timeout: 10),
            "signed-in shell should still be mounted after foregrounding"
        )
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not reappear after foregrounding"
        )
    }

    // MARK: - 9. Open switcher control

    /// Regression anchor: the signed-in shell should expose open-switcher.
    func test_open_switcher_button_present_after_signin() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(appRoot(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible in the signed-in path"
        )
        XCTAssertTrue(
            openSwitcherButton(in: app).waitForExistence(timeout: 5),
            "signed-in shell should expose the open-switcher control"
        )
    }

    // MARK: - 10. Sign-out control

    /// Regression anchor: the signed-in shell should expose sign-out.
    func test_sign_out_button_present_in_signed_in_shell() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(appRoot(in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(
            isSignInShellVisible(in: app),
            "sign-in shell must not be visible in the signed-in path"
        )
        XCTAssertTrue(
            signOutButton(in: app).waitForExistence(timeout: 5),
            "signed-in shell should expose the sign-out control"
        )
    }

    // MARK: - Helpers

    private func appRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "app.root.ios")
            .firstMatch
    }

    private func signInRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "auth.signin.root")
            .firstMatch
    }

    private func signInPromptCopy(in app: XCUIApplication) -> XCUIElement {
        app.staticTexts["Sign in to Smithers"]
    }

    private func waitForSignInShell(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            self.isSignInShellVisible(in: app)
        }
    }

    private func isSignInShellVisible(in app: XCUIApplication) -> Bool {
        signInRoot(in: app).exists || signInPromptCopy(in: app).exists
    }

    private func openSwitcherButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["content.ios.open-switcher"]
    }

    private func signOutButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons["content.ios.sign-out"]
    }

    /// Polls for an identifier that must never appear in this scenario.
    private func assertNeverAppears(
        _ element: XCUIElement,
        timeout: TimeInterval,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists {
                XCTFail(message, file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return condition()
    }
}
#endif
