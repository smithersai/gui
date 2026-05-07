import XCTest
@testable import SmithersGUI

final class AncestorErrorIndexTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        id: Int,
        type: SmithersNodeType = .task,
        name: String = "Node",
        state: String? = nil,
        children: [DevToolsNode] = [],
        depth: Int = 0
    ) -> DevToolsNode {
        var props: [String: JSONValue] = [:]
        if let state { props["state"] = .string(state) }
        return DevToolsNode(id: id, type: type, name: name, props: props, children: children, depth: depth)
    }

    // MARK: - No Failures

    func testNoFailuresEmptySet() {
        let root = makeNode(id: 1, type: .workflow, state: "running", children: [
            makeNode(id: 2, state: "finished", depth: 1),
            makeNode(id: 3, state: "running", depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.ancestorsWithFailedDescendants.isEmpty)
        XCTAssertFalse(index.hasFailedDescendant(1))
        XCTAssertFalse(index.hasFailedDescendant(2))
        XCTAssertFalse(index.hasFailedDescendant(3))
    }

    // MARK: - Single Leaf Failed

    func testSingleLeafFailedMarksAllAncestors() {
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 3, state: "failed", depth: 2),
            ], depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.hasFailedDescendant(1))
        XCTAssertTrue(index.hasFailedDescendant(2))
        XCTAssertFalse(index.hasFailedDescendant(3))
    }

    // MARK: - Two Sibling Failures

    func testTwoSiblingFailuresMergeAncestorChains() {
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .parallel, children: [
                makeNode(id: 3, state: "failed", depth: 2),
                makeNode(id: 4, state: "failed", depth: 2),
            ], depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.hasFailedDescendant(1))
        XCTAssertTrue(index.hasFailedDescendant(2))
        XCTAssertEqual(index.failedDescendantCount(2), 2)
        XCTAssertEqual(index.failedDescendantCount(1), 2)
        XCTAssertFalse(index.hasFailedDescendant(3))
        XCTAssertFalse(index.hasFailedDescendant(4))
    }

    // MARK: - Nested Failures

    func testNestedFailuresBothMarked() {
        let root = makeNode(id: 1, type: .workflow, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 3, state: "failed", children: [
                    makeNode(id: 4, state: "failed", depth: 3),
                ], depth: 2),
            ], depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.hasFailedDescendant(1))
        XCTAssertTrue(index.hasFailedDescendant(2))
        XCTAssertTrue(index.hasFailedDescendant(3))
    }

    // MARK: - Failure at Root

    func testFailureAtRootNoAncestors() {
        let root = makeNode(id: 1, type: .workflow, state: "failed")
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.ancestorsWithFailedDescendants.isEmpty)
    }

    // MARK: - Nil Root

    func testNilRootEmptyIndex() {
        let index = AncestorErrorIndex(root: nil, seq: 0)
        XCTAssertTrue(index.ancestorsWithFailedDescendants.isEmpty)
        XCTAssertFalse(index.hasFailedDescendant(1))
        XCTAssertEqual(index.failedDescendantCount(99), 0)
    }

    // MARK: - All Nodes Failed

    func testAllNodesFailed() {
        let root = makeNode(id: 1, type: .workflow, state: "failed", children: [
            makeNode(id: 2, state: "failed", children: [
                makeNode(id: 3, state: "failed", depth: 2),
            ], depth: 1),
            makeNode(id: 4, state: "failed", depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.hasFailedDescendant(1))
        XCTAssertTrue(index.hasFailedDescendant(2))
        XCTAssertEqual(index.failedDescendantCount(1), 3)
    }

    // MARK: - All Nodes Pending

    func testAllNodesPendingNoRedDots() {
        let root = makeNode(id: 1, type: .workflow, state: "pending", children: [
            makeNode(id: 2, state: "pending", depth: 1),
            makeNode(id: 3, state: "pending", depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.ancestorsWithFailedDescendants.isEmpty)
    }

    // MARK: - Cached Seq

    func testCachedSeq() {
        let index = AncestorErrorIndex(root: nil, seq: 42)
        XCTAssertEqual(index.cachedSeq, 42)
    }

    // MARK: - Deep Tree

    func testDeepTree() {
        var leaf = makeNode(id: 50, state: "failed", depth: 49)
        for i in stride(from: 49, through: 1, by: -1) {
            leaf = makeNode(id: i, type: .sequence, children: [leaf], depth: i - 1)
        }
        let index = AncestorErrorIndex(root: leaf, seq: 1)
        for i in 1..<50 {
            XCTAssertTrue(index.hasFailedDescendant(i), "Node \(i) should have failed descendant")
        }
        XCTAssertFalse(index.hasFailedDescendant(50))
    }

    // MARK: - Separate Branches

    func testSeparateBranchesOnlyAffectOwnAncestors() {
        let root = makeNode(id: 1, type: .parallel, children: [
            makeNode(id: 2, type: .sequence, children: [
                makeNode(id: 3, state: "finished", depth: 2),
            ], depth: 1),
            makeNode(id: 4, type: .sequence, children: [
                makeNode(id: 5, state: "failed", depth: 2),
            ], depth: 1),
        ])
        let index = AncestorErrorIndex(root: root, seq: 1)
        XCTAssertTrue(index.hasFailedDescendant(1))
        XCTAssertFalse(index.hasFailedDescendant(2))
        XCTAssertTrue(index.hasFailedDescendant(4))
        XCTAssertFalse(index.hasFailedDescendant(3))
    }
}
