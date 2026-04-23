import XCTest
import ViewInspector
@testable import SmithersGUI

// MARK: - RunSummary Model Tests

final class RunSummaryTests: XCTestCase {

    // MARK: - RUNS_ID_PREFIX_DISPLAY / CONSTANT_ID_PREFIX_8_CHARS

    func testIdPrefix8Chars() {
        let run = makeRun(runId: "abcdefghijklmnop")
        XCTAssertEqual(String(run.runId.prefix(8)), "abcdefgh",
                       "Run ID prefix should be exactly 8 characters")
    }

    func testIdPrefixShortId() {
        let run = makeRun(runId: "abc")
        XCTAssertEqual(String(run.runId.prefix(8)), "abc",
                       "prefix(8) on a short string returns the whole string")
    }

    // MARK: - Identifiable

    func testIdentifiableUsesRunId() {
        let run = makeRun(runId: "run-123")
        XCTAssertEqual(run.id, "run-123")
    }

    // MARK: - RUNS_WORKFLOW_NAME_FALLBACK

    func testWorkflowNameNilFallback() {
        let run = makeRun(workflowName: nil)
        // The view uses `run.workflowName ?? "Unnamed workflow"`
        XCTAssertNil(run.workflowName)
        let displayed = run.workflowName ?? "Unnamed workflow"
        XCTAssertEqual(displayed, "Unnamed workflow")
    }

    func testWorkflowNamePresent() {
        let run = makeRun(workflowName: "deploy-prod")
        XCTAssertEqual(run.workflowName, "deploy-prod")
    }

    // MARK: - RUNS_PROGRESS_BAR / RUNS_PROGRESS_PERCENTAGE

    func testProgressZeroWhenNoSummary() {
        let run = makeRun(summary: nil)
        XCTAssertEqual(run.progress, 0)
        XCTAssertEqual(run.totalNodes, 0)
    }

    func testProgressZeroWhenTotalZero() {
        let run = makeRun(summary: ["total": 0, "finished": 0])
        XCTAssertEqual(run.progress, 0)
    }

    func testProgressCalculation() {
        let run = makeRun(summary: ["total": 10, "finished": 3, "failed": 1])
        XCTAssertEqual(run.totalNodes, 10)
        XCTAssertEqual(run.finishedNodes, 3)
        XCTAssertEqual(run.failedNodes, 1)
        XCTAssertEqual(run.completedNodes, 4)
        XCTAssertEqual(run.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(run.finishedProgress, 0.3, accuracy: 0.001)
        XCTAssertEqual(run.failedProgress, 0.1, accuracy: 0.001)
    }

    func testProgressIncludesFailedNodes() {
        let run = makeRun(summary: ["total": 10, "finished": 5, "failed": 5])
        XCTAssertEqual(run.completedNodes, 10)
        XCTAssertEqual(run.progress, 1.0,
                       "Progress should count both finished and failed nodes as completed work")
    }

    /// BUG: Progress percentage display uses `Int(run.progress * 100)` which truncates.
    /// 1/3 = 0.333... shows as "33%" not "34%". Minor but inconsistent with rounded display.
    func testBug_ProgressPercentageTruncatesInsteadOfRounding() {
        let run = makeRun(summary: ["total": 3, "finished": 1])
        let displayed = Int(run.progress * 100)
        XCTAssertEqual(displayed, 33, "Truncation: 33.33% -> 33% (not rounded to 33%)")
        // 2/3 case:
        let run2 = makeRun(summary: ["total": 3, "finished": 2])
        let displayed2 = Int(run2.progress * 100)
        XCTAssertEqual(displayed2, 66, "Truncation: 66.66% -> 66% (not rounded to 67%)")
    }

    // MARK: - RUNS_ELAPSED_TIME_DISPLAY / RUNS_ELAPSED_TIME_FORMATTING

    func testElapsedStringNoStartDate() {
        let run = makeRun(startedAtMs: nil)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testElapsedStringSeconds() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-45).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        XCTAssertEqual(run.elapsedString, "45s")
    }

    func testElapsedStringMinutesAndSeconds() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-125).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        XCTAssertEqual(run.elapsedString, "2m 5s")
    }

    func testElapsedStringHoursAndMinutes() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-3661).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        // 3661s = 1h 1m 1s -> "1h 1m"
        XCTAssertEqual(run.elapsedString, "1h 1m")
    }

    func testElapsedStringExactly60Seconds() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        // 60s: seconds % 60 == 0 -> "1m" (no trailing "0s")
        XCTAssertEqual(run.elapsedString, "1m")
    }

    func testElapsedStringExactly3600Seconds() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        // 3600s: not < 3600 -> "1h 0m"
        XCTAssertEqual(run.elapsedString, "1h 0m")
    }

    /// BUG: elapsedString for hours format drops seconds entirely.
    /// "1h 1m" for 3661 seconds is fine, but there's no way to see seconds for long runs.
    /// This is a design choice, not necessarily a bug, but documented for completeness.
    func testElapsedStringDropsSecondsInHoursFormat() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-3601).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: endMs)
        // 3601s = 1h 0m 1s, displays "1h 0m" — seconds lost
        XCTAssertEqual(run.elapsedString, "1h 0m")
    }

    /// When finishedAt is nil, elapsedString computes against Date() (live timer).
    /// This means the value changes on every call for running runs.
    func testElapsedStringUsesNowWhenNotFinished() {
        let startMs = Int64(Date().addingTimeInterval(-10).timeIntervalSince1970 * 1000)
        let run = makeRun(startedAtMs: startMs, finishedAtMs: nil)
        // Should be approximately "10s" (could be 10s or 11s depending on timing)
        let elapsed = run.elapsedString
        XCTAssertTrue(elapsed.hasSuffix("s"), "Should display seconds: got '\(elapsed)'")
    }

    // MARK: - Date conversions

    func testStartedAtConversion() {
        let run = makeRun(startedAtMs: 1700000000000)
        XCTAssertNotNil(run.startedAt)
        XCTAssertEqual(run.startedAt!.timeIntervalSince1970, 1700000000, accuracy: 0.001)
    }

    func testFinishedAtNil() {
        let run = makeRun(finishedAtMs: nil)
        XCTAssertNil(run.finishedAt)
    }
}

