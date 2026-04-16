import Foundation

/// Reports how an incoming stream event changed transcript state.
struct ChatBlockMergeStats {
    let appended: Int
    let replaced: Int
    let merged: Int

    static let none = ChatBlockMergeStats(appended: 0, replaced: 0, merged: 0)
}

/// Maintains a deduplicated, stream-merge-safe transcript with O(1) lifecycle lookups.
struct ChatBlockMerger {
    private(set) var blocks: [ChatBlock] = []
    private var indexByLifecycleId: [String: Int] = [:]

    mutating func reset() {
        blocks.removeAll(keepingCapacity: false)
        indexByLifecycleId.removeAll(keepingCapacity: false)
    }

    mutating func replaceAll(with newBlocks: [ChatBlock]) {
        reset()
        append(contentsOf: newBlocks)
    }

    @discardableResult
    mutating func append(_ block: ChatBlock) -> ChatBlockMergeStats {
        if let lifecycleId = block.lifecycleId,
           !lifecycleId.isEmpty,
           let existingIndex = resolveIndex(forLifecycleId: lifecycleId) {
            let existing = blocks[existingIndex]
            if existing.canMergeAssistantStream(with: block) {
                blocks[existingIndex] = existing.mergingAssistantStream(with: block)
                indexLifecycleIds(for: existing, at: existingIndex)
                indexLifecycleIds(for: block, at: existingIndex)
                indexLifecycleIds(for: blocks[existingIndex], at: existingIndex)
                return ChatBlockMergeStats(appended: 0, replaced: 0, merged: 1)
            }

            blocks[existingIndex] = block
            indexLifecycleIds(for: existing, at: existingIndex)
            indexLifecycleIds(for: block, at: existingIndex)
            return ChatBlockMergeStats(appended: 0, replaced: 1, merged: 0)
        }

        if let lastIndex = blocks.indices.last {
            let existing = blocks[lastIndex]
            let existingLifecycleId = existing.lifecycleId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let incomingLifecycleId = block.lifecycleId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDistinctLifecycleIds: Bool = {
                guard let existingLifecycleId,
                      !existingLifecycleId.isEmpty,
                      let incomingLifecycleId,
                      !incomingLifecycleId.isEmpty else {
                    return false
                }
                return existingLifecycleId != incomingLifecycleId
            }()

            if !hasDistinctLifecycleIds,
               existing.canMergeAssistantStream(with: block),
               existing.hasStreamingContentOverlap(with: block) {
                blocks[lastIndex] = existing.mergingAssistantStream(with: block)
                indexLifecycleIds(for: existing, at: lastIndex)
                indexLifecycleIds(for: block, at: lastIndex)
                indexLifecycleIds(for: blocks[lastIndex], at: lastIndex)
                return ChatBlockMergeStats(appended: 0, replaced: 0, merged: 1)
            }
        }

        blocks.append(block)
        indexLifecycleIds(for: block, at: blocks.count - 1)
        return ChatBlockMergeStats(appended: 1, replaced: 0, merged: 0)
    }

    @discardableResult
    mutating func append(contentsOf incomingBlocks: [ChatBlock]) -> ChatBlockMergeStats {
        var appended = 0
        var replaced = 0
        var merged = 0

        for block in incomingBlocks {
            let stats = append(block)
            appended += stats.appended
            replaced += stats.replaced
            merged += stats.merged
        }

        return ChatBlockMergeStats(appended: appended, replaced: replaced, merged: merged)
    }

    static func merged(_ blocks: [ChatBlock]) -> [ChatBlock] {
        var merger = ChatBlockMerger()
        merger.append(contentsOf: blocks)
        return merger.blocks
    }

    private func resolveIndex(forLifecycleId lifecycleId: String) -> Int? {
        if let mapped = indexByLifecycleId[lifecycleId], blocks.indices.contains(mapped) {
            return mapped
        }
        return blocks.lastIndex(where: { $0.lifecycleId == lifecycleId })
    }

    private mutating func indexLifecycleIds(for block: ChatBlock, at index: Int) {
        guard blocks.indices.contains(index) else { return }
        if let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty {
            indexByLifecycleId[lifecycleId] = index
        }
    }
}
