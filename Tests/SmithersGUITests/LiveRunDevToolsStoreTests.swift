import XCTest
@testable import SmithersGUI

// MARK: - Mock Stream Provider

final class MockDevToolsStreamProvider: DevToolsStreamProvider, @unchecked Sendable {
    var events: [DevToolsEvent] = []
    var snapshotToReturn: DevToolsSnapshot?
    var jumpResultToReturn = DevToolsJumpResult(
        ok: true,
        newFrameNo: 0,
        revertedSandboxes: 1,
        deletedFrames: 1,
        deletedAttempts: 1,
        invalidatedDiffs: 1,
        durationMs: 10
    )
    var streamError: Error?
    var snapshotError: Error?
    var jumpError: Error?
    var jumpDelayNs: UInt64 = 0
    var streamCallCount = 0
    var snapshotCallCount = 0
    var jumpCallCount = 0
    var lastFromSeq: Int?
    var lastJumpFrameNo: Int?
    var lastJumpConfirm: Bool?

    func streamDevTools(runId: String, fromSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        streamCallCount += 1
        lastFromSeq = fromSeq
        let capturedEvents = events
        let capturedError = streamError
        return AsyncThrowingStream { continuation in
            Task {
                if let error = capturedError {
                    continuation.finish(throwing: error)
                    return
                }
                for event in capturedEvents {
                    continuation.yield(event)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                continuation.finish()
            }
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot {
        snapshotCallCount += 1
        if let error = snapshotError {
            throw error
        }
        guard let snapshot = snapshotToReturn else {
            throw DevToolsClientError.runNotFound(runId)
        }
        return snapshot
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        jumpCallCount += 1
        lastJumpFrameNo = frameNo
        lastJumpConfirm = confirm
        if jumpDelayNs > 0 {
            try? await Task.sleep(nanoseconds: jumpDelayNs)
        }
        if let jumpError {
            throw jumpError
        }
        return jumpResultToReturn
    }
}

// MARK: - Helpers

private func makeNode(
    id: Int, type: SmithersNodeType = .task, name: String = "node",
    props: [String: JSONValue] = [:], task: DevToolsTaskInfo? = nil,
    children: [DevToolsNode] = [], depth: Int = 0
) -> DevToolsNode {
    DevToolsNode(id: id, type: type, name: name, props: props, task: task, children: children, depth: depth)
}

private func makeSnapshot(
    runId: String = "run_test", frameNo: Int = 1, seq: Int = 1,
    root: DevToolsNode? = nil
) -> DevToolsSnapshot {
    DevToolsSnapshot(
        runId: runId, frameNo: frameNo, seq: seq,
        root: root ?? makeNode(id: 0, type: .workflow, name: "root")
    )
}

// MARK: - Store Tests

@MainActor
final class LiveRunDevToolsStoreTests: XCTestCase {

    // MARK: - Snapshot handling

    func testSnapshotReplacesTree() {
        let store = LiveRunDevToolsStore()
        let root = makeNode(id: 1, type: .workflow, name: "wf")
        let snapshot = makeSnapshot(seq: 1, root: root)
        store.runId = "run_test"
        store.applyEvent(.snapshot(snapshot))

        XCTAssertEqual(store.tree?.id, 1)
        XCTAssertEqual(store.tree?.name, "wf")
        XCTAssertEqual(store.seq, 1)
    }

    func testSnapshotUpdatesSeq() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        store.applyEvent(.snapshot(makeSnapshot(seq: 5)))
        XCTAssertEqual(store.seq, 5)
    }

    func testDuplicateSnapshotSeqIgnored() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root1 = makeNode(id: 1, type: .workflow, name: "first")
        store.applyEvent(.snapshot(makeSnapshot(seq: 5, root: root1)))

        let root2 = makeNode(id: 2, type: .workflow, name: "second")
        store.applyEvent(.snapshot(makeSnapshot(seq: 5, root: root2)))

        XCTAssertEqual(store.tree?.name, "first", "Duplicate seq should be ignored")
    }

    func testSnapshotMismatchedRunIdDisconnects() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_a"
        let snapshot = DevToolsSnapshot(
            runId: "run_b", frameNo: 1, seq: 1,
            root: makeNode(id: 1, type: .workflow, name: "wrong")
        )
        store.applySnapshot(snapshot)
        XCTAssertNil(store.runId, "Mismatched runId should trigger disconnect")
    }

    // MARK: - Delta handling

