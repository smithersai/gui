#if os(iOS)
import XCTest

final class SmithersGUIiOSE2EHappyPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_beta_happy_path_trace() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1",
            "happy-path trace requires PLUE_E2E_SEEDED=1"
        )

        let app = XCUIApplication()
        _ = applyE2ELaunchEnvironment(to: app)
        app.launch()

        let appRoot = app.descendants(matching: .any).matching(identifier: "app.root.ios").firstMatch
        XCTAssertTrue(appRoot.waitForExistence(timeout: 15), "signed-in iOS shell must mount")
        XCTAssertFalse(app.staticTexts["Sign in to Smithers"].exists, "sign-in shell must be absent while authenticated")

        let openSwitcher = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(openSwitcher.waitForExistence(timeout: 5), "open switcher control should be visible")
        openSwitcher.tap()

        let workspaceID = ProcessInfo.processInfo.environment[E2ELaunchKey.seededWorkspaceID] ?? ""
        let row = workspaceID.isEmpty
            ? app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")).firstMatch
            : app.buttons["switcher.row.\(workspaceID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "seeded workspace must be discoverable through production switcher flow")
        row.tap()

        let detail = app.descendants(matching: .any).matching(identifier: "content.ios.workspace-detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 12), "workspace detail should open from selected row")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier CONTAINS 'send'")).firstMatch.waitForExistence(timeout: 8),
            "workspace detail should expose a send control for dispatch/chat"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS[c] 'run'")).count > 0,
            "happy-path shell should expose run-discovery UI"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS[c] 'approval'")).count > 0,
            "happy-path shell should expose approval UI"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier CONTAINS[c] 'output' OR identifier CONTAINS[c] 'log'")).count > 0,
            "happy-path shell should expose output/log visibility UI"
        )

        let terminalWrapper = app.descendants(matching: .any).matching(identifier: "content.ios.workspace-detail.terminal").firstMatch
        XCTAssertTrue(terminalWrapper.waitForExistence(timeout: 12), "terminal wrapper should be available in shipped 0188 path")
        let terminalSurface = app.descendants(matching: .any).matching(identifier: "terminal.ios.surface").firstMatch
        XCTAssertTrue(terminalSurface.waitForExistence(timeout: 12), "terminal surface should mount in happy path")

        let signOut = app.buttons["content.ios.sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "sign-out control should be visible in authenticated shell")
        signOut.tap()

        XCTAssertTrue(app.staticTexts["Sign in to Smithers"].waitForExistence(timeout: 10), "sign-out should return to sign-in shell")
        XCTAssertFalse(appRoot.exists, "signed-in shell must unmount after sign-out")
        XCTAssertFalse(app.buttons["switcher.row.\(workspaceID)"].exists, "signed-out UI must not expose prior user workspace row")
    }
}
#endif
