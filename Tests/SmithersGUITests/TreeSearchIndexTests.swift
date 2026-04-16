import XCTest
@testable import SmithersGUI

final class TreeSearchIndexTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        id: Int,
        type: SmithersNodeType = .task,
        name: String = "Task",
        task: DevToolsTaskInfo? = nil,
        children: [DevToolsNode] = [],
        depth: Int = 0
    ) -> DevToolsNode {
        DevToolsNode(id: id, type: type, name: name, task: task, children: children, depth: depth)
    }

    private func makeTask(
        nodeId: String = "task:0",
        kind: String = "agent",
        agent: String? = nil,
        label: String? = nil
    ) -> DevToolsTaskInfo {
        DevToolsTaskInfo(nodeId: nodeId, kind: kind, agent: agent, label: label, outputTableName: nil, iteration: nil)
    }

    // MARK: - Empty Query

    func testEmptyQueryAllVisible() {
        let root = makeNode(id: 1, type: .workflow, name: "Workflow", children: [
            makeNode(id: 2, name: "TaskA", depth: 1),
            makeNode(id: 3, name: "TaskB", depth: 1),
        ])
        let index = TreeSearchIndex(root: root, query: "")
        XCTAssertTrue(index.isEmpty)
        XCTAssertTrue(index.isMatch(1))
        XCTAssertTrue(index.isMatch(2))
        XCTAssertTrue(index.isMatch(3))
        XCTAssertFalse(index.isDimmed(1))
        XCTAssertFalse(index.isDimmed(2))
    }

    // MARK: - Tag Match

    func testMatchesByTag() {
        let root = makeNode(id: 1, type: .workflow, name: "Workflow", children: [
            makeNode(id: 2, type: .task, name: "FetchData", depth: 1),
            makeNode(id: 3, type: .parallel, name: "Parallel", depth: 1),
        ])
        let index = TreeSearchIndex(root: root, query: "Parallel")
        XCTAssertTrue(index.isMatch(3))
        XCTAssertTrue(index.isDimmed(2))
    }

    func testMatchesByNodeName() {
        let root = makeNode(id: 1, type: .workflow, name: "ReviewWorkflow", children: [
            makeNode(id: 2, name: "FetchData", depth: 1),
        ])
        let index = TreeSearchIndex(root: root, query: "Review")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - NodeId Match

    func testMatchesByNodeId() {
        let root = makeNode(id: 1, name: "Task", task: makeTask(nodeId: "task:review:0"))
        let index = TreeSearchIndex(root: root, query: "review")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Label Match

    func testMatchesByLabel() {
        let root = makeNode(id: 1, name: "Task", task: makeTask(label: "Review PR #42"))
        let index = TreeSearchIndex(root: root, query: "PR #42")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Agent Match

    func testMatchesByAgent() {
        let root = makeNode(id: 1, name: "Task", task: makeTask(agent: "claude-opus-4-7"))
        let index = TreeSearchIndex(root: root, query: "opus")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Case Insensitive

    func testCaseInsensitive() {
        let root = makeNode(id: 1, type: .workflow, name: "ReviewWorkflow")
        let index = TreeSearchIndex(root: root, query: "REVIEW")
        XCTAssertTrue(index.isMatch(1))
    }

    func testCaseInsensitiveReverse() {
        let root = makeNode(id: 1, type: .workflow, name: "WORKFLOW")
        let index = TreeSearchIndex(root: root, query: "workflow")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Unicode

    func testUnicodeNormalization() {
        // é as precomposed vs decomposed
        let precomposed = "\u{00E9}" // é
        let decomposed = "\u{0065}\u{0301}" // e + combining acute

        let root = makeNode(id: 1, name: "R\(precomposed)sum\(precomposed)")
        let index = TreeSearchIndex(root: root, query: "r\(decomposed)sum")
        XCTAssertTrue(index.isMatch(1))
    }

    func testEmojiInName() {
        let root = makeNode(id: 1, name: "Task🚀Deploy")
        let index = TreeSearchIndex(root: root, query: "🚀")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Regex Metacharacters Treated Literally

    func testRegexMetacharactersLiteral() {
        let root = makeNode(id: 1, name: "Task", task: makeTask(nodeId: "task.review[0]"))
        let index = TreeSearchIndex(root: root, query: "[0]")
        XCTAssertTrue(index.isMatch(1))
    }

    func testDotInQuery() {
        let root = makeNode(id: 1, name: "Task", task: makeTask(nodeId: "task.review.0"))
        let index = TreeSearchIndex(root: root, query: "task.review")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Query Longer Than Fields

    func testQueryLongerThanAnyFieldEmptyMatches() {
        let root = makeNode(id: 1, name: "Short")
        let longQuery = String(repeating: "x", count: 500)
        let index = TreeSearchIndex(root: root, query: longQuery)
        XCTAssertFalse(index.isMatch(1))
        XCTAssertTrue(index.isDimmed(1))
        XCTAssertFalse(index.hasMatches)
    }

    // MARK: - Nil Root

    func testNilRoot() {
        let index = TreeSearchIndex(root: nil, query: "test")
        XCTAssertFalse(index.hasMatches)
    }

    // MARK: - Non-Matching Dimmed

    func testNonMatchingNodesDimmed() {
        let root = makeNode(id: 1, type: .workflow, name: "Workflow", children: [
            makeNode(id: 2, name: "FetchData", depth: 1),
            makeNode(id: 3, name: "ReviewPR", depth: 1),
            makeNode(id: 4, name: "MergeCode", depth: 1),
        ])
        let index = TreeSearchIndex(root: root, query: "Review")
        XCTAssertTrue(index.isDimmed(1))
        XCTAssertTrue(index.isDimmed(2))
        XCTAssertFalse(index.isDimmed(3))
        XCTAssertTrue(index.isDimmed(4))
    }

    // MARK: - Performance

    func testLargeTreePerformance() {
        var children: [DevToolsNode] = []
        for i in 1...10000 {
            children.append(makeNode(
                id: i + 1,
                name: "Task\(i)",
                task: makeTask(nodeId: "task:\(i)", label: "Label \(i)"),
                depth: 1
            ))
        }
        let root = makeNode(id: 1, type: .workflow, name: "BigWorkflow", children: children)

        measure {
            _ = TreeSearchIndex(root: root, query: "Task5000")
        }
    }

    // MARK: - Build Index Static Method

    func testBuildIndexStaticMethod() {
        let root = makeNode(id: 1, name: "TestNode")
        let index = TreeSearchIndex.buildIndex(root: root, query: "Test")
        XCTAssertTrue(index.isMatch(1))
    }

    // MARK: - Multiple Matches in Tree

    func testMultipleMatchesInTree() {
        let root = makeNode(id: 1, type: .workflow, name: "Workflow", children: [
            makeNode(id: 2, name: "ReviewA", depth: 1),
            makeNode(id: 3, name: "ReviewB", depth: 1),
            makeNode(id: 4, name: "Deploy", depth: 1),
        ])
        let index = TreeSearchIndex(root: root, query: "Review")
        XCTAssertTrue(index.isMatch(2))
        XCTAssertTrue(index.isMatch(3))
        XCTAssertFalse(index.isMatch(4))
        XCTAssertTrue(index.hasMatches)
    }

    // MARK: - Type Tag Name Matching

    func testMatchesByTypeName() {
        let root = makeNode(id: 1, type: .forEach, name: "Loop")
        let index = TreeSearchIndex(root: root, query: "ForEach")
        XCTAssertTrue(index.isMatch(1))
    }

    func testMatchesWorkflowType() {
        let root = makeNode(id: 1, type: .workflow, name: "MyFlow")
        let index = TreeSearchIndex(root: root, query: "Workflow")
        XCTAssertTrue(index.isMatch(1))
    }
}
