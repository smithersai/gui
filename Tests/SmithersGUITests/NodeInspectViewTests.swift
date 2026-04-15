import XCTest
import ViewInspector
@testable import SmithersGUI

extension NodeInspectView: @retroactive Inspectable {}

@MainActor
final class NodeInspectViewTests: XCTestCase {
    private func makeTask(
        nodeId: String = "node-build",
        label: String? = "Build",
        iteration: Int? = 2,
        state: String = "running",
        lastAttempt: Int? = 3,
        updatedAtMs: Int64? = 1_700_000_000_000
    ) -> RunTask {
        RunTask(
            nodeId: nodeId,
            label: label,
            iteration: iteration,
            state: state,
            lastAttempt: lastAttempt,
            updatedAtMs: updatedAtMs
        )
    }

    func testNodeInspectViewRendersTaskMetadata() throws {
        let view = NodeInspectView(
            runId: "run-1234567890",
            task: makeTask()
        )
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Node Inspector"))
        XCTAssertNoThrow(try inspected.find(text: "run-1234 · Build"))
        XCTAssertNoThrow(try inspected.find(text: "Label"))
        XCTAssertNoThrow(try inspected.find(text: "Build"))
        XCTAssertNoThrow(try inspected.find(text: "ID"))
        XCTAssertNoThrow(try inspected.find(text: "node-build"))
        XCTAssertNoThrow(try inspected.find(text: "RUNNING"))
        XCTAssertNoThrow(try inspected.find(text: "Iteration"))
        XCTAssertNoThrow(try inspected.find(text: "2"))
        XCTAssertNoThrow(try inspected.find(text: "Attempt"))
        XCTAssertNoThrow(try inspected.find(text: "#3"))
        XCTAssertNoThrow(try inspected.find(text: "Run ID"))
        XCTAssertNoThrow(try inspected.find(text: "run-1234567890"))
    }

    func testNodeInspectViewFallsBackToNodeIDAndMissingTimingPlaceholders() throws {
        let view = NodeInspectView(
            runId: "abcdefghijk",
            task: makeTask(
                nodeId: "node-test",
                label: nil,
                iteration: nil,
                state: "waiting-approval",
                lastAttempt: nil,
                updatedAtMs: nil
            )
        )
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "abcdefgh · node-test"))
        XCTAssertNoThrow(try inspected.find(text: "WAITING APPROVAL"))
        XCTAssertNoThrow(try inspected.find(text: "-"))
    }

    func testChatButtonClosesBeforeOpeningLiveChat() throws {
        var events: [String] = []
        let view = NodeInspectView(
            runId: "run-abc",
            task: makeTask(nodeId: "node-a"),
            onOpenLiveChat: { runId, nodeId in
                events.append("chat:\(runId):\(nodeId ?? "nil")")
            },
            onClose: {
                events.append("close")
            }
        )

        try view.inspect().find(button: "Chat").tap()
        XCTAssertEqual(events, ["close"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(events, ["close", "chat:run-abc:node-a"])
    }

    func testSnapshotsButtonClosesBeforeOpeningSnapshots() throws {
        var events: [String] = []
        let view = NodeInspectView(
            runId: "run-abc",
            task: makeTask(nodeId: "node-a"),
            onOpenSnapshots: { nodeId in
                events.append("snapshots:\(nodeId ?? "nil")")
            },
            onClose: {
                events.append("close")
            }
        )

        try view.inspect().find(button: "Snapshots").tap()
        XCTAssertEqual(events, ["close"])

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(events, ["close", "snapshots:node-a"])
    }
}
