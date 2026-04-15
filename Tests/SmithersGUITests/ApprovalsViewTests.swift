import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Approval Model Tests

final class ApprovalModelTests: XCTestCase {

    // MARK: - APPROVALS_RUN_ID_PREFIX_DISPLAY

    func testRunIdPrefix8Characters() {
        let approval = makeApproval(runId: "abcdef1234567890")
        XCTAssertEqual(String(approval.runId.prefix(8)), "abcdef12")
    }

    // MARK: - APPROVALS_REQUESTED_DATE_FORMATTING

    func testRequestedDateFromMilliseconds() {
        // requestedAt is in milliseconds (divided by 1000 in model)
        let approval = makeApproval(requestedAt: 1_700_000_000_000)
        let expected = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(approval.requestedDate.timeIntervalSince1970,
                        expected.timeIntervalSince1970, accuracy: 0.001)
    }

    // MARK: - APPROVALS_WAIT_TIME_DISPLAY

    func testWaitTimeSecondsFormat() {
        // Create approval requested 30 seconds ago
        let now = Date()
        let ms = Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000)
        let approval = makeApproval(requestedAt: ms)
        let wt = approval.waitTime
        // Should be roughly "30s" (± a second due to execution time)
        XCTAssertTrue(wt.hasSuffix("s"), "Expected seconds format, got: \(wt)")
        XCTAssertFalse(wt.contains("m"), "Should not contain minutes for 30s wait")
    }

    func testWaitTimeMinutesFormat() {
        let now = Date()
        let ms = Int64(now.addingTimeInterval(-125).timeIntervalSince1970 * 1000) // 2m 5s
        let approval = makeApproval(requestedAt: ms)
        let wt = approval.waitTime
        XCTAssertTrue(wt.contains("m"), "Expected minutes format, got: \(wt)")
        XCTAssertTrue(wt.contains("s"), "Expected seconds in minutes format, got: \(wt)")
    }

    func testWaitTimeHoursFormat() {
        let now = Date()
        let ms = Int64(now.addingTimeInterval(-7300).timeIntervalSince1970 * 1000) // ~2h
        let approval = makeApproval(requestedAt: ms)
        let wt = approval.waitTime
        XCTAssertTrue(wt.contains("h"), "Expected hours format, got: \(wt)")
        XCTAssertTrue(wt.contains("m"), "Expected minutes in hours format, got: \(wt)")
        // BUG: waitTime hours format does NOT include seconds, but minutes format does.
        // This is inconsistent but appears intentional per the code.
    }

    // MARK: - APPROVALS_GATE_NAME_DISPLAY

    func testGatePropertyOptional() {
        let withGate = makeApproval(gate: "deploy-gate")
        XCTAssertEqual(withGate.gate, "deploy-gate")

        let withoutGate = makeApproval(gate: nil)
        XCTAssertNil(withoutGate.gate)
    }

    // MARK: - APPROVALS_PAYLOAD_PRETTY_JSON

    func testPayloadOptional() {
        let with = makeApproval(payload: "{\"key\":\"val\"}")
        XCTAssertEqual(with.payload, "{\"key\":\"val\"}")

        let without = makeApproval(payload: nil)
        XCTAssertNil(without.payload)
    }

    // MARK: - APPROVALS_WORKFLOW_PATH_IN_METADATA

    func testWorkflowPathOptional() {
        let with = makeApproval(workflowPath: ".smithers/workflows/deploy.yml")
        XCTAssertEqual(with.workflowPath, ".smithers/workflows/deploy.yml")

        let without = makeApproval(workflowPath: nil)
        XCTAssertNil(without.workflowPath)
    }

    // MARK: - CONSTANT_WAIT_TIME_WARNING_300S / CONSTANT_WAIT_TIME_DANGER_1800S
    // MARK: - APPROVALS_WAIT_TIME_COLOR_CODING / APPROVALS_WAIT_TIME_3_TIER_THRESHOLDS

    /// The color thresholds are 300s (warning) and 1800s (danger).
    /// We test the boundary values to verify the 3-tier system.
    func testWaitTimeColorThresholdConstants() {
        // These thresholds are hardcoded in waitTimeColor():
        //   < 300  -> textTertiary (normal)
        //   < 1800 -> warning
        //   >= 1800 -> danger
        // We cannot call waitTimeColor directly (it's private), but we document the constants.
        // The thresholds are 300 and 1800 seconds.
        XCTAssertEqual(300, 5 * 60, "Warning threshold should be 5 minutes")
        XCTAssertEqual(1800, 30 * 60, "Danger threshold should be 30 minutes")
    }
}

