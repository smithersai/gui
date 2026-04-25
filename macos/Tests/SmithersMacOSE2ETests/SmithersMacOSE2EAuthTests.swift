#if os(macOS)
import XCTest

enum MacE2ESeedKey {
    static let repoOwner = "PLUE_E2E_REPO_OWNER"
    static let repoName = "PLUE_E2E_REPO_NAME"
    static let repoID = "PLUE_E2E_REPO_ID"
    static let workspaceSessionID = "PLUE_E2E_WORKSPACE_SESSION_ID"
    static let agentSessionID = "PLUE_E2E_AGENT_SESSION_ID"
    static let approvalID = "PLUE_E2E_APPROVAL_ID"
}

enum MacE2ETestSupport {
    static func clearSavedApplicationState() {
        let savedStateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State/com.smithers.SmithersGUI.savedState")
        try? FileManager.default.removeItem(at: savedStateDir)
    }

    static func launchAndWaitForForeground(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 40) {
            app.terminate()
            app.launch()
        }
        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 40),
            "app did not reach .runningForeground within 40s",
            file: file,
            line: line
        )
        app.activate()
        Thread.sleep(forTimeInterval: 2.0)
    }

    @discardableResult
    static func launchSignedInShell(
        autoOpen: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (XCUIApplication, MacE2ELaunchEnvironment) {
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(
            to: app,
            bypassAuth: true,
            remoteFlag: true,
            autoOpen: autoOpen
        )
        launchAndWaitForForeground(app, file: file, line: line)
        if autoOpen {
            XCTAssertTrue(
                element("app.root", in: app).waitForExistence(timeout: 45),
                "content shell should mount when SMITHERS_OPEN_WORKSPACE is set",
                file: file,
                line: line
            )
        }
        return (app, env)
    }

    static func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    static func waitUntil(
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

    static func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            !element.exists
        }
    }

    static func assertNeverAppears(
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

    static var isSeeded: Bool {
        ProcessInfo.processInfo.environment[MacE2ELaunchKey.seededData] == "1"
    }

    static func requireSeeded(_ message: String) throws {
        try XCTSkipUnless(isSeeded, message)
    }

    static func env(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            return nil
        }
        return value
    }

    static func requireEnv(_ key: String) throws -> String {
        guard let value = env(key) else {
            throw XCTSkip("macOS e2e scenario requires \(key)")
        }
        return value
    }

    static func waitForWelcomeSignIn(in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            app.buttons["welcome.remote.signIn"].exists ||
                element("auth.signin.root", in: app).exists ||
                app.staticTexts["Sign in to Smithers"].exists
        }
    }
}

final class SmithersMacOSE2EAuthTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MacE2ETestSupport.clearSavedApplicationState()
    }

    func test_cold_launch_shows_sign_in() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: false, remoteFlag: true)
        MacE2ETestSupport.launchAndWaitForForeground(app)

        XCTAssertTrue(
            MacE2ETestSupport.waitForWelcomeSignIn(in: app, timeout: 45),
            "cold launch should expose the macOS remote sign-in entry"
        )
        XCTAssertFalse(
            MacE2ETestSupport.element("app.root", in: app).exists,
            "content shell must not mount before auth/workspace open on cold launch"
        )
    }

    func test_signed_in_with_valid_bearer_mounts_shell() throws {
        let (app, _) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)

        XCTAssertTrue(
            MacE2ETestSupport.element("sidebar.remote.section", in: app).waitForExistence(timeout: 30),
            "signed-in macOS shell should expose the REMOTE section"
        )
        XCTAssertTrue(
            app.buttons["sidebar.remote.signOut"].waitForExistence(timeout: 30),
            "signed-in macOS shell should expose the remote sign-out control"
        )
        XCTAssertFalse(
            app.buttons["welcome.remote.signIn"].exists,
            "welcome sign-in entry must not be visible after the shell mounts"
        )
    }

    func test_invalid_bearer_rejected() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true)
        app.launchEnvironment[MacE2ELaunchKey.bearer] = "jjhub_0000000000000000000000000000000000000000"
        MacE2ETestSupport.launchAndWaitForForeground(app)

        XCTAssertTrue(
            MacE2ETestSupport.waitForWelcomeSignIn(in: app, timeout: 45),
            "invalid bearer should return macOS to the sign-in surface"
        )
        MacE2ETestSupport.assertNeverAppears(
            app.buttons["welcome.remote.manage"],
            timeout: 8,
            message: "invalid bearer must not leave the signed-in manage control visible"
        )
    }

    func test_sign_out_returns_to_sign_in() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true)
        MacE2ETestSupport.launchAndWaitForForeground(app)

        let manage = app.buttons["welcome.remote.manage"]
        XCTAssertTrue(
            manage.waitForExistence(timeout: 45),
            "signed-in Welcome surface should expose the manage control"
        )
        manage.click()

        let sheet = MacE2ETestSupport.element("auth.signin.root", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "manage should open the auth sheet")

        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "auth sheet should expose Sign out")
        signOut.click()

        XCTAssertTrue(
            app.buttons["auth.signin.primary-cta"].waitForExistence(timeout: 10),
            "sign-out should return the auth sheet to the sign-in state"
        )
        XCTAssertFalse(
            app.buttons["welcome.remote.manage"].exists,
            "signed-in manage control should disappear after sign-out"
        )
    }

    func test_signed_in_welcome_exposes_browse_sandboxes_entry() throws {
        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app, bypassAuth: true, remoteFlag: true, autoOpen: false)
        MacE2ETestSupport.launchAndWaitForForeground(app)

        XCTAssertTrue(
            app.buttons["welcome.remote.browse"].waitForExistence(timeout: 45),
            "signed-in Welcome surface should expose the remote browse entry"
        )
    }
}
#endif
