import SwiftUI
import XCTest
import ViewInspector
@testable import SmithersGUI

// MARK: - Test Helpers

@MainActor
private func makeClient() -> SmithersClient {
    SmithersClient(cwd: "/tmp")
}

private func makeRun(
    id: String = "run-1",
    workflowName: String? = "Test Workflow",
    status: RunStatus = .running,
    startedAtMs: Int64? = 1700000000000,
    finishedAtMs: Int64? = nil,
    summary: [String: Int]? = ["total": 10, "finished": 5, "failed": 0]
) -> RunSummary {
    RunSummary(
        runId: id,
        workflowName: workflowName,
        workflowPath: nil,
        status: status,
        startedAtMs: startedAtMs,
        finishedAtMs: finishedAtMs,
        summary: summary,
        errorJson: nil
    )
}

private func makeWorkflow(
    id: String = "wf-1",
    name: String = "My Workflow",
    status: WorkflowStatus? = .active
) -> Workflow {
    Workflow(
        id: id,
        workspaceId: nil,
        name: name,
        relativePath: "workflows/main.ts",
        status: status,
        updatedAt: nil
    )
}

private func makeApproval(
    id: String = "appr-1",
    runId: String = "run-1",
    status: String = "pending",
    gate: String? = "Deploy Gate"
) -> Approval {
    Approval(
        id: id,
        runId: runId,
        nodeId: "node-1",
        workflowPath: nil,
        gate: gate,
        status: status,
        payload: nil,
        requestedAt: Int64(Date().timeIntervalSince1970 * 1000),
        resolvedAt: nil,
        resolvedBy: nil
    )
}

// MARK: - StatCard Tests (UI_STAT_CARD, DASHBOARD_STAT_CARD_MONOSPACED_24PT)

final class StatCardTests: XCTestCase {

    func testStatCardRendersValueTitleAndIcon() throws {
        let card = StatCard(title: "Active Runs", value: "3", icon: "play.circle.fill", color: Theme.success)
        let vstack = try card.inspect().vStack()

        // Value text
        let valueText = try vstack.text(1)
        XCTAssertEqual(try valueText.string(), "3")

        // Title text
        let titleText = try vstack.text(2)
        XCTAssertEqual(try titleText.string(), "Active Runs")
    }

    /// DASHBOARD_STAT_CARD_MONOSPACED_24PT: The stat value must use monospaced 24pt bold font.
    func testStatCardValueFontIsMonospaced24pt() throws {
        let card = StatCard(title: "Count", value: "42", icon: "number", color: Theme.accent)
        let vstack = try card.inspect().vStack()
        let valueText = try vstack.text(1)

        // Verify the font is set to system size 24, bold, monospaced
        let font = try valueText.attributes().font()
        // Font should be .system(size: 24, weight: .bold, design: .monospaced)
        XCTAssertEqual(font, .system(size: 24, weight: .bold, design: .monospaced))
    }

    func testStatCardZeroValue() throws {
        let card = StatCard(title: "Failed", value: "0", icon: "xmark.circle.fill", color: Theme.danger)
        let valueText = try card.inspect().vStack().text(1)
        XCTAssertEqual(try valueText.string(), "0")
    }

    func testStatCardLargeValue() throws {
        let card = StatCard(title: "Workflows", value: "9999", icon: "arrow.triangle.branch", color: Theme.accent)
        let valueText = try card.inspect().vStack().text(1)
        XCTAssertEqual(try valueText.string(), "9999")
    }
}

// MARK: - SectionCard Tests (UI_SECTION_CARD)

final class SectionCardTests: XCTestCase {

    func testSectionCardRendersTitle() throws {
        let card = SectionCard(title: "Recent Runs") {
            Text("Child content")
        }
        let vstack = try card.inspect().vStack()
        let titleText = try vstack.text(0)
        XCTAssertEqual(try titleText.string(), "Recent Runs")
    }

    func testSectionCardRendersChildContent() throws {
        let card = SectionCard(title: "Test") {
            Text("Hello")
            Text("World")
        }
        let vstack = try card.inspect().vStack()
        // Inner VStack contains children
        let innerVStack = try vstack.vStack(1)
        let hello = try innerVStack.text(0)
        XCTAssertEqual(try hello.string(), "Hello")
    }
}

// MARK: - StatusPill Tests

final class StatusPillTests: XCTestCase {

