import XCTest
import ViewInspector
@testable import SmithersGUI

extension FrameScrubberView: @retroactive Inspectable {}

@MainActor
final class FrameScrubberTests: XCTestCase {
    private func makeSnapshot(runId: String = "run-test", frameNo: Int, seq: Int, state: String = "running", name: String) -> DevToolsSnapshot {
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

    func testHistoricalBannerRendersExactText() async throws {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live")))

        await store.scrubTo(frameNo: 1)

        let view = FrameScrubberView(store: store)
        XCTAssertNoThrow(try view.inspect().find(text: "Viewing frame 1 of 3 (historical)."))
    }

    func testRewindButtonHiddenForFinishedRun() async throws {
        let provider = MockDevToolsStreamProvider()
        provider.snapshotToReturn = makeSnapshot(frameNo: 1, seq: 101, name: "historical")

        let store = LiveRunDevToolsStore(streamProvider: provider)
        store.runId = "run-test"
        store.applyEvent(.snapshot(makeSnapshot(frameNo: 3, seq: 3, name: "live")))
        await store.scrubTo(frameNo: 1)
        store.setRunStatus(.finished)

        let view = FrameScrubberView(store: store)
        XCTAssertThrowsError(try view.inspect().find(button: "Rewind"))
    }
}