    func testDeltaAppliesOps() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, type: .workflow, name: "wf")
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        let delta = DevToolsDelta(baseSeq: 1, seq: 2, ops: [
            .addNode(parentId: 1, index: 0, node: makeNode(id: 2, name: "child"))
        ])
        store.applyEvent(.delta(delta))

        XCTAssertEqual(store.tree?.children.count, 1)
        XCTAssertEqual(store.tree?.children[0].name, "child")
        XCTAssertEqual(store.seq, 2)
    }

    func testBackwardsSeqDeltaIgnored() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        store.applyEvent(.snapshot(makeSnapshot(seq: 10)))

        let delta = DevToolsDelta(baseSeq: 5, seq: 8, ops: [
            .addNode(parentId: 0, index: 0, node: makeNode(id: 99))
        ])
        store.applyDeltaEvent(delta)

        XCTAssertEqual(store.seq, 10, "Backwards seq should be ignored")
        XCTAssertTrue(store.tree?.children.isEmpty ?? true)
    }

    func testLargeSeqGapTriggersResync() {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")

        let root = makeNode(id: 1, type: .workflow, name: "wf")
        store.applyEvent(.snapshot(makeSnapshot(seq: 10, root: root)))

        let delta = DevToolsDelta(baseSeq: 1010, seq: 1011, ops: [
            .addNode(parentId: 1, index: 0, node: makeNode(id: 99))
        ])
        store.applyDeltaEvent(delta)

        XCTAssertEqual(store.seq, 10, "Large seq gap should not apply delta")
        XCTAssertTrue(store.tree?.children.isEmpty ?? true, "Tree should be unchanged after resync request")
    }

    // MARK: - Ghost state

    func testSelectNodeSetsSelectedNodeId() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)
        XCTAssertEqual(store.selectedNodeId, 2)
        XCTAssertFalse(store.isGhost)
    }

    func testGhostWhenSelectedNodeRemoved() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)
        XCTAssertFalse(store.isGhost)

        let newRoot = makeNode(id: 1)
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: newRoot)))

        XCTAssertTrue(store.isGhost)
        XCTAssertNotNil(store.selectedNode, "Ghost node should still be accessible")
    }

    func testGhostClearsOnReselectLiveNode() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2), makeNode(id: 3)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)
        let newRoot = makeNode(id: 1, children: [makeNode(id: 3)])
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: newRoot)))
        XCTAssertTrue(store.isGhost)

        store.selectNode(3)
        XCTAssertFalse(store.isGhost)
    }

    func testGhostAutoClears() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)

        let emptyRoot = makeNode(id: 1)
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: emptyRoot)))
        XCTAssertTrue(store.isGhost)

        let restored = makeNode(id: 1, children: [makeNode(id: 2, name: "back")])
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 3, seq: 3, root: restored)))
        XCTAssertFalse(store.isGhost, "Ghost should auto-clear when node reappears")
    }

    func testDeselectClearsGhost() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)
        let emptyRoot = makeNode(id: 1)
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: emptyRoot)))
        XCTAssertTrue(store.isGhost)

        store.selectNode(nil)
        XCTAssertFalse(store.isGhost)
    }

    func testNodeStillExistsNotGhost() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)

        let updatedRoot = makeNode(id: 1, children: [makeNode(id: 2, name: "updated")])
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: updatedRoot)))
        XCTAssertFalse(store.isGhost, "Node still exists, should not be ghost")
    }

    // MARK: - Events applied counter

    func testEventsAppliedCounter() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        XCTAssertEqual(store.eventsApplied, 0)

        store.applyEvent(.snapshot(makeSnapshot(seq: 1)))
        XCTAssertEqual(store.eventsApplied, 1)

        let delta = DevToolsDelta(baseSeq: 1, seq: 2, ops: [])
        store.applyEvent(.delta(delta))
        XCTAssertEqual(store.eventsApplied, 2)
    }

    // MARK: - lastEventAt

    func testLastEventAtUpdated() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        XCTAssertNil(store.lastEventAt)

        store.applyEvent(.snapshot(makeSnapshot(seq: 1)))
        XCTAssertNotNil(store.lastEventAt)
    }

    // MARK: - heartbeatAgeMs

    func testHeartbeatAgeMsMaxWhenNoEvents() {
        let store = LiveRunDevToolsStore()
        XCTAssertEqual(store.heartbeatAgeMs, Int.max)
    }

    func testHeartbeatAgeMsAfterEvent() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        store.applyEvent(.snapshot(makeSnapshot(seq: 1)))
        XCTAssertLessThan(store.heartbeatAgeMs, 1000)
    }

    // MARK: - Connection state

    func testInitialConnectionStateDisconnected() {
        let store = LiveRunDevToolsStore()
        XCTAssertEqual(store.connectionState, .disconnected)
    }

    func testConnectSetsConnecting() {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        XCTAssertEqual(store.connectionState, .connecting)
    }

    func testDisconnectSetsDisconnected() {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        store.disconnect()
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNil(store.runId)
    }

    func testDoubleConnectCancelsFirst() {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.connect(runId: "run_a")
        store.connect(runId: "run_b")
        XCTAssertEqual(store.runId, "run_b")
    }

    // MARK: - Concurrency annotations

    func testStoreIsMainActor() {
        let store = LiveRunDevToolsStore()
        XCTAssertNotNil(store, "Store should be constructible on @MainActor")
    }

    // MARK: - selectedNode property

    func testSelectedNodeReturnsNodeFromTree() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let child = makeNode(id: 2, name: "target")
        let root = makeNode(id: 1, children: [child])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)
        XCTAssertEqual(store.selectedNode?.name, "target")
    }

    func testSelectedNodeReturnsGhostWhenRemoved() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let root = makeNode(id: 1, children: [makeNode(id: 2, name: "will-vanish")])
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        store.selectNode(2)

        let emptyRoot = makeNode(id: 1)
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "run_test", frameNo: 2, seq: 2, root: emptyRoot)))

        XCTAssertTrue(store.isGhost)
        XCTAssertEqual(store.selectedNode?.name, "will-vanish")
    }

    func testSelectedNodeNilWhenNothingSelected() {
        let store = LiveRunDevToolsStore()
        XCTAssertNil(store.selectedNode)
    }
}
