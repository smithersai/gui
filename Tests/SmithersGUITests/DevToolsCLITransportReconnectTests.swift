import XCTest
@testable import SmithersGUI

// MARK: - File-level docs
//
// The user-facing target was `DevToolsCLITransport.swift`, but that file is a
// collection of pure data helpers (validators, SQL helpers, XML decoding,
// frame applier, tree builder). It contains no networking, no reconnect logic,
// no streaming state machine. The actual transport behaviour the brief asks
// about — reconnect-with-backoff, snapshot/delta interleave, frame-jump races,
// in-flight cancellation — lives in `DevToolsStore` (Runtime/DevToolsStore.swift)
// behind the `DevToolsStreamProvider` injection point.
//
// This file exercises that real surface via the public API. Tests construct a
// `DevToolsStore` with a fake `DevToolsStreamProvider` and assert the documented
// invariants. The transport-style file naming is preserved so the test file
// matches the brief's filename even though the system under test is logically
// the store + its provider boundary.
//
// Documented untestable code paths (no production injection points):
//   - Real wall-clock backoff timing. `ReconnectBackoff` is unit-tested in
//     `ReconnectBackoffTests.swift`. Here we observe its *behaviour* (more than
//     one stream call, increasing afterSeq cursor) without asserting absolute
//     timings — `Task.sleep` cannot be substituted without a clock injection
//     point. Tests use real (small) sleeps to allow the actor task to step.
//   - There is **no max-retry exhaustion / permanent-error state**. The store
//     reconnects forever with backoff capped at 30 s. A test below documents
//     this as an explicit invariant ("infinite retries"); if the product
//     introduces a retry cap later, that test should flip to assert the new
//     terminal error state.
//   - `getDevToolsSnapshot` cancellation on disconnect cannot be observed
//     deterministically through the `MainActor`-isolated public API; the test
//     here asserts the store ends in `.disconnected` and that the in-flight
//     fetch's eventual result does not corrupt state.

// MARK: - Test fakes

/// Fake stream provider with first-class control over per-attempt behaviour.
/// Each entry in `scripts` is consumed by successive `streamDevTools` invocations,
/// so a single test can script the contents of attempt 1, attempt 2, etc.
@MainActor
private final class ScriptedStreamProvider: DevToolsStreamProvider, @unchecked Sendable {

    enum Script {
        /// Yield events then close the stream cleanly (server-initiated close).
        case yieldThenClose([DevToolsEvent])
        /// Yield events then throw (mid-stream network error).
        case yieldThenThrow([DevToolsEvent], Error)
        /// Throw immediately, no events.
        case throwImmediately(Error)
        /// Yield then keep the stream open until the consumer cancels.
        case yieldThenHold([DevToolsEvent])
    }

    var scripts: [Script] = []
    var streamCalls: [(runId: String, afterSeq: Int?)] = []
    var snapshotCalls: [(runId: String, frameNo: Int?)] = []
    var jumpCalls: [(runId: String, frameNo: Int, confirm: Bool)] = []

    var snapshotsToReturn: [DevToolsSnapshot] = []
    var snapshotErrorsToThrow: [Error] = []
    var snapshotDelayNs: UInt64 = 0
    var jumpResultsToReturn: [DevToolsJumpResult] = []
    var jumpErrorsToThrow: [Error] = []
    var jumpDelayNs: UInt64 = 0

    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        streamCalls.append((runId, afterSeq))
        let attempt = streamCalls.count
        // If we've run out of scripted attempts, hold open so the test can settle.
        let script: Script = attempt <= scripts.count
            ? scripts[attempt - 1]
            : .yieldThenHold([])

