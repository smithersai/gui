import XCTest

final class HighImpactMissingE2ETests: SmithersGUIUITestCase {

    func testTriggersShowsFixtureRowsAndMetadata() {
        navigate(to: "Triggers", expectedViewIdentifier: "view.triggers")

        XCTAssertTrue(app.staticTexts["Triggers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cron-ui-1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["cron-ui-2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 * * * *"].exists)
        XCTAssertTrue(app.staticTexts[".smithers/workflows/hourly-checks.tsx"].exists)
        XCTAssertTrue(app.staticTexts["30 9 * * 1-5"].exists)
        XCTAssertTrue(app.staticTexts[".smithers/workflows/weekday-standup.tsx"].exists)
    }

    func testTriggersCreateFormValidatesRequiredFields() {
        navigate(to: "Triggers", expectedViewIdentifier: "view.triggers")

        openNewTriggerForm()
        XCTAssertTrue(app.staticTexts["Cron pattern and workflow path are required."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create"].isEnabled)
    }

    func testTriggersCreateFormRequiresWorkflowPath() {
        navigate(to: "Triggers", expectedViewIdentifier: "view.triggers")

        openNewTriggerForm()
        typeIntoTextField(placeholder: "e.g. 0 8 * * *", text: "45 7 * * 2")
        XCTAssertTrue(app.staticTexts["Workflow path is required."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Create"].isEnabled)
    }

    func testTriggersCreateAndListNewCron() {
        navigate(to: "Triggers", expectedViewIdentifier: "view.triggers")

        openNewTriggerForm()
        typeIntoTextField(placeholder: "e.g. 0 8 * * *", text: "15 10 * * 1")
        typeIntoTextField(placeholder: "e.g. .smithers/workflows/nightly.tsx", text: ".smithers/workflows/e2e-weekly.tsx")
        app.buttons["Create"].click()

        XCTAssertTrue(app.staticTexts["15 10 * * 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[".smithers/workflows/e2e-weekly.tsx"].exists)
        XCTAssertFalse(app.staticTexts["Create Trigger"].waitForExistence(timeout: 2))
    }

    func testTriggersCancelCreateFormHidesForm() {
        navigate(to: "Triggers", expectedViewIdentifier: "view.triggers")

        openNewTriggerForm()
        typeIntoTextField(placeholder: "e.g. 0 8 * * *", text: "5 6 * * *")
        let closeButton = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", "view.triggers", "Close"))
            .firstMatch
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.click()
        XCTAssertFalse(app.staticTexts["Create Trigger"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["cron-ui-1"].exists)
    }

    func testTicketsLoadsFixturesAndSelectsDetail() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        XCTAssertTrue(app.staticTexts["Tickets"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("tickets.row.0007-port-tickets-workflow").waitForExistence(timeout: 5))
        XCTAssertTrue(element("tickets.row.0015-wire-issues-backend").waitForExistence(timeout: 5))

        waitForElement("tickets.row.0007-port-tickets-workflow").click()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0007-port-tickets-workflow"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    func testTicketsSearchFiltersToMatchingFixture() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        typeIntoTextField(placeholder: "Search tickets...", text: "0015")
        XCTAssertTrue(element("tickets.row.0015-wire-issues-backend").waitForExistence(timeout: 5))
        XCTAssertFalse(element("tickets.row.0007-port-tickets-workflow").waitForExistence(timeout: 2))
    }

    func testTicketsSearchNoResultsShowsEmptyState() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        typeIntoTextField(placeholder: "Search tickets...", text: "ticket-that-does-not-exist")
        XCTAssertTrue(app.staticTexts["No tickets found"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Select a ticket"].waitForExistence(timeout: 5))
    }

    func testTicketsCreateCancelHidesDraftForm() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        openNewTicketForm()
        typeIntoTextField(placeholder: "ticket-id (e.g. feat-login-flow)", text: "e2e-cancel-ticket")
        app.buttons["Cancel"].click()

        XCTAssertFalse(app.staticTexts["NEW TICKET"].waitForExistence(timeout: 2))
        XCTAssertFalse(element("tickets.row.e2e-cancel-ticket").exists)
    }

    func testTicketsCreateNewTicketAndSelectsIt() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        openNewTicketForm()
        typeIntoTextField(placeholder: "ticket-id (e.g. feat-login-flow)", text: "e2e-created-ticket")
        app.buttons["Create"].click()

        XCTAssertTrue(element("tickets.row.e2e-created-ticket").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["e2e-created-ticket"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
    }

    func testTicketsEditingFixtureShowsSaveAndClearsModifiedAfterSave() {
        navigate(to: "Tickets", expectedViewIdentifier: "view.tickets")

        waitForElement("tickets.row.0007-port-tickets-workflow").click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeText("\nE2E edit marker.")

        XCTAssertTrue(app.staticTexts["Modified"].waitForExistence(timeout: 5))
        app.buttons["Save"].click()
        XCTAssertFalse(app.buttons["Save"].waitForExistence(timeout: 5))
    }

    func testWorkflowLaunchTabShowsFixtureGraphAndInputs() {
        openWorkflowLaunchTab()

        XCTAssertTrue(element("workflows.graph").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["prompt"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["review"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.launchField.prompt").waitForExistence(timeout: 5))
        XCTAssertTrue(element("workflows.launchField.environment").waitForExistence(timeout: 5))
    }

    func testWorkflowLaunchRunButtonIsEnabled() {
        openWorkflowLaunchTab()

        XCTAssertTrue(element("workflows.runButton").isEnabled)
    }

    func testWorkflowDagDetailsToggleShowsSchema() {
        openWorkflowLaunchTab()

        XCTAssertTrue(app.staticTexts["prompt"].waitForExistence(timeout: 5))
        app.buttons["Show Details"].click()
        XCTAssertTrue(app.buttons["Hide Details"].waitForExistence(timeout: 5))
    }

    func testWorkflowDetailShowsRunCountAndLastStatus() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")
        waitForElement("workflow.row.deploy-preview").click()

        XCTAssertTrue(workflowDetailTab("Runs").exists)
        XCTAssertTrue(app.staticTexts["last: RUNNING"].waitForExistence(timeout: 5))
    }

    func testWorkflowRunLaunchCreatesLiveRunTab() {
        openWorkflowLaunchTab()

        waitForElement("workflows.runButton").click()
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.run:")).count, 1)
    }

    func testRunsLiveChatActionOpensLiveRunTab() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        waitForElement("runs.chat.ui-run-active-001").click()
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab.run:")).count, 1)
    }

    func testRunsSnapshotsActionOpensAndClosesSnapshotsSheet() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        waitForElement("runs.snapshots.ui-run-active-001").click()
        XCTAssertTrue(element("view.runsnapshots").waitForExistence(timeout: 5))
        XCTAssertTrue(element("runsnapshots.row.ui-snapshot-run").waitForExistence(timeout: 5))
        waitForElement("runsnapshots.close").click()
        XCTAssertFalse(element("view.runsnapshots").waitForExistence(timeout: 2))
    }

    func testRunsViewStaysLoadedAfterFixtureActionsRender() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        XCTAssertTrue(element("view.runs").exists)
        XCTAssertTrue(element("runs.chat.ui-run-active-001").waitForExistence(timeout: 5))
        XCTAssertTrue(element("runs.snapshots.ui-run-active-001").waitForExistence(timeout: 5))
    }

    func testSQLSelectingFixtureTableShowsSchema() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        XCTAssertTrue(app.staticTexts["_smithers_runs"].waitForExistence(timeout: 5))
        app.staticTexts["_smithers_runs"].click()
        XCTAssertTrue(app.staticTexts["id"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TEXT"].exists)
    }

    func testSQLFixtureQueryExecutesAndRendersResultRows() {
        navigate(to: "SQL Browser", expectedViewIdentifier: "view.sql")

        XCTAssertTrue(app.staticTexts["_smithers_runs"].waitForExistence(timeout: 5))
        app.staticTexts["_smithers_runs"].click()

        let runQuery = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Run Query"))
            .firstMatch
        XCTAssertTrue(runQuery.waitForExistence(timeout: 5))
        XCTAssertTrue(runQuery.isEnabled)
        runQuery.click()

        XCTAssertTrue(app.staticTexts["run_id"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ui-run-running-001"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["finished"].waitForExistence(timeout: 5))
    }

    func testScoresMetricsTabShowsTokenLatencyAndCostFixtures() {
        navigate(to: "Scores", expectedViewIdentifier: "view.scores")

        let metricsTab = app.buttons
            .matching(NSPredicate(format: "label == %@", "Metrics"))
            .firstMatch
        XCTAssertTrue(metricsTab.waitForExistence(timeout: 5))
        metricsTab.click()

        XCTAssertTrue(app.staticTexts["Token Usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Latency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cost Tracking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["33.2K"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["812ms"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$0.358800 USD"].waitForExistence(timeout: 5))
    }

    func testRunInspectorWaitingApprovalShowsActionableGateControls() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        waitForElement("runs.inspect.ui-run-approval-001").click()
        XCTAssertTrue(element("view.runinspect").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Release Gate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["WAITING APPROVAL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Deploy gate"].waitForExistence(timeout: 5))

        let approve = waitForElement("runinspect.action.approve")
        let deny = waitForElement("runinspect.action.deny")
        XCTAssertTrue(approve.isEnabled)
        XCTAssertTrue(deny.isEnabled)

        deny.click()
        waitForElement("runinspect.cancelDenyButton").click()
        XCTAssertTrue(element("view.runinspect").waitForExistence(timeout: 5))
    }

    func testLiveRunChatShowsLatestAttemptTranscriptAndContextPane() {
        navigate(to: "Runs", expectedViewIdentifier: "view.runs")

        waitForElement("runs.chat.ui-run-active-001").click()
        XCTAssertTrue(element("view.liveRun").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Live Run Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Second attempt is active with updated context."].waitForExistence(timeout: 5))

        let contextButton = app.buttons["Context"]
        XCTAssertTrue(contextButton.waitForExistence(timeout: 5))
        contextButton.click()

        XCTAssertTrue(app.staticTexts["Context"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workflow"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Deploy Preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["running"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Blocks"].waitForExistence(timeout: 5))
    }

    private func openWorkflowLaunchTab() {
        navigate(to: "Workflows", expectedViewIdentifier: "view.workflows")
        waitForElement("workflow.row.deploy-preview").click()
        workflowDetailTab("Launch").click()
        XCTAssertTrue(element("workflows.runButton").waitForExistence(timeout: 5))
    }

    private func workflowDetailTab(_ title: String) -> XCUIElement {
        let tab = app.buttons
            .matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "view.workflows", title))
            .firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Missing workflow detail tab: \(title)")
        return tab
    }

    private func openNewTriggerForm() {
        let newButton = app.buttons["New"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5), "Missing trigger New button")
        newButton.click()
        XCTAssertTrue(app.staticTexts["Create Trigger"].waitForExistence(timeout: 5))
    }

    private func openNewTicketForm() {
        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), "Missing ticket Add button")
        addButton.click()
        XCTAssertTrue(app.staticTexts["NEW TICKET"].waitForExistence(timeout: 5))
    }

    private func typeIntoTextField(placeholder: String, text: String) {
        let field = app.textFields[placeholder]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing text field: \(placeholder)")
        field.click()
        field.typeText(text)
    }
}