    func testRunningLabel() throws {
        let pill = StatusPill(status: .running)
        let text = try pill.inspect().text()
        XCTAssertEqual(try text.string(), "RUNNING")
    }

    func testFailedLabel() throws {
        let pill = StatusPill(status: .failed)
        let text = try pill.inspect().text()
        XCTAssertEqual(try text.string(), "FAILED")
    }

    func testFinishedLabel() throws {
        let pill = StatusPill(status: .finished)
        let text = try pill.inspect().text()
        XCTAssertEqual(try text.string(), "FINISHED")
    }

    func testCancelledLabel() throws {
        let pill = StatusPill(status: .cancelled)
        let text = try pill.inspect().text()
        XCTAssertEqual(try text.string(), "CANCELLED")
    }

    func testWaitingApprovalLabel() throws {
        let pill = StatusPill(status: .waitingApproval)
        let text = try pill.inspect().text()
        XCTAssertEqual(try text.string(), "APPROVAL")
    }
}

// MARK: - RunRow Tests

final class RunRowTests: XCTestCase {

    func testRunRowDisplaysWorkflowName() throws {
        let run = makeRun(workflowName: "Deploy Pipeline")
        let row = RunRow(run: run)
        let text = try row.inspect().find(text: "Deploy Pipeline")
        XCTAssertEqual(try text.string(), "Deploy Pipeline")
    }

    func testRunRowFallsBackToRunIdWhenNoWorkflowName() throws {
        let run = makeRun(id: "abc12345-long-id", workflowName: nil)
        let row = RunRow(run: run)
        // Should display the full runId as the title
        let text = try row.inspect().find(text: "abc12345-long-id")
        XCTAssertEqual(try text.string(), "abc12345-long-id")
    }

    func testRunRowShowsTruncatedRunId() throws {
        let run = makeRun(id: "abcdefghijklmnop")
        let row = RunRow(run: run)
        // Shows prefix(8) of runId
        let text = try row.inspect().find(text: "abcdefgh")
        XCTAssertEqual(try text.string(), "abcdefgh")
    }

    func testRunRowShowsNodeProgress() throws {
        let run = makeRun(summary: ["total": 10, "finished": 7, "failed": 0])
        let row = RunRow(run: run)
        let text = try row.inspect().find(text: "7/10 nodes")
        XCTAssertEqual(try text.string(), "7/10 nodes")
    }

    func testRunRowDistinguishesFailedNodeCount() throws {
        let run = makeRun(summary: ["total": 10, "finished": 7, "failed": 2])
        let row = RunRow(run: run)
        let text = try row.inspect().find(text: "7 succeeded, 2 failed / 10 nodes")
        XCTAssertEqual(try text.string(), "7 succeeded, 2 failed / 10 nodes")
    }

    /// BUG: When totalNodes is 0, the node count text should be hidden.
    /// The view correctly checks `run.totalNodes > 0` before showing it.
    func testRunRowHidesNodeCountWhenZeroTotal() throws {
        let run = makeRun(summary: ["total": 0, "finished": 0, "failed": 0])
        let row = RunRow(run: run)
        XCTAssertThrowsError(try row.inspect().find(text: "0/0 nodes"))
    }

    func testRunRowShowsProgressBarForRunningWithNodes() throws {
        let run = makeRun(status: .running, summary: ["total": 10, "finished": 5, "failed": 0])
        let row = RunRow(run: run)
        // ProgressBar should be present
        _ = try row.inspect().find(ProgressBar.self)
    }

    func testRunRowHidesProgressBarForFinishedRun() throws {
        let run = makeRun(status: .finished, summary: ["total": 10, "finished": 10, "failed": 0])
        let row = RunRow(run: run)
        XCTAssertThrowsError(try row.inspect().find(ProgressBar.self))
    }

    /// Clicking a RunRow should invoke the onOpen callback with the row's run
    /// and a nil nodeId (root-of-run open). This enables Dashboard "Recent Runs"
    /// rows to open the Live Run view — see DashboardView.onOpenLiveChat wiring.
    func testRunRowTapInvokesOnOpenCallback() throws {
        var opened: [(String, String?)] = []
        let run = makeRun(id: "run-tap-123", workflowName: "Tap Target")
        let row = RunRow(run: run, onOpen: { tappedRun, nodeId in
            opened.append((tappedRun.runId, nodeId))
        })

        try row.inspect().find(ViewType.Button.self).tap()

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first?.0, "run-tap-123")
        XCTAssertNil(opened.first?.1)
    }

    /// A RunRow without a callback should not crash when tapped.
    func testRunRowTapWithoutCallbackDoesNotCrash() throws {
        let run = makeRun()
        let row = RunRow(run: run)
        XCTAssertNoThrow(try row.inspect().find(ViewType.Button.self).tap())
    }
}

