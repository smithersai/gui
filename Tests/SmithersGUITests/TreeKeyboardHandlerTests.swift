import XCTest
@testable import SmithersGUI

final class TreeKeyboardHandlerTests: XCTestCase {

    // MARK: - Helpers

    private func makeNode(
        id: Int,
        type: SmithersNodeType = .task,
        name: String = "Node",
        children: [DevToolsNode] = [],
        depth: Int = 0
    ) -> DevToolsNode {
        DevToolsNode(id: id, type: type, name: name, children: children, depth: depth)
    }

    private func makeTree() -> (root: DevToolsNode, visible: [DevToolsNode]) {
        let child1 = makeNode(id: 2, name: "Child1", depth: 1)
        let child2 = makeNode(id: 3, name: "Child2", depth: 1)
        let grandchild = makeNode(id: 4, name: "Grandchild", depth: 2)
        let child3 = makeNode(id: 5, name: "Child3", children: [grandchild], depth: 1)
        let root = makeNode(id: 1, type: .workflow, name: "Root", children: [child1, child2, child3])
        let visible = [root, child1, child2, child3]
        return (root, visible)
    }

    // MARK: - Move Down

    func testMoveDownFromFirstRow() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: 1,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 2)
        XCTAssertNil(result.expandedChange)
    }

    func testMoveDownFromLastRow() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: 5,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 5)
    }

    func testMoveDownFromNilSelectsFirst() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: nil,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testMoveDownFromMiddle() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 3)
    }

    // MARK: - Move Up

    func testMoveUpFromSecondRow() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveUp,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testMoveUpFromFirstRow() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveUp,
            selectedId: 1,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testMoveUpFromNilSelectsLast() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveUp,
            selectedId: nil,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 5)
    }

    // MARK: - Collapse

    func testCollapseExpandedNode() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .collapse,
            selectedId: 5,
            visibleRows: visible,
            expandedIds: [1, 5],
            root: root
        )
        XCTAssertEqual(result.selectedId, 5)
        XCTAssertEqual(result.expandedChange, .collapse(5))
    }

    func testCollapseAlreadyCollapsedMovesToParent() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .collapse,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
        XCTAssertNil(result.expandedChange)
    }

    func testCollapseLeafMovesToParent() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .collapse,
            selectedId: 3,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testCollapseNilSelection() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .collapse,
            selectedId: nil,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertNil(result.selectedId)
    }

    func testCollapseRootAlreadyCollapsed() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .collapse,
            selectedId: 1,
            visibleRows: visible,
            expandedIds: [],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    // MARK: - Expand

    func testExpandCollapsedNode() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .expand,
            selectedId: 5,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 5)
        XCTAssertEqual(result.expandedChange, .expand(5))
    }

    func testExpandAlreadyExpandedMovesToFirstChild() {
        let (root, _) = makeTree()
        let grandchild = root.children[2].children[0]
        let visibleWithGrandchild = [root, root.children[0], root.children[1], root.children[2], grandchild]
        let result = TreeKeyboardHandler.handle(
            action: .expand,
            selectedId: 5,
            visibleRows: visibleWithGrandchild,
            expandedIds: [1, 5],
            root: root
        )
        XCTAssertEqual(result.selectedId, 4)
    }

    func testExpandLeafNoChange() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .expand,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 2)
        XCTAssertNil(result.expandedChange)
    }

    func testExpandNilSelection() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .expand,
            selectedId: nil,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertNil(result.selectedId)
    }

    // MARK: - Focus Actions

    func testFocusInspector() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .focusInspector,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.focusChange, .inspector)
        XCTAssertEqual(result.selectedId, 2)
    }

    func testFocusSearch() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .focusSearch,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.focusChange, .search)
    }

    func testClearSearch() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .clearSearch,
            selectedId: 2,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.focusChange, .clearSearch)
    }

    // MARK: - Home / End

    func testMoveToFirst() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveToFirst,
            selectedId: 5,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testMoveToLast() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveToLast,
            selectedId: 1,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 5)
    }

    // MARK: - Empty Visible Rows

    func testMoveDownEmptyRows() {
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: nil,
            visibleRows: [],
            expandedIds: [],
            root: nil
        )
        XCTAssertNil(result.selectedId)
    }

    func testMoveUpEmptyRows() {
        let result = TreeKeyboardHandler.handle(
            action: .moveUp,
            selectedId: nil,
            visibleRows: [],
            expandedIds: [],
            root: nil
        )
        XCTAssertNil(result.selectedId)
    }

    // MARK: - Unknown Selection

    func testMoveDownWithUnknownSelectionSelectsFirst() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveDown,
            selectedId: 999,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    func testMoveUpWithUnknownSelectionSelectsFirst() {
        let (root, visible) = makeTree()
        let result = TreeKeyboardHandler.handle(
            action: .moveUp,
            selectedId: 999,
            visibleRows: visible,
            expandedIds: [1],
            root: root
        )
        XCTAssertEqual(result.selectedId, 1)
    }

    // MARK: - Result Equatable

    func testResultEquatable() {
        let r1 = TreeKeyboardHandler.Result(selectedId: 1, expandedChange: nil, focusChange: nil)
        let r2 = TreeKeyboardHandler.Result(selectedId: 1, expandedChange: nil, focusChange: nil)
        XCTAssertEqual(r1, r2)
    }

    func testResultNotEqual() {
        let r1 = TreeKeyboardHandler.Result(selectedId: 1, expandedChange: nil, focusChange: nil)
        let r2 = TreeKeyboardHandler.Result(selectedId: 2, expandedChange: nil, focusChange: nil)
        XCTAssertNotEqual(r1, r2)
    }
}