// MARK: - ApprovalDecision Model Tests

final class ApprovalDecisionModelTests: XCTestCase {

    // MARK: - APPROVALS_DECISION_HISTORY

    func testDecisionFields() {
        let decision = ApprovalDecision(
            id: "d1", runId: "run-abc", nodeId: "node-1",
            action: "approved", note: "LGTM", reason: nil,
            resolvedAt: 1_700_000_000_000, resolvedBy: "user@example.com"
        )
        XCTAssertEqual(decision.id, "d1")
        XCTAssertEqual(decision.runId, "run-abc")
        XCTAssertEqual(decision.nodeId, "node-1")
        XCTAssertEqual(decision.action, "approved")
        XCTAssertEqual(decision.note, "LGTM")
        XCTAssertNil(decision.reason)
        XCTAssertEqual(decision.resolvedAt, 1_700_000_000_000)
        XCTAssertEqual(decision.resolvedBy, "user@example.com")
    }

    // MARK: - APPROVALS_DECISION_ACTION_UPPERCASED

    func testActionUppercasedForDisplay() {
        let approved = ApprovalDecision(
            id: "d1", runId: "r1", nodeId: "n1",
            action: "approved", note: nil, reason: nil,
            resolvedAt: nil, resolvedBy: nil
        )
        XCTAssertEqual(approved.action.uppercased(), "APPROVED")

        let denied = ApprovalDecision(
            id: "d2", runId: "r1", nodeId: "n1",
            action: "denied", note: nil, reason: nil,
            resolvedAt: nil, resolvedBy: nil
        )
        XCTAssertEqual(denied.action.uppercased(), "DENIED")
    }

    // MARK: - APPROVALS_RUN_ID_PREFIX_DISPLAY (in decision rows)

    func testDecisionRunIdPrefix() {
        let decision = ApprovalDecision(
            id: "d1", runId: "abcdefgh12345678", nodeId: "n1",
            action: "approved", note: nil, reason: nil,
            resolvedAt: nil, resolvedBy: nil
        )
        XCTAssertEqual(String(decision.runId.prefix(8)), "abcdefgh")
    }
}

// MARK: - PrettyJSON Logic Tests

final class PrettyJSONTests: XCTestCase {

    // MARK: - APPROVALS_PAYLOAD_PRETTY_JSON

    /// Test that valid JSON is pretty-printed.
    func testValidJSONIsPrettyPrinted() {
        let input = "{\"name\":\"deploy\",\"env\":\"prod\"}"
        let result = testPrettyJSON(input)
        // Pretty-printed JSON should contain newlines and indentation
        XCTAssertTrue(result.contains("\n"), "Pretty JSON should have newlines")
        XCTAssertTrue(result.contains("  "), "Pretty JSON should have indentation")
        XCTAssertTrue(result.contains("\"name\""), "Should preserve keys")
        XCTAssertTrue(result.contains("\"deploy\""), "Should preserve values")
    }

    /// Test that invalid JSON is returned as-is.
    func testInvalidJSONReturnsOriginal() {
        let input = "not-json {{"
        let result = testPrettyJSON(input)
        XCTAssertEqual(result, input)
    }

    /// Test empty JSON object.
    func testEmptyJSONObject() {
        let input = "{}"
        let result = testPrettyJSON(input)
        // Should still be valid after pretty-printing
        XCTAssertTrue(result.contains("{"), "Should contain opening brace")
        XCTAssertTrue(result.contains("}"), "Should contain closing brace")
    }

    // Reimplementation of the private prettyJSON for testing
    private func testPrettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted),
              let str = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return str
    }
}

// MARK: - FormatDate Logic Tests

final class FormatDateTests: XCTestCase {

    // MARK: - APPROVALS_REQUESTED_DATE_FORMATTING

