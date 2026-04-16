import Foundation

struct TreeKeyboardHandler {
    enum Action: Equatable {
        case moveUp
        case moveDown
        case collapse
        case expand
        case focusInspector
        case focusSearch
        case clearSearch
        case moveToFirst
        case moveToLast
    }

    struct Result: Equatable {
        let selectedId: Int?
        let expandedChange: ExpandedChange?
        let focusChange: FocusChange?
    }

    enum ExpandedChange: Equatable {
        case collapse(Int)
        case expand(Int)
    }

    enum FocusChange: Equatable {
        case inspector
        case search
        case clearSearch
    }

    static func handle(
        action: Action,
        selectedId: Int?,
        visibleRows: [DevToolsNode],
        expandedIds: Set<Int>,
        root: DevToolsNode?
    ) -> Result {
        switch action {
        case .moveUp:
            return moveUp(selectedId: selectedId, visibleRows: visibleRows)
        case .moveDown:
            return moveDown(selectedId: selectedId, visibleRows: visibleRows)
        case .collapse:
            return collapse(selectedId: selectedId, visibleRows: visibleRows, expandedIds: expandedIds, root: root)
        case .expand:
            return expand(selectedId: selectedId, visibleRows: visibleRows, expandedIds: expandedIds)
        case .focusInspector:
            return Result(selectedId: selectedId, expandedChange: nil, focusChange: .inspector)
        case .focusSearch:
            return Result(selectedId: selectedId, expandedChange: nil, focusChange: .search)
        case .clearSearch:
            return Result(selectedId: selectedId, expandedChange: nil, focusChange: .clearSearch)
        case .moveToFirst:
            let firstId = visibleRows.first?.id
            return Result(selectedId: firstId, expandedChange: nil, focusChange: nil)
        case .moveToLast:
            let lastId = visibleRows.last?.id
            return Result(selectedId: lastId, expandedChange: nil, focusChange: nil)
        }
    }

    private static func moveUp(selectedId: Int?, visibleRows: [DevToolsNode]) -> Result {
        guard let selectedId else {
            return Result(selectedId: visibleRows.last?.id, expandedChange: nil, focusChange: nil)
        }
        guard let index = visibleRows.firstIndex(where: { $0.id == selectedId }) else {
            return Result(selectedId: visibleRows.first?.id, expandedChange: nil, focusChange: nil)
        }
        if index > 0 {
            return Result(selectedId: visibleRows[index - 1].id, expandedChange: nil, focusChange: nil)
        }
        return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
    }

    private static func moveDown(selectedId: Int?, visibleRows: [DevToolsNode]) -> Result {
        guard let selectedId else {
            return Result(selectedId: visibleRows.first?.id, expandedChange: nil, focusChange: nil)
        }
        guard let index = visibleRows.firstIndex(where: { $0.id == selectedId }) else {
            return Result(selectedId: visibleRows.first?.id, expandedChange: nil, focusChange: nil)
        }
        if index < visibleRows.count - 1 {
            return Result(selectedId: visibleRows[index + 1].id, expandedChange: nil, focusChange: nil)
        }
        return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
    }

    private static func collapse(
        selectedId: Int?,
        visibleRows: [DevToolsNode],
        expandedIds: Set<Int>,
        root: DevToolsNode?
    ) -> Result {
        guard let selectedId else {
            return Result(selectedId: nil, expandedChange: nil, focusChange: nil)
        }
        guard let node = root?.findNode(byId: selectedId) else {
            return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
        }

        if !node.children.isEmpty && expandedIds.contains(selectedId) {
            return Result(selectedId: selectedId, expandedChange: .collapse(selectedId), focusChange: nil)
        }

        if let parent = root?.findParent(ofNodeId: selectedId) {
            return Result(selectedId: parent.id, expandedChange: nil, focusChange: nil)
        }

        return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
    }

    private static func expand(
        selectedId: Int?,
        visibleRows: [DevToolsNode],
        expandedIds: Set<Int>
    ) -> Result {
        guard let selectedId else {
            return Result(selectedId: nil, expandedChange: nil, focusChange: nil)
        }
        guard let index = visibleRows.firstIndex(where: { $0.id == selectedId }) else {
            return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
        }

        let node = visibleRows[index]
        if !node.children.isEmpty && !expandedIds.contains(selectedId) {
            return Result(selectedId: selectedId, expandedChange: .expand(selectedId), focusChange: nil)
        }

        if !node.children.isEmpty && expandedIds.contains(selectedId) {
            if index < visibleRows.count - 1 {
                return Result(selectedId: visibleRows[index + 1].id, expandedChange: nil, focusChange: nil)
            }
        }

        return Result(selectedId: selectedId, expandedChange: nil, focusChange: nil)
    }
}
