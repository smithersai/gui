import XCTest
@testable import SmithersGUI

@MainActor
final class StoreScrubTests: XCTestCase {
    private func makeSnapshot(runId: String = "run-test", frameNo: Int, seq: Int, name: String, state: String = "running") -> DevToolsSnapshot {
        let root = DevToolsNode(
            id: 1,
            type: .workflow,
            name: name,
            props: ["state": .string(state)],
            children: [],
            depth: 0
        )
        return DevToolsSnapshot(runId: runId, frameNo: frameNo, seq: seq, root: root)
    }

    func testScrubToFetchesSnapshotAndEntersHistoricalMode() async {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 20, name: "historical")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live")))

        await store.scrubTo(frameNo: 1)

        XCTAssertEqual(provider.snapshotCallCount, 1)
        XCTAssertEqual(store.mode, .historical(frameNo: 1))
        XCTAssertEqual(store.tree?.name, "historical")
    }

    func testReturnToLiveReappliesBufferedLatestTreeAndResubscribes() async {
        let provider = MockDevToolsStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)

        store.connect(runId: "run-test")
        let baselineStreamCalls = provider.streamCallCount

        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live-v1")))

        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical")
        await store.scrubTo(frameNo: 1)
        XCTAssertEqual(store.tree?.name, "historical")

        store.applyEvent(.snapshot(makeSnapshot(frameNo: 4, seq: 4, name: "live-v2")))
        XCTAssertEqual(store.tree?.name, "historical", "Historical mode must not apply live events")

        store.returnToLive()

        XCTAssertEqual(store.mode, .live)
        XCTAssertEqual(store.tree?.name, "live-v2")
        XCTAssertGreaterThanOrEqual(provider.streamCallCount, baselineStreamCalls + 1)

        store.disconnect()
    }

    func testStreamEventsBufferedInHistoricalModeThenAppliedOnReturnToLive() async {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live-v1")))

        await store.scrubTo(frameNo: 1)
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 5, seq: 5, name: "live-v2")))

        XCTAssertEqual(store.tree?.name, "historical")

        store.returnToLive()

        XCTAssertEqual(store.mode, .live)
        XCTAssertEqual(store.tree?.name, "live-v2")
    }

    func testScrubFailureKeepsPreviousGoodFrameAndRemainsHistorical() async {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical-good")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live")))
        await store.scrubTo(frameNo: 1)

        provider.snapshotError = DevToolsClientError.frameOutOfRange(9)
        await store.scrubTo(frameNo: 2)

        XCTAssertEqual(store.tree?.name, "historical-good")
        XCTAssertEqual(store.mode, .historical(frameNo: 2))
        XCTAssertEqual(store.scrubError, .frameOutOfRange(9))
    }

    func testScrubFrameZeroOnEmptyRunSurfacesFrameOutOfRange() async {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotError = DevToolsClientError.frameOutOfRange(0)

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"

        await store.scrubTo(frameNo: 0)

        XCTAssertEqual(store.mode, .historical(frameNo: 0))
        XCTAssertEqual(store.scrubError, .frameOutOfRange(0))
    }
}