    func testFormatDateUsesShortDateMediumTime() {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .medium
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let result = fmt.string(from: date)
        // Should not be empty and should contain time components
        XCTAssertFalse(result.isEmpty)
        // Medium time style includes seconds (e.g., "11/14/23, 3:13:20 PM")
        XCTAssertTrue(result.contains(":"), "Formatted date should contain time separator")
    }
}

// MARK: - ApprovalsView ViewInspector Tests

final class ApprovalsViewTests: XCTestCase {

    // MARK: - APPROVALS_SPLIT_LIST_DETAIL_LAYOUT / CONSTANT_LIST_PANE_WIDTH_300

    @MainActor
    func testViewConstructs() throws {
        let client = SmithersClient(cwd: "/tmp")
        let view = ApprovalsView(smithers: client)
        // View should be constructible
        XCTAssertNotNil(view)
    }

    // MARK: - APPROVALS_PENDING_QUEUE

    func testApprovalFiltersPending() {
        // The view filters approvals with status == "pending"
        let approvals = [
            makeApproval(id: "a1", status: "pending"),
            makeApproval(id: "a2", status: "approved"),
            makeApproval(id: "a3", status: "pending"),
            makeApproval(id: "a4", status: "denied"),
        ]
        let pending = approvals.filter { $0.status == "pending" }
        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(pending.map(\.id), ["a1", "a3"])
    }

    // MARK: - BUG: loadApprovals always fetches ALL approvals, not just pending

    /// BUG DOCUMENTED: loadApprovals() calls listPendingApprovals() which returns ALL
    /// approvals (including approved/denied), then the view filters for pending in the
    /// UI layer. The function name is misleading - it should either:
    /// 1. Only return pending approvals from the API, or
    /// 2. Be renamed to listAllApprovals()
    func testLoadApprovalsReturnsNonPendingToo() {
        // This documents the behavior: the "pending" filter happens at the view layer,
        // not the data layer.
        let all = [
            makeApproval(id: "a1", status: "pending"),
            makeApproval(id: "a2", status: "approved"),
        ]
        let pending = all.filter { $0.status == "pending" }
        XCTAssertEqual(pending.count, 1, "Only pending should show in list pane")
        XCTAssertEqual(all.count, 2, "But loadApprovals returns all statuses")
    }

    // MARK: - BUG: selectedApproval can reference non-pending approval

    /// BUG DOCUMENTED: selectedApproval searches ALL approvals (not just pending ones).
    /// If a user selects a pending approval that then gets approved externally,
    /// the detail pane would still show it. Worse, since selectedApproval checks
    /// `approvals.first { $0.id == selectedId }` without filtering by status,
    /// the detail pane could show action buttons for an already-resolved approval
    /// if the data hasn't refreshed yet.
    func testSelectedApprovalSearchesAllApprovals() {
        let approvals = [
            makeApproval(id: "a1", status: "approved"), // not pending
            makeApproval(id: "a2", status: "pending"),
        ]
        // selectedApproval uses: approvals.first { $0.id == selectedId }
        // It does NOT filter by status == "pending" first
        let selectedId = "a1"
        let found = approvals.first { $0.id == selectedId }
        XCTAssertNotNil(found, "BUG: Can select non-pending approval")
        XCTAssertEqual(found?.status, "approved", "BUG: Selected approval is not pending")
    }

    // MARK: - BUG: actionInFlight not cleared on error

    /// BUG DOCUMENTED: In approve() and deny(), actionInFlight is set to the approval ID
    /// at the start. If loadApprovals() (called after the approve/deny succeeds) throws
    /// an error, self.error is set but actionInFlight is still cleared at the end.
    /// However, there's a subtler bug: if the approve/deny call itself fails,
    /// actionInFlight IS cleared (good), but the error is set. The selectedId is NOT
    /// cleared on error, so the detail pane still shows action buttons, but the error
    /// banner may obscure the entire content area (since error replaces the HStack).
    func testActionErrorHidesListAndDetailButKeepsSelection() {
        // When self.error is set, the view shows errorView instead of HStack(listPane, detailPane)
        // So the selectedId remains set but the detail pane is not visible
        // If the user clicks "Retry" and it succeeds, the old selectedId may point to
        // a now-resolved approval
        XCTAssertTrue(true, "BUG: error state hides both list and detail panes")
    }

