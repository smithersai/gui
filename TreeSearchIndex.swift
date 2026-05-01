import Foundation

struct TreeSearchIndex: Sendable {
    let matchedIds: Set<Int>
    let query: String

    var isEmpty: Bool { query.isEmpty }
    var hasMatches: Bool { !matchedIds.isEmpty }

    init(root: DevToolsNode?, query: String) {
        self.query = query
        guard let root, !query.isEmpty else {
            matchedIds = []
            return
        }
        let normalizedQuery = Self.normalize(query)
        var matched = Set<Int>()
        Self.walk(node: root, query: normalizedQuery, matched: &matched)
        matchedIds = matched
    }

    func isMatch(_ nodeId: Int) -> Bool {
        isEmpty || matchedIds.contains(nodeId)
    }

    func isDimmed(_ nodeId: Int) -> Bool {
        !isEmpty && !matchedIds.contains(nodeId)
    }

    static func buildIndex(root: DevToolsNode?, query: String) -> TreeSearchIndex {
        TreeSearchIndex(root: root, query: query)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().precomposedStringWithCanonicalMapping
    }

    private static func walk(node: DevToolsNode, query: String, matched: inout Set<Int>) {
        let searchableFields = collectSearchableText(from: node)
        for field in searchableFields {
            if normalize(field).contains(query) {
                matched.insert(node.id)
                break
            }
        }
        for child in node.children {
            walk(node: child, query: query, matched: &matched)
        }
    }

    private static func collectSearchableText(from node: DevToolsNode) -> [String] {
        var fields: [String] = [node.name]

        if let typeName = typeTagName(node.type) {
            fields.append(typeName)
        }

        if let task = node.task {
            fields.append(task.nodeId)
            if let label = task.label { fields.append(label) }
            if let agent = task.agent { fields.append(agent) }
        }

        return fields
    }

    private static func typeTagName(_ type: SmithersNodeType) -> String? {
        switch type {
        case .workflow: return "Workflow"
        case .sequence: return "Sequence"
        case .parallel: return "Parallel"
        case .task: return "Task"
        case .forEach: return "ForEach"
        case .conditional: return "Conditional"
        case .mergeQueue: return "MergeQueue"
        case .branch: return "Branch"
        case .loop: return "Loop"
        case .worktree: return "Worktree"
        case .approval: return "Approval"
        case .timer: return "Timer"
        case .subflow: return "Subflow"
        case .waitForEvent: return "WaitForEvent"
        case .saga: return "Saga"
        case .tryCatch: return "TryCatch"
        case .fragment: return "Fragment"
        case .unknown: return nil
        }
    }
}
