import XCTest

// MARK: - Agents E2E Tests

final class AgentsE2ETests: SmithersGUIUITestCase {

    func testAgentsViewLoads() {
        navigate(to: "Agents", expectedViewIdentifier: "view.agents")
        XCTAssertTrue(app.staticTexts["Agents"].waitForExistence(timeout: 5))
    }

    func testAgentsViewShowsAvailableSection() {
        navigate(to: "Agents", expectedViewIdentifier: "view.agents")

        // UI test fixtures mark claude-code, codex, gemini, amp as usable
        // The available section header should contain a count
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Available")).firstMatch.waitForExistence(timeout: 5))
    }

    func testAgentsViewShowsUnavailableSection() {
        navigate(to: "Agents", expectedViewIdentifier: "view.agents")

        // Agents not detected section should also exist
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Not Detected")).firstMatch.waitForExistence(timeout: 5))
    }

    func testAgentsViewShowsAgentCards() {
        navigate(to: "Agents", expectedViewIdentifier: "view.agents")

        // Claude Code should appear (usable agent from fixtures)
        XCTAssertTrue(app.staticTexts["Claude Code"].waitForExistence(timeout: 5))

        // Codex should appear (usable agent from fixtures)
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 5))
    }

    func testAgentsViewShowsAgentDetailFields() {
        navigate(to: "Agents", expectedViewIdentifier: "view.agents")

        // Wait for cards to load
        XCTAssertTrue(app.staticTexts["Claude Code"].waitForExistence(timeout: 5))

        // Info row labels should be visible
        XCTAssertTrue(app.staticTexts["Status"].exists)
        XCTAssertTrue(app.staticTexts["Roles"].exists)
        XCTAssertTrue(app.staticTexts["Command"].exists)
        XCTAssertTrue(app.staticTexts["Auth"].exists)
        XCTAssertTrue(app.staticTexts["API Key"].exists)

        // Status tags should appear
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Availability:")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Usable:")).firstMatch.exists)
    }
}

// MARK: - Changes E2E Tests

final class ChangesE2ETests: SmithersGUIUITestCase {

    func testChangesViewLoads() {
        navigate(to: "Changes", expectedViewIdentifier: "view.changes")

        // The changes header should be visible
        XCTAssertTrue(app.staticTexts["Changes"].waitForExistence(timeout: 5))
    }

    func testChangesViewShowsModeToggle() {
        navigate(to: "Changes", expectedViewIdentifier: "view.changes")

        // The segmented picker should show Changes and Status modes
        XCTAssertTrue(app.staticTexts["Changes"].waitForExistence(timeout: 5))

        // The mode picker items should exist
        let changesModeButton = app.buttons.matching(NSPredicate(format: "label == %@", "Changes")).firstMatch
        let statusModeButton = app.buttons.matching(NSPredicate(format: "label == %@", "Status")).firstMatch
        XCTAssertTrue(changesModeButton.waitForExistence(timeout: 5))
        XCTAssertTrue(statusModeButton.waitForExistence(timeout: 5))
    }

    func testChangesViewShowsSelectAChangePromptWhenNothingSelected() {
        navigate(to: "Changes", expectedViewIdentifier: "view.changes")

        // If no changes loaded (jjhub not available), the view should show either
        // an error state, empty state, or the "Select a change" placeholder.
        // We verify the view is at least rendered.
        let selectPrompt = app.staticTexts["Select a change"]
        let noChanges = app.staticTexts["No recent changes found."]
        let changesHeader = app.staticTexts["Changes"]

        XCTAssertTrue(changesHeader.waitForExistence(timeout: 5))

        // At least one of these states should be present
        let hasExpectedState = selectPrompt.waitForExistence(timeout: 5)
            || noChanges.exists
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Error")).firstMatch.exists

        XCTAssertTrue(hasExpectedState, "Changes view should show either a placeholder, empty state, or error")
    }

