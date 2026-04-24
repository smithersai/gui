import XCTest
@testable import SmithersGUI

final class ApplyDeltaTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        id: Int, type: SmithersNodeType = .task, name: String = "node",
        props: [String: JSONValue] = [:], task: DevToolsTaskInfo? = nil,
        children: [DevToolsNode] = [], depth: Int = 0
    ) -> DevToolsNode {
        DevToolsNode(id: id, type: type, name: name, props: props, task: task, children: children, depth: depth)
    }

    private func makeTask(nodeId: String = "task:0", kind: String = "agent") -> DevToolsTaskInfo {
        DevToolsTaskInfo(nodeId: nodeId, kind: kind, agent: "claude", label: nil, outputTableName: nil, iteration: 0)
    }

    // MARK: - addNode

    func testAddNodeToNilTreeWithRootParent() throws {
        let node = makeNode(id: 1, name: "root")
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: -1, index: 0, node: node)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: nil)
        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(result?.name, "root")
    }

    func testAddNodeToNilTreeNonRootParentThrows() {
        let node = makeNode(id: 2)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 5, index: 0, node: node)])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: nil)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownParent(5))
        }
    }

    func testAddNodeAtIndex0() throws {
        let root = makeNode(id: 1, children: [makeNode(id: 2, name: "existing")])
        let newChild = makeNode(id: 3, name: "new")
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 1, index: 0, node: newChild)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 2)
        XCTAssertEqual(result?.children[0].id, 3)
        XCTAssertEqual(result?.children[1].id, 2)
    }

    func testAddNodeAtIndex1() throws {
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        let newChild = makeNode(id: 3)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 1, index: 1, node: newChild)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 2)
        XCTAssertEqual(result?.children[1].id, 3)
    }

    func testAddNodeAtEnd() throws {
        let root = makeNode(id: 1, children: [makeNode(id: 2), makeNode(id: 3)])
        let newChild = makeNode(id: 4)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 1, index: 2, node: newChild)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 3)
        XCTAssertEqual(result?.children[2].id, 4)
    }

    func testAddNodeUnknownParentThrows() {
        let root = makeNode(id: 1)
        let newChild = makeNode(id: 2)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 999, index: 0, node: newChild)])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: root)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownParent(999))
        }
    }

    func testAddNodeIndexOutOfBoundsThrows() {
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        let newChild = makeNode(id: 3)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.addNode(parentId: 1, index: 5, node: newChild)])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: root)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .indexOutOfBounds(parentId: 1, index: 5, childCount: 1))
        }
    }

    // MARK: - removeNode

    func testRemoveExistingNode() throws {
        let root = makeNode(id: 1, children: [makeNode(id: 2), makeNode(id: 3)])
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.removeNode(id: 2)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 1)
        XCTAssertEqual(result?.children[0].id, 3)
    }

    func testRemoveNodeWithChildren() throws {
        let child = makeNode(id: 3)
        let parent = makeNode(id: 2, children: [child])
        let root = makeNode(id: 1, children: [parent])
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.removeNode(id: 2)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 0)
        XCTAssertNil(result?.findNode(byId: 3))
    }

    func testRemoveUnknownNodeThrows() {
        let root = makeNode(id: 1)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.removeNode(id: 999)])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: root)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownNode(999))
        }
    }

    func testRemoveRoot() throws {
        let root = makeNode(id: 1)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.removeNode(id: 1)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertNil(result)
    }

    func testRemoveFromNilTreeThrows() {
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.removeNode(id: 1)])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: nil)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownNode(1))
        }
    }

    // MARK: - updateProps

    func testUpdatePropsOnExistingNode() throws {
        let root = makeNode(id: 1, props: ["a": .string("old")])
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateProps(id: 1, props: ["a": .string("new"), "b": .number(42)])])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.props["a"], .string("new"))
        XCTAssertEqual(result?.props["b"], .number(42))
    }

    func testUpdatePropsMergesNotReplaces() throws {
        let root = makeNode(id: 1, props: ["existing": .bool(true)])
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateProps(id: 1, props: ["new": .string("val")])])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.props["existing"], .bool(true))
        XCTAssertEqual(result?.props["new"], .string("val"))
    }

    func testUpdatePropsUnknownNodeThrows() {
        let root = makeNode(id: 1)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateProps(id: 999, props: ["a": .null])])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: root)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownNode(999))
        }
    }

    // MARK: - updateTask

    func testUpdateTaskOnExistingNode() throws {
        let task = makeTask()
        let root = makeNode(id: 1, type: .task)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateTask(id: 1, task: task)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.task?.nodeId, "task:0")
        XCTAssertEqual(result?.task?.kind, "agent")
    }

    func testUpdateTaskToNilClears() throws {
        let root = makeNode(id: 1, type: .task, task: makeTask())
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateTask(id: 1, task: nil)])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertNil(result?.task)
    }

    func testUpdateTaskUnknownNodeThrows() {
        let root = makeNode(id: 1)
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.updateTask(id: 999, task: makeTask())])
        XCTAssertThrowsError(try DevToolsDeltaApplier.applyDelta(delta, to: root)) { error in
            XCTAssertEqual(error as? ApplyDeltaError, .unknownNode(999))
        }
    }

    func testReplaceRoot() throws {
        let original = makeNode(id: 1, type: .workflow, name: "old-root")
        let replacement = makeNode(id: 99, type: .workflow, name: "new-root")
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [.replaceRoot(node: replacement)])

        let result = try DevToolsDeltaApplier.applyDelta(delta, to: original)
        XCTAssertEqual(result?.id, 99)
        XCTAssertEqual(result?.name, "new-root")
    }

    // MARK: - Multi-op delta

    func testMultiOpDeltaAppliedInOrder() throws {
        let root = makeNode(id: 1)
        var ops: [DevToolsDeltaOp] = []
        for i in 2...101 {
            ops.append(.addNode(parentId: 1, index: i - 2, node: makeNode(id: i, name: "child-\(i)")))
        }
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: ops)
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.children.count, 100)
        XCTAssertEqual(result?.children[0].id, 2)
        XCTAssertEqual(result?.children[99].id, 101)
    }

    func testEmptyDeltaLeavesTreeUnchanged() throws {
        let root = makeNode(id: 1, children: [makeNode(id: 2)])
        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [])
        let result = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(result?.children.count, 1)
    }

    // MARK: - Codable round-trip

    func testDevToolsNodeCodableRoundTrip() throws {
        let node = makeNode(id: 42, type: .workflow, name: "test", props: ["key": .string("val")])
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(DevToolsNode.self, from: data)
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.type, .workflow)
        XCTAssertEqual(decoded.name, "test")
        XCTAssertEqual(decoded.props["key"], .string("val"))
    }

    func testDevToolsSnapshotCodableRoundTrip() throws {
        let root = makeNode(id: 1, type: .workflow, name: "wf")
        let snapshot = DevToolsSnapshot(runId: "run_abc", frameNo: 5, seq: 10, root: root)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DevToolsSnapshot.self, from: data)
        XCTAssertEqual(decoded.runId, "run_abc")
        XCTAssertEqual(decoded.frameNo, 5)
        XCTAssertEqual(decoded.seq, 10)
        XCTAssertEqual(decoded.root.id, 1)
    }

    func testDevToolsDeltaCodableRoundTrip() throws {
        let ops: [DevToolsDeltaOp] = [
            .addNode(parentId: 1, index: 0, node: makeNode(id: 2)),
            .removeNode(id: 3),
            .updateProps(id: 1, props: ["x": .number(1)]),
            .updateTask(id: 1, task: makeTask()),
            .replaceRoot(node: makeNode(id: 999, type: .workflow, name: "replacement")),
        ]
        let delta = DevToolsDelta(baseSeq: 5, seq: 6, ops: ops)
        let data = try JSONEncoder().encode(delta)
        let decoded = try JSONDecoder().decode(DevToolsDelta.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.baseSeq, 5)
        XCTAssertEqual(decoded.seq, 6)
        XCTAssertEqual(decoded.ops.count, 5)
    }

    // MARK: - Input boundary tests

    func testSnapshotWith0Nodes() throws {
        let root = makeNode(id: 1, type: .workflow, name: "empty")
        let snapshot = DevToolsSnapshot(runId: "run_0", frameNo: 0, seq: 1, root: root)
        XCTAssertEqual(snapshot.root.children.count, 0)
    }

    func testSnapshotWith10000Nodes() throws {
        let root = makeNode(id: 0, type: .workflow, name: "big")
        for i in 1...10000 {
            root.children.append(makeNode(id: i, name: "node-\(i)"))
        }
        XCTAssertEqual(root.children.count, 10000)
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(DevToolsNode.self, from: data)
        XCTAssertEqual(decoded.children.count, 10000)
    }

    func testSnapshotWith1MBPropString() throws {
        let bigString = String(repeating: "x", count: 1_000_000)
        let root = makeNode(id: 1, props: ["prompt": .string(bigString)])
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(DevToolsNode.self, from: data)
        XCTAssertEqual(decoded.props["prompt"], .string(bigString))
    }

    func testUnicodeEmojiRoundTrips() throws {
        let root = makeNode(id: 1, props: [
            "emoji": .string("\u{1F680}\u{1F4A5}\u{2764}\u{FE0F}"),
            "cjk": .string("\u{4F60}\u{597D}\u{4E16}\u{754C}"),
        ])
        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(DevToolsNode.self, from: data)
        XCTAssertEqual(decoded.props["emoji"], .string("\u{1F680}\u{1F4A5}\u{2764}\u{FE0F}"))
        XCTAssertEqual(decoded.props["cjk"], .string("\u{4F60}\u{597D}\u{4E16}\u{754C}"))
    }

    func test100ConsecutiveDeltasIn1Second() throws {
        let root = makeNode(id: 0, type: .workflow, name: "perf-test")
        var currentTree: DevToolsNode? = root
        let start = CFAbsoluteTimeGetCurrent()

        for i in 1...100 {
            let delta = DevToolsDelta(baseSeq: i - 1, seq: i, ops: [
                .addNode(parentId: 0, index: i - 1, node: makeNode(id: i, name: "child-\(i)"))
            ])
            currentTree = try DevToolsDeltaApplier.applyDelta(delta, to: currentTree)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.5, "100 deltas should complete in < 500ms")
        XCTAssertEqual(currentTree?.children.count, 100)
    }

    // MARK: - Performance baseline

    func testApplyDeltaOn500NodeTree() throws {
        let root = makeNode(id: 0, type: .workflow, name: "perf")
        for i in 1...500 {
            root.children.append(makeNode(id: i, name: "n\(i)"))
        }

        let delta = DevToolsDelta(baseSeq: 0, seq: 1, ops: [
            .updateProps(id: 250, props: ["state": .string("running")])
        ])

        let start = CFAbsoluteTimeGetCurrent()
        _ = try DevToolsDeltaApplier.applyDelta(delta, to: root)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 5.0, "applyDelta on 500-node tree should be < 5ms p95")
    }

    func testFullSnapshotDecodePerformance() throws {
        let root = makeNode(id: 0, type: .workflow, name: "perf")
        for i in 1...500 {
            root.children.append(makeNode(id: i, name: "n\(i)", props: ["state": .string("pending")]))
        }
        let snapshot = DevToolsSnapshot(runId: "perf_run", frameNo: 1, seq: 1, root: root)
        let data = try JSONEncoder().encode(snapshot)

        let start = CFAbsoluteTimeGetCurrent()
        _ = try JSONDecoder().decode(DevToolsSnapshot.self, from: data)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
        XCTAssertLessThan(elapsed, 50.0, "500-node snapshot decode should be < 50ms")
    }

    // MARK: - SmithersNodeType

    func testUnknownNodeTypeDecodesAsUnknown() throws {
        let json = "\"some-future-type\""
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SmithersNodeType.self, from: data)
        XCTAssertEqual(decoded, .unknown)
    }

    func testKnownNodeTypes() throws {
        let types: [String: SmithersNodeType] = [
            "workflow": .workflow,
            "sequence": .sequence,
            "parallel": .parallel,
            "task": .task,
            "forEach": .forEach,
            "conditional": .conditional,
            "merge-queue": .mergeQueue,
            "branch": .branch,
            "loop": .loop,
            "worktree": .worktree,
            "approval": .approval,
            "timer": .timer,
            "subflow": .subflow,
            "wait-for-event": .waitForEvent,
            "saga": .saga,
            "try-catch": .tryCatch,
            "fragment": .fragment,
        ]
        for (raw, expected) in types {
            let data = "\"\(raw)\"".data(using: .utf8)!
            let decoded = try JSONDecoder().decode(SmithersNodeType.self, from: data)
            XCTAssertEqual(decoded, expected, "Expected \(raw) to decode to \(expected)")
        }
    }
}
