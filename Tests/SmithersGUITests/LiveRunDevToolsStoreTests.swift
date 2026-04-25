import XCTest
@testable import SmithersGUI

// MARK: - Mock Stream Provider

@MainActor
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
    var lastAfterSeq: Int?
    var streamCalls: [(runId: String, afterSeq: Int?)] = []
    var lastJumpFrameNo: Int?
    var lastJumpConfirm: Bool?

    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        streamCallCount += 1
        lastAfterSeq = afterSeq
        streamCalls.append((runId, afterSeq))
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

@MainActor
private final class ReconnectFixtureStreamProvider: DevToolsStreamProvider, @unchecked Sendable {
    var streamCalls: [(runId: String, afterSeq: Int?)] = []

    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        streamCalls.append((runId, afterSeq))
        let attempt = streamCalls.count

        return AsyncThrowingStream { continuation in
            let task = Task {
                switch attempt {
                case 1:
                    let root = makeNode(id: 1, type: .workflow, name: "wf")
                    continuation.yield(.snapshot(makeSnapshot(runId: runId, frameNo: 1, seq: 1, root: root)))
                    continuation.yield(.delta(DevToolsDelta(
                        baseSeq: 1,
                        seq: 2,
                        ops: [.addNode(parentId: 1, index: 0, node: makeNode(id: 2, name: "first"))]
                    )))
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                default:
                    continuation.yield(.delta(DevToolsDelta(
                        baseSeq: 2,
                        seq: 3,
                        ops: [.addNode(parentId: 1, index: 1, node: makeNode(id: 3, name: "second"))]
                    )))
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot {
        throw DevToolsClientError.runNotFound(runId)
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        throw DevToolsClientError.runNotFound(runId)
    }
}

// MARK: - Helpers

private func makeNode(
    id: Int, type: SmithersNodeType = .task, name: String = "node",
    props: [String: JSONValue] = [:], task: DevToolsTaskInfo? = nil,
    children: [DevToolsNode] = [], depth: Int = 0
) -> DevToolsNode {
    let effectiveTask: DevToolsTaskInfo?
    if let task {
        effectiveTask = task
    } else if type == .task {
        effectiveTask = DevToolsTaskInfo(
            nodeId: "task:\(id)",
            kind: "agent",
            agent: nil,
            label: nil,
            outputTableName: nil,
            iteration: nil
        )
    } else {
        effectiveTask = nil
    }
    return DevToolsNode(
        id: id,
        type: type,
        name: name,
        props: props,
        task: effectiveTask,
        children: children,
        depth: depth
    )
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

    func testGapResyncDiscardsDeltaPatchingUntilSnapshotArrives() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"
        let originalRoot = makeNode(
            id: 1,
            type: .workflow,
            children: [makeNode(id: 2, name: "before")]
        )
        store.applyEvent(.snapshot(makeSnapshot(seq: 10, root: originalRoot)))

        store.applyEvent(.gapResync(DevToolsGapResync(fromSeq: 10, toSeq: 20)))

        let ignoredDelta = DevToolsDelta(baseSeq: 20, seq: 21, ops: [
            .addNode(parentId: 1, index: 1, node: makeNode(id: 3, name: "ignored"))
        ])
        store.applyEvent(.delta(ignoredDelta))
        XCTAssertNil(store.tree?.findNode(byId: 3), "Deltas should be ignored until the follow-up snapshot")

        let replacementRoot = makeNode(
            id: 1,
            type: .workflow,
            children: [makeNode(id: 4, name: "after-resync")]
        )
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 2, seq: 21, root: replacementRoot)))
        XCTAssertEqual(store.tree?.children.first?.id, 4)
        XCTAssertEqual(store.seq, 21)
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
        XCTAssertTrue(store.ghostNodes.isEmpty, "Ghost map entry should be removed once node is active again")
        XCTAssertFalse(store.isGhostNode(restored.children[0]))
    }

    func testGhostEvictionHonorsConfiguredCap() {
        let store = LiveRunDevToolsStore(ghostNodeCap: 1)
        store.runId = "run_test"

        let initialRoot = makeNode(
            id: 1,
            type: .workflow,
            children: [
                makeNode(id: 2, name: "first"),
                makeNode(id: 3, name: "second"),
            ]
        )
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 1, seq: 1, root: initialRoot)))

        let emptyRoot = makeNode(id: 1, type: .workflow, children: [])
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 2, seq: 2, root: emptyRoot)))

        XCTAssertEqual(store.ghostNodes.count, 1)
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

    func testIntegrationFixtureStreamAppliesLiveUpdates() async {
        let provider = MockDevToolsStreamProvider()
        let initialRoot = makeNode(id: 1, type: .workflow, children: [])
        provider.events = [
            .snapshot(makeSnapshot(runId: "run_test", frameNo: 1, seq: 1, root: initialRoot)),
            .delta(
                DevToolsDelta(
                    baseSeq: 1,
                    seq: 2,
                    ops: [.addNode(parentId: 1, index: 0, node: makeNode(id: 2, name: "live-child"))]
                )
            ),
        ]

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        try? await Task.sleep(nanoseconds: 40_000_000)

        XCTAssertEqual(store.connectionState, .streaming)
        XCTAssertEqual(store.seq, 2)
        XCTAssertEqual(store.tree?.findNode(byId: 2)?.name, "live-child")
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

    func testReconnectUsesStoredCursorPerRun() async {
        let provider = MockDevToolsStreamProvider()
        provider.events = [.snapshot(makeSnapshot(runId: "run_test", frameNo: 1, seq: 9))]
        let store = LiveRunDevToolsStore(streamProvider: provider)

        store.connect(runId: "run_test")
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.disconnect()

        provider.events = []
        store.connect(runId: "run_test")

        XCTAssertEqual(provider.lastAfterSeq, 9)
    }

    func testReconnectAfterMidStreamDropReplaysMissingDeltas() async {
        let provider = ReconnectFixtureStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        defer { store.disconnect() }

        store.connect(runId: "run_test")
        try? await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertGreaterThanOrEqual(provider.streamCalls.count, 2)
        XCTAssertNil(provider.streamCalls[0].afterSeq)
        XCTAssertEqual(provider.streamCalls[1].afterSeq, 2)
        XCTAssertEqual(store.seq, 3)
        XCTAssertEqual(store.tree?.children.map(\.name), ["first", "second"])
    }

    func testSwitchingBackToRunRequestsFreshSnapshotAfterTreeReset() async {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)

        provider.events = [.snapshot(makeSnapshot(runId: "run_a", frameNo: 1, seq: 9))]
        store.connect(runId: "run_a")
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.disconnect()

        provider.events = [.snapshot(makeSnapshot(runId: "run_b", frameNo: 1, seq: 3))]
        store.connect(runId: "run_b")
        try? await Task.sleep(nanoseconds: 20_000_000)
        store.disconnect()

        provider.events = []
        store.connect(runId: "run_a")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(provider.streamCalls.last?.runId, "run_a")
        XCTAssertNil(provider.streamCalls.last?.afterSeq)
    }

    func testRewindPastGhostMountClearsGhostEntry() async {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run_test"

        let mountedRoot = makeNode(
            id: 1,
            type: .workflow,
            children: [makeNode(id: 2, name: "selected")]
        )
        let unmountedRoot = makeNode(id: 1, type: .workflow, children: [])
        store.applyEvent(.snapshot(makeSnapshot(runId: "run_test", frameNo: 10, seq: 10, root: mountedRoot)))
        store.selectNode(2)
        store.applyEvent(.snapshot(makeSnapshot(runId: "run_test", frameNo: 11, seq: 11, root: unmountedRoot)))
        XCTAssertTrue(store.isGhost)
        XCTAssertEqual(store.selectedGhostRecord?.mountedFrameNo, 10)

        provider.snapshotToReturn = makeSnapshot(runId: "run_test", frameNo: 5, seq: 12, root: mountedRoot)
        await store.scrubTo(frameNo: 5)
        provider.snapshotToReturn = makeSnapshot(runId: "run_test", frameNo: 5, seq: 13, root: unmountedRoot)
        await store.rewind(to: 5, confirm: true)

        XCTAssertTrue(store.ghostNodes.isEmpty, "Ghost entries mounted after rewind target should be cleared")
        XCTAssertFalse(store.isGhost)
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

    // MARK: - Running-node tracking (historical scrubber cursor)

    func testRunningNodeCountReflectsRunningLeafTasks() {
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"

        let runningTask = makeNode(
            id: 2, type: .task, name: "Task",
            props: ["state": .string("running")],
            task: DevToolsTaskInfo(
                nodeId: "alpha", kind: "agent",
                agent: nil, label: nil, outputTableName: nil, iteration: nil
            )
        )
        let finishedTask = makeNode(
            id: 3, type: .task, name: "Task",
            props: ["state": .string("finished")],
            task: DevToolsTaskInfo(
                nodeId: "beta", kind: "agent",
                agent: nil, label: nil, outputTableName: nil, iteration: nil
            )
        )
        let pendingTask = makeNode(
            id: 4, type: .task, name: "Task",
            props: ["state": .string("pending")],
            task: DevToolsTaskInfo(
                nodeId: "gamma", kind: "agent",
                agent: nil, label: nil, outputTableName: nil, iteration: nil
            )
        )
        let root = makeNode(
            id: 1, type: .workflow, name: "wf",
            props: ["state": .string("running")],
            children: [runningTask, finishedTask, pendingTask]
        )
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        XCTAssertEqual(store.runningNodeCount, 1, "only the running leaf task counts")
        XCTAssertEqual(store.runningNodeIds, ["alpha"])
    }

    func testRunningNodeCountIgnoresStructuralParents() {
        // A sequence node with state="running" (from rollup) but no task payload
        // should NOT contribute to the count — only leaf tasks do.
        let store = LiveRunDevToolsStore()
        store.runId = "run_test"

        let task = makeNode(
            id: 3, type: .task, name: "Task",
            props: ["state": .string("finished")],
            task: DevToolsTaskInfo(
                nodeId: "only", kind: "agent",
                agent: nil, label: nil, outputTableName: nil, iteration: nil
            )
        )
        let sequence = makeNode(
            id: 2, type: .sequence, name: "Sequence",
            props: ["state": .string("running")],  // rollup value; NOT a leaf task
            children: [task]
        )
        let root = makeNode(
            id: 1, type: .workflow, name: "wf",
            props: ["state": .string("running")],
            children: [sequence]
        )
        store.applyEvent(.snapshot(makeSnapshot(seq: 1, root: root)))

        XCTAssertEqual(store.runningNodeCount, 0,
            "sequence/workflow rollup state must not inflate the running-task count"
        )
        XCTAssertEqual(store.runningNodeIds, [])
    }

    func testRunningNodeCountUpdatesOnHistoricalScrub() async {
        // Frame 1: task in running state. Frame 2: task finished. The store should
        // expose runningNodeCount=1 for frame 1 and 0 for frame 2.
        let runningRoot = makeNode(
            id: 1, type: .workflow, name: "wf",
            props: ["state": .string("running")],
            children: [makeNode(
                id: 2, type: .task, name: "Task",
                props: ["state": .string("running")],
                task: DevToolsTaskInfo(
                    nodeId: "alpha", kind: "agent",
                    agent: nil, label: nil, outputTableName: nil, iteration: nil
                )
            )]
        )
        let finishedRoot = makeNode(
            id: 1, type: .workflow, name: "wf",
            props: ["state": .string("finished")],
            children: [makeNode(
                id: 2, type: .task, name: "Task",
                props: ["state": .string("finished")],
                task: DevToolsTaskInfo(
                    nodeId: "alpha", kind: "agent",
                    agent: nil, label: nil, outputTableName: nil, iteration: nil
                )
            )]
        )

        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run_test"

        // Live state = frame 2 (finished). Simulate a live snapshot arriving so the
        // store knows latestFrameNo=2.
        store.applyEvent(.snapshot(DevToolsSnapshot(
            runId: "run_test", frameNo: 2, seq: 2, root: finishedRoot
        )))
        XCTAssertEqual(store.runningNodeCount, 0, "live: task finished")

        // Now scrub to frame 1 (running). The provider returns a running snapshot.
        provider.snapshotToReturn = DevToolsSnapshot(
            runId: "run_test", frameNo: 1, seq: 1, root: runningRoot
        )
        await store.scrubTo(frameNo: 1)

        XCTAssertTrue(store.mode.isHistorical, "should be in historical mode after scrub")
        XCTAssertEqual(store.runningNodeCount, 1, "historical frame 1: task running")
        XCTAssertEqual(store.runningNodeIds, ["alpha"])
    }
}