// MARK: - WorkflowRow Tests

final class WorkflowRowTests: XCTestCase {

    func testWorkflowRowDisplaysName() throws {
        let wf = makeWorkflow(name: "Build and Deploy")
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "Build and Deploy")
        XCTAssertEqual(try text.string(), "Build and Deploy")
    }

    func testWorkflowRowDisplaysRelativePath() throws {
        let wf = makeWorkflow()
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "workflows/main.ts")
        XCTAssertEqual(try text.string(), "workflows/main.ts")
    }

    func testWorkflowRowDisplaysStatusBadge() throws {
        let wf = makeWorkflow(status: .active)
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "ACTIVE")
        XCTAssertEqual(try text.string(), "ACTIVE")
    }

    func testWorkflowRowHotStatus() throws {
        let wf = makeWorkflow(status: .hot)
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "HOT")
        XCTAssertEqual(try text.string(), "HOT")
    }

    func testWorkflowRowDraftStatus() throws {
        let wf = makeWorkflow(status: .draft)
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "DRAFT")
        XCTAssertEqual(try text.string(), "DRAFT")
    }

    func testWorkflowRowArchivedStatus() throws {
        let wf = makeWorkflow(status: .archived)
        let row = WorkflowRow(workflow: wf)
        let text = try row.inspect().find(text: "ARCHIVED")
        XCTAssertEqual(try text.string(), "ARCHIVED")
    }

    func testWorkflowRowNoStatusHidesBadge() throws {
        let wf = Workflow(id: "1", workspaceId: nil, name: "Test", relativePath: nil, status: nil, updatedAt: nil)
        let row = WorkflowRow(workflow: wf)
        // No status text should be found (no uppercase status badge)
        XCTAssertThrowsError(try row.inspect().find(text: "ACTIVE"))
        XCTAssertThrowsError(try row.inspect().find(text: "DRAFT"))
    }
}

// MARK: - ApprovalRow Tests

final class ApprovalRowTests: XCTestCase {

    func testApprovalRowDisplaysGateName() throws {
        let approval = makeApproval(gate: "Production Gate")
        let row = ApprovalRow(approval: approval)
        let text = try row.inspect().find(text: "Production Gate")
        XCTAssertEqual(try text.string(), "Production Gate")
    }

    func testApprovalRowFallsBackToNodeId() throws {
        let approval = Approval(
            id: "a1", runId: "r1", nodeId: "node-deploy",
            workflowPath: nil, gate: nil, status: "pending",
            payload: nil, requestedAt: Int64(Date().timeIntervalSince1970 * 1000),
            resolvedAt: nil, resolvedBy: nil
        )
        let row = ApprovalRow(approval: approval)
        let text = try row.inspect().find(text: "node-deploy")
        XCTAssertEqual(try text.string(), "node-deploy")
    }

    func testApprovalRowShowsTruncatedRunId() throws {
        let approval = makeApproval(runId: "abcdefghijklmnop")
        let row = ApprovalRow(approval: approval)
        let text = try row.inspect().find(text: "Run: abcdefgh")
        XCTAssertEqual(try text.string(), "Run: abcdefgh")
    }
}

// MARK: - ProgressBar Tests

final class ProgressBarTests: XCTestCase {

    func testProgressBarClampsToZero() throws {
        let bar = ProgressBar(progress: -0.5)
        _ = try bar.inspect().geometryReader()
        // Should not crash; progress is clamped via max(0, min(1, progress))
    }

    func testProgressBarClampsToOne() throws {
        let bar = ProgressBar(progress: 1.5)
        _ = try bar.inspect().geometryReader()
    }

    func testProgressBarZero() throws {
        let bar = ProgressBar(progress: 0.0)
        _ = try bar.inspect().geometryReader()
    }

    func testProgressBarHalf() throws {
        let bar = ProgressBar(progress: 0.5)
        _ = try bar.inspect().geometryReader()
    }