        return AsyncThrowingStream { continuation in
            let task = Task {
                switch script {
                case .yieldThenClose(let events):
                    for event in events {
                        continuation.yield(event)
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    continuation.finish()
                case .yieldThenThrow(let events, let error):
                    for event in events {
                        continuation.yield(event)
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    continuation.finish(throwing: error)
                case .throwImmediately(let error):
                    continuation.finish(throwing: error)
                case .yieldThenHold(let events):
                    for event in events {
                        continuation.yield(event)
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
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
        snapshotCalls.append((runId, frameNo))
        if snapshotDelayNs > 0 {
            try? await Task.sleep(nanoseconds: snapshotDelayNs)
        }
        try Task.checkCancellation()
        if !snapshotErrorsToThrow.isEmpty {
            throw snapshotErrorsToThrow.removeFirst()
        }
        guard !snapshotsToReturn.isEmpty else {
            throw DevToolsClientError.runNotFound(runId)
        }
        return snapshotsToReturn.removeFirst()
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        jumpCalls.append((runId, frameNo, confirm))
        if jumpDelayNs > 0 {
            try? await Task.sleep(nanoseconds: jumpDelayNs)
        }
        if !jumpErrorsToThrow.isEmpty {
            throw jumpErrorsToThrow.removeFirst()
        }
        guard !jumpResultsToReturn.isEmpty else {
            return DevToolsJumpResult(
                ok: true, newFrameNo: frameNo, revertedSandboxes: 0,
                deletedFrames: 0, deletedAttempts: 0, invalidatedDiffs: 0,
                durationMs: 0, auditRowId: nil
            )
        }
        return jumpResultsToReturn.removeFirst()
    }
}

// MARK: - Local helpers

private func mkNode(
    id: Int, type: SmithersNodeType = .task, name: String = "node",
    props: [String: JSONValue] = [:], children: [DevToolsNode] = []
) -> DevToolsNode {
    let task: DevToolsTaskInfo? = type == .task
        ? DevToolsTaskInfo(
            nodeId: "task:\(id)", kind: "agent",
            agent: nil, label: nil, outputTableName: nil, iteration: nil
        )
        : nil
    return DevToolsNode(
        id: id, type: type, name: name,
        props: props, task: task, children: children, depth: 0
    )
}

private func mkSnapshot(
    runId: String = "run_test", frameNo: Int = 1, seq: Int = 1,
    root: DevToolsNode? = nil
) -> DevToolsSnapshot {
    DevToolsSnapshot(
        runId: runId, frameNo: frameNo, seq: seq,
        root: root ?? mkNode(id: 1, type: .workflow, name: "wf")
    )
}

private func mkAddDelta(baseSeq: Int, seq: Int, parentId: Int, index: Int, childId: Int, name: String) -> DevToolsDelta {
    DevToolsDelta(
        baseSeq: baseSeq,
        seq: seq,
        ops: [.addNode(parentId: parentId, index: index, node: mkNode(id: childId, name: name))]
    )
}

/// Wait until `predicate()` returns true or the budget elapses. Returns whether
/// the predicate succeeded. Polls in small steps to keep tests responsive.
private func waitFor(
    timeoutMs: Int = 4_000,
    stepMs: Int = 25,
    _ predicate: @Sendable @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
    while Date() < deadline {
        if await MainActor.run(body: predicate) { return true }
        try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
    }
    return false
}

// MARK: - Tests

@MainActor
final class DevToolsCLITransportReconnectTests: XCTestCase {

    // MARK: - Reconnection: server-initiated close

    func testReconnectsAfterServerInitiatedClose() async {
        // Stream 1: yields a snapshot, then closes cleanly. Stream 2: empty hold.
        // The store should reconnect and call streamDevTools again.
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenClose([.snapshot(mkSnapshot(seq: 1, root: root))]),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let reconnected = await waitFor { provider.streamCalls.count >= 2 }
        XCTAssertTrue(reconnected, "Expected at least 2 stream calls after server close")
        XCTAssertGreaterThanOrEqual(store.reconnectCount, 1)
    }

    func testReconnectResumesFromLastSeqCursor() async {
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenClose([
                .snapshot(mkSnapshot(seq: 5, root: root)),
                .delta(mkAddDelta(baseSeq: 5, seq: 6, parentId: 1, index: 0, childId: 2, name: "a")),
            ]),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor { provider.streamCalls.count >= 2 }
        XCTAssertTrue(ok, "Reconnect must occur")
        XCTAssertNil(provider.streamCalls.first?.afterSeq, "First call has no cursor")
        XCTAssertEqual(provider.streamCalls[1].afterSeq, 6, "Reconnect must resume from last applied seq")
    }

    func testReconnectsAfterMidStreamNetworkError() async {
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenThrow(
                [.snapshot(mkSnapshot(seq: 1, root: root))],
                URLError(.networkConnectionLost)
            ),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor { provider.streamCalls.count >= 2 }
        XCTAssertTrue(ok, "Network error mid-stream must trigger reconnect")
        XCTAssertEqual(store.tree?.id, 1, "Snapshot received before error must remain applied")
    }

    func testReconnectAttemptsContinueAcrossMultipleFailures() async {
        // Three failures in a row. Backoff caps at 30 s but the first delays are 1s/2s.
        // We only assert that at least 2 reconnects were attempted within the timeout.
        let provider = ScriptedStreamProvider()
        provider.scripts = [
            .throwImmediately(URLError(.networkConnectionLost)),
            .throwImmediately(URLError(.timedOut)),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        // Wait long enough to clear at least the first 1s backoff.
        let ok = await waitFor(timeoutMs: 4_000) { provider.streamCalls.count >= 2 }
        XCTAssertTrue(ok, "Expected at least one reconnect attempt within the backoff window")
        XCTAssertGreaterThanOrEqual(store.reconnectCount, 1)
    }

    func testReconnectDoesNotOccurAfterDisconnect() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [.throwImmediately(URLError(.networkConnectionLost))]

        let store = DevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        // Give the initial stream a moment to fail.
        try? await Task.sleep(nanoseconds: 100_000_000)
        store.disconnect()

        // Wait past the 1s backoff: there must be no second stream call.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(provider.streamCalls.count, 1,
            "disconnect() must cancel the scheduled reconnect")
        XCTAssertEqual(store.connectionState, .disconnected)
    }

    /// DOCUMENTED INVARIANT: the store reconnects forever (delay capped at 30 s) and
    /// never surfaces a permanent terminal error from repeated stream failures.
    /// If product behaviour changes to introduce a max-retry cap, flip this test
    /// to assert the new terminal `connectionState`.
    func testReconnectHasNoMaxRetryExhaustion() async {
        let provider = ScriptedStreamProvider()
        // Many consecutive failures; final hold to stop yielding.
        provider.scripts = [
            .throwImmediately(URLError(.networkConnectionLost)),
            .throwImmediately(URLError(.networkConnectionLost)),
            .throwImmediately(URLError(.networkConnectionLost)),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor(timeoutMs: 5_000) { provider.streamCalls.count >= 2 }
        XCTAssertTrue(ok, "Expected at least one reconnect attempt")
        // Crucially: reconnects keep coming. The connection state never lands on a
        // 'permanent error' terminal (because no such state exists).
        XCTAssertNotEqual(store.connectionState, .disconnected,
            "Store should still be trying to reconnect — never goes permanently disconnected")
    }

    // MARK: - In-flight frame replay vs error surface

    func testInFlightDeltasBeforeErrorAreApplied() async {
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenThrow(
                [
                    .snapshot(mkSnapshot(seq: 1, root: root)),
                    .delta(mkAddDelta(baseSeq: 1, seq: 2, parentId: 1, index: 0, childId: 10, name: "first")),
                ],
                URLError(.networkConnectionLost)
            ),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor { store.tree?.findNode(byId: 10) != nil }
        XCTAssertTrue(ok, "Delta yielded before the error must remain applied to the tree")
    }

    func testReconnectAfterErrorResumesUsingLastSeq() async {
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenThrow(
                [
                    .snapshot(mkSnapshot(seq: 1, root: root)),
                    .delta(mkAddDelta(baseSeq: 1, seq: 2, parentId: 1, index: 0, childId: 10, name: "first")),
                ],
                URLError(.networkConnectionLost)
            ),
            .yieldThenHold([
                .delta(mkAddDelta(baseSeq: 2, seq: 3, parentId: 1, index: 1, childId: 11, name: "second"))
            ]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor { store.tree?.findNode(byId: 11) != nil }
        XCTAssertTrue(ok, "Post-reconnect delta must apply on top of pre-error state")
        XCTAssertEqual(provider.streamCalls.count, 2)
        XCTAssertEqual(provider.streamCalls[1].afterSeq, 2,
            "Reconnect must use the last applied seq (2), not start over")
        XCTAssertEqual(store.seq, 3)
    }

    // MARK: - Snapshot / delta interleave invariants

    func testSnapshotReceivedMidStreamResetsState() {
        // pre-snapshot: one delta on top of the original snapshot.
        // mid-stream new snapshot replaces tree; subsequent delta applies to the new tree.
        let store = DevToolsStore()
        store.runId = "run_test"
        let original = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 2, name: "old")])
        store.applyEvent(.snapshot(mkSnapshot(seq: 1, root: original)))
        store.applyEvent(.delta(mkAddDelta(
            baseSeq: 1, seq: 2, parentId: 1, index: 1, childId: 3, name: "extra"
        )))
        XCTAssertEqual(store.tree?.children.count, 2)

        // New snapshot — completely different tree.
        let replacement = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 100, name: "fresh")])
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 5, seq: 10, root: replacement)))
        XCTAssertEqual(store.tree?.children.count, 1, "Snapshot must replace tree, not merge")
        XCTAssertEqual(store.tree?.children[0].id, 100)
        XCTAssertEqual(store.seq, 10)

        // Next delta is built on the new snapshot's seq.
        store.applyEvent(.delta(mkAddDelta(
            baseSeq: 10, seq: 11, parentId: 1, index: 1, childId: 101, name: "post-snap"
        )))
        XCTAssertEqual(store.tree?.children.count, 2)
        XCTAssertEqual(store.tree?.children[1].id, 101)
        XCTAssertNil(store.tree?.findNode(byId: 3),
            "Pre-snapshot delta state must NOT survive the snapshot reset")
    }

    func testDeltaWithStaleBaseSeqIsDroppedAfterSnapshot() {
        // After a snapshot resets seq to 10, a delta with baseSeq=1 (stale) must NOT
        // apply. This is the canonical "delta in flight when snapshot lands" race.
        let store = DevToolsStore()
        store.runId = "run_test"
        let firstRoot = mkNode(id: 1, type: .workflow, name: "wf")
        store.applyEvent(.snapshot(mkSnapshot(seq: 1, root: firstRoot)))

        // New snapshot at seq=10.
        let newRoot = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 50, name: "fresh")])
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 5, seq: 10, root: newRoot)))

        // Stale delta from before the snapshot.
        let stale = mkAddDelta(baseSeq: 1, seq: 2, parentId: 1, index: 0, childId: 999, name: "stale")
        store.applyEvent(.delta(stale))
        XCTAssertNil(store.tree?.findNode(byId: 999),
            "Stale delta (seq <= current liveSeq) must be dropped")
        XCTAssertEqual(store.seq, 10, "Live seq must not regress")
    }

    func testMultipleBackToBackSnapshotsLatestWins() {
        let store = DevToolsStore()
        store.runId = "run_test"

        let r1 = mkNode(id: 1, type: .workflow, name: "v1")
        let r2 = mkNode(id: 1, type: .workflow, name: "v2")
        let r3 = mkNode(id: 1, type: .workflow, name: "v3")
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 1, seq: 5, root: r1)))
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 2, seq: 7, root: r2)))
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 3, seq: 9, root: r3)))

        XCTAssertEqual(store.tree?.name, "v3", "Latest snapshot must win")
        XCTAssertEqual(store.seq, 9)
        XCTAssertEqual(store.latestFrameNo, 3)
    }

    func testInterveningDeltasBetweenSnapshotsDroppedIfDuplicateSeq() {
        // Snapshot A at seq=10 → delta seq=8 (backwards) MUST be dropped → snapshot B at seq=15.
        // Final state should reflect B.
        let store = DevToolsStore()
        store.runId = "run_test"

        let a = mkNode(id: 1, type: .workflow, name: "A")
        let b = mkNode(id: 1, type: .workflow, name: "B")
        store.applyEvent(.snapshot(mkSnapshot(seq: 10, root: a)))

        // Backwards delta — should be dropped.
        let stale = DevToolsDelta(baseSeq: 7, seq: 8, ops: [
            .addNode(parentId: 1, index: 0, node: mkNode(id: 99, name: "ghost"))
        ])
        store.applyEvent(.delta(stale))
        XCTAssertNil(store.tree?.findNode(byId: 99),
            "Backwards-seq delta between snapshots must be dropped")

        store.applyEvent(.snapshot(mkSnapshot(frameNo: 2, seq: 15, root: b)))
        XCTAssertEqual(store.tree?.name, "B")
        XCTAssertEqual(store.seq, 15)
    }

    func testGapResyncPreservesDisplayThenSnapshotResets() {
        // Gap-resync should preserve the *displayed* tree (no UI flicker), drop
        // any deltas until the follow-up snapshot, and reset on snapshot arrival.
        let store = DevToolsStore()
        store.runId = "run_test"

        let initial = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 2, name: "kept")])
        store.applyEvent(.snapshot(mkSnapshot(seq: 10, root: initial)))

        store.applyEvent(.gapResync(DevToolsGapResync(fromSeq: 10, toSeq: 50)))
        XCTAssertEqual(store.tree?.findNode(byId: 2)?.name, "kept",
            "Gap resync must preserve the displayed tree until the follow-up snapshot")

        // Delta lands while waiting for snapshot — must be dropped.
        store.applyEvent(.delta(mkAddDelta(
            baseSeq: 50, seq: 51, parentId: 1, index: 1, childId: 3, name: "discarded"
        )))
        XCTAssertNil(store.tree?.findNode(byId: 3),
            "Deltas between gap-resync and snapshot must be dropped")

        // Snapshot arrives — tree resets.
        let after = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 4, name: "post")])
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 6, seq: 51, root: after)))
        XCTAssertEqual(store.tree?.findNode(byId: 4)?.name, "post")
        XCTAssertNil(store.tree?.findNode(byId: 2))
    }

    func testDeltaWithUnexpectedBaseSeqTriggersResync() async {
        // baseSeq != currentSeq → store calls requestResync → new stream call without afterSeq.
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [
            .yieldThenHold([
                .snapshot(mkSnapshot(seq: 5, root: root)),
                // baseSeq=99 doesn't match liveSeq=5 → triggers resync.
                .delta(mkAddDelta(baseSeq: 99, seq: 100, parentId: 1, index: 0, childId: 7, name: "ghost")),
            ]),
            .yieldThenHold([]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor { provider.streamCalls.count >= 2 }
        XCTAssertTrue(ok, "Mismatched baseSeq must trigger a resync stream call")
        XCTAssertNil(provider.streamCalls[1].afterSeq, "Resync must NOT pass afterSeq")
        XCTAssertNil(store.tree?.findNode(byId: 7), "The bad delta must not have applied")
    }

    // MARK: - Frame-jump confirmation race

    func testFrameJumpDuringDeltaUsesSnapshotSeqNotStaleDelta() async {
        // Scenario: live stream is mid-delta (seq=5). User issues rewind-to-frame.
        // Provider returns jump result + new snapshot at seq=20. After rewind:
        //   * mode is .live
        //   * seq has advanced to the snapshot's seq
        //   * the in-flight stream's stale deltas at seq < 20 are dropped
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 2, name: "running")])
        provider.scripts = [
            // Live state at frameNo=10 so a scrubTo(3) actually enters historical mode.
            .yieldThenHold([
                .snapshot(mkSnapshot(frameNo: 10, seq: 5, root: root)),
            ]),
        ]

        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")
        _ = await waitFor { store.seq == 5 && store.latestFrameNo == 10 }

        // Move into historical mode — required for rewind to be accepted.
        provider.snapshotsToReturn = [
            mkSnapshot(frameNo: 3, seq: 6, root: root), // scrub snapshot
            // After jump confirm: a snapshot showing post-rewind state at seq=20.
            mkSnapshot(frameNo: 3, seq: 20, root: mkNode(
                id: 1, type: .workflow, name: "wf",
                children: [mkNode(id: 99, name: "post-rewind")]
            )),
        ]
        await store.scrubTo(frameNo: 3)
        XCTAssertTrue(store.mode.isHistorical, "scrubTo(3) must enter historical mode when latestFrameNo=10")

        // Issue the rewind. Must consume the second snapshotsToReturn entry.
        await store.rewind(to: 3, confirm: true)

        XCTAssertEqual(provider.jumpCalls.count, 1)
        XCTAssertEqual(provider.jumpCalls.first?.frameNo, 3)
        XCTAssertEqual(provider.jumpCalls.first?.confirm, true)
        XCTAssertEqual(store.seq, 20, "Rewind snapshot seq must override pre-rewind seq")
        XCTAssertEqual(store.tree?.findNode(byId: 99)?.name, "post-rewind")
        // Honor the right sequence id: the *jump's* snapshot seq, not the in-flight delta.
        XCTAssertFalse(store.mode.isHistorical, "Rewind must drop back to live mode")
    }

    func testStaleDeltaAfterRewindIsDropped() async {
        // After rewind moves liveSeq to 20, a delta from before (baseSeq=5, seq=6)
        // must be dropped — the seq id of the rewind snapshot is the new source of truth.
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf")
        provider.scripts = [.yieldThenHold([.snapshot(mkSnapshot(frameNo: 10, seq: 5, root: root))])]
        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")
        _ = await waitFor { store.seq == 5 && store.latestFrameNo == 10 }

        provider.snapshotsToReturn = [
            mkSnapshot(frameNo: 3, seq: 6, root: root),
            mkSnapshot(frameNo: 3, seq: 20, root: root),
        ]
        await store.scrubTo(frameNo: 3)
        XCTAssertTrue(store.mode.isHistorical, "Pre-rewind: must be in historical mode")
        await store.rewind(to: 3, confirm: true)
        XCTAssertEqual(store.seq, 20)

        // Stale delta arrives — must be dropped.
        let stale = mkAddDelta(baseSeq: 5, seq: 6, parentId: 1, index: 0, childId: 77, name: "stale")
        store.applyEvent(.delta(stale))
        XCTAssertNil(store.tree?.findNode(byId: 77),
            "Stale delta with seq < post-rewind liveSeq must be dropped")
        XCTAssertEqual(store.seq, 20)
    }

    func testFrameJumpWithoutConfirmIsNoOp() async {
        let provider = ScriptedStreamProvider()
        let store = DevToolsStore(streamProvider: provider)
        // No connect — direct call. confirm:false should bail before any I/O.
        await store.rewind(to: 3, confirm: false)
        XCTAssertEqual(provider.jumpCalls.count, 0)
        XCTAssertEqual(provider.snapshotCalls.count, 0)
        XCTAssertNil(store.rewindError, "confirm:false is a silent no-op")
    }

    func testFrameJumpRequiresHistoricalMode() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [.yieldThenHold([.snapshot(mkSnapshot(seq: 1))])]
        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")
        _ = await waitFor { store.seq == 1 }

        // mode is .live — rewind should refuse.
        await store.rewind(to: 0, confirm: true)
        XCTAssertEqual(provider.jumpCalls.count, 0,
            "Rewind from live mode must be rejected before issuing the RPC")
        XCTAssertEqual(store.rewindError, .confirmationRequired)
    }

    // MARK: - Multiple consumers / mutation safety

    /// `DevToolsStore` is `@MainActor` and exposes a single ObservableObject. The
    /// "multiple consumers" the brief asks about are SwiftUI subscribers reading
    /// `@Published tree` — there's no public multi-stream-read API.  We assert
    /// that interleaved reads and event applies remain consistent.
    func testInterleavedReadsAndAppliesProduceConsistentView() {
        let store = DevToolsStore()
        store.runId = "run_test"
        let root = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 2, name: "child")])
        store.applyEvent(.snapshot(mkSnapshot(seq: 1, root: root)))

        // 50 alternating apply / read cycles. Each read must see the result of the
        // prior apply (since both run on the main actor).
        for i in 0..<50 {
            let delta = mkAddDelta(
                baseSeq: i + 1, seq: i + 2, parentId: 1, index: i, childId: 100 + i,
                name: "n\(i)"
            )
            store.applyEvent(.delta(delta))
            XCTAssertEqual(store.seq, i + 2, "Read-after-apply must observe the new seq")
            XCTAssertNotNil(store.tree?.findNode(byId: 100 + i))
        }
        XCTAssertEqual(store.seq, 51)
    }

    func testTreeMutationDuringSnapshotDoesNotCrash() {
        // Snapshot a tree, then immediately apply many tree-mutating deltas.
        // Tests there's no aliasing issue between the snapshot's `root` and the
        // store's working tree (deepCopy on snapshot path).
        let store = DevToolsStore()
        store.runId = "run_test"
        var children: [DevToolsNode] = []
        for i in 0..<50 {
            children.append(mkNode(id: 100 + i, name: "leaf-\(i)"))
        }
        let big = mkNode(id: 1, type: .workflow, name: "wf", children: children)
        store.applyEvent(.snapshot(mkSnapshot(seq: 1, root: big)))

        // Aggressively mutate.
        var seq = 1
        for i in 0..<25 {
            seq += 1
            let delta = DevToolsDelta(
                baseSeq: seq - 1, seq: seq,
                ops: [.removeNode(id: 100 + i)]
            )
            store.applyEvent(.delta(delta))
        }
        XCTAssertEqual(store.tree?.children.count, 25, "Should have removed 25 of 50 leaves")
    }

    // MARK: - Snapshot fetch timeout / retry

    func testScrubSnapshotTimeoutSurfacesError() async {
        let provider = ScriptedStreamProvider()
        provider.snapshotErrorsToThrow = [URLError(.timedOut)]
        let store = DevToolsStore(streamProvider: provider)
        store.runId = "run_test"
        // Need a non-zero latestFrameNo so scrubTo doesn't short-circuit to live.
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 10, seq: 10)))

        await store.scrubTo(frameNo: 5)
        XCTAssertNotNil(store.scrubError, "Snapshot timeout must surface to scrubError")
        if case .network(let err) = store.scrubError {
            XCTAssertEqual(err.code, .timedOut)
        } else {
            XCTFail("Expected .network(.timedOut), got \(String(describing: store.scrubError))")
        }
    }

    func testScrubRetryAfterErrorSucceeds() async {
        let provider = ScriptedStreamProvider()
        let root = mkNode(id: 1, type: .workflow, name: "wf",
            children: [mkNode(id: 99, name: "historical")])
        provider.snapshotErrorsToThrow = [URLError(.timedOut)]
        provider.snapshotsToReturn = [mkSnapshot(frameNo: 5, seq: 5, root: root)]

        let store = DevToolsStore(streamProvider: provider)
        store.runId = "run_test"
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 10, seq: 10)))

        // First scrub: error.
        await store.scrubTo(frameNo: 5)
        XCTAssertNotNil(store.scrubError)

        // Retry: succeeds.
        store.clearHistoricalError()
        XCTAssertNil(store.scrubError)
        await store.scrubTo(frameNo: 5)
        XCTAssertNil(store.scrubError, "Successful retry must clear scrub error")
        XCTAssertTrue(store.mode.isHistorical)
        XCTAssertEqual(store.tree?.findNode(byId: 99)?.name, "historical")
    }

    func testSnapshotFetchFailsWhenRunNotFound() async {
        let provider = ScriptedStreamProvider()
        provider.snapshotErrorsToThrow = [DevToolsClientError.runNotFound("bogus")]
        let store = DevToolsStore(streamProvider: provider)
        store.runId = "bogus"
        store.applyEvent(.snapshot(mkSnapshot(runId: "bogus", frameNo: 10, seq: 10)))

        await store.scrubTo(frameNo: 5)
        XCTAssertEqual(store.scrubError, .runNotFound("bogus"))
    }

    func testScrubWithoutProviderSurfacesError() async {
        // No provider injected → scrubTo must fail fast.
        let store = DevToolsStore(streamProvider: nil)
        store.runId = "run_test"
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 10, seq: 10)))
        await store.scrubTo(frameNo: 5)
        XCTAssertNotNil(store.scrubError)
        if case .unknown(let msg) = store.scrubError {
            XCTAssertTrue(msg.contains("snapshot"), "Error message should mention snapshot provider")
        } else {
            XCTFail("Expected .unknown(...) for missing provider, got \(String(describing: store.scrubError))")
        }
    }

    // MARK: - Cancellation on close

    func testDisconnectMidFetchEndsInDisconnectedState() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [.yieldThenHold([])]
        // Long-running snapshot fetch.
        provider.snapshotDelayNs = 500_000_000
        provider.snapshotsToReturn = [mkSnapshot(frameNo: 5, seq: 5)]

        let store = DevToolsStore(streamProvider: provider)
        store.runId = "run_test"
        store.applyEvent(.snapshot(mkSnapshot(frameNo: 10, seq: 10)))

        async let scrub: Void = store.scrubTo(frameNo: 5)
        // Give the scrub a moment to start.
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.disconnect()
        await scrub

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNil(store.runId, "disconnect() must clear runId")
    }

    func testDisconnectStopsStreamLoop() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [.yieldThenHold([.snapshot(mkSnapshot(seq: 1))])]
        let store = DevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        _ = await waitFor { store.seq == 1 }
        XCTAssertEqual(provider.streamCalls.count, 1)

        store.disconnect()

        // Wait well past any backoff window. There must be no further stream calls.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(provider.streamCalls.count, 1,
            "disconnect() must terminate the stream loop and prevent further reconnects")
    }

    func testDisconnectWhileReconnectScheduledCancelsReconnect() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [
            .throwImmediately(URLError(.networkConnectionLost)), // forces a backoff sleep
        ]
        let store = DevToolsStore(streamProvider: provider)
        store.connect(runId: "run_test")
        // Let the first failure fire.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(store.reconnectCount, 1)

        // Now disconnect during the 1s backoff window.
        store.disconnect()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        XCTAssertEqual(provider.streamCalls.count, 1,
            "Disconnect during backoff sleep must cancel the pending reconnect")
        XCTAssertEqual(store.connectionState, .disconnected)
    }

    func testReconnectCountIncrementsAcrossClosures() async {
        let provider = ScriptedStreamProvider()
        provider.scripts = [
            .yieldThenClose([.snapshot(mkSnapshot(seq: 1))]),
            .throwImmediately(URLError(.timedOut)),
            .yieldThenHold([]),
        ]
        let store = DevToolsStore(streamProvider: provider)
        defer { store.disconnect() }
        store.connect(runId: "run_test")

        let ok = await waitFor(timeoutMs: 5_000) { store.reconnectCount >= 2 }
        XCTAssertTrue(ok, "reconnectCount must increment on each reconnection trigger")
    }

    // MARK: - Run-id mismatch on snapshot

    func testSnapshotForWrongRunIdDisconnects() {
        // Belt-and-suspenders: a snapshot whose runId doesn't match the active runId
        // must trigger disconnect (defends against multiplexed streams or proxy bugs).
        let store = DevToolsStore()
        store.runId = "run_a"
        let snap = DevToolsSnapshot(runId: "run_b", frameNo: 1, seq: 1,
            root: mkNode(id: 1, type: .workflow, name: "x"))
        store.applyEvent(.snapshot(snap))
        XCTAssertNil(store.runId, "Mismatched runId in snapshot must trigger disconnect()")
        XCTAssertEqual(store.connectionState, .disconnected)
    }
}