    func testChangesViewCanSwitchToStatusMode() {
        navigate(to: "Changes", expectedViewIdentifier: "view.changes")

        let statusButton = app.buttons.matching(NSPredicate(format: "label == %@", "Status")).firstMatch
        XCTAssertTrue(statusButton.waitForExistence(timeout: 5))
        statusButton.click()

        // In status mode, we should see either loading, status text, an error, or "Clean working copy."
        let hasStatusContent = app.staticTexts["Working Copy Status"].waitForExistence(timeout: 5)
            || app.staticTexts["Clean working copy."].waitForExistence(timeout: 5)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Error")).firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Loading status")).firstMatch.waitForExistence(timeout: 3)

        XCTAssertTrue(hasStatusContent, "Status mode should show some content or error state")
    }

    func testChangesViewDetailTabsExistWhenInfoTabSelected() {
        navigate(to: "Changes", expectedViewIdentifier: "view.changes")

        // The Info and Diff tab buttons appear in the detail pane when a change is selected.
        // If no change is selected, they won't appear. We verify the view loaded.
        let infoTab = app.buttons.matching(NSPredicate(format: "label == %@", "Info")).firstMatch
        let diffTab = app.buttons.matching(NSPredicate(format: "label == %@", "Diff")).firstMatch

        // These tabs only appear when a change is selected. If jjhub is unavailable,
        // no change will be selected and tabs won't show. Either way the view should be stable.
        if infoTab.waitForExistence(timeout: 3) {
            XCTAssertTrue(diffTab.exists, "Diff tab should exist alongside Info tab")

            // Click Diff tab
            diffTab.click()

            // Click back to Info tab
            infoTab.click()
        }

        // The view should still be showing
        XCTAssertTrue(element("view.changes").exists)
    }
}

// MARK: - Terminal E2E Tests

final class TerminalE2ETests: SmithersGUIUITestCase {
    private func terminalTabCount() -> Int {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "workspace.terminal:")
        return app.buttons.matching(predicate).count
    }

    private func terminalTabIdentifiers() -> Set<String> {
        let predicate = NSPredicate(format: "identifier BEGINSWITH %@", "workspace.terminal:")
        let tabs = app.buttons.matching(predicate).allElementsBoundByIndex
        return Set(tabs.map(\.identifier))
    }

    private func openNewTerminalFromMenu(file: StaticString = #filePath, line: UInt = #line) {
        let before = terminalTabCount()
        // The built-in chat "New" menu was removed; use the hidden keyboard
        // shortcut button that production code still exposes for creating a
        // new terminal workspace.
        waitForElement("shortcut.newTerminal", file: file, line: line).click()

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.terminalTabCount() >= before + 1
            },
            object: nil
        )
        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(element("view.terminal").waitForExistence(timeout: 5), file: file, line: line)
    }

    func testTerminalViewLoads() {
        openNewTerminalFromMenu()

        // In UI test mode, TerminalView shows a placeholder
        XCTAssertTrue(element("terminal.root").waitForExistence(timeout: 5))
    }

    func testTerminalPlaceholderShowsInUITestMode() {
        openNewTerminalFromMenu()

        // The UI test placeholder should display
        XCTAssertTrue(element("terminal.placeholder").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Terminal ready"].waitForExistence(timeout: 5))
    }

    func testTerminalViewPersistsAcrossNavigationSwitches() {
        openNewTerminalFromMenu()
        XCTAssertTrue(element("terminal.root").waitForExistence(timeout: 5))

        // Navigate away
        navigate(to: "Dashboard", expectedViewIdentifier: "view.dashboard")

        // Navigate back by clicking the terminal tab in the sidebar
        let terminalTab = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "workspace.terminal:")).firstMatch
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 5))
        terminalTab.click()
        XCTAssertTrue(element("view.terminal").waitForExistence(timeout: 5))
        XCTAssertTrue(element("terminal.root").waitForExistence(timeout: 5))
        XCTAssertTrue(element("terminal.placeholder").waitForExistence(timeout: 5))
    }

    func testTerminalAccessibleFromNewMenu() {
        openNewTerminalFromMenu()
        XCTAssertTrue(element("view.terminal").waitForExistence(timeout: 5))
    }

    func testNewMenuCreatesMultipleTerminalTabs() {
        openNewTerminalFromMenu()
        openNewTerminalFromMenu()

        XCTAssertGreaterThanOrEqual(terminalTabCount(), 2)
        XCTAssertGreaterThanOrEqual(terminalTabIdentifiers().count, 2)
    }
}

// NOTE: `ChatEdgeCaseE2ETests` was removed along with the built-in chat
// feature (view.chat / chat.surface / chat.composer / chat.input /
// chat.slashPalette / chat.targetPicker no longer exist in production code).