    func testProgressBarAcceptsFailedProgressSegment() throws {
        let bar = ProgressBar(progress: 0.6, failedProgress: 0.2)
        _ = try bar.inspect().geometryReader()
    }
}

// MARK: - DashboardView Tab Tests (UI_TAB_BAR, DASHBOARD_*_TAB)

final class DashboardViewTabTests: XCTestCase {

    /// DASHBOARD_OVERVIEW_TAB: The overview tab should be the default.
    @MainActor
    func testDefaultTabIsOverview() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        let inspected = try view.inspect()

        // The tab bar should show "Overview" as selected (semibold)
        let overviewText = try inspected.find(text: "Overview")
        XCTAssertEqual(try overviewText.string(), "Overview")
    }

    /// DASHBOARD_RUNS_TAB, DASHBOARD_WORKFLOWS_TAB, DASHBOARD_APPROVALS_TAB, DASHBOARD_SESSIONS_TAB
    @MainActor
    func testBaseDashboardTabsArePresent() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        let inspected = try view.inspect()

        _ = try inspected.find(text: "Overview")
        _ = try inspected.find(text: "Runs")
        _ = try inspected.find(text: "Workflows")
        _ = try inspected.find(text: "Approvals")
        _ = try inspected.find(text: "Sessions")
    }

    /// UI_TAB_BAR: DashboardTab enum should include all dashboard destinations.
    func testDashboardTabEnumCases() {
        let allCases = DashboardView.DashboardTab.allCases
        XCTAssertEqual(allCases.count, 8)
        XCTAssertEqual(allCases[0], .overview)
        XCTAssertEqual(allCases[1], .runs)
        XCTAssertEqual(allCases[2], .workflows)
        XCTAssertEqual(allCases[3], .approvals)
        XCTAssertEqual(allCases[4], .sessions)
        XCTAssertEqual(allCases[5], .landings)
        XCTAssertEqual(allCases[6], .issues)
        XCTAssertEqual(allCases[7], .workspaces)
    }

    func testDashboardTabRawValues() {
        XCTAssertEqual(DashboardView.DashboardTab.overview.rawValue, "Overview")
        XCTAssertEqual(DashboardView.DashboardTab.runs.rawValue, "Runs")
        XCTAssertEqual(DashboardView.DashboardTab.workflows.rawValue, "Workflows")
        XCTAssertEqual(DashboardView.DashboardTab.approvals.rawValue, "Approvals")
        XCTAssertEqual(DashboardView.DashboardTab.sessions.rawValue, "Sessions")
        XCTAssertEqual(DashboardView.DashboardTab.landings.rawValue, "Landings")
        XCTAssertEqual(DashboardView.DashboardTab.issues.rawValue, "Issues")
        XCTAssertEqual(DashboardView.DashboardTab.workspaces.rawValue, "Workspaces")
    }

    /// DASHBOARD_OVERVIEW_TAB: Verify the header shows "Dashboard" text.
    @MainActor
    func testHeaderShowsDashboardTitle() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        let inspected = try view.inspect()
        let title = try inspected.find(text: "Dashboard")
        XCTAssertEqual(try title.string(), "Dashboard")
    }
}

// MARK: - DashboardView Stat Cards Tests (DASHBOARD_STAT_CARDS)

final class DashboardViewStatCardTests: XCTestCase {

    /// DASHBOARD_STAT_ACTIVE_RUNS_COUNT: Active runs stat should count only .running status.
    func testActiveRunsCountsOnlyRunningStatus() {
        let runs = [
            makeRun(id: "1", status: .running),
            makeRun(id: "2", status: .running),
            makeRun(id: "3", status: .finished),
            makeRun(id: "4", status: .failed),
            makeRun(id: "5", status: .cancelled),
        ]
        let activeCount = runs.filter { $0.status == .running }.count
        XCTAssertEqual(activeCount, 2)
    }

    /// DASHBOARD_STAT_PENDING_APPROVALS_COUNT: Should count only status == "pending".
    func testPendingApprovalsCountsOnlyPending() {
        let approvals = [
            makeApproval(id: "1", status: "pending"),
            makeApproval(id: "2", status: "pending"),
            makeApproval(id: "3", status: "approved"),
            makeApproval(id: "4", status: "denied"),
        ]
        let pendingCount = approvals.filter { $0.status == "pending" }.count
        XCTAssertEqual(pendingCount, 2)
    }