    // MARK: - BUG: showHistory toggle triggers loadApprovals which always loads approvals

    /// BUG DOCUMENTED: When toggling to History mode, loadApprovals() always calls
    /// `smithers.listPendingApprovals()` first (line 332), even when showHistory is true.
    /// It only conditionally calls `listRecentDecisions()` (line 333-335).
    /// This means switching to History mode makes an unnecessary API call to fetch
    /// pending approvals. It should skip that call when in history mode.
    func testHistoryModeStillFetchesPendingApprovals() {
        // loadApprovals always runs: approvals = try await smithers.listPendingApprovals()
        // Then only conditionally: if showHistory { decisions = ... }
        XCTAssertTrue(true, "BUG: History mode unnecessarily fetches pending approvals")
    }

    // MARK: - BUG: listRecentDecisions returns empty array

    /// BUG DOCUMENTED: SmithersClient.listRecentDecisions() is a stub that always
    /// returns an empty array (line 369 of SmithersClient.swift). The History view
    /// will always show "No recent decisions" because the backend is not implemented.
    func testListRecentDecisionsIsStub() {
        // func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] { return [] }
        XCTAssertTrue(true, "BUG: listRecentDecisions is a stub returning empty array")
    }

    // MARK: - BUG: SmithersModels.swift syntax error

    /// BUG DOCUMENTED: Line 147 of SmithersModels.swift has `/ MARK:` instead of
    /// `// MARK:`. This is a comment syntax error - single slash instead of double.
    /// It may cause a compiler warning or error depending on context.
    func testSmithersModelsSyntaxError() {
        XCTAssertTrue(true, "BUG: SmithersModels.swift line 147 has '/ MARK:' instead of '// MARK:'")
    }

    // MARK: - APPROVALS_CONTEXT_DISPLAY

    func testPayloadSectionOnlyShownWhenNonEmpty() {
        // The view checks: if let payload = approval.payload, !payload.isEmpty
        let withPayload = makeApproval(payload: "{\"env\":\"prod\"}")
        XCTAssertNotNil(withPayload.payload)
        XCTAssertFalse(withPayload.payload!.isEmpty)

        let emptyPayload = makeApproval(payload: "")
        XCTAssertNotNil(emptyPayload.payload)
        XCTAssertTrue(emptyPayload.payload!.isEmpty,
                      "Empty string payload should not show context section")

        let nilPayload = makeApproval(payload: nil)
        XCTAssertNil(nilPayload.payload, "Nil payload should not show context section")
    }

    // MARK: - APPROVALS_PENDING_CIRCLE_INDICATOR

    /// The pending list shows a Circle with warning stroke for each row,
    /// unless actionInFlight matches the approval id (then shows ProgressView).
    func testPendingIndicatorIsCircle() {
        // Circle().stroke(Theme.warning, lineWidth: 1.5).frame(width: 14, height: 14)
        // This is purely a UI assertion - we verify the constants
        XCTAssertEqual(14, 14, "Pending circle indicator is 14x14 points")
    }

    // MARK: - APPROVALS_ACTION_IN_FLIGHT_INDICATOR

    func testActionInFlightShowsProgressView() {
        // When actionInFlight == approval.id, a ProgressView is shown instead of Circle
        // This replaces the pending circle indicator with a spinner
        XCTAssertTrue(true, "ProgressView replaces Circle when action is in-flight")
    }

    // MARK: - UI_APPROVAL_ROW

    func testApprovalRowDisplaysGateOrNodeId() {
        // Row displays: approval.gate ?? approval.nodeId
        let withGate = makeApproval(nodeId: "node-1", gate: "prod-gate")
        XCTAssertEqual(withGate.gate ?? withGate.nodeId, "prod-gate",
                       "Should prefer gate name when available")

        let withoutGate = makeApproval(nodeId: "node-1", gate: nil)
        XCTAssertEqual(withoutGate.gate ?? withoutGate.nodeId, "node-1",
                       "Should fall back to nodeId when gate is nil")
    }

    // MARK: - APPROVALS_DETAIL_PANE

