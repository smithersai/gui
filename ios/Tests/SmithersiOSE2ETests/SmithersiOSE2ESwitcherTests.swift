#if os(iOS)
import XCTest

final class SmithersiOSE2ESwitcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_switcher_opens_from_content_shell() throws {
        let (app, _) = launchSignedInApp()
        let switcherRoot = switcherRoot(in: app)
        let detailShell = workspaceDetailShell(in: app)
        let openSwitcher = app.buttons["content.ios.open-switcher"]

        XCTAssertTrue(
            openSwitcher.waitForExistence(timeout: 5),
            "content shell should expose content.ios.open-switcher"
        )
        XCTAssertFalse(
            switcherRoot.exists,
            "switcher must not already be visible before tapping content.ios.open-switcher"
        )
        XCTAssertFalse(
            detailShell.exists,
            "workspace detail must not already be visible on the content shell"
        )

        openSwitcher.tap()

        XCTAssertTrue(
            switcherRoot.waitForExistence(timeout: 5),
            "switcher.ios.root should appear within 5s after tapping content.ios.open-switcher"
        )
        XCTAssertFalse(
            detailShell.exists,
            "opening the switcher must not also open workspace detail"
        )
    }

    func test_switcher_shows_seeded_row() throws {
        try XCTSkipUnless(
            isSeeded,
            "seeded switcher row scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, _) = launchSignedInApp()
        _ = openSwitcher(in: app)

        let row = seededWorkspaceRow(in: app)
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "seeded backend should expose switcher.row.<PLUE_E2E_WORKSPACE_ID>"
        )
        XCTAssertFalse(
            signedInEmptyState(in: app).exists,
            "seeded backend must not render the signed-in empty state"
        )
        XCTAssertFalse(
            backendUnavailableState(in: app).exists,
            "real plue backend should not render backendUnavailable in the seeded path"
        )
    }

    func test_switcher_empty_state_when_unseeded() throws {
        try XCTSkipIf(
            isSeeded,
            "empty-state scenario only applies when PLUE_E2E_SEEDED is not 1"
        )

        let (app, _) = launchSignedInApp()
        _ = openSwitcher(in: app)

        let emptyState = signedInEmptyState(in: app)
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 15),
            "unseeded backend should render switcher.empty.signedIn"
        )
        XCTAssertFalse(
            rowsList(in: app).exists,
            "unseeded backend must not render switcher.rows"
        )
        XCTAssertFalse(
            backendUnavailableState(in: app).exists,
            "real plue backend should be reachable even when no workspaces are seeded"
        )
    }

    func test_switcher_backend_unavailable_state_not_reached() throws {
        let (app, env) = launchSignedInApp()
        _ = openSwitcher(in: app)

        if env.seeded {
            XCTAssertTrue(
                rowsList(in: app).waitForExistence(timeout: 15),
                "seeded backend should resolve to switcher.rows"
            )
            XCTAssertFalse(
                signedInEmptyState(in: app).exists,
                "seeded backend must not render switcher.empty.signedIn"
            )
        } else {
            XCTAssertTrue(
                signedInEmptyState(in: app).waitForExistence(timeout: 15),
                "unseeded backend should resolve to switcher.empty.signedIn"
            )
            XCTAssertFalse(
                rowsList(in: app).exists,
                "unseeded backend must not render switcher.rows"
            )
        }

        XCTAssertFalse(
            backendUnavailableState(in: app).exists,
            "switcher.empty.backendUnavailable must not be visible when the real backend is reachable"
        )
    }

    func test_switcher_dismiss_returns_to_content() throws {
        let (app, _) = launchSignedInApp()
        let switcherRoot = openSwitcher(in: app)

        dismissSwitcher(in: app)

        let openSwitcher = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(
            openSwitcher.waitForExistence(timeout: 5),
            "content shell should be visible again after dismissing the switcher"
        )
        XCTAssertFalse(
            switcherRoot.exists,
            "switcher.ios.root must be gone after dismissal"
        )
        XCTAssertFalse(
            workspaceDetailShell(in: app).exists,
            "dismissing the switcher must return to content, not workspace detail"
        )
    }

    func test_switcher_row_tap_opens_workspace_detail() throws {
        try XCTSkipUnless(
            isSeeded,
            "workspace-detail scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, _) = launchSignedInApp()
        let switcherRoot = openSwitcher(in: app)
        let row = seededWorkspaceRow(in: app)
        let detailShell = workspaceDetailShell(in: app)

        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "seeded switcher row should be present before tapping"
        )
        XCTAssertFalse(
            detailShell.exists,
            "workspace detail must not be visible before a row is opened"
        )

        row.tap()

        XCTAssertTrue(
            detailShell.waitForExistence(timeout: 10),
            "tapping switcher.row.<id> should open content.ios.workspace-detail"
        )
        XCTAssertTrue(
            waitForDisappearance(of: switcherRoot, timeout: 5),
            "switcher should dismiss after a workspace row is opened"
        )
        XCTAssertFalse(
            switcherRoot.exists,
            "switcher should dismiss after a workspace row is opened"
        )
    }

    func test_switcher_row_double_tap_does_not_open_twice() throws {
        try XCTSkipUnless(
            isSeeded,
            "double-tap scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, _) = launchSignedInApp()
        let switcherRoot = openSwitcher(in: app)
        let row = seededWorkspaceRow(in: app)
        let detailQuery = app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail")

        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "seeded switcher row should be present before double-tapping"
        )
        XCTAssertFalse(
            detailQuery.firstMatch.exists,
            "workspace detail must not be visible before the row is opened"
        )

        row.doubleTap()

        XCTAssertTrue(
            detailQuery.firstMatch.waitForExistence(timeout: 10),
            "double-tapping the row should still land on one workspace detail shell"
        )
        XCTAssertTrue(
            waitForDisappearance(of: switcherRoot, timeout: 5),
            "switcher should dismiss after the row is opened"
        )
        XCTAssertFalse(
            switcherRoot.exists,
            "switcher should dismiss after the row is opened"
        )
        XCTAssertEqual(
            detailQuery.allElementsBoundByIndex.filter { $0.exists }.count,
            1,
            "double-tapping must not create duplicate content.ios.workspace-detail shells"
        )
    }

    func test_switcher_reopens_after_close() throws {
        let (app, _) = launchSignedInApp()

        let firstRoot = openSwitcher(in: app)
        XCTAssertTrue(
            firstRoot.waitForExistence(timeout: 5),
            "switcher should open the first time"
        )

        dismissSwitcher(in: app)
        XCTAssertFalse(
            firstRoot.exists,
            "switcher.ios.root must be gone after the first close"
        )

        let reopenButton = app.buttons["content.ios.open-switcher"]
        XCTAssertTrue(
            reopenButton.waitForExistence(timeout: 5),
            "content shell should be visible before reopening the switcher"
        )
        reopenButton.tap()

        let secondRoot = switcherRoot(in: app)
        XCTAssertTrue(
            secondRoot.waitForExistence(timeout: 5),
            "switcher should open again after being closed"
        )
        XCTAssertFalse(
            workspaceDetailShell(in: app).exists,
            "reopening the switcher must not unexpectedly show workspace detail"
        )
    }

    func test_switcher_row_count_matches_seed() throws {
        try XCTSkipUnless(
            isSeeded,
            "row-count scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, _) = launchSignedInApp()
        _ = openSwitcher(in: app)

        let rows = rowsList(in: app)
        XCTAssertTrue(
            rows.waitForExistence(timeout: 15),
            "seeded backend should resolve to switcher.rows"
        )

        let rowQuery = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'switcher.row.'")
        )
        XCTAssertGreaterThanOrEqual(
            rowQuery.count,
            1,
            "seeded backend should expose at least one switcher.row.<id> button"
        )
        XCTAssertFalse(
            signedInEmptyState(in: app).exists,
            "seeded backend must not render the signed-in empty state"
        )
        XCTAssertFalse(
            backendUnavailableState(in: app).exists,
            "real plue backend should not render backendUnavailable in the seeded path"
        )
    }

    func test_switcher_root_identifier_regression() throws {
        let (app, _) = launchSignedInApp()
        let exactRoot = openSwitcher(in: app)

        XCTAssertTrue(
            exactRoot.waitForExistence(timeout: 5),
            "switcher must continue exposing the exact identifier switcher.ios.root"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(identifier: "switcher.root")
                .firstMatch.exists,
            "identifier drift to switcher.root would break the E2E harness"
        )
    }

    // MARK: - Helpers

    private var isSeeded: Bool {
        ProcessInfo.processInfo.environment[E2ELaunchKey.seededData] == "1"
    }

    @discardableResult
    private func launchSignedInApp(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> (XCUIApplication, E2ELaunchEnvironment) {
        let app = XCUIApplication()
        let env = applyE2ELaunchEnvironment(to: app)
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.root.ios"].waitForExistence(timeout: 15),
            "signed-in iOS shell should mount when PLUE_E2E_MODE=1",
            file: file,
            line: line
        )
        XCTAssertFalse(
            app.staticTexts["Sign in to Smithers"].exists,
            "sign-in shell must not appear when the E2E bearer is installed",
            file: file,
            line: line
        )

        return (app, env)
    }

    @discardableResult
    private func openSwitcher(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let openSwitcher = app.buttons["content.ios.open-switcher"]
        let switcherRoot = switcherRoot(in: app)

        XCTAssertTrue(
            openSwitcher.waitForExistence(timeout: 5),
            "content shell should expose content.ios.open-switcher",
            file: file,
            line: line
        )
        XCTAssertFalse(
            switcherRoot.exists,
            "switcher.ios.root must not already be visible before opening",
            file: file,
            line: line
        )

        openSwitcher.tap()

        XCTAssertTrue(
            switcherRoot.waitForExistence(timeout: 5),
            "switcher.ios.root should appear after tapping content.ios.open-switcher",
            file: file,
            line: line
        )

        return switcherRoot
    }

    private func dismissSwitcher(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let switcherRoot = switcherRoot(in: app)
        let closeButton = app.buttons["switcher.ios.close"]
        if closeButton.waitForExistence(timeout: 2) {
            closeButton.tap()
        } else {
            app.swipeDown()
        }

        XCTAssertTrue(
            app.buttons["content.ios.open-switcher"].waitForExistence(timeout: 5),
            "content shell should be reachable after dismissing the switcher",
            file: file,
            line: line
        )
        XCTAssertTrue(
            waitForDisappearance(of: switcherRoot, timeout: 5),
            "switcher.ios.root should disappear after dismissal",
            file: file,
            line: line
        )
    }

    private func switcherRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "switcher.ios.root")
            .firstMatch
    }

    private func rowsList(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "switcher.rows")
            .firstMatch
    }

    private func signedInEmptyState(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.signedIn")
            .firstMatch
    }

    private func backendUnavailableState(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "switcher.empty.backendUnavailable")
            .firstMatch
    }

    private func workspaceDetailShell(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "content.ios.workspace-detail")
            .firstMatch
    }

    private func seededWorkspaceRow(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        guard
            let workspaceID = ProcessInfo.processInfo.environment[E2ELaunchKey.seededWorkspaceID],
            !workspaceID.isEmpty
        else {
            XCTFail(
                "seeded switcher scenarios require PLUE_E2E_WORKSPACE_ID",
                file: file,
                line: line
            )
            return app.buttons["switcher.row.missing-seeded-workspace-id"]
        }

        return app.buttons["switcher.row.\(workspaceID)"]
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }
}
#endif