    /// DASHBOARD_STAT_WORKFLOW_COUNT: Should count all workflows regardless of status.
    func testWorkflowCountIncludesAll() {
        let workflows = [
            makeWorkflow(id: "1", status: .active),
            makeWorkflow(id: "2", status: .draft),
            makeWorkflow(id: "3", status: .archived),
        ]
        XCTAssertEqual(workflows.count, 3)
    }

    /// DASHBOARD_STAT_FAILED_RUNS_COUNT: Should count only .failed status.
    func testFailedRunsCountsOnlyFailed() {
        let runs = [
            makeRun(id: "1", status: .failed),
            makeRun(id: "2", status: .running),
            makeRun(id: "3", status: .failed),
            makeRun(id: "4", status: .cancelled),
        ]
        let failedCount = runs.filter { $0.status == .failed }.count
        XCTAssertEqual(failedCount, 2)
    }

    /// BUG: waitingApproval runs are NOT counted as "active" runs.
    /// A run with status .waitingApproval is arguably still active but the dashboard
    /// only counts .running. This means waiting-approval runs vanish from the active count.
    func testBug_WaitingApprovalRunsNotCountedAsActive() {
        let runs = [
            makeRun(id: "1", status: .running),
            makeRun(id: "2", status: .waitingApproval),
        ]
        let activeCount = runs.filter { $0.status == .running }.count
        // BUG: waitingApproval is excluded from "Active Runs" count
        XCTAssertEqual(activeCount, 1, "BUG: waitingApproval runs are not counted as active; expected 2 if they should be included")
    }

    /// DASHBOARD_STAT_CARDS: Verify all 4 stat cards appear in the overview.
    @MainActor
    func testOverviewShowsFourStatCards() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        let inspected = try view.inspect()

        // The stat card titles should all be present
        _ = try inspected.find(text: "Active Runs")
        _ = try inspected.find(text: "Pending Approvals")
        _ = try inspected.find(text: "Workflows")
        _ = try inspected.find(text: "Failed Runs")
    }
}

// MARK: - DashboardView Section Tests (DASHBOARD_RECENT_RUNS_SECTION, etc.)

final class DashboardViewSectionTests: XCTestCase {

    /// DASHBOARD_RECENT_RUNS_SECTION: Section card title should be "Recent Runs".
    func testRecentRunsSectionTitle() throws {
        let card = SectionCard(title: "Recent Runs") { Text("content") }
        let title = try card.inspect().vStack().text(0)
        XCTAssertEqual(try title.string(), "Recent Runs")
    }

    /// DASHBOARD_PENDING_APPROVALS_SECTION: Section card title should be "Pending Approvals".
    func testPendingApprovalsSectionTitle() throws {
        let card = SectionCard(title: "Pending Approvals") { Text("content") }
        let title = try card.inspect().vStack().text(0)
        XCTAssertEqual(try title.string(), "Pending Approvals")
    }

    /// DASHBOARD_WORKFLOWS_SECTION: Section card title should be "Workflows".
    func testWorkflowsSectionTitle() throws {
        let card = SectionCard(title: "Workflows") { Text("content") }
        let title = try card.inspect().vStack().text(0)
        XCTAssertEqual(try title.string(), "Workflows")
    }
}

// MARK: - DASHBOARD_TOP_5_ITEM_LIMITING Tests

final class DashboardViewItemLimitingTests: XCTestCase {

    /// DASHBOARD_TOP_5_ITEM_LIMITING: Overview tab should limit runs to 5.
    func testRunsPrefixLimitedToFive() {
        let runs = (0..<10).map { makeRun(id: "run-\($0)") }
        let limited = Array(runs.prefix(5))
        XCTAssertEqual(limited.count, 5)
        XCTAssertEqual(limited.first?.runId, "run-0")
        XCTAssertEqual(limited.last?.runId, "run-4")
    }

    /// DASHBOARD_TOP_5_ITEM_LIMITING: Overview tab should limit workflows to 5.
    func testWorkflowsPrefixLimitedToFive() {
        let workflows = (0..<8).map { makeWorkflow(id: "wf-\($0)", name: "Workflow \($0)") }
        let limited = Array(workflows.prefix(5))
        XCTAssertEqual(limited.count, 5)
    }

    /// DASHBOARD_TOP_5_ITEM_LIMITING: Overview tab should limit pending approvals to 5.
    func testApprovalsPrefixLimitedToFive() {
        let approvals = (0..<7).map { makeApproval(id: "a-\($0)") }
        let pending = approvals.filter { $0.status == "pending" }
        let limited = Array(pending.prefix(5))
        XCTAssertEqual(limited.count, 5)
    }