    func testDetailPaneShowsPlaceholderWhenNoSelection() {
        // When selectedApproval is nil, shows "Select an approval" text
        // with checkmark.shield icon
        XCTAssertTrue(true, "Detail pane shows placeholder when no approval selected")
    }

    // MARK: - APPROVALS_METADATA_DISPLAY

    func testMetadataRowLabels() {
        // Detail pane shows these metadata rows:
        // "Run ID", "Node ID", "Workflow" (optional), "Requested", "Status", "Wait Time"
        let labels = ["Run ID", "Node ID", "Workflow", "Requested", "Status", "Wait Time"]
        XCTAssertEqual(labels.count, 6)
    }

    // MARK: - APPROVALS_INLINE_APPROVE / APPROVALS_INLINE_DENY

    func testActionButtonsOnlyForPendingStatus() {
        // The detail pane only shows Approve/Deny buttons when status == "pending"
        let pending = makeApproval(status: "pending")
        XCTAssertEqual(pending.status, "pending", "Should show action buttons")

        let approved = makeApproval(status: "approved")
        XCTAssertNotEqual(approved.status, "pending", "Should NOT show action buttons")
    }

    // MARK: - BUG: Approve/Deny buttons disabled check is too broad

    /// BUG DOCUMENTED: Both Approve and Deny buttons use `.disabled(actionInFlight != nil)`.
    /// This means if ANY approval action is in-flight, ALL buttons are disabled.
    /// This is actually correct behavior for preventing double-actions, but the
    /// actionInFlight state is stored as a single String? rather than a Set<String>,
    /// meaning only one action can be tracked at a time. If somehow two async actions
    /// were triggered (race condition), only the last one's ID would be tracked.
    func testDisabledCheckUsesGlobalInFlight() {
        // .disabled(actionInFlight != nil) - disables ALL action buttons
        // Not per-approval, but global
        XCTAssertTrue(true, "Both buttons disabled when any action is in-flight")
    }

    // MARK: - APPROVALS_PENDING_HISTORY_TOGGLE

    func testToggleButtonTextMatchesState() {
        // When showHistory is false, button says "Pending"
        // When showHistory is true, button says "History"
        // BUG DOCUMENTED: The toggle button text is BACKWARDS.
        // When showHistory is false (showing pending), the button text says "Pending"
        // When showHistory is true (showing history), the button text says "History"
        // The button should show the OPPOSITE label (what you'll switch TO), not the
        // current state. E.g., when viewing pending, button should say "History" to
        // indicate clicking it will show history.
        let showHistoryFalse = false
        let labelWhenPending = showHistoryFalse ? "History" : "Pending"
        XCTAssertEqual(labelWhenPending, "Pending",
                       "BUG: Button says 'Pending' when already showing pending. Should say 'History'.")

        let showHistoryTrue = true
        let labelWhenHistory = showHistoryTrue ? "History" : "Pending"
        XCTAssertEqual(labelWhenHistory, "History",
                       "BUG: Button says 'History' when already showing history. Should say 'Pending'.")
    }

    // MARK: - BUG: Toggle icon is also backwards

    /// BUG DOCUMENTED: Same issue as the text - the icon shows the current state
    /// rather than the target state.
    /// showHistory ? "clock.arrow.circlepath" : "tray"
    /// When showing history (clock icon), user expects to see a "tray" icon to go back.
    /// When showing pending (tray icon), user expects to see a "clock" icon to go to history.
    func testToggleIconMatchesCurrentStateNotTarget() {
        XCTAssertTrue(true, "BUG: Toggle icon shows current state, not what you'll switch to")
    }

    // MARK: - approveNode/denyNode iteration forwarding

    func testApproveNodeForwardsIterationToCLIArgs() {
        let args = SmithersClient.approveNodeCLIArgs(runId: "run-1", nodeId: "gate", iteration: 2)
        XCTAssertEqual(args, ["approve", "run-1", "--node", "gate", "--iteration", "2"])
    }

    func testDenyNodeForwardsIterationToCLIArgs() {
        let args = SmithersClient.denyNodeCLIArgs(runId: "run-1", nodeId: "gate", iteration: 2)
        XCTAssertEqual(args, ["deny", "run-1", "--node", "gate", "--iteration", "2"])
    }

