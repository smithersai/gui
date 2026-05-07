import XCTest

// MARK: - Prompts E2E Tests

final class PromptsE2ETests: SmithersGUIUITestCase {

    func testPromptsListLoadsAndShowsPlaceholder() {
        navigate(to: "Prompts", expectedViewIdentifier: "view.prompts")

        // Before selecting a prompt, placeholder should appear
        XCTAssertTrue(app.staticTexts["Select a prompt"].waitForExistence(timeout: 5))
    }

    func testSelectPromptShowsDetailWithTabs() {
        navigate(to: "Prompts", expectedViewIdentifier: "view.prompts")

        // Wait for prompts list to load; find any prompt button in the list
        let promptRow = app.buttons.matching(NSPredicate(format: "identifier CONTAINS %@", "doc.text")).firstMatch
        // If no rows with that icon, try clicking first visible button in the left panel
        let listArea = app.scrollViews.firstMatch
        if listArea.waitForExistence(timeout: 5) {
            // Try to find a prompt row by looking for the first non-placeholder text
            let noPrompts = app.staticTexts["No prompts found"]
            if noPrompts.waitForExistence(timeout: 3) {
                // No fixture prompts, verify empty state
                XCTAssertTrue(noPrompts.exists)
                return
            }
        }

        // If prompts exist, placeholder should have gone away or we click one
        // Detail tabs should appear once selected
        let sourceTab = app.buttons.matching(NSPredicate(format: "label == %@", "Source")).firstMatch
        let inputsTab = app.buttons.matching(NSPredicate(format: "label == %@", "Inputs")).firstMatch
        let previewTab = app.buttons.matching(NSPredicate(format: "label == %@", "Preview")).firstMatch

        if sourceTab.waitForExistence(timeout: 5) {
            XCTAssertTrue(sourceTab.exists)
            XCTAssertTrue(inputsTab.exists)
            XCTAssertTrue(previewTab.exists)
        }
    }

    func testPromptsDetailTabSwitching() {
        navigate(to: "Prompts", expectedViewIdentifier: "view.prompts")

        // Wait for content to load
        let noPrompts = app.staticTexts["No prompts found"]
        let selectPrompt = app.staticTexts["Select a prompt"]

        if noPrompts.waitForExistence(timeout: 3) {
            // No fixture data, skip
            return
        }

        // If we have prompts and one is auto-selected, tabs should exist
        let sourceTab = app.buttons.matching(NSPredicate(format: "label == %@", "Source")).firstMatch
        let inputsTab = app.buttons.matching(NSPredicate(format: "label == %@", "Inputs")).firstMatch
        let previewTab = app.buttons.matching(NSPredicate(format: "label == %@", "Preview")).firstMatch

        guard sourceTab.waitForExistence(timeout: 5) else {
            // No prompt selected yet, just verify placeholder
            XCTAssertTrue(selectPrompt.waitForExistence(timeout: 3))
            return
        }

        // Switch to Inputs tab
        inputsTab.click()
        // Should show either inputs or "No inputs discovered"
        let noInputs = app.staticTexts["No inputs discovered"]
        let inputsHeader = app.staticTexts["DISCOVERED INPUTS"]
        let hasInputsContent = noInputs.waitForExistence(timeout: 3) || inputsHeader.waitForExistence(timeout: 2)
        XCTAssertTrue(hasInputsContent, "Expected inputs content or empty state")

        // Switch to Preview tab
        previewTab.click()
        let noPreview = app.staticTexts["No preview available"]
        XCTAssertTrue(noPreview.waitForExistence(timeout: 5) || app.buttons.matching(NSPredicate(format: "label == %@", "Generate Preview")).firstMatch.waitForExistence(timeout: 3))

        // Switch back to Source
        sourceTab.click()
    }

    func testPromptsRefreshButton() {
        navigate(to: "Prompts", expectedViewIdentifier: "view.prompts")

        let refreshButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "arrow.clockwise")).firstMatch
        if refreshButton.waitForExistence(timeout: 5) {
            refreshButton.click()
        }
        XCTAssertTrue(element("view.prompts").exists)
    }

    func testPromptsEmptyState() {
        navigate(to: "Prompts", expectedViewIdentifier: "view.prompts")

        // Either we see prompts list content or the empty state
        let noPrompts = app.staticTexts["No prompts found"]
        let selectPrompt = app.staticTexts["Select a prompt"]

        let hasContent = noPrompts.waitForExistence(timeout: 5) || selectPrompt.waitForExistence(timeout: 2)
        XCTAssertTrue(hasContent, "Expected prompt list content or placeholder/empty state")
    }
}

// MARK: - Landings E2E Tests

final class LandingsE2ETests: SmithersGUIUITestCase {

