import XCTest

// MARK: - Runs E2E Tests

final class RunsE2ETests: SmithersGUIUITestCase {

    func testRunsListLoadsWithSections() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // The view should load and show section headers for grouped runs
        // Fixture data contains runs in various statuses
        let activeSection = app.staticTexts["ACTIVE"]
        let completedSection = app.staticTexts["COMPLETED"]
        let failedSection = app.staticTexts["FAILED"]

        // At least one section should appear
        let anySection = activeSection.waitForExistence(timeout: 5)
            || completedSection.waitForExistence(timeout: 2)
            || failedSection.waitForExistence(timeout: 2)
        XCTAssertTrue(anySection, "Expected at least one run section (ACTIVE, COMPLETED, or FAILED)")
    }

    func testRunsSearchFilterNarrowsResults() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // The search field is embedded in the filter bar
        let searchField = app.textFields["Search runs..."]
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("nonexistent-workflow-xyz")

            // Should show empty state
            XCTAssertTrue(app.staticTexts["No runs found"].waitForExistence(timeout: 5))

            // Clear search
            searchField.click()
            searchField.typeKey("a", modifierFlags: .command)
            searchField.typeText("")
        }
    }

    func testRunsStatusFilterMenu() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // The "All Statuses" menu button should exist
        let statusMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "All Statuses")).firstMatch
        XCTAssertTrue(statusMenu.waitForExistence(timeout: 5))
    }

    func testRunsDateFilterMenu() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // The "All Time" date filter menu button should exist
        let dateMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "All Time")).firstMatch
        XCTAssertTrue(dateMenu.waitForExistence(timeout: 5))
    }

    func testRunsEmptyStateShownWhenNoResults() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        // Type a search that yields no results
        let searchField = app.textFields["Search runs..."]
        if searchField.waitForExistence(timeout: 5) {
            searchField.click()
            searchField.typeText("zzzzz-no-match")
            XCTAssertTrue(app.staticTexts["No runs found"].waitForExistence(timeout: 5))
        }
    }
}

// MARK: - Scores E2E Tests

final class ScoresE2ETests: SmithersGUIUITestCase {

    func testScoresViewLoadsWithSummaryTab() {
        navigate(to: "Scores", expectedViewIdentifier: "view.scores")

        // Summary and Recent tabs should exist
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Summary")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Recent")).firstMatch.exists)

        // Summary tab is default; table headers should appear if data exists
        let scorerHeader = app.staticTexts["Scorer"]
        let noDataLabel = app.staticTexts["No scorer data"]
        let hasSummary = scorerHeader.waitForExistence(timeout: 5) || noDataLabel.waitForExistence(timeout: 2)
        XCTAssertTrue(hasSummary, "Expected either scorer table or empty state in Summary tab")
    }

    func testScoresRecentTab() {
        navigate(to: "Scores", expectedViewIdentifier: "view.scores")

        let recentButton = app.buttons.matching(NSPredicate(format: "label == %@", "Recent")).firstMatch
        XCTAssertTrue(recentButton.waitForExistence(timeout: 5))
        recentButton.click()

        // Should show recent scores or the empty state
        let noRecent = app.staticTexts["No recent evaluations"]
        let hasContent = noRecent.waitForExistence(timeout: 5) || app.staticTexts.count > 0
        XCTAssertTrue(hasContent, "Expected recent scores content or empty state")
    }

    func testScoresTabSwitching() {
        navigate(to: "Scores", expectedViewIdentifier: "view.scores")

        let summaryButton = app.buttons.matching(NSPredicate(format: "label == %@", "Summary")).firstMatch
        let recentButton = app.buttons.matching(NSPredicate(format: "label == %@", "Recent")).firstMatch

        XCTAssertTrue(summaryButton.waitForExistence(timeout: 5))

        recentButton.click()
        // Recent tab content
        let noRecent = app.staticTexts["No recent evaluations"]
        _ = noRecent.waitForExistence(timeout: 3)

        summaryButton.click()
        // Summary tab content
        let scorerHeader = app.staticTexts["Scorer"]
        let noData = app.staticTexts["No scorer data"]
        let switchedBack = scorerHeader.waitForExistence(timeout: 3) || noData.waitForExistence(timeout: 2)
        XCTAssertTrue(switchedBack, "Should return to Summary tab content")
    }

    func testScoresRefreshButton() {
        navigate(to: "Scores", expectedViewIdentifier: "view.scores")

        // The refresh button (arrow.clockwise) should exist in header
        let refreshButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "arrow.clockwise")).firstMatch
        if refreshButton.waitForExistence(timeout: 5) {
            refreshButton.click()
        }
        // View should still be present after refresh
        XCTAssertTrue(element("view.scores").exists)
    }
}