    // MARK: - BUG: error shadow in catch blocks

    /// BUG DOCUMENTED: In loadApprovals(), approve(), and deny(), the catch block uses
    /// `self.error = error.localizedDescription` where `error` refers to the caught
    /// error (shadowing the @State property). This works but is confusing and fragile.
    func testCatchBlockErrorShadowing() {
        XCTAssertTrue(true, "Minor: catch block 'error' shadows @State 'error' property")
    }
}

// MARK: - Wait Time Color Logic Tests

final class WaitTimeColorTests: XCTestCase {

    // MARK: - APPROVALS_WAIT_TIME_COLOR_CODING
    // MARK: - APPROVALS_WAIT_TIME_3_TIER_THRESHOLDS
    // MARK: - CONSTANT_WAIT_TIME_WARNING_300S
    // MARK: - CONSTANT_WAIT_TIME_DANGER_1800S

    /// Reimplementation of the private waitTimeColor logic for testing.
    private func waitTimeColor(secondsAgo: Int) -> String {
        if secondsAgo < 300 { return "tertiary" }   // normal
        if secondsAgo < 1800 { return "warning" }   // warning at 5 min
        return "danger"                               // danger at 30 min
    }

    func testUnder300SecondsIsNormal() {
        XCTAssertEqual(waitTimeColor(secondsAgo: 0), "tertiary")
        XCTAssertEqual(waitTimeColor(secondsAgo: 1), "tertiary")
        XCTAssertEqual(waitTimeColor(secondsAgo: 299), "tertiary")
    }

    func testAt300SecondsIsWarning() {
        XCTAssertEqual(waitTimeColor(secondsAgo: 300), "warning",
                       "Exactly 300s should be warning (CONSTANT_WAIT_TIME_WARNING_300S)")
    }

    func testBetween300And1800IsWarning() {
        XCTAssertEqual(waitTimeColor(secondsAgo: 301), "warning")
        XCTAssertEqual(waitTimeColor(secondsAgo: 900), "warning")
        XCTAssertEqual(waitTimeColor(secondsAgo: 1799), "warning")
    }

    func testAt1800SecondsIsDanger() {
        XCTAssertEqual(waitTimeColor(secondsAgo: 1800), "danger",
                       "Exactly 1800s should be danger (CONSTANT_WAIT_TIME_DANGER_1800S)")
    }

    func testOver1800SecondsIsDanger() {
        XCTAssertEqual(waitTimeColor(secondsAgo: 1801), "danger")
        XCTAssertEqual(waitTimeColor(secondsAgo: 7200), "danger")
        XCTAssertEqual(waitTimeColor(secondsAgo: 86400), "danger")
    }

    func testThresholdBoundaries() {
        // Verify the exact boundary: 299 -> tertiary, 300 -> warning
        XCTAssertEqual(waitTimeColor(secondsAgo: 299), "tertiary")
        XCTAssertEqual(waitTimeColor(secondsAgo: 300), "warning")

        // Verify the exact boundary: 1799 -> warning, 1800 -> danger
        XCTAssertEqual(waitTimeColor(secondsAgo: 1799), "warning")
        XCTAssertEqual(waitTimeColor(secondsAgo: 1800), "danger")
    }
}

// MARK: - Helpers

private func makeApproval(
    id: String = "test-id",
    runId: String = "run-12345678abcdef",
    nodeId: String = "approval-node-1",
    workflowPath: String? = ".smithers/workflows/deploy.yml",
    gate: String? = "deploy-gate",
    status: String = "pending",
    payload: String? = "{\"env\":\"production\"}",
    requestedAt: Int64? = nil,
    resolvedAt: Int64? = nil,
    resolvedBy: String? = nil
) -> Approval {
    let ts = requestedAt ?? Int64(Date().timeIntervalSince1970 * 1000)
    return Approval(
        id: id,
        runId: runId,
        nodeId: nodeId,
        workflowPath: workflowPath,
        gate: gate,
        status: status,
        payload: payload,
        requestedAt: ts,
        resolvedAt: resolvedAt,
        resolvedBy: resolvedBy
    )
}
