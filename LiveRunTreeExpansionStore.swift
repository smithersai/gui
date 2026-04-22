import Foundation
import SwiftUI

final class LiveRunTreeExpansionStore: ObservableObject {
    static let shared = LiveRunTreeExpansionStore()

    @Published private var expandedByRunId: [String: Set<Int>] = [:]
    @Published private var userCollapsedByRunId: [String: Set<Int>] = [:]

    func expandedIds(runId: String?) -> Set<Int> {
        guard let runId else { return [] }
        return expandedByRunId[runId] ?? []
    }

    func userCollapsedIds(runId: String?) -> Set<Int> {
        guard let runId else { return [] }
        return userCollapsedByRunId[runId] ?? []
    }

    func toggle(nodeId: Int, runId: String?) {
        guard let runId else { return }
        var expanded = expandedByRunId[runId] ?? []
        var collapsed = userCollapsedByRunId[runId] ?? []
        if expanded.contains(nodeId) {
            expanded.remove(nodeId)
            collapsed.insert(nodeId)
        } else {
            expanded.insert(nodeId)
            collapsed.remove(nodeId)
        }
        expandedByRunId[runId] = expanded
        userCollapsedByRunId[runId] = collapsed
    }

    func collapse(nodeId: Int, runId: String?) {
        guard let runId else { return }
        var expanded = expandedByRunId[runId] ?? []
        var collapsed = userCollapsedByRunId[runId] ?? []
        expanded.remove(nodeId)
        collapsed.insert(nodeId)
        expandedByRunId[runId] = expanded
        userCollapsedByRunId[runId] = collapsed
    }

    func expand(nodeId: Int, runId: String?) {
        guard let runId else { return }
        var expanded = expandedByRunId[runId] ?? []
        var collapsed = userCollapsedByRunId[runId] ?? []
        expanded.insert(nodeId)
        collapsed.remove(nodeId)
        expandedByRunId[runId] = expanded
        userCollapsedByRunId[runId] = collapsed
    }

    func expandAll(_ ids: Set<Int>, runId: String?) {
        guard let runId, !ids.isEmpty else { return }
        var expanded = expandedByRunId[runId] ?? []
        expanded.formUnion(ids)
        expandedByRunId[runId] = expanded

        let collapsed = userCollapsedByRunId[runId] ?? []
        let trimmed = collapsed.subtracting(ids)
        if trimmed.count != collapsed.count {
            userCollapsedByRunId[runId] = trimmed
        }
    }

    func reset(runId: String?) {
        guard let runId else { return }
        expandedByRunId.removeValue(forKey: runId)
        userCollapsedByRunId.removeValue(forKey: runId)
    }
}
