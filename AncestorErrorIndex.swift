import Foundation

struct AncestorErrorIndex: Sendable {
    let ancestorsWithFailedDescendants: Set<Int>
    let failedDescendantCounts: [Int: Int]
    let cachedSeq: Int

    init(root: DevToolsNode?, seq: Int) {
        cachedSeq = seq
        guard let root else {
            ancestorsWithFailedDescendants = []
            failedDescendantCounts = [:]
            return
        }
        var ancestors = Set<Int>()
        var counts = [Int: Int]()
        Self.walk(node: root, ancestorPath: [], ancestors: &ancestors, counts: &counts)
        ancestorsWithFailedDescendants = ancestors
        failedDescendantCounts = counts
    }

    func hasFailedDescendant(_ nodeId: Int) -> Bool {
        ancestorsWithFailedDescendants.contains(nodeId)
    }

    func failedDescendantCount(_ nodeId: Int) -> Int {
        failedDescendantCounts[nodeId] ?? 0
    }

    private static func walk(
        node: DevToolsNode,
        ancestorPath: [Int],
        ancestors: inout Set<Int>,
        counts: inout [Int: Int]
    ) {
        let state = extractState(from: node)
        if state.isFailed {
            for ancestorId in ancestorPath {
                ancestors.insert(ancestorId)
                counts[ancestorId, default: 0] += 1
            }
        }

        let newPath = ancestorPath + [node.id]
        for child in node.children {
            walk(node: child, ancestorPath: newPath, ancestors: &ancestors, counts: &counts)
        }
    }
}
