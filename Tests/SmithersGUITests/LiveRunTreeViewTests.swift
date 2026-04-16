import XCTest
@testable import SmithersGUI

final class LiveRunTreeViewTests: XCTestCase {

    private func makeTask(
        nodeId: String,
        label: String,
        agent: String? = nil,
        iteration: Int? = nil
    ) -> DevToolsTaskInfo {
        DevToolsTaskInfo(
            nodeId: nodeId,
            kind: "agent",
            agent: agent,
            label: label,
            outputTableName: nil,
            iteration: iteration
        )
    }

    private func makeNode(
        id: Int,
        type: SmithersNodeType = .task,
        name: String = "Node",
        state: String? = nil,
        task: DevToolsTaskInfo? = nil,
        children: [DevToolsNode] = [],
        depth: Int = 0
    ) -> DevToolsNode {
        var props: [String: JSONValue] = [:]
        if let state {
            props["state"] = .string(state)
        }
        return DevToolsNode(
            id: id,
            type: type,
            name: name,
            props: props,
            task: task,
            children: children,
            depth: depth
        )
    }

    func testVisibleRowsRootOnlyWhenCollapsed() {
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, depth: 1),
            makeNode(id: 3, depth: 1),
        ])

        let rows = visibleTreeRows(root: root, expandedIds: [])
        XCTAssertEqual(rows.map(\.id), [1])
    }

    func testVisibleRowsExpandedDepthFirstStructuralOrder() {
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 4, depth: 2),
                makeNode(id: 5, depth: 2),
            ], depth: 1),
            makeNode(id: 3, depth: 1),
        ])

        let rows = visibleTreeRows(root: root, expandedIds: [1, 2])
        XCTAssertEqual(rows.map(\.id), [1, 2, 4, 5, 3])
    }

    func testRunningPathExpansionIncludesRunningNodeAncestors() {
        let runningLeaf = makeNode(id: 5, state: "running", depth: 3)
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 3, type: .parallel, children: [
                    runningLeaf,
                ], depth: 2),
            ], depth: 1),
        ])

        let ids = runningPathExpansionIDs(root: root, userCollapsedIds: [])
        XCTAssertEqual(ids, Set([1, 2, 3, 5]))
    }

    func testRunningPathExpansionRespectsUserCollapsedNodes() {
        let runningLeaf = makeNode(id: 5, state: "running", depth: 3)
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 3, type: .parallel, children: [runningLeaf], depth: 2),
            ], depth: 1),
        ])

        let ids = runningPathExpansionIDs(root: root, userCollapsedIds: [2, 3])
        XCTAssertEqual(ids, Set([1, 5]))
        XCTAssertFalse(ids.contains(2))
        XCTAssertFalse(ids.contains(3))
    }

    func testRootOnlyTreeHasSingleVisibleRow() {
        let root = makeNode(id: 10, type: .workflow, state: "running")
        let rows = visibleTreeRows(root: root, expandedIds: [])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, 10)
    }

    func testDeepTreeDepthFiftyTraversalIsStable() {
        var leaf = makeNode(id: 50, depth: 49)
        for i in stride(from: 49, through: 1, by: -1) {
            leaf = makeNode(id: i, type: .sequence, children: [leaf], depth: i - 1)
        }

        let expanded = Set(1...49)
        let rows = visibleTreeRows(root: leaf, expandedIds: expanded)
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows.first?.id, 1)
        XCTAssertEqual(rows.last?.id, 50)
    }

    func testKeyPropsSummaryTruncatesLongLabel() {
        let longLabel = String(repeating: "x", count: 500)
        let node = makeNode(
            id: 1,
            task: makeTask(nodeId: "task:long", label: longLabel, agent: "claude-opus-4-7", iteration: 2)
        )

        let summary = keyPropsSummary(for: node, maxLength: 120)
        XCTAssertLessThanOrEqual(summary.count, 120)
        XCTAssertTrue(summary.hasSuffix("…"))
    }
}
