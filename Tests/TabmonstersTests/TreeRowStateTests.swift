import XCTest
@testable import SmithersGUI

final class TreeRowStateTests: XCTestCase {

    // MARK: - Enum Exhaustiveness

    func testAllCasesHaveColor() {
        for state in TaskExecutionState.allCases {
            XCTAssertNotNil(state.color, "Missing color for \(state)")
        }
    }

    func testAllCasesHaveIcon() {
        for state in TaskExecutionState.allCases {
            XCTAssertFalse(state.icon.isEmpty, "Missing icon for \(state)")
        }
    }

    func testAllCasesHaveLabel() {
        for state in TaskExecutionState.allCases {
            XCTAssertFalse(state.label.isEmpty, "Missing label for \(state)")
        }
    }

    // MARK: - Specific State Properties

    func testFailedState() {
        let state = TaskExecutionState.failed
        XCTAssertTrue(state.isFailed)
        XCTAssertFalse(state.isStrikethrough)
        XCTAssertFalse(state.shouldPulse)
    }

    func testRunningState() {
        let state = TaskExecutionState.running
        XCTAssertFalse(state.isFailed)
        XCTAssertTrue(state.shouldPulse)
        XCTAssertFalse(state.isStrikethrough)
    }

    func testCancelledState() {
        let state = TaskExecutionState.cancelled
        XCTAssertTrue(state.isStrikethrough)
        XCTAssertFalse(state.isFailed)
        XCTAssertFalse(state.shouldPulse)
    }

    func testPendingState() {
        let state = TaskExecutionState.pending
        XCTAssertFalse(state.isFailed)
        XCTAssertFalse(state.shouldPulse)
        XCTAssertFalse(state.isStrikethrough)
    }

    func testFinishedState() {
        let state = TaskExecutionState.finished
        XCTAssertFalse(state.isFailed)
        XCTAssertFalse(state.shouldPulse)
        XCTAssertFalse(state.isStrikethrough)
    }

    func testBlockedState() {
        let state = TaskExecutionState.blocked
        XCTAssertFalse(state.isFailed)
        XCTAssertFalse(state.shouldPulse)
    }

    func testWaitingApprovalState() {
        let state = TaskExecutionState.waitingApproval
        XCTAssertFalse(state.isFailed)
        XCTAssertFalse(state.shouldPulse)
    }

    func testOnlyFailedHasRedRowBackground() {
        for state in TaskExecutionState.allCases {
            if state == .failed {
                XCTAssertNotEqual(state.rowBackground, .clear, "Failed should have non-clear row bg")
            } else {
                XCTAssertEqual(state.rowBackground, .clear, "\(state) should have clear row bg")
            }
        }
    }

    func testOnlyRunningPulses() {
        for state in TaskExecutionState.allCases {
            if state == .running {
                XCTAssertTrue(state.shouldPulse)
            } else {
                XCTAssertFalse(state.shouldPulse, "\(state) should not pulse")
            }
        }
    }

    func testOnlyCancelledHasStrikethrough() {
        for state in TaskExecutionState.allCases {
            if state == .cancelled {
                XCTAssertTrue(state.isStrikethrough)
            } else {
                XCTAssertFalse(state.isStrikethrough, "\(state) should not be strikethrough")
            }
        }
    }

    // MARK: - Extract State

    func testExtractStateFromProps() {
        let node = DevToolsNode(id: 1, type: .task, name: "Test", props: ["state": .string("running")])
        XCTAssertEqual(extractState(from: node), .running)
    }

    func testExtractStateUnknown() {
        let node = DevToolsNode(id: 1, type: .task, name: "Test", props: ["state": .string("somethingElse")])
        XCTAssertEqual(extractState(from: node), .unknown)
    }

    func testExtractStateWaitingApprovalWithHyphenatedValue() {
        let node = DevToolsNode(id: 1, type: .task, name: "Test", props: ["state": .string("waiting-approval")])
        XCTAssertEqual(extractState(from: node), .waitingApproval)
    }

    func testExtractStateMissing() {
        let node = DevToolsNode(id: 1, type: .task, name: "Test", props: [:])
        XCTAssertEqual(extractState(from: node), .unknown)
    }

    func testExtractStateNonString() {
        let node = DevToolsNode(id: 1, type: .task, name: "Test", props: ["state": .number(42)])
        XCTAssertEqual(extractState(from: node), .unknown)
    }

    func testExtractAllStates() {
        for state in TaskExecutionState.allCases where state != .unknown {
            let node = DevToolsNode(id: 1, type: .task, name: "Test", props: ["state": .string(state.rawValue)])
            XCTAssertEqual(extractState(from: node), state, "Failed to extract \(state.rawValue)")
        }
    }

    // MARK: - Key Props Summary

    func testKeyPropsSummaryWithTaskInfo() {
        let task = DevToolsTaskInfo(nodeId: "task:review:0", kind: "agent", agent: "claude-opus-4-7", label: "Review PR", outputTableName: nil, iteration: 2)
        let node = DevToolsNode(id: 1, type: .task, name: "Task", task: task)
        let summary = keyPropsSummary(for: node)
        XCTAssertTrue(summary.contains("Review PR"))
        XCTAssertTrue(summary.contains("claude-opus-4-7"))
        XCTAssertTrue(summary.contains("iter=2"))
    }

    func testKeyPropsSummaryWithNameProp() {
        let node = DevToolsNode(id: 1, type: .workflow, name: "Workflow", props: ["name": .string("reviewer")])
        let summary = keyPropsSummary(for: node)
        XCTAssertTrue(summary.contains("name=\"reviewer\""))
    }

    func testKeyPropsSummaryEmpty() {
        let node = DevToolsNode(id: 1, type: .sequence, name: "Sequence")
        let summary = keyPropsSummary(for: node)
        XCTAssertTrue(summary.isEmpty)
    }

    func testKeyPropsSummaryTruncation() {
        let longLabel = String(repeating: "a", count: 200)
        let task = DevToolsTaskInfo(nodeId: "t:0", kind: "agent", agent: nil, label: longLabel, outputTableName: nil, iteration: nil)
        let node = DevToolsNode(id: 1, type: .task, name: "Task", task: task)
        let summary = keyPropsSummary(for: node, maxLength: 120)
        XCTAssertLessThanOrEqual(summary.count, 120)
        XCTAssertTrue(summary.hasSuffix("…"))
    }

    func testKeyPropsSummaryIdProp() {
        let node = DevToolsNode(id: 1, type: .task, name: "Task", props: ["id": .string("fetch")])
        let summary = keyPropsSummary(for: node)
        XCTAssertTrue(summary.contains("id=\"fetch\""))
    }

    func testKeyPropsSummaryIterationZeroOmitted() {
        let task = DevToolsTaskInfo(nodeId: "t:0", kind: "agent", agent: nil, label: nil, outputTableName: nil, iteration: 0)
        let node = DevToolsNode(id: 1, type: .task, name: "Task", task: task)
        let summary = keyPropsSummary(for: node)
        XCTAssertFalse(summary.contains("iter="))
    }

    func testNodeTypeIconCoverage() {
        let coveredIcons = [
            nodeTypeIcon(for: .workflow),
            nodeTypeIcon(for: .sequence),
            nodeTypeIcon(for: .parallel),
            nodeTypeIcon(for: .task),
            nodeTypeIcon(for: .approval),
            nodeTypeIcon(for: .unknown),
        ]
        XCTAssertTrue(coveredIcons.allSatisfy { !$0.isEmpty })
    }
}
