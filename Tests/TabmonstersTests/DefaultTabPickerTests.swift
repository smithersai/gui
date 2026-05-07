import XCTest
@testable import SmithersGUI

final class DefaultTabPickerTests: XCTestCase {

    // MARK: - Task node: finished states

    func testFinishedWithOutput() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "finished", hasOutput: true, hasDiff: true, hasLogs: true
        )
        XCTAssertEqual(tab, .output)
    }

    func testFinishedNoOutputWithDiff() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "finished", hasOutput: false, hasDiff: true, hasLogs: true
        )
        XCTAssertEqual(tab, .diff)
    }

    func testFinishedNoOutputNoDiff() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "finished", hasOutput: false, hasDiff: false, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }

    func testFinishedNoOutputNoDiffNoLogs() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "finished", hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertEqual(tab, .logs)
    }

    // MARK: - Task node: running states

    func testRunningAlwaysLogs() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "running", hasOutput: true, hasDiff: true, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }

    func testRunningNoData() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "running", hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertEqual(tab, .logs)
    }

    // MARK: - Task node: failed states

    func testFailedWithOutput() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "failed", hasOutput: true, hasDiff: false, hasLogs: true
        )
        XCTAssertEqual(tab, .output)
    }

    func testFailedNoOutput() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "failed", hasOutput: false, hasDiff: true, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }

    // MARK: - Task node: pending state

    func testPending() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "pending", hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertEqual(tab, .logs)
    }

    func testNilStateDefaultsPending() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: nil, hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertEqual(tab, .logs)
    }

    // MARK: - Non-task nodes

    func testWorkflowReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .workflow, state: "running", hasOutput: true, hasDiff: true, hasLogs: true
        )
        XCTAssertNil(tab)
    }

    func testSequenceReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .sequence, state: "finished", hasOutput: true, hasDiff: false, hasLogs: false
        )
        XCTAssertNil(tab)
    }

    func testParallelReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .parallel, state: "running", hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertNil(tab)
    }

    func testForEachReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .forEach, state: "finished", hasOutput: true, hasDiff: true, hasLogs: true
        )
        XCTAssertNil(tab)
    }

    func testConditionalReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .conditional, state: nil, hasOutput: false, hasDiff: false, hasLogs: false
        )
        XCTAssertNil(tab)
    }

    func testUnknownReturnsNil() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .unknown, state: "running", hasOutput: true, hasDiff: true, hasLogs: true
        )
        XCTAssertNil(tab)
    }

    // MARK: - Edge: exotic state strings

    func testBlockedState() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "blocked", hasOutput: false, hasDiff: false, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }

    func testWaitingApprovalState() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "waitingApproval", hasOutput: false, hasDiff: false, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }

    func testCancelledState() {
        let tab = DefaultTabPicker.pickDefault(
            nodeType: .task, state: "cancelled", hasOutput: false, hasDiff: false, hasLogs: true
        )
        XCTAssertEqual(tab, .logs)
    }
}
