#if os(macOS)
import XCTest

final class TabmonstersMacOSE2EHappyPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MacE2ETestSupport.clearSavedApplicationState()
    }

    func test_beta_happy_path_trace() throws {
        try MacE2ETestSupport.requireSeeded("macOS happy-path trace requires PLUE_E2E_SEEDED=1")

        let (app, env) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)
        XCTAssertTrue(MacE2ETestSupport.element("sidebar.remote.section", in: app).waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["sidebar.remote.signOut"].waitForExistence(timeout: 20))

        guard let workspaceID = env.seededWorkspaceID, !workspaceID.isEmpty else {
            return XCTFail("PLUE_E2E_WORKSPACE_ID missing")
        }

        let row = app.buttons["sidebar.remote.row.\(workspaceID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "seeded remote workspace should be discoverable")
        row.tap()

        XCTAssertTrue(
            MacE2ETestSupport.element("content.macos.workspace-detail", in: app).waitForExistence(timeout: 20),
            "workspace detail should render after row selection"
        )

        let signOut = app.buttons["sidebar.remote.signOut"]
        signOut.click()
        XCTAssertTrue(
            MacE2ETestSupport.waitForWelcomeSignIn(in: app, timeout: 20),
            "sign-out should return to signed-out welcome/auth state"
        )
        XCTAssertFalse(app.buttons["sidebar.remote.row.\(workspaceID)"].exists, "signed-out UI should not show prior workspace row")
    }
}
#endif