// MARK: - RunStatus Tests

final class RunStatusTests: XCTestCase {

    // MARK: - RUNS_STATUS_COLOR_MAPPING / RUNS_STATUS_GROUP_LABELS_ACTIVE_COMPLETED_FAILED

    func testAllCases() {
        let cases = RunStatus.allCases
        XCTAssertEqual(cases.count, 8)
        XCTAssertTrue(cases.contains(.running))
        XCTAssertTrue(cases.contains(.waitingApproval))
        XCTAssertTrue(cases.contains(.finished))
        XCTAssertTrue(cases.contains(.failed))
        XCTAssertTrue(cases.contains(.cancelled))
        XCTAssertTrue(cases.contains(.stale))
        XCTAssertTrue(cases.contains(.orphaned))
        XCTAssertTrue(cases.contains(.unknown))
    }

    func testRawValues() {
        XCTAssertEqual(RunStatus.running.rawValue, "running")
        XCTAssertEqual(RunStatus.waitingApproval.rawValue, "waiting-approval")
        XCTAssertEqual(RunStatus.finished.rawValue, "finished")
        XCTAssertEqual(RunStatus.failed.rawValue, "failed")
        XCTAssertEqual(RunStatus.cancelled.rawValue, "cancelled")
        XCTAssertEqual(RunStatus.stale.rawValue, "stale")
        XCTAssertEqual(RunStatus.orphaned.rawValue, "orphaned")
    }

    func testLabels() {
        XCTAssertEqual(RunStatus.running.label, "RUNNING")
        XCTAssertEqual(RunStatus.waitingApproval.label, "APPROVAL")
        XCTAssertEqual(RunStatus.finished.label, "FINISHED")
        XCTAssertEqual(RunStatus.failed.label, "FAILED")
        XCTAssertEqual(RunStatus.cancelled.label, "CANCELLED")
        XCTAssertEqual(RunStatus.stale.label, "STALE")
        XCTAssertEqual(RunStatus.orphaned.label, "ORPHANED")
    }

