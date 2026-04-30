import Foundation

extension Smithers {
    enum Models {
        static func aggregateScores(_ scores: [ScoreRow]) throws -> [AggregateScore] {
            var namesByID: [String: String] = [:]
            for row in scores {
                guard let id = normalized(row.scorerId)?.lowercased(),
                      let name = normalized(row.scorerName),
                      namesByID[id] == nil else { continue }
                namesByID[id] = name
            }

            let groups = Dictionary(grouping: scores) { row -> String in
                if let name = normalized(row.scorerName) { return name.lowercased() }
                if let id = normalized(row.scorerId) { return namesByID[id.lowercased()]?.lowercased() ?? id.lowercased() }
                return "unknown"
            }

            return groups.compactMap { _, rows in
                let values = rows.map(\.score).sorted()
                guard !values.isEmpty else { return nil }
                let name = normalized(rows.first?.scorerName)
                    ?? rows.compactMap { row in normalized(row.scorerId).flatMap { namesByID[$0.lowercased()] } }.first
                    ?? normalized(rows.first?.scorerId)
                    ?? "Unknown"
                let sum = values.reduce(0, +)
                let mid = values.count / 2
                let p50 = values.count.isMultiple(of: 2)
                    ? (values[mid - 1] + values[mid]) / 2.0
                    : values[mid]
                return AggregateScore(
                    scorerName: name,
                    count: values.count,
                    mean: sum / Double(values.count),
                    min: values[0],
                    max: values[values.count - 1],
                    p50: p50
                )
            }
            .sorted { $0.scorerName.localizedCaseInsensitiveCompare($1.scorerName) == .orderedAscending }
        }

        static func deduplicatedChatMessages(_ messages: [ChatMessage]) throws -> [ChatMessage] {
            var result: [ChatMessage] = []
            var indexByItemID: [String: Int] = [:]
            for message in messages {
                let itemID = normalized(message.command?.itemID) ?? normalized(message.tool?.itemID)
                guard let itemID else {
                    result.append(message)
                    continue
                }
                if let index = indexByItemID[itemID] {
                    result[index] = message
                } else {
                    indexByItemID[itemID] = result.count
                    result.append(message)
                }
            }
            return result
        }

        static func deduplicatedChatBlocks(_ blocks: [ChatBlock]) throws -> [ChatBlock] {
            ChatBlockMerger.merged(blocks)
        }

        static func chatBlockCanMerge(_ existing: ChatBlock, with incoming: ChatBlock) throws -> Bool {
            isAssistantLike(existing)
                && isAssistantLike(incoming)
                && existing.attemptIndex == incoming.attemptIndex
                && compatibleIdentifier(existing.runId, incoming.runId)
                && compatibleIdentifier(existing.nodeId, incoming.nodeId)
        }

        static func chatBlockHasOverlap(_ existing: ChatBlock, with incoming: ChatBlock) throws -> Bool {
            hasStreamingContentOverlap(existing.content, incoming.content)
        }

        static func chatBlockMerge(_ existing: ChatBlock, with incoming: ChatBlock) throws -> ChatBlock {
            let shouldMergeContent = hasStreamingContentOverlap(existing.content, incoming.content)
                || (existing.timestampMs != nil && incoming.timestampMs != nil)
            let content = shouldMergeContent
                ? try mergedStreamingContent(
                    existing: existing.content,
                    incoming: incoming.content,
                    existingTimestampMs: existing.timestampMs,
                    incomingTimestampMs: incoming.timestampMs
                )
                : incoming.content
            return ChatBlock(
                id: incoming.id ?? existing.id,
                itemId: incoming.itemId ?? existing.itemId,
                runId: incoming.runId ?? existing.runId,
                nodeId: incoming.nodeId ?? existing.nodeId,
                attempt: incoming.attempt ?? existing.attempt,
                role: incoming.role,
                content: content,
                timestampMs: incoming.timestampMs ?? existing.timestampMs
            )
        }

        static func mergedStreamingContent(
            existing: String,
            incoming: String,
            existingTimestampMs: Int64? = nil,
            incomingTimestampMs: Int64? = nil
        ) throws -> String {
            if existing.isEmpty { return incoming }
            if incoming.isEmpty { return existing }
            if existing == incoming { return existing }
            if incoming.hasPrefix(existing) {
                let continuation = String(incoming.dropFirst(existing.count))
                if let collapsed = collapsedRetransmittedContinuation(existing: existing, continuation: continuation) {
                    return collapsed
                }
                return incoming
            }
            if existing.hasPrefix(incoming) { return existing }
            if existing.contains(incoming) { return existing }
            if incoming.contains(existing) { return incoming }

            let forward = suffixPrefixOverlap(existing, incoming)
            let reverse = suffixPrefixOverlap(incoming, existing)
            if forward > 0 || reverse > 0 {
                if reverse > forward {
                    return incoming + String(existing.dropFirst(reverse))
                }
                return existing + String(incoming.dropFirst(forward))
            }

            if let range = inferredOffsetRange(existing: existing, incoming: incoming) {
                return String(existing.prefix(range.existingEnd)) + String(incoming.dropFirst(range.incomingOffset))
            }

            if let existingTimestampMs,
               let incomingTimestampMs,
               incomingTimestampMs < existingTimestampMs {
                return incoming + existing
            }
            return existing + incoming
        }