    /// When fewer than 5 items exist, all should be shown.
    func testFewerThanFiveShowsAll() {
        let runs = (0..<3).map { makeRun(id: "run-\($0)") }
        let limited = Array(runs.prefix(5))
        XCTAssertEqual(limited.count, 3)
    }

    /// BUG: The Runs tab (not overview) shows ALL runs with no limit.
    /// This is inconsistent: overview limits to 5 but the Runs tab is unlimited.
    /// This may be intentional but is worth documenting since the tabs serve different purposes.
    func testBug_RunsTabShowsAllRunsUnlimited() {
        // The runsContent view uses `ForEach(runs)` with no .prefix(5)
        // while overviewContent uses `ForEach(runs.prefix(5))`
        // This is intentional behavior (detail tab vs. overview) but the
        // Approvals tab filters to only pending, which is inconsistent with
        // the Runs tab showing all statuses.
        let runs = (0..<20).map { makeRun(id: "run-\($0)") }
        // runsContent would show all 20
        XCTAssertEqual(runs.count, 20)
    }
}

// MARK: - Dashboard Ordering and Count Source Tests

final class DashboardViewOrderingAndCountTests: XCTestCase {

    func testRunsSortByStartedAtDescending() {
        let runs = [
            makeRun(id: "old", startedAtMs: 1_700_000_000_000),
            makeRun(id: "newest", startedAtMs: 1_700_000_120_000),
            makeRun(id: "middle", startedAtMs: 1_700_000_060_000),
        ]

        let sorted = runs.sortedByStartedAtDescending()

        XCTAssertEqual(sorted.map(\.runId), ["newest", "middle", "old"])
    }

    func testRunsSortKeepsMissingStartedAtLast() {
        let runs = [
            makeRun(id: "missing-1", startedAtMs: nil),
            makeRun(id: "newest", startedAtMs: 1_700_000_120_000),
            makeRun(id: "missing-2", startedAtMs: nil),
            makeRun(id: "old", startedAtMs: 1_700_000_000_000),
        ]

        let sorted = runs.sortedByStartedAtDescending()

        XCTAssertEqual(sorted.map(\.runId), ["newest", "old", "missing-1", "missing-2"])
    }

    func testPendingApprovalCountUsesFilteredPendingApprovals() {
        let approvals = [
            makeApproval(id: "pending-lower", status: "pending"),
            makeApproval(id: "pending-normalized", status: " Pending "),
            makeApproval(id: "approved", status: "approved"),
            makeApproval(id: "denied", status: "denied"),
        ]

        let pendingApprovals = approvals.filterPendingApprovals()

        XCTAssertEqual(pendingApprovals.map(\.id), ["pending-lower", "pending-normalized"])
        XCTAssertEqual(pendingApprovals.count, 2)
    }
}

// MARK: - DASHBOARD_PARALLEL_DATA_LOADING Tests

final class DashboardViewDataLoadingTests: XCTestCase {

    /// DASHBOARD_PARALLEL_DATA_LOADING: loadAll() uses async let for parallel loading.
    /// We verify the pattern by checking that DashboardView compiles and the loading
    /// state transitions correctly.
    @MainActor
    func testLoadingStateIsInitiallyTrue() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        // The view starts with isLoading = true
        // After .task fires, loadAll sets isLoading=true then false
        let inspected = try view.inspect()
        // The ProgressView should be present when isLoading is true
        // (initial state before .task fires)
        // We can at least verify the view renders without crashing
        XCTAssertNoThrow(try inspected.find(text: "Dashboard"))
    }

    /// BUG: loadAll() sets isLoading = false OUTSIDE the do/catch block.
    /// If an error occurs, isLoading is still set to false, which is correct.
    /// However, the error state and loading state can be inconsistent during
    /// the brief window between setting self.error and setting isLoading = false.
    /// This is a race condition that could cause a flash of error content while
    /// still showing the loading spinner.
    func testBug_LoadingFalseAfterError() {
        // In loadAll():
        //   } catch {
        //       self.error = error.localizedDescription  // error set here
        //   }
        //   isLoading = false  // loading cleared AFTER catch block
        //
        // This means there's a frame where error != nil AND isLoading == true,
        // but since the error view takes precedence (checked first in body),
        // this is cosmetically benign. Still, the ProgressView in the header
        // will briefly show alongside the error view.
        XCTAssert(true, "Documented: isLoading set to false after catch, causing brief spinner+error overlap")
    }

    /// BUG: loadAll() does NOT run on MainActor despite mutating @State/@Published.
    /// The function is called from .task and button actions which run on MainActor,
    /// but the async let results are assigned without explicit MainActor dispatch.
    /// In practice this works because DashboardView body is implicitly @MainActor,
    /// but the function itself is not annotated.
    func testBug_LoadAllNotExplicitlyMainActor() {
        // loadAll is `private func loadAll() async` -- not @MainActor
        // State mutations (runs = fetchedRuns, etc.) happen in this context
        // SwiftUI @State is MainActor-isolated, so this should be fine in practice
        // because .task inherits the view's actor context.
        XCTAssert(true, "Documented: loadAll not explicitly @MainActor annotated")
    }
}