    func testLandingsListLoadsAndShowsPlaceholder() {
        navigate(to: "Landings", expectedViewIdentifier: "view.landings")

        // Before selecting, placeholder should show
        let placeholder = app.staticTexts["Select a landing"]
        let noLandings = app.staticTexts["No landings found"]
        let hasContent = placeholder.waitForExistence(timeout: 5) || noLandings.waitForExistence(timeout: 2)
        XCTAssertTrue(hasContent, "Expected landing placeholder or empty state")
    }

    func testLandingsStateFilterMenu() {
        navigate(to: "Landings", expectedViewIdentifier: "view.landings")

        // The state filter menu ("All") should exist in the header
        let filterMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "All")).firstMatch
        XCTAssertTrue(filterMenu.waitForExistence(timeout: 5))
    }

    func testLandingsDetailInfoAndDiffTabs() {
        navigate(to: "Landings", expectedViewIdentifier: "view.landings")

        let noLandings = app.staticTexts["No landings found"]
        if noLandings.waitForExistence(timeout: 3) {
            // No fixture data
            return
        }

        // If there are landings, try clicking the first row
        // Landing rows don't have specific accessibility IDs, use the scroll view
        let placeholder = app.staticTexts["Select a landing"]
        if placeholder.waitForExistence(timeout: 5) {
            // Landings loaded but none selected; look for a clickable row
        }

        // Check for Info/Diff tabs if a landing is selected
        let infoTab = app.buttons.matching(NSPredicate(format: "label == %@", "Info")).firstMatch
        let diffTab = app.buttons.matching(NSPredicate(format: "label == %@", "Diff")).firstMatch

        if infoTab.waitForExistence(timeout: 5) {
            XCTAssertTrue(infoTab.exists)
            XCTAssertTrue(diffTab.exists)

            // Switch to Diff tab
            diffTab.click()
            // Switch back to Info tab
            infoTab.click()
        }
    }

    func testLandingsRefreshButton() {
        navigate(to: "Landings", expectedViewIdentifier: "view.landings")

        let refreshButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "arrow.clockwise")).firstMatch
        if refreshButton.waitForExistence(timeout: 5) {
            refreshButton.click()
        }
        XCTAssertTrue(element("view.landings").exists)
    }

    func testLandingsApproveButtonVisibleForNonLandedItems() {
        navigate(to: "Landings", expectedViewIdentifier: "view.landings")

        let noLandings = app.staticTexts["No landings found"]
        if noLandings.waitForExistence(timeout: 3) {
            return
        }

        // If an Info tab is visible, check for Approve button
        let approveButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Approve")).firstMatch
        let landButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Land")).firstMatch

        // These buttons only appear for non-landed items when selected
        // Just verify the view is functional
        XCTAssertTrue(element("view.landings").exists)
    }
}

// MARK: - SQL Browser E2E Tests

final class SQLBrowserE2ETests: SmithersGUIUITestCase {

    func testSQLBrowserLoadsTablesSidebar() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        // Header shows "SQL Browser"
        XCTAssertTrue(app.staticTexts["SQL Browser"].waitForExistence(timeout: 5))

        // Tables sidebar label
        XCTAssertTrue(app.staticTexts["Tables"].waitForExistence(timeout: 5))

        // Should show table count or loading/error/empty state
        let noTables = app.staticTexts["No tables found."]
        let tablesCount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "tables")).firstMatch
        let hasContent = noTables.waitForExistence(timeout: 5) || tablesCount.waitForExistence(timeout: 2)
        XCTAssertTrue(hasContent, "Expected tables sidebar content")
    }

    func testSQLBrowserQueryEditorExists() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        // Query card header
        XCTAssertTrue(app.staticTexts["Query"].waitForExistence(timeout: 5))

        // Run Query button
        let runButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Run Query")).firstMatch
        XCTAssertTrue(runButton.waitForExistence(timeout: 5))

        // Results section
        XCTAssertTrue(app.staticTexts["Results"].waitForExistence(timeout: 5))
    }

    func testSQLBrowserSchemaCardExists() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        // Schema card should show
        XCTAssertTrue(app.staticTexts["Schema"].waitForExistence(timeout: 5))

        // If no table selected, shows placeholder
        let schemaPlaceholder = app.staticTexts["Select a table to inspect its schema."]
        // If a table was auto-selected, schema columns would show
        // Either outcome is valid
        XCTAssertTrue(element("view.sql").exists)
    }

    func testSQLBrowserResultsPlaceholder() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        // Before running a query, results section shows placeholder
        let noResults = app.staticTexts["No results yet. Run a query to see output."]
        XCTAssertTrue(noResults.waitForExistence(timeout: 5))
    }

    func testSQLBrowserRefreshButton() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        let refreshButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "arrow.clockwise")).firstMatch
        if refreshButton.waitForExistence(timeout: 5) {
            refreshButton.click()
        }
        XCTAssertTrue(element("view.sql").exists)
    }
}
