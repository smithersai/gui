import XCTest
import ViewInspector
@testable import SmithersGUI

@MainActor
final class HighCoverageViewRenderTests: XCTestCase {
    private func client() -> SmithersClient {
        SmithersClient(cwd: NSTemporaryDirectory())
    }

    private func assertText<T: BaseViewType>(
        _ text: String,
        existsIn inspected: InspectableView<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(
            try inspected.find(text: text),
            "Expected to find text '\(text)'",
            file: file,
            line: line
        )
    }

    func testApprovalsViewInitialRenderCoversHeaderListAndPlaceholder() throws {
        let inspected = try ApprovalsView(smithers: client()).inspect()

        assertText("Approvals", existsIn: inspected)
        assertText("History", existsIn: inspected)
        assertText("Select an approval", existsIn: inspected)
    }

    func testRunsViewInitialRenderCoversFiltersAndCount() throws {
        let inspected = try RunsView(smithers: client()).inspect()

        assertText("Runs", existsIn: inspected)
        assertText("All Statuses", existsIn: inspected)
        assertText("All Workflows", existsIn: inspected)
        assertText("All Time", existsIn: inspected)
        assertText("0 runs", existsIn: inspected)
    }

    func testSQLBrowserInitialRenderCoversSidebarQuerySchemaAndResults() throws {
        let inspected = try SQLBrowserView(smithers: client()).inspect()

        assertText("SQL Browser", existsIn: inspected)
        assertText("0 tables", existsIn: inspected)
        assertText("Tables", existsIn: inspected)
        assertText("Query", existsIn: inspected)
        assertText("Run Query", existsIn: inspected)
        assertText("Schema", existsIn: inspected)
        assertText("Select a table to inspect its schema.", existsIn: inspected)
        assertText("Results", existsIn: inspected)
        assertText("No results yet. Run a query to see output.", existsIn: inspected)
    }

    func testScoresViewInitialRenderCoversTabsSummaryMetricsAndPerScorerSection() throws {
        let inspected = try ScoresView(smithers: client()).inspect()

        assertText("Scores", existsIn: inspected)
        assertText("No runs", existsIn: inspected)
        assertText("Summary", existsIn: inspected)
        assertText("Metrics", existsIn: inspected)
        assertText("Recent", existsIn: inspected)
        assertText("Evaluations", existsIn: inspected)
        assertText("Mean score", existsIn: inspected)
        assertText("Tokens", existsIn: inspected)
        assertText("Avg duration", existsIn: inspected)
        assertText("Cache hit rate", existsIn: inspected)
        assertText("Est. cost", existsIn: inspected)
        assertText("Per-scorer statistics", existsIn: inspected)
    }

    func testRunInspectViewInitialRenderCoversToolbarMetadataActionsAndLoadingState() throws {
        var openedChat: (runId: String, nodeId: String?)?
        let inspected = try RunInspectView(
            smithers: client(),
            runId: "deploy-run-123456",
            onOpenLiveChat: { runId, nodeId in
                openedChat = (runId, nodeId)
            }
        )
        .inspect()

        assertText("Run Inspector", existsIn: inspected)
        assertText("deploy-r", existsIn: inspected)
        assertText("UNKNOWN", existsIn: inspected)
        assertText("Run", existsIn: inspected)
        assertText("Nodes", existsIn: inspected)
        assertText("0/0", existsIn: inspected)
        assertText("Live Chat", existsIn: inspected)
        assertText("Snapshots", existsIn: inspected)
        assertText("Hijack", existsIn: inspected)
        assertText("Watch", existsIn: inspected)
        assertText("Rerun", existsIn: inspected)
        assertText("List", existsIn: inspected)
        assertText("DAG", existsIn: inspected)
        assertText("Loading run...", existsIn: inspected)

        try inspected.find(button: "Live Chat").tap()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(openedChat?.runId, "deploy-run-123456")
        XCTAssertNil(openedChat?.nodeId)
    }

    func testLiveRunChatViewInitialRenderCoversControlsAndLoadingTranscript() throws {
        let inspected = try LiveRunChatView(
            smithers: client(),
            runId: "run-abcdef123456",
            nodeId: "node-1"
        )
        .inspect()

        assertText("Live Run Chat", existsIn: inspected)
        assertText("run-abcd", existsIn: inspected)
        assertText("Following", existsIn: inspected)
        assertText("Context", existsIn: inspected)
        assertText("Refresh", existsIn: inspected)
        assertText("Hijack", existsIn: inspected)
        assertText("Loading chat...", existsIn: inspected)
    }

    func testJJHubWorkflowsViewInitialRenderCoversHeaderListAndPlaceholder() throws {
        let inspected = try JJHubWorkflowsView(smithers: client()).inspect()

        assertText("JJHub Workflows", existsIn: inspected)
        assertText("Select a workflow", existsIn: inspected)
    }
}

final class RunInspectorHelperTests: XCTestCase {
    func testTaskStateIconCoversApprovalAndFallbackStates() {
        XCTAssertEqual(runInspectorTaskStateIcon("running"), "circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("finished"), "checkmark.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("failed"), "xmark.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("cancelled"), "minus.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("skipped"), "arrowshape.turn.up.right.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("blocked"), "pause.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("waiting-approval"), "pause.circle.fill")
        XCTAssertEqual(runInspectorTaskStateIcon("queued"), "circle")
    }

    func testTaskStateLabelNormalizesHyphenatedStates() {
        XCTAssertEqual(runInspectorTaskStateLabel("waiting-approval"), "WAITING APPROVAL")
        XCTAssertEqual(runInspectorTaskStateLabel("queued"), "QUEUED")
    }

    func testSafeIDPreservesAllowedCharactersAndReplacesPunctuation() {
        XCTAssertEqual(runInspectorSafeID("abc-DEF_123"), "abc-DEF_123")
        XCTAssertEqual(runInspectorSafeID("run/id:node.1"), "run-id-node-1")
    }

    func testShellQuoteEscapesSingleQuotesForTerminalCommands() {
        XCTAssertEqual(runInspectorShellQuote("simple"), "'simple'")
        XCTAssertEqual(runInspectorShellQuote("can't stop"), "'can'\"'\"'t stop'")
    }

    func testShortDateReturnsStableTimestampComponents() {
        XCTAssertTrue(runInspectorShortDate(1_700_000_000_000).contains("2023"))
    }
}