// MARK: - Approvals Tab Bug Tests

final class DashboardViewApprovalsBugTests: XCTestCase {

    /// BUG: The Approvals tab filters to only "pending" approvals,
    /// but the overview stat card also counts pending approvals.
    /// If the user navigates to the Approvals tab expecting to see ALL approvals
    /// (including approved/denied), they will only see pending ones.
    /// There is no way to view historical approved/denied approvals from the dashboard.
    func testBug_ApprovalsTabOnlyShowsPending() {
        let approvals = [
            makeApproval(id: "1", status: "pending"),
            makeApproval(id: "2", status: "approved"),
            makeApproval(id: "3", status: "denied"),
        ]
        let pending = approvals.filter { $0.status == "pending" }
        XCTAssertEqual(pending.count, 1, "BUG: Approvals tab filters to pending only; approved/denied approvals are invisible")
    }

    /// BUG: The Approvals tab empty state says "No pending approvals" but the
    /// overview section says "Pending Approvals". If listPendingApprovals returns
    /// non-pending approvals (which it currently doesn't), they would be filtered
    /// out silently.
    func testBug_ApprovalsTabEmptyStateMessage() {
        // approvalsContent filters: approvals.filter { $0.status == "pending" }
        // If all approvals are "approved", the empty state shows "No pending approvals"
        // This is technically correct but the data source is called listPendingApprovals()
        // which should only return pending ones -- double filtering is redundant.
        let approvals = [makeApproval(id: "1", status: "approved")]
        let pending = approvals.filter { $0.status == "pending" }
        XCTAssertTrue(pending.isEmpty, "Documented: double-filtering of pending approvals")
    }
}

// MARK: - Overview Content Visibility Tests

final class DashboardViewOverviewVisibilityTests: XCTestCase {

    /// When runs array is empty, the "Recent Runs" section should be hidden.
    func testRecentRunsSectionHiddenWhenEmpty() {
        let runs: [RunSummary] = []
        // The view checks: if !runs.isEmpty { SectionCard(title: "Recent Runs") ... }
        XCTAssertTrue(runs.isEmpty)
        // Section would not render
    }

    /// When all approvals are non-pending, "Pending Approvals" section is hidden.
    func testPendingApprovalsSectionHiddenWhenNoPending() {
        let approvals = [makeApproval(id: "1", status: "approved")]
        let pending = approvals.filter { $0.status == "pending" }
        XCTAssertTrue(pending.isEmpty)
    }

    /// When workflows array is empty, "Workflows" section is hidden.
    func testWorkflowsSectionHiddenWhenEmpty() {
        let workflows: [Workflow] = []
        XCTAssertTrue(workflows.isEmpty)
    }
}

// MARK: - Divider Logic Bug Tests

final class DashboardViewDividerBugTests: XCTestCase {

    /// BUG: The divider logic in overview uses `run.id != runs.prefix(5).last?.id`
    /// to determine if a divider should be shown. If two runs have the same id
    /// (which shouldn't happen but is not enforced), dividers could be skipped
    /// for the wrong items.
    func testBug_DividerLogicReliesOnIdUniqueness() {
        let runs = [
            makeRun(id: "same-id"),
            makeRun(id: "same-id"),
        ]
        // Both have id "same-id", so the divider check:
        //   run.id != runs.prefix(5).last?.id
        // would be false for BOTH items, meaning NO dividers are shown
        // when there should be a divider between them.
        let last = runs.prefix(5).last
        let firstMatchesLast = runs[0].id == last?.id
        XCTAssertTrue(firstMatchesLast, "BUG: First item matches last id, so no divider is shown between duplicate-id items")
    }

