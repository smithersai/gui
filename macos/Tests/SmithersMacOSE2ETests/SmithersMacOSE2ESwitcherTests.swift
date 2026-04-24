#if os(macOS)
import XCTest

final class SmithersMacOSE2ESwitcherTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MacE2ETestSupport.clearSavedApplicationState()
    }

    func test_switcher_opens_from_content_shell() throws {
        let (app, _) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)

        let browse = app.buttons["nav.Browsesandboxes"]
        XCTAssertTrue(
            browse.waitForExistence(timeout: 30),
            "macOS content shell should expose the remote workspace browser entry"
        )
        XCTAssertFalse(
            MacE2ETestSupport.element("workspaces.root", in: app).exists,
            "workspace browser should not already be selected before opening"
        )

        browse.click()

        XCTAssertTrue(
            MacE2ETestSupport.element("workspaces.root", in: app).waitForExistence(timeout: 15),
            "remote workspace browser should open from the content shell"
        )
        XCTAssertTrue(
            MacE2ETestSupport.element("content.macos.workspace-detail", in: app).waitForExistence(timeout: 15),
            "macOS remote workspace detail anchor should render after opening the browser"
        )
    }

    func test_switcher_shows_seeded_row() throws {
        try MacE2ETestSupport.requireSeeded(
            "seeded switcher row scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, env) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)
        guard let workspaceID = env.seededWorkspaceID, !workspaceID.isEmpty else {
            return XCTFail("seeded switcher scenario requires PLUE_E2E_WORKSPACE_ID")
        }

        XCTAssertTrue(
            MacE2ETestSupport.element("sidebar.remote.section", in: app).waitForExistence(timeout: 30),
            "REMOTE section should render before checking seeded rows"
        )
        XCTAssertTrue(
            app.buttons["sidebar.remote.row.\(workspaceID)"].waitForExistence(timeout: 45),
            "seeded workspace should appear as sidebar.remote.row.\(workspaceID)"
        )
        XCTAssertFalse(
            MacE2ETestSupport.element("sidebar.remote.empty", in: app).exists,
            "seeded remote workspace list must not render the empty state"
        )
    }

    func test_switcher_row_tap_opens_workspace_detail() throws {
        try MacE2ETestSupport.requireSeeded(
            "workspace detail scenario requires PLUE_E2E_SEEDED=1"
        )

        let (app, env) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)
        guard let workspaceID = env.seededWorkspaceID, !workspaceID.isEmpty else {
            return XCTFail("workspace detail scenario requires PLUE_E2E_WORKSPACE_ID")
        }

        let row = app.buttons["sidebar.remote.row.\(workspaceID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 45), "seeded remote row should be present before tapping")
        XCTAssertFalse(
            MacE2ETestSupport.element("content.macos.workspace-detail", in: app).exists,
            "workspace detail should not be selected before opening the remote row"
        )

        row.click()

        XCTAssertTrue(
            MacE2ETestSupport.element("content.macos.workspace-detail", in: app).waitForExistence(timeout: 15),
            "tapping the seeded remote row should open the macOS workspace detail surface"
        )
    }
}
#endif