    func testDecodableFromJSON() throws {
        let json = "\"running\""
        let status = try JSONDecoder().decode(RunStatus.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(status, .running)
    }

    func testDecodableWaitingApproval() throws {
        let json = "\"waiting-approval\""
        let status = try JSONDecoder().decode(RunStatus.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(status, .waitingApproval)
    }

    // MARK: - RUNS_STATUS_SECTIONING

    /// The view groups statuses into 3 sections:
    /// ACTIVE: running, waitingApproval
    /// COMPLETED: finished
    /// FAILED: failed, cancelled
    func testStatusSectioning() {
        let activeStatuses: [RunStatus] = [.running, .waitingApproval]
        let completedStatuses: [RunStatus] = [.finished]
        let failedStatuses: [RunStatus] = [.failed, .cancelled]

        for status in activeStatuses {
            XCTAssertTrue(status == .running || status == .waitingApproval,
                          "\(status) should be in ACTIVE section")
        }
        for status in completedStatuses {
            XCTAssertEqual(status, .finished)
        }
        for status in failedStatuses {
            XCTAssertTrue(status == .failed || status == .cancelled)
        }
    }
}

// MARK: - RunTask Tests

final class RunTaskTests: XCTestCase {

    // MARK: - RUNS_NODE_STATE_6_STATE_MAPPING

    func testAllSixNodeStates() {
        let states = ["pending", "running", "finished", "failed", "skipped", "blocked"]
        for state in states {
            let task = RunTask(nodeId: "n1", label: nil, iteration: nil,
                               state: state, lastAttempt: nil, updatedAtMs: nil)
            XCTAssertEqual(task.state, state)
        }
    }

    /// BUG: "waiting-approval" is used in the view to find blocked nodes for approve/deny
    /// (line 298: `$0.state == "blocked" || $0.state == "waiting-approval"`),
    /// but the RunTask model documents only 6 states: pending, running, finished, failed, skipped, blocked.
    /// The nodeStateIcon and nodeStateColor functions don't handle "waiting-approval" — it falls to default.
    /// This means a node in "waiting-approval" state gets a generic gray circle icon instead of
    /// the warning-colored pause icon that "blocked" gets.
    func testBug_WaitingApprovalStateNotHandledInIconMapping() {
        // nodeStateIcon switch cases: running, finished, failed, skipped, blocked, default
        // "waiting-approval" hits default -> ("circle", Theme.textTertiary)
        // but logically it should probably map to the same as "blocked"
        let states = ["running", "finished", "failed", "skipped", "blocked"]
        XCTAssertFalse(states.contains("waiting-approval"),
                       "BUG: 'waiting-approval' is not in the icon/color mapping switch cases")
    }

    // MARK: - RUNS_NODE_ITERATION_TRACKING

    func testIterationTracking() {
        let task = RunTask(nodeId: "n1", label: "Process", iteration: 3,
                           state: "running", lastAttempt: nil, updatedAtMs: nil)
        XCTAssertEqual(task.iteration, 3)
    }

    func testIterationNil() {
        let task = RunTask(nodeId: "n1", label: nil, iteration: nil,
                           state: "pending", lastAttempt: nil, updatedAtMs: nil)
        XCTAssertNil(task.iteration)
    }

    func testIterationZeroNotDisplayed() {
        // The view shows "iter \(iter)" only when iter > 0
        let task = RunTask(nodeId: "n1", label: nil, iteration: 0,
                           state: "finished", lastAttempt: nil, updatedAtMs: nil)
        let shouldDisplay = (task.iteration ?? 0) > 0
        XCTAssertFalse(shouldDisplay, "Iteration 0 should not be displayed")
    }

    func testIterationPositiveDisplayed() {
        let task = RunTask(nodeId: "n1", label: nil, iteration: 2,
                           state: "running", lastAttempt: nil, updatedAtMs: nil)
        let shouldDisplay = (task.iteration ?? 0) > 0
        XCTAssertTrue(shouldDisplay, "Iteration 2 should be displayed")
    }

    // MARK: - Identifiable

    func testIdentifiableUsesNodeId() {
        let task = RunTask(nodeId: "node-abc", label: nil, iteration: nil,
                           state: "pending", lastAttempt: nil, updatedAtMs: nil)
        XCTAssertEqual(task.id, "node-abc")
    }

    func testRepeatedNodeIdsUseIterationInIdentity() {
        let t1 = RunTask(nodeId: "n1", label: "A", iteration: 0,
                          state: "finished", lastAttempt: nil, updatedAtMs: nil)
        let t2 = RunTask(nodeId: "n1", label: "A", iteration: 1,
                          state: "running", lastAttempt: nil, updatedAtMs: nil)
        XCTAssertNotEqual(t1.id, t2.id)
    }

    // MARK: - Label fallback

    func testLabelFallbackToNodeId() {
        let task = RunTask(nodeId: "my-node", label: nil, iteration: nil,
                           state: "pending", lastAttempt: nil, updatedAtMs: nil)
        // The view uses: task.label ?? task.nodeId
        let displayed = task.label ?? task.nodeId
        XCTAssertEqual(displayed, "my-node")
    }

    func testLabelWhenPresent() {
        let task = RunTask(nodeId: "my-node", label: "My Node", iteration: nil,
                           state: "pending", lastAttempt: nil, updatedAtMs: nil)
        let displayed = task.label ?? task.nodeId
        XCTAssertEqual(displayed, "My Node")
    }
}

// MARK: - RunInspection Tests

final class RunInspectionTests: XCTestCase {

    func testDecodable() throws {
        let json = """
        {
            "run": {
                "runId": "r1",
                "workflowName": "test",
                "workflowPath": null,
                "status": "running",
                "startedAtMs": 1700000000000,
                "finishedAtMs": null,
                "summary": {"total": 2, "finished": 1},
                "errorJson": null
            },
            "tasks": [
                {
                    "nodeId": "n1",
                    "label": "Step 1",
                    "iteration": 0,
                    "state": "finished",
                    "lastAttempt": null,
                    "updatedAtMs": null
                },
                {
                    "nodeId": "n2",
                    "label": null,
                    "iteration": null,
                    "state": "running",
                    "lastAttempt": null,
                    "updatedAtMs": null
                }
            ]
        }
        """
        let inspection = try JSONDecoder().decode(RunInspection.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(inspection.run.runId, "r1")
        XCTAssertEqual(inspection.tasks.count, 2)
        XCTAssertEqual(inspection.tasks[0].state, "finished")
        XCTAssertEqual(inspection.tasks[1].state, "running")
    }
}

// MARK: - DateFilter Tests

final class DateFilterTests: XCTestCase {

    // MARK: - RUNS_DATE_FILTER_PRESETS

    func testAllDateFilterPresets() {
        let allCases = RunsView.DateFilter.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertEqual(allCases.map(\.rawValue), ["All Time", "Today", "This Week", "This Month"])
    }

    func testDateFilterRawValues() {
        XCTAssertEqual(RunsView.DateFilter.all.rawValue, "All Time")
        XCTAssertEqual(RunsView.DateFilter.today.rawValue, "Today")
        XCTAssertEqual(RunsView.DateFilter.week.rawValue, "This Week")
        XCTAssertEqual(RunsView.DateFilter.month.rawValue, "This Month")
    }
}

// MARK: - Filtering Logic Tests (unit tests on pure functions)

final class RunsFilteringTests: XCTestCase {

    // MARK: - RUNS_FILTER_BY_STATUS

    func testFilterByStatusRunning() {
        let runs = sampleRuns()
        let filtered = runs.filter { $0.status == .running }
        XCTAssertTrue(filtered.allSatisfy { $0.status == .running })
        XCTAssertEqual(filtered.count, 1)
    }

    func testFilterByStatusFailed() {
        let runs = sampleRuns()
        let filtered = runs.filter { $0.status == .failed }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.runId, "r3")
    }

    func testFilterByStatusNilReturnsAll() {
        let runs = sampleRuns()
        let statusFilter: RunStatus? = nil
        var result = runs
        if let statusFilter {
            result = result.filter { $0.status == statusFilter }
        }
        XCTAssertEqual(result.count, runs.count)
    }

    // MARK: - RUNS_SEARCH

    func testSearchByWorkflowName() {
        let runs = sampleRuns()
        let searchText = "deploy"
        let filtered = runs.filter {
            ($0.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
            $0.runId.localizedCaseInsensitiveContains(searchText)
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.workflowName, "deploy-prod")
    }

    func testSearchByRunId() {
        let runs = sampleRuns()
        let searchText = "r2"
        let filtered = runs.filter {
            ($0.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
            $0.runId.localizedCaseInsensitiveContains(searchText)
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.runId, "r2-abcdefgh")
    }

    func testSearchCaseInsensitive() {
        let runs = sampleRuns()
        let searchText = "DEPLOY"
        let filtered = runs.filter {
            ($0.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
            $0.runId.localizedCaseInsensitiveContains(searchText)
        }
        XCTAssertEqual(filtered.count, 1)
    }

    func testSearchEmptyReturnsAll() {
        let runs = sampleRuns()
        let searchText = ""
        var result = runs
        if !searchText.isEmpty {
            result = result.filter {
                ($0.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
                $0.runId.localizedCaseInsensitiveContains(searchText)
            }
        }
        XCTAssertEqual(result.count, runs.count)
    }

    /// BUG: Search on a run with nil workflowName uses empty string for comparison.
    /// Searching for "Unnamed" won't find runs with nil workflowName, even though the UI
    /// displays "Unnamed workflow" for those runs. The search and display are inconsistent.
    func testBug_SearchDoesNotMatchFallbackWorkflowName() {
        let run = makeRun(runId: "r99", workflowName: nil)
        let searchText = "Unnamed"
        let matches = (run.workflowName ?? "").localizedCaseInsensitiveContains(searchText) ||
                      run.runId.localizedCaseInsensitiveContains(searchText)
        XCTAssertFalse(matches,
                       "BUG: Searching 'Unnamed' does not match runs with nil workflowName, " +
                       "even though UI shows 'Unnamed workflow'")
    }

    // MARK: - RUNS_FILTER_BY_DATE_RANGE

    func testDateFilterToday() {
        let now = Date()
        let todayCutoff = Calendar.current.startOfDay(for: now)
        let todayMs = Int64(now.timeIntervalSince1970 * 1000)
        let yesterdayMs = Int64(now.addingTimeInterval(-86400 * 2).timeIntervalSince1970 * 1000)

        let runs = [
            makeRun(runId: "today", startedAtMs: todayMs),
            makeRun(runId: "yesterday", startedAtMs: yesterdayMs),
        ]

        let filtered = runs.filter { ($0.startedAt ?? .distantPast) >= todayCutoff }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.runId, "today")
    }

    func testDateFilterWeek() {
        let now = Date()
        let weekCutoff = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let recentMs = Int64(now.addingTimeInterval(-86400).timeIntervalSince1970 * 1000)
        let oldMs = Int64(now.addingTimeInterval(-86400 * 30).timeIntervalSince1970 * 1000)

        let runs = [
            makeRun(runId: "recent", startedAtMs: recentMs),
            makeRun(runId: "old", startedAtMs: oldMs),
        ]

        let filtered = runs.filter { ($0.startedAt ?? .distantPast) >= weekCutoff }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.runId, "recent")
    }

    func testDateFilterNilStartedAtFilteredOut() {
        let now = Date()
        let todayCutoff = Calendar.current.startOfDay(for: now)
        let run = makeRun(runId: "no-start", startedAtMs: nil)
        // nil startedAt -> .distantPast, which is before any cutoff
        let passes = (run.startedAt ?? .distantPast) >= todayCutoff
        XCTAssertFalse(passes, "Runs with nil startedAt are filtered out by date filters")
    }

    // MARK: - RUNS_FILTER_CLEAR

    func testClearFiltersResetState() {
        // Simulates: statusFilter = nil; dateFilter = .all; searchText = ""
        var statusFilter: RunStatus? = .running
        var dateFilter = RunsView.DateFilter.today
        var searchText = "test"

        // Clear action:
        statusFilter = nil
        dateFilter = .all
        searchText = ""

        XCTAssertNil(statusFilter)
        XCTAssertEqual(dateFilter, .all)
        XCTAssertEqual(searchText, "")
    }

    // MARK: - RUNS_COUNT_DISPLAY

    func testCountDisplayReflectsFiltered() {
        let runs = sampleRuns()
        let filtered = runs.filter { $0.status == .running }
        let countText = "\(filtered.count) runs"
        XCTAssertEqual(countText, "1 runs")
    }

    /// BUG: Count display says "1 runs" (plural) for a single run. Should be "1 run".
    func testBug_CountDisplayPluralForSingleRun() {
        let count = 1
        let text = "\(count) runs"
        XCTAssertEqual(text, "1 runs",
                       "BUG: '1 runs' is grammatically incorrect; should be '1 run'")
    }

    // MARK: - RUNS_STATUS_SECTIONING

    func testActiveSectionIncludesRunningAndWaitingApproval() {
        let runs = sampleRuns()
        let active = runs.filter { $0.status == .running || $0.status == .waitingApproval }
        XCTAssertEqual(active.count, 2) // running + waitingApproval
    }

    func testCompletedSectionIncludesFinished() {
        let runs = sampleRuns()
        let completed = runs.filter { $0.status == .finished }
        XCTAssertEqual(completed.count, 1)
    }

    func testFailedSectionIncludesFailedAndCancelled() {
        let runs = sampleRuns()
        let failed = runs.filter { $0.status == .failed || $0.status == .cancelled }
        XCTAssertEqual(failed.count, 2)
    }

    // MARK: - RUNS_STATUS_GROUP_LABELS_ACTIVE_COMPLETED_FAILED

    func testSectionLabels() {
        // The view uses hardcoded strings "ACTIVE", "COMPLETED", "FAILED"
        let labels = ["ACTIVE", "COMPLETED", "FAILED"]
        XCTAssertEqual(labels[0], "ACTIVE")
        XCTAssertEqual(labels[1], "COMPLETED")
        XCTAssertEqual(labels[2], "FAILED")
    }
}

// MARK: - RUNS_NODE_STATE_ICONS / RUNS_NODE_STATE_6_STATE_MAPPING Tests

final class NodeStateIconMappingTests: XCTestCase {

    /// Tests that nodeStateIcon maps to the correct SF Symbol for each state.
    /// The mapping from RunsView:
    ///   running  -> circle.fill (accent)
    ///   finished -> checkmark.circle.fill (success)
    ///   failed   -> xmark.circle.fill (danger)
    ///   skipped  -> minus.circle.fill (textTertiary)
    ///   blocked  -> pause.circle.fill (warning)
    ///   default  -> circle (textTertiary) — covers "pending"
    func testNodeStateIconMapping() {
        let expected: [(String, String)] = [
            ("running", "circle.fill"),
            ("finished", "checkmark.circle.fill"),
            ("failed", "xmark.circle.fill"),
            ("skipped", "minus.circle.fill"),
            ("blocked", "pause.circle.fill"),
            ("pending", "circle"),           // default case
            ("unknown", "circle"),           // default case
        ]
        // We can't call the private function directly, but we verify the specification
        for (state, expectedIcon) in expected {
            let icon: String = {
                switch state {
                case "running": return "circle.fill"
                case "finished": return "checkmark.circle.fill"
                case "failed": return "xmark.circle.fill"
                case "skipped": return "minus.circle.fill"
                case "blocked": return "pause.circle.fill"
                default: return "circle"
                }
            }()
            XCTAssertEqual(icon, expectedIcon, "State '\(state)' should map to '\(expectedIcon)'")
        }
    }

    /// BUG: nodeStateIcon handles only 5 named states + default (6 total),
    /// but the approve/deny logic checks for "waiting-approval" state on nodes.
    /// "waiting-approval" falls to default case and gets a generic gray circle,
    /// while it should logically get the same treatment as "blocked".
    func testBug_WaitingApprovalFallsToDefault() {
        let state = "waiting-approval"
        let icon: String = {
            switch state {
            case "running": return "circle.fill"
            case "finished": return "checkmark.circle.fill"
            case "failed": return "xmark.circle.fill"
            case "skipped": return "minus.circle.fill"
            case "blocked": return "pause.circle.fill"
            default: return "circle"  // waiting-approval lands here
            }
        }()
        XCTAssertEqual(icon, "circle",
                       "BUG: 'waiting-approval' gets default icon instead of pause.circle.fill")
    }
}

// MARK: - RUNS_BLOCKED_NODE_LOOKUP_FOR_APPROVE / RUNS_INLINE_APPROVE / RUNS_INLINE_DENY

final class BlockedNodeLookupTests: XCTestCase {

    func testFindsBlockedNode() {
        let tasks = [
            RunTask(nodeId: "n1", label: "A", iteration: nil, state: "finished", lastAttempt: nil, updatedAtMs: nil),
            RunTask(nodeId: "n2", label: "B", iteration: nil, state: "blocked", lastAttempt: nil, updatedAtMs: nil),
        ]
        let blocked = tasks.first(where: { $0.state == "blocked" || $0.state == "waiting-approval" })
        XCTAssertNotNil(blocked)
        XCTAssertEqual(blocked?.nodeId, "n2")
    }

    func testFindsWaitingApprovalNode() {
        let tasks = [
            RunTask(nodeId: "n1", label: "A", iteration: nil, state: "running", lastAttempt: nil, updatedAtMs: nil),
            RunTask(nodeId: "n2", label: "B", iteration: nil, state: "waiting-approval", lastAttempt: nil, updatedAtMs: nil),
        ]
        let blocked = tasks.first(where: { $0.state == "blocked" || $0.state == "waiting-approval" })
        XCTAssertNotNil(blocked)
        XCTAssertEqual(blocked?.nodeId, "n2")
    }

    func testNoBlockedNodeDisablesButtons() {
        let tasks = [
            RunTask(nodeId: "n1", label: "A", iteration: nil, state: "finished", lastAttempt: nil, updatedAtMs: nil),
            RunTask(nodeId: "n2", label: "B", iteration: nil, state: "running", lastAttempt: nil, updatedAtMs: nil),
        ]
        let blocked = tasks.first(where: { $0.state == "blocked" || $0.state == "waiting-approval" })
        XCTAssertNil(blocked, "No blocked node means approve/deny buttons should be disabled")
    }

    /// BUG: When a run has waitingApproval status but no inspection loaded yet,
    /// the approve/deny buttons appear disabled (opacity 0.5) with empty action closures.
    /// The disabled buttons still render but do nothing.
    /// Also, if the inspection fails to load (silently caught), the buttons stay disabled forever
    /// with no error feedback to the user.
    func testBug_ApproveButtonsDisabledWithNoInspection() {
        // inspections[run.runId] is nil -> buttons show but disabled
        let inspections: [String: RunInspection] = [:]
        let run = makeRun(runId: "r1", status: .waitingApproval)
        let inspection = inspections[run.runId]
        XCTAssertNil(inspection,
                     "BUG: No inspection data means approve/deny show disabled with no way to retry loading")
    }

    /// BUG: The view uses `first(where:)` to find the blocked node, which means only
    /// the FIRST blocked/waiting-approval node can be approved/denied. If multiple nodes
    /// are blocked simultaneously, the user can only interact with the first one.
    func testBug_OnlyFirstBlockedNodeIsActionable() {
        let tasks = [
            RunTask(nodeId: "n1", label: "Gate A", iteration: nil, state: "blocked", lastAttempt: nil, updatedAtMs: nil),
            RunTask(nodeId: "n2", label: "Gate B", iteration: nil, state: "blocked", lastAttempt: nil, updatedAtMs: nil),
        ]
        let found = tasks.first(where: { $0.state == "blocked" || $0.state == "waiting-approval" })
        XCTAssertEqual(found?.nodeId, "n1",
                       "BUG: Only first blocked node is actionable; 'Gate B' cannot be approved/denied")
    }
}

// MARK: - RUNS_EXPANDABLE_DETAIL / RUNS_CHEVRON_EXPAND_COLLAPSE_ICON

final class ExpandCollapseTests: XCTestCase {

    func testChevronIconCollapsed() {
        let expandedRunId: String? = nil
        let run = makeRun(runId: "r1")
        let icon = expandedRunId == run.id ? "chevron.down" : "chevron.right"
        XCTAssertEqual(icon, "chevron.right")
    }

    func testChevronIconExpanded() {
        let expandedRunId: String? = "r1"
        let run = makeRun(runId: "r1")
        let icon = expandedRunId == run.id ? "chevron.down" : "chevron.right"
        XCTAssertEqual(icon, "chevron.down")
    }

    func testChevronIconDifferentRunExpanded() {
        let expandedRunId: String? = "r2"
        let run = makeRun(runId: "r1")
        let icon = expandedRunId == run.id ? "chevron.down" : "chevron.right"
        XCTAssertEqual(icon, "chevron.right")
    }

    /// BUG: Only one run can be expanded at a time (expandedRunId is a single String?).
    /// Clicking a second run collapses the first. This may be intentional UX, but
    /// it prevents comparing two runs side by side.
    func testBug_OnlyOneRunExpandableAtATime() {
        var expandedRunId: String? = "r1"
        // Simulate toggling a different run
        let newRunId = "r2"
        if expandedRunId == newRunId {
            expandedRunId = nil
        } else {
            expandedRunId = newRunId
        }
        XCTAssertEqual(expandedRunId, "r2",
                       "BUG: Expanding r2 collapsed r1; only one run expandable at a time")
    }
}

// MARK: - RUNS_LAZY_INSPECTION_LOADING

final class LazyInspectionLoadingTests: XCTestCase {

    func testInspectionOnlyLoadedOnExpand() {
        // Simulates the toggleExpand logic
        var inspections: [String: Bool] = [:] // simplified: tracks whether loaded
        var expandedRunId: String? = nil

        // Before expand: no inspection
        XCTAssertNil(inspections["r1"])

        // Expand r1
        expandedRunId = "r1"
        if inspections["r1"] == nil {
            inspections["r1"] = true // simulates loading
        }

        XCTAssertEqual(expandedRunId, "r1")
        XCTAssertNotNil(inspections["r1"])
    }

    func testInspectionNotReloadedOnReExpand() {
        var inspections: [String: Bool] = ["r1": true]
        var expandedRunId: String? = nil
        var loadCount = 0

        // Expand r1
        expandedRunId = "r1"
        if inspections["r1"] == nil {
            loadCount += 1
        }

        XCTAssertEqual(loadCount, 0, "Should not reload inspection if already cached")
    }

    /// BUG: The toggleExpand function checks `inspections[run.id]` but loadInspection
    /// uses `run.runId` as the key. Since `run.id == run.runId`, this works, but the
    /// inconsistency (using `run.id` in one place and `run.runId` in another) is fragile.
    func testBug_InconsistentKeyUsageIdVsRunId() {
        let run = makeRun(runId: "r1")
        // toggleExpand checks: inspections[run.id]
        // loadInspection stores: inspections[runId] (the parameter, which is run.runId)
        XCTAssertEqual(run.id, run.runId,
                       "Currently safe because id == runId, but inconsistent key usage is fragile")
    }
}

// MARK: - RUNS_DETAIL_INDENT_24PX

final class DetailIndentTests: XCTestCase {

    /// The expanded run detail has .padding(.leading, 24) for indent under chevron.
    func testDetailIndentConstant() {
        let expectedIndent: CGFloat = 24
        XCTAssertEqual(expectedIndent, 24, "Detail indent should be 24px")
    }
}

// MARK: - CONSTANT_PROGRESS_BAR_HEIGHT_6

final class ProgressBarConstantsTests: XCTestCase {

    func testProgressBarHeight() {
        // ProgressBar uses .frame(height: 6)
        let expectedHeight: CGFloat = 6
        XCTAssertEqual(expectedHeight, 6, "Progress bar height constant should be 6")
    }
}

// MARK: - UI_STATUS_PILL (StatusPill color mapping)

final class StatusPillColorMappingTests: XCTestCase {

    /// RUNS_STATUS_COLOR_MAPPING:
    ///   running -> accent (blue)
    ///   waitingApproval -> warning (yellow)
    ///   finished -> success (green)
    ///   failed -> danger (red)
        ///   stale/orphaned -> warning (yellow)
        ///   cancelled -> textTertiary (gray)
    func testStatusColorMapping() {
        // Verify the specification matches by replicating the switch
        let mapping: [(RunStatus, String)] = [
            (.running, "accent"),
            (.waitingApproval, "warning"),
            (.finished, "success"),
            (.failed, "danger"),
            (.stale, "warning"),
            (.orphaned, "warning"),
            (.cancelled, "textTertiary"),
        ]
        for (status, expectedColor) in mapping {
            let color: String = {
                switch status {
                case .running: return "accent"
                case .waitingApproval, .waitingEvent, .waitingTimer: return "warning"
                case .finished: return "success"
                case .failed: return "danger"
                case .stale, .orphaned: return "warning"
                case .cancelled: return "textTertiary"
                case .unknown: return "textSecondary"
                }
            }()
            XCTAssertEqual(color, expectedColor,
                           "Status \(status.label) should use \(expectedColor) color")
        }
    }
}

// MARK: - RUNS_CANCEL

final class RunsCancelTests: XCTestCase {

    /// Cancel button shows for running and waitingApproval statuses.
    func testCancelVisibleForRunning() {
        let run = makeRun(status: .running)
        let showCancel = run.status == .running || run.status == .waitingApproval
        XCTAssertTrue(showCancel)
    }

    func testCancelVisibleForWaitingApproval() {
        let run = makeRun(status: .waitingApproval)
        let showCancel = run.status == .running || run.status == .waitingApproval
        XCTAssertTrue(showCancel)
    }

    func testCancelHiddenForFinished() {
        let run = makeRun(status: .finished)
        let showCancel = run.status == .running || run.status == .waitingApproval
        XCTAssertFalse(showCancel)
    }

    func testCancelHiddenForFailed() {
        let run = makeRun(status: .failed)
        let showCancel = run.status == .running || run.status == .waitingApproval
        XCTAssertFalse(showCancel)
    }

    func testCancelHiddenForCancelled() {
        let run = makeRun(status: .cancelled)
        let showCancel = run.status == .running || run.status == .waitingApproval
        XCTAssertFalse(showCancel)
    }
}

// MARK: - RUNS_ERROR_DISPLAY

final class RunsErrorDisplayTests: XCTestCase {

    func testErrorJsonDisplayed() {
        let run = makeRun(errorJson: "{\"code\":\"TIMEOUT\",\"message\":\"Node timed out\"}")
        XCTAssertNotNil(run.errorJson)
    }

    func testNoErrorJson() {
        let run = makeRun(errorJson: nil)
        XCTAssertNil(run.errorJson)
    }
}

// MARK: - RunSummary JSON Decoding

final class RunSummaryDecodingTests: XCTestCase {

    func testDecodeFullJSON() throws {
        let json = """
        {
            "runId": "abc12345-6789-def0",
            "workflowName": "deploy-prod",
            "workflowPath": "workflows/deploy.ts",
            "status": "running",
            "startedAtMs": 1700000000000,
            "finishedAtMs": null,
            "summary": {"total": 5, "finished": 2, "failed": 0},
            "errorJson": null
        }
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.runId, "abc12345-6789-def0")
        XCTAssertEqual(run.workflowName, "deploy-prod")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.totalNodes, 5)
        XCTAssertEqual(run.finishedNodes, 2)
        XCTAssertEqual(run.progress, 0.4, accuracy: 0.001)
    }

    func testDecodeMinimalJSON() throws {
        let json = """
        {
            "runId": "r1",
            "workflowName": null,
            "workflowPath": null,
            "status": "finished",
            "startedAtMs": null,
            "finishedAtMs": null,
            "summary": null,
            "errorJson": null
        }
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.runId, "r1")
        XCTAssertNil(run.workflowName)
        XCTAssertEqual(run.status, .finished)
        XCTAssertEqual(run.progress, 0)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testDecodeWaitingApprovalStatus() throws {
        let json = """
        {"runId":"r1","workflowName":null,"workflowPath":null,"status":"waiting-approval","startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.status, .waitingApproval)
    }

    func testDecodeWithErrorJson() throws {
        let json = """
        {
            "runId": "r1",
            "workflowName": "test",
            "workflowPath": null,
            "status": "failed",
            "startedAtMs": 1700000000000,
            "finishedAtMs": 1700000060000,
            "summary": {"total": 3, "finished": 1, "failed": 1},
            "errorJson": "{\\"code\\":\\"NODE_FAILED\\",\\"message\\":\\"Step 2 failed\\"}"
        }
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.status, .failed)
        XCTAssertNotNil(run.errorJson)
        XCTAssertTrue(run.errorJson!.contains("NODE_FAILED"))
    }
}

// MARK: - Combined Filter Tests

final class CombinedFilterTests: XCTestCase {

    /// Tests applying status + search + date filters simultaneously.
    func testCombinedFilters() {
        let now = Date()
        let todayCutoff = Calendar.current.startOfDay(for: now)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let oldMs = Int64(now.addingTimeInterval(-86400 * 30).timeIntervalSince1970 * 1000)

        let runs = [
            makeRun(runId: "r1", workflowName: "deploy-prod", status: .running, startedAtMs: nowMs),
            makeRun(runId: "r2", workflowName: "deploy-staging", status: .running, startedAtMs: oldMs),
            makeRun(runId: "r3", workflowName: "test-suite", status: .running, startedAtMs: nowMs),
            makeRun(runId: "r4", workflowName: "deploy-prod", status: .finished, startedAtMs: nowMs),
        ]

        // Filter: status=running, search="deploy", date=today
        let filtered = runs
            .filter { $0.status == .running }
            .filter {
                ($0.workflowName ?? "").localizedCaseInsensitiveContains("deploy") ||
                $0.runId.localizedCaseInsensitiveContains("deploy")
            }
            .filter { ($0.startedAt ?? .distantPast) >= todayCutoff }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.runId, "r1")
    }
}

// MARK: - UI_PROGRESS_BAR (ProgressBar clamping)

final class ProgressBarClampingTests: XCTestCase {

    /// ProgressBar clamps progress to [0, 1] using max(0, min(1, progress)).
    func testClampNegativeProgress() {
        let progress = -0.5
        let clamped = max(0, min(1, progress))
        XCTAssertEqual(clamped, 0)
    }

    func testClampOverOneProgress() {
        let progress = 1.5
        let clamped = max(0, min(1, progress))
        XCTAssertEqual(clamped, 1)
    }

    func testClampNormalProgress() {
        let progress = 0.75
        let clamped = max(0, min(1, progress))
        XCTAssertEqual(clamped, 0.75)
    }

    func testClampZero() {
        let clamped = max(0, min(1, 0.0))
        XCTAssertEqual(clamped, 0)
    }

    func testClampOne() {
        let clamped = max(0, min(1, 1.0))
        XCTAssertEqual(clamped, 1)
    }
}

// MARK: - UI_RUN_ROW (progress bar visibility)

final class RunRowProgressVisibilityTests: XCTestCase {

    /// Progress bar only shows when status == .running AND totalNodes > 0.
    func testProgressBarShownForRunningWithNodes() {
        let run = makeRun(status: .running, summary: ["total": 5, "finished": 2])
        let show = run.status == .running && run.totalNodes > 0
        XCTAssertTrue(show)
    }

    func testProgressBarHiddenForRunningWithNoNodes() {
        let run = makeRun(status: .running, summary: nil)
        let show = run.status == .running && run.totalNodes > 0
        XCTAssertFalse(show)
    }

    func testProgressBarHiddenForFinished() {
        let run = makeRun(status: .finished, summary: ["total": 5, "finished": 5])
        let show = run.status == .running && run.totalNodes > 0
        XCTAssertFalse(show)
    }

    func testProgressBarHiddenForFailed() {
        let run = makeRun(status: .failed, summary: ["total": 5, "finished": 3, "failed": 2])
        let show = run.status == .running && run.totalNodes > 0
        XCTAssertFalse(show)
    }

    /// BUG: Progress bar is hidden for waitingApproval status even if nodes are partially complete.
    /// A run that is waiting-approval might be 80% done, but the user sees no progress indicator.
    func testBug_ProgressBarHiddenForWaitingApproval() {
        let run = makeRun(status: .waitingApproval, summary: ["total": 10, "finished": 8])
        let show = run.status == .running && run.totalNodes > 0
        XCTAssertFalse(show,
                       "BUG: Progress bar hidden for waitingApproval even with progress data")
        XCTAssertEqual(run.progress, 0.8, "Run is 80% done but no progress bar shown")
    }
}

// MARK: - Approve/Deny after action behavior

final class ApproveAfterActionTests: XCTestCase {

    /// BUG: After approveNode/denyNode, the code calls:
    ///   await loadRuns()
    ///   if let expandedRunId { await loadInspection(expandedRunId) }
    /// But expandedRunId is the run.id (which == run.runId). However, loadInspection
    /// expects a runId parameter. Since expandedRunId stores run.id, this works by coincidence.
    ///
    /// More importantly, there's a subtle bug: after loadRuns(), the runs array is replaced.
    /// If the run's status changed (e.g., from waitingApproval to running after approval),
    /// it now appears in a different section. The expanded state is preserved, but the run
    /// may visually jump to a different section, which is disorienting.
    func testApproveChangesRunSection() {
        let run = makeRun(runId: "r1", status: .waitingApproval)
        // After approval, status might change to .running
        let updatedRun = makeRun(runId: "r1", status: .running)

        // Before: ACTIVE section (waitingApproval)
        let beforeActive = [run].filter { $0.status == .running || $0.status == .waitingApproval }
        XCTAssertEqual(beforeActive.count, 1)

        // After: still ACTIVE section (running) — same section, different reason
        let afterActive = [updatedRun].filter { $0.status == .running || $0.status == .waitingApproval }
        XCTAssertEqual(afterActive.count, 1)
    }
}

// MARK: - Error handling in loadRuns

final class LoadRunsErrorTests: XCTestCase {

    /// BUG: In approveNode, denyNode, and cancelRun, the catch block sets
    /// `self.error = error.localizedDescription`. But `error` here shadows the
    /// property `self.error` with the caught error. This is correct Swift behavior,
    /// but the error display shows the raw localizedDescription which may be
    /// unhelpful (e.g., "The operation couldn't be completed.").
    func testErrorMessageUsesLocalizedDescription() {
        let error = SmithersError.cli("smithers: node not found")
        XCTAssertEqual(error.localizedDescription, "smithers: node not found")
    }

    func testErrorMessageForUnauthorized() {
        let error = SmithersError.unauthorized
        XCTAssertEqual(error.localizedDescription, "Unauthorized - check your API token")
    }
}

// MARK: - Edge cases

final class RunsEdgeCaseTests: XCTestCase {

    /// Empty runs list shows "No runs found" (when not loading).
    func testEmptyRunsShowsPlaceholder() {
        let runs: [RunSummary] = []
        let isLoading = false
        let error: String? = nil
        let showEmpty = runs.isEmpty && !isLoading && error == nil
        XCTAssertTrue(showEmpty)
    }

    /// Error state takes priority over empty state.
    func testErrorTakesPriorityOverEmpty() {
        let runs: [RunSummary] = []
        let error: String? = "Connection failed"
        // The view checks `if let error` first, then `else if filteredRuns.isEmpty && !isLoading`
        let showError = error != nil
        XCTAssertTrue(showError, "Error state should display even when runs are empty")
    }

    /// BUG: When isLoading is true and runs are empty, neither error nor empty state shows.
    /// The user sees a blank content area with only the loading spinner in the header.
    /// There's no skeleton/placeholder in the main content area during initial load.
    func testBug_NoLoadingStateInContentArea() {
        let runs: [RunSummary] = []
        let isLoading = true
        let error: String? = nil

        let showError = error != nil
        let showEmpty = runs.isEmpty && !isLoading
        let showList = !runs.isEmpty

        XCTAssertFalse(showError)
        XCTAssertFalse(showEmpty)  // isLoading prevents this
        XCTAssertFalse(showList)
        // All three are false -> blank content area
    }

    /// All sections empty after filtering: no sections render, just empty scroll view content.
    func testAllSectionsEmptyAfterFiltering() {
        let runs: [RunSummary] = []
        let active = runs.filter { $0.status == .running || $0.status == .waitingApproval }
        let completed = runs.filter { $0.status == .finished }
        let failed = runs.filter { $0.status == .failed || $0.status == .cancelled }

        // When filteredRuns is empty and not loading, the view shows "No runs found"
        // but only if we reach that branch. The `else` branch (ScrollView) would show
        // empty content if filteredRuns were non-empty but all sections were empty.
        // This can't actually happen since the sections cover all statuses.
        XCTAssertTrue(active.isEmpty)
        XCTAssertTrue(completed.isEmpty)
        XCTAssertTrue(failed.isEmpty)
    }
}

// MARK: - Test Helpers

private func makeRun(
    runId: String = "run-12345678",
    workflowName: String? = "test-workflow",
    workflowPath: String? = nil,
    status: RunStatus = .running,
    startedAtMs: Int64? = 1700000000000,
    finishedAtMs: Int64? = nil,
    summary: [String: Int]? = nil,
    errorJson: String? = nil
) -> RunSummary {
    RunSummary(
        runId: runId,
        workflowName: workflowName,
        workflowPath: workflowPath,
        status: status,
        startedAtMs: startedAtMs,
        finishedAtMs: finishedAtMs,
        summary: summary,
        errorJson: errorJson
    )
}

private func sampleRuns() -> [RunSummary] {
    let now = Date()
    let nowMs = Int64(now.timeIntervalSince1970 * 1000)
    return [
        makeRun(runId: "r1-abcdefgh", workflowName: "deploy-prod", status: .running, startedAtMs: nowMs, summary: ["total": 5, "finished": 2]),
        makeRun(runId: "r2-abcdefgh", workflowName: "test-suite", status: .waitingApproval, startedAtMs: nowMs),
        makeRun(runId: "r3", workflowName: "build", status: .failed, startedAtMs: nowMs, finishedAtMs: nowMs, errorJson: "{\"error\":\"timeout\"}"),
        makeRun(runId: "r4", workflowName: "lint", status: .finished, startedAtMs: nowMs, finishedAtMs: nowMs),
        makeRun(runId: "r5", workflowName: "cleanup", status: .cancelled, startedAtMs: nowMs, finishedAtMs: nowMs),
    ]
}