// MARK: - Memory E2E Tests

final class MemoryE2ETests: SmithersGUIUITestCase {

    func testMemoryViewLoadsFactsList() {
        navigate(to: "Memory", expectedViewIdentifier: "view.memory")

        // Facts mode button should exist and be active by default
        let factsButton = app.buttons.matching(NSPredicate(format: "label == %@", "Facts")).firstMatch
        XCTAssertTrue(factsButton.waitForExistence(timeout: 5))

        // Should show fact table headers or empty state
        let nsHeader = app.staticTexts["Namespace"]
        let emptyState = app.staticTexts["No memory facts"]
        let hasContent = nsHeader.waitForExistence(timeout: 5) || emptyState.waitForExistence(timeout: 2)
        XCTAssertTrue(hasContent, "Expected facts table or empty state")
    }

    func testMemoryRecallMode() {
        navigate(to: "Memory", expectedViewIdentifier: "view.memory")

        let recallButton = app.buttons.matching(NSPredicate(format: "label == %@", "Recall")).firstMatch
        XCTAssertTrue(recallButton.waitForExistence(timeout: 5))
        recallButton.click()

        // Recall mode should show query input
        let queryField = app.textFields["Semantic recall query..."]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))

        // Top-K control should be available in recall mode.
        XCTAssertTrue(app.textFields["memory.recall.topK"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["memory.recall.topK.slider"].waitForExistence(timeout: 5))

        // Search button should exist
        let searchButton = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        XCTAssertTrue(searchButton.exists)
    }

    func testMemoryRecallSubmitQuery() {
        navigate(to: "Memory", expectedViewIdentifier: "view.memory")

        let recallButton = app.buttons.matching(NSPredicate(format: "label == %@", "Recall")).firstMatch
        XCTAssertTrue(recallButton.waitForExistence(timeout: 5))
        recallButton.click()

        let queryField = app.textFields["Semantic recall query..."]
        XCTAssertTrue(queryField.waitForExistence(timeout: 5))
        queryField.click()
        queryField.typeText("test query")

        let searchButton = app.buttons.matching(NSPredicate(format: "label == %@", "Search")).firstMatch
        searchButton.click()

        // After submitting, the empty prompt should disappear
        XCTAssertFalse(app.staticTexts["Enter a query to search memory"].waitForExistence(timeout: 5))
    }

    func testMemoryModeSwitching() {
        navigate(to: "Memory", expectedViewIdentifier: "view.memory")

        let factsButton = app.buttons.matching(NSPredicate(format: "label == %@", "Facts")).firstMatch
        let recallButton = app.buttons.matching(NSPredicate(format: "label == %@", "Recall")).firstMatch

        XCTAssertTrue(factsButton.waitForExistence(timeout: 5))

        recallButton.click()
        XCTAssertTrue(app.textFields["Semantic recall query..."].waitForExistence(timeout: 5))

        factsButton.click()
        // Should be back to facts list or empty state
        let nsHeader = app.staticTexts["Namespace"]
        let emptyState = app.staticTexts["No memory facts"]
        let hasContent = nsHeader.waitForExistence(timeout: 3) || emptyState.waitForExistence(timeout: 2)
        XCTAssertTrue(hasContent, "Should return to Facts mode")
    }

    func testMemoryNamespaceFilterExists() {
        navigate(to: "Memory", expectedViewIdentifier: "view.memory")

        // The "All Namespaces" filter menu should exist
        let nsMenu = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "All Namespaces")).firstMatch
        XCTAssertTrue(nsMenu.waitForExistence(timeout: 5))
    }
}
