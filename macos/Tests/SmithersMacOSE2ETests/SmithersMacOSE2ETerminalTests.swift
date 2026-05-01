#if os(macOS)
import XCTest

final class SmithersMacOSE2ETerminalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        MacE2ETestSupport.clearSavedApplicationState()
    }

    func test_terminal_surface_mounts_when_workspace_session_seeded() throws {
        try MacE2ETestSupport.requireSeeded(
            "terminal scenario requires PLUE_E2E_SEEDED=1"
        )
        _ = try MacE2ETestSupport.requireEnv(MacE2ESeedKey.workspaceSessionID)

        let (app, _) = MacE2ETestSupport.launchSignedInShell(autoOpen: true)

        XCTAssertFalse(
            MacE2ETestSupport.element("terminal.root", in: app).exists,
            "terminal surface must not leak onto the shell before a terminal workspace is opened"
        )

        let newTerminal = MacE2ETestSupport.element("shortcut.newTerminal", in: app)
        XCTAssertTrue(
            newTerminal.waitForExistence(timeout: 15),
            "macOS shell should expose the hidden new-terminal affordance in UI-test mode"
        )
        newTerminal.click()

        XCTAssertTrue(
            MacE2ETestSupport.element("view.terminal", in: app).waitForExistence(timeout: 10),
            "new terminal route should render"
        )
        XCTAssertTrue(
            MacE2ETestSupport.element("workspace.terminal.root", in: app).waitForExistence(timeout: 10),
            "terminal workspace root should mount"
        )
        XCTAssertTrue(
            MacE2ETestSupport.element("terminal.root", in: app).waitForExistence(timeout: 10),
            "macOS terminal surface root should mount"
        )
        XCTAssertTrue(
            MacE2ETestSupport.element("terminal.placeholder", in: app).waitForExistence(timeout: 10),
            "UI-test mode should render the deterministic macOS terminal placeholder"
        )
    }
}
#endif
