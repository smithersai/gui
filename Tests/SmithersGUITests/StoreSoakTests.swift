import XCTest
@testable import SmithersGUI

@MainActor
final class StoreSoakTests: XCTestCase {

    private func isSoakEnabled() -> Bool {
        ProcessInfo.processInfo.environment["SMITHERS_SOAK"] == "1"
    }

    private func makeNode(
        id: Int, type: SmithersNodeType = .task, name: String = "node",
        children: [DevToolsNode] = []
    ) -> DevToolsNode {
        DevToolsNode(id: id, type: type, name: name, children: children)
    }

    func testSoakStoreProcessesManyEvents() throws {
        guard isSoakEnabled() else {
            throw XCTSkip("Soak test requires SMITHERS_SOAK=1")
        }

        let store = LiveRunDevToolsStore()
        store.runId = "soak_run"

        let root = makeNode(id: 0, type: .workflow, name: "soak-root")
        store.applyEvent(.snapshot(DevToolsSnapshot(runId: "soak_run", frameNo: 0, seq: 1, root: root)))

        var nextNodeId = 1
        var currentSeq = 1

        for batch in 0..<600 {
            for _ in 0..<100 {
                currentSeq += 1
                let op: DevToolsDeltaOp
                if nextNodeId < 50 || batch % 3 == 0 {
                    op = .addNode(parentId: 0, index: min(nextNodeId - 1, store.tree?.children.count ?? 0), node: makeNode(id: nextNodeId, name: "n\(nextNodeId)"))
                    nextNodeId += 1
                } else if batch % 3 == 1 {
                    op = .updateProps(id: 0, props: ["tick": .number(Double(currentSeq))])
                } else {
                    let childCount = store.tree?.children.count ?? 0
                    if childCount > 10 {
                        let removeId = store.tree!.children[childCount - 1].id
                        op = .removeNode(id: removeId)
                    } else {
                        op = .updateProps(id: 0, props: ["tick": .number(Double(currentSeq))])
                    }
                }

                let delta = DevToolsDelta(baseSeq: currentSeq - 1, seq: currentSeq, ops: [op])
                store.applyEvent(.delta(delta))
            }
        }

        XCTAssertEqual(store.seq, currentSeq)
        XCTAssertEqual(store.eventsApplied, 60001, "1 snapshot + 60000 deltas")
        XCTAssertNotNil(store.tree)
    }

    func testSoakNoTaskLeaks() throws {
        guard isSoakEnabled() else {
            throw XCTSkip("Soak test requires SMITHERS_SOAK=1")
        }

        let provider = MockSoakStreamProvider()
        let store = LiveRunDevToolsStore(streamProvider: provider)

        for _ in 0..<100 {
            store.connect(runId: "leak_test")
            store.disconnect()
        }

        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNil(store.runId)
    }
}

@MainActor
private final class MockSoakStreamProvider: DevToolsStreamProvider, @unchecked Sendable {
    func streamDevTools(runId: String, afterSeq: Int?) -> AsyncThrowingStream<DevToolsEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int?) async throws -> DevToolsSnapshot {
        throw DevToolsClientError.runNotFound(runId)
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool) async throws -> DevToolsJumpResult {
        throw DevToolsClientError.runNotFound(runId)
    }
}