        static func filteredSSEEvent(
            event: String?,
            data: String,
            eventRunId: String?,
            expectedRunId: String?,
            requireAttributedRunId: Bool
        ) throws -> SSEEvent? {
            let expected = normalizedRunId(expectedRunId)
            let eventID = normalizedRunId(eventRunId)
            let payloadID = extractRunId(from: data)
            if let eventID, let payloadID, eventID != payloadID { return nil }
            let resolved = eventID ?? payloadID
            if requireAttributedRunId, expected != nil, resolved == nil { return nil }
            guard try sseRunId(resolved, matches: expected) else { return nil }
            return SSEEvent(event: event, data: data, runId: resolved ?? expected)
        }

        static func sseExtractRunId(from data: String) throws -> String? {
            extractRunId(from: data)
        }

        static func sseRunId(_ actualRunId: String?, matches expectedRunId: String?) throws -> Bool {
            let expected = normalizedRunId(expectedRunId)
            let actual = normalizedRunId(actualRunId)
            guard let expected else { return true }
            guard let actual else { return true }
            return actual == expected
        }

        static func sseNormalizedRunId(_ runId: String?) throws -> String? {
            normalizedRunId(runId)
        }

        private static func isAssistantLike(_ block: ChatBlock) -> Bool {
            let role = block.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return role == "assistant" || role == "agent"
        }

        private static func compatibleIdentifier(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs = normalized(lhs), let rhs = normalized(rhs) else { return true }
            return lhs == rhs
        }

        private static func hasStreamingContentOverlap(_ existing: String, _ incoming: String) -> Bool {
            if existing.isEmpty || incoming.isEmpty { return false }
            if existing == incoming { return true }
            if existing.hasPrefix(incoming) || incoming.hasPrefix(existing) { return true }
            if existing.contains(incoming) || incoming.contains(existing) { return true }
            if inferredOffsetRange(existing: existing, incoming: incoming) != nil { return true }
            return suffixPrefixOverlap(existing, incoming) > 0 || suffixPrefixOverlap(incoming, existing) > 0
        }

        private static func collapsedRetransmittedContinuation(existing: String, continuation: String) -> String? {
            if continuation.isEmpty { return existing }
            let overlap = suffixPrefixOverlap(existing, continuation)
            guard overlap >= minimumReliableOverlapLength(existing, continuation) else { return nil }
            return existing + String(continuation.dropFirst(overlap))
        }

        private static func inferredOffsetRange(existing: String, incoming: String) -> (existingEnd: Int, incomingOffset: Int)? {
            let maxLength = min(existing.count, incoming.count)
            let minLength = minimumReliableOverlapLength(existing, incoming)
            guard minLength > 0, maxLength >= minLength else { return nil }
            let existingChars = Array(existing)
            let incomingChars = Array(incoming)
            var length = maxLength
            while length >= minLength {
                let prefix = String(incomingChars[0..<length])
                if let range = existing.range(of: prefix, options: .backwards) {
                    let match = existing.distance(from: existing.startIndex, to: range.lowerBound)
                    if match + length < existingChars.count {
                        return (match + length, length)
                    }
                }
                if length == minLength { break }
                length -= 1
            }
            return nil
        }

        private static func suffixPrefixOverlap(_ lhs: String, _ rhs: String) -> Int {
            let lhsChars = Array(lhs)
            let rhsChars = Array(rhs)
            var length = min(lhsChars.count, rhsChars.count)
            while length > 0 {
                if Array(lhsChars[(lhsChars.count - length)..<lhsChars.count]) == Array(rhsChars[0..<length]) {
                    return length
                }
                length -= 1
            }
            return 0
        }

        private static func minimumReliableOverlapLength(_ existing: String, _ incoming: String) -> Int {
            let shortest = min(existing.count, incoming.count)
            if shortest < 6 { return 0 }
            return min(24, max(6, shortest / 3))
        }

        private static func extractRunId(from data: String) -> String? {
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let jsonData = trimmed.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: jsonData) else { return nil }
            return extractRunId(from: value)
        }

        private static func extractRunId(from value: Any) -> String? {
            if let dict = value as? [String: Any] {
                for key in ["runId", "run_id", "workflowRunId", "workflow_run_id"] {
                    if let id = normalizedRunId(dict[key]) { return id }
                }
                for key in ["event", "data", "block", "payload", "message"] {
                    if let nested = dict[key], let id = extractRunId(from: nested) { return id }
                }
                for (key, nested) in dict where !["event", "data", "block", "payload", "message"].contains(key) {
                    if let id = extractRunId(from: nested) { return id }
                }
            } else if let array = value as? [Any] {
                for nested in array {
                    if let id = extractRunId(from: nested) { return id }
                }
            } else if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
                   let data = trimmed.data(using: .utf8),
                   let nested = try? JSONSerialization.jsonObject(with: data) {
                    return extractRunId(from: nested)
                }
            }
            return nil
        }

        private static func normalizedRunId(_ value: Any?) -> String? {
            switch value {
            case let value as String:
                return normalized(value)
            case let value as Int:
                return String(value)
            case let value as Int64:
                return String(value)
            case let value as Double:
                return value == value.rounded() ? String(Int64(value)) : String(value)
            default:
                return nil
            }
        }

        private static func normalized(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}