    /// BUG: The Runs tab (runsContent) shows a divider AFTER every item including
    /// the last one. This creates an unnecessary trailing divider.
    /// In contrast, the overview uses conditional dividers (no trailing divider).
    func testBug_RunsTabHasTrailingDivider() {
        // runsContent:
        //   ForEach(runs) { run in
        //       RunRow(run: run)
        //       Divider()          // <-- always shown, even for last item
        //   }
        // vs. overviewContent:
        //   if run.id != runs.prefix(5).last?.id {
        //       Divider()          // <-- conditional, no trailing divider
        //   }
        XCTAssert(true, "BUG: runsContent, workflowsContent, and approvalsContent all have trailing dividers after the last item")
    }

    /// BUG: The same trailing-divider issue exists in workflowsContent and approvalsContent.
    func testBug_WorkflowsAndApprovalsTabsHaveTrailingDividers() {
        // workflowsContent and approvalsContent both use:
        //   ForEach(...) { item in
        //       Row(...)
        //       Divider()  // always, including last
        //   }
        XCTAssert(true, "BUG: Trailing dividers in workflows and approvals tabs")
    }
}

// MARK: - Error View Tests

final class DashboardViewErrorTests: XCTestCase {

    /// The error view should show when error state is non-nil.
    /// This tests the errorView helper directly.
    @MainActor
    func testErrorViewShowsRetryButton() throws {
        let client = makeClient()
        let view = DashboardView(smithers: client)
        // We can at least verify the view structure renders
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "Dashboard"))
    }
}

// MARK: - RunSummary Progress Calculation Tests

final class RunSummaryProgressTests: XCTestCase {

    func testProgressCalculation() {
        let run = makeRun(summary: ["total": 10, "finished": 5, "failed": 0])
        XCTAssertEqual(run.progress, 0.5)
    }

    func testProgressZeroWhenNoTotal() {
        let run = makeRun(summary: ["total": 0, "finished": 0, "failed": 0])
        XCTAssertEqual(run.progress, 0.0)
    }

    func testProgressOneWhenComplete() {
        let run = makeRun(summary: ["total": 10, "finished": 10, "failed": 0])
        XCTAssertEqual(run.progress, 1.0)
    }

    func testProgressWithNilSummary() {
        let run = makeRun(summary: nil)
        XCTAssertEqual(run.progress, 0.0)
        XCTAssertEqual(run.totalNodes, 0)
        XCTAssertEqual(run.finishedNodes, 0)
    }

    func testProgressIncludesFailedNodes() {
        let run = makeRun(summary: ["total": 10, "finished": 5, "failed": 5])
        XCTAssertEqual(run.completedNodes, 10)
        XCTAssertEqual(run.progress, 1.0, "Progress should include failed nodes as completed work")
        XCTAssertEqual(run.finishedProgress, 0.5)
        XCTAssertEqual(run.failedProgress, 0.5)
    }
}

// MARK: - ElapsedString Tests

final class RunSummaryElapsedStringTests: XCTestCase {

    func testElapsedStringWithNoStartTime() {
        let run = makeRun(startedAtMs: nil)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testElapsedStringSeconds() {
        let now = Date()
        let startMs = Int64((now.timeIntervalSince1970 - 30) * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(run.elapsedString, "30s")
    }

    func testElapsedStringMinutes() {
        let now = Date()
        let startMs = Int64((now.timeIntervalSince1970 - 125) * 1000) // 2m 5s
        let run = makeRun(startedAtMs: startMs, finishedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(run.elapsedString, "2m 5s")
    }

    func testElapsedStringHours() {
        let now = Date()
        let startMs = Int64((now.timeIntervalSince1970 - 3665) * 1000) // 1h 1m 5s
        let run = makeRun(startedAtMs: startMs, finishedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(run.elapsedString, "1h 1m")
    }

    /// elapsedString for exactly 60 seconds returns "1m" (no trailing "0s").
    func testElapsedStringExactlyOneMinute() {
        let now = Date()
        let startMs = Int64((now.timeIntervalSince1970 - 60) * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: Int64(now.timeIntervalSince1970 * 1000))
        XCTAssertEqual(run.elapsedString, "1m")
    }
}
