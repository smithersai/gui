import Foundation

extension Smithers {
    enum DevTools {
        static func validateRunId(_ runId: String) throws -> Bool {
            isValid(runId, maxLength: 64, extraAllowed: [])
        }

        static func validateNodeId(_ nodeId: String) throws -> Bool {
            isValid(nodeId, maxLength: 128, extraAllowed: [":"])
        }

        static func validateIteration(_ iteration: Int) throws -> Bool {
            iteration >= 0
        }

        static func validateFrameNo(_ frameNo: Int) throws -> Bool {
            frameNo >= 0
        }

        static func sqlQuote(_ value: String) throws -> String {
            "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }

        static func normalizeNodeState(_ state: String) throws -> String {
            let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = trimmed
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
                .replacingOccurrences(of: " ", with: "-")

            switch token {
            case "running", "in-progress", "inprogress", "started":
                return "running"
            case "finished", "complete", "completed", "success", "succeeded", "done":
                return "finished"
            case "failed", "failure", "error", "errored":
                return "failed"
            case "waiting-approval", "waitingapproval":
                return "waitingApproval"
            case "blocked", "paused":
                return "blocked"
            case "cancelled", "canceled", "skipped":
                return "cancelled"
            case "pending", "":
                return "pending"
            default:
                return state
            }
        }

        static func rolledUpState(childStates: [String]) throws -> String? {
            var bestState: String?
            var bestRank = Int.min
            for state in childStates where !state.isEmpty {
                let rank = rollupRank(state)
                if bestState == nil || rank > bestRank {
                    bestState = state
                    bestRank = rank
                }
            }
            return bestState
        }

        static func nodeStateQuery(runId: String) throws -> String {
            """
            SELECT node_id, state, iteration, last_attempt
            FROM _smithers_nodes
            WHERE run_id=\(try sqlQuote(runId))
            ORDER BY iteration ASC;
            """
        }

        static func attemptQuery(runId: String) throws -> String {
            """
            SELECT node_id, iteration, attempt, state, started_at_ms, finished_at_ms
            FROM _smithers_attempts
            WHERE run_id=\(try sqlQuote(runId))
            ORDER BY started_at_ms ASC;
            """
        }

        static func nodeStateDict(fromRows rows: [[String: Any]]) throws -> [String: DevToolsNodeStateEntry] {
            var entries: [String: DevToolsNodeStateEntry] = [:]
            for row in rows {
                guard let nodeId = stringValue(row["node_id"]),
                      let state = stringValue(row["state"])
                else { continue }
                let iteration = intValue(row["iteration"]) ?? 0
                let entry = DevToolsNodeStateEntry(
                    nodeId: nodeId,
                    state: state,
                    iteration: iteration,
                    lastAttempt: intValue(row["last_attempt"])
                )
                if let existing = entries[nodeId], existing.iteration >= iteration {
                    continue
                }
                entries[nodeId] = entry
            }
            return entries
        }

        static func attemptEntries(fromRows rows: [[String: Any]]) throws -> [DevToolsAttemptEntry] {
            rows.compactMap { row in
                guard let nodeId = stringValue(row["node_id"]),
                      let startedAtMs = int64Value(row["started_at_ms"])
                else { return nil }
                return DevToolsAttemptEntry(
                    nodeId: nodeId,
                    iteration: intValue(row["iteration"]) ?? 0,
                    attempt: intValue(row["attempt"]) ?? 0,
                    state: stringValue(row["state"]) ?? "",
                    startedAtMs: startedAtMs,
                    finishedAtMs: int64Value(row["finished_at_ms"])
                )
            }
        }

        static func nodeStatesAtTimestamp(
            attempts: [DevToolsAttemptEntry],
            frameTimestampMs: Int64
        ) throws -> [String: DevToolsNodeStateEntry] {
            var chosenByIteration: [String: DevToolsAttemptEntry] = [:]
            for entry in attempts where entry.startedAtMs <= frameTimestampMs {
                let key = "\(entry.nodeId)\u{0}\(entry.iteration)"
                if let existing = chosenByIteration[key],
                   existing.attempt > entry.attempt ||
                   (existing.attempt == entry.attempt && existing.startedAtMs >= entry.startedAtMs) {
                    continue
                }
                chosenByIteration[key] = entry
            }

            var latestByNode: [String: DevToolsAttemptEntry] = [:]
            for entry in chosenByIteration.values {
                if let existing = latestByNode[entry.nodeId], existing.iteration >= entry.iteration {
                    continue
                }
                latestByNode[entry.nodeId] = entry
            }

            var states: [String: DevToolsNodeStateEntry] = [:]
            for entry in latestByNode.values {
                let stateAtFrame: String
                if let finishedAtMs = entry.finishedAtMs {
                    stateAtFrame = finishedAtMs <= frameTimestampMs ? entry.state : "running"
                } else {
                    stateAtFrame = "running"
                }
                states[entry.nodeId] = DevToolsNodeStateEntry(
                    nodeId: entry.nodeId,
                    state: stateAtFrame,
                    iteration: entry.iteration,
                    lastAttempt: entry.attempt
                )
            }
            return states
        }

        static func buildTree(
            xml: DevToolsFrameXMLNode,
            taskIndex: [DevToolsTaskIndexEntry],
            nodeStates: [String: DevToolsNodeStateEntry]
        ) throws -> DevToolsNode {
            var nextID = 0
            return buildNode(
                xml: xml,
                depth: 0,
                nextID: &nextID,
                taskIndex: taskIndex,
                nodeStates: nodeStates
            ).node
        }

        static func applyFrameDeltas(
            _ deltas: [DevToolsFrameDelta],
            toKeyframe keyframe: DevToolsFrameXMLNode
        ) throws -> DevToolsFrameXMLNode {
            var tree = keyframe
            for delta in deltas {
                for op in delta.ops {
                    switch op.op {
                    case "set":
                        applyFrameSet(path: op.path, value: op.value, to: &tree)
                    case "insert":
                        applyFrameInsert(path: op.path, value: op.value, to: &tree)
                    case "remove":
                        applyFrameRemove(path: op.path, from: &tree)
                    default:
                        continue
                    }
                }
            }
            return tree
        }

        static func applyDelta(_ delta: DevToolsDelta, to tree: DevToolsNode?) throws -> DevToolsNode? {
            try DevToolsDeltaApplier.applyDelta(delta, to: tree)
        }

        static func applyOp(_ op: DevToolsDeltaOp, to tree: DevToolsNode?) throws -> DevToolsNode? {
            try DevToolsDeltaApplier.applyOp(op, to: tree)
        }

        private static func isValid(_ value: String, maxLength: Int, extraAllowed: Set<Character>) -> Bool {
            guard !value.isEmpty, value.count <= maxLength else { return false }
            for character in value {
                if character.isLetter || character.isNumber || character == "_" || character == "-" {
                    continue
                }
                if extraAllowed.contains(character) {
                    continue
                }
                return false
            }
            return true
        }

        private static func rollupRank(_ state: String) -> Int {
            switch state {
            case "failed": return 6
            case "running": return 5
            case "blocked": return 4
            case "waitingApproval": return 3
            case "pending": return 2
            case "finished": return 1
            case "cancelled": return 0
            default: return -1
            }
        }

        private static func buildNode(
            xml: DevToolsFrameXMLNode,
            depth: Int,
            nextID: inout Int,
            taskIndex: [DevToolsTaskIndexEntry],
            nodeStates: [String: DevToolsNodeStateEntry]
        ) -> (node: DevToolsNode, state: String) {
            let id = nextID
            nextID += 1

            let tag = xml.tag ?? ""
            let type = smithersType(tag)
            let name = derivedName(tag: tag, props: xml.props)

            var props = xml.props.mapValues { JSONValue.string($0) }
            var inlineText = xml.text
            var children: [DevToolsNode] = []
            var childStates: [String] = []

            for childXML in xml.children {
                if childXML.kind == "text" || childXML.kind == "cdata" {
                    guard let text = childXML.text, !text.isEmpty else { continue }
                    if let existing = inlineText, !existing.isEmpty {
                        inlineText = "\(existing)\n\(text)"
                    } else {
                        inlineText = text
                    }
                    continue
                }
                let built = buildNode(
                    xml: childXML,
                    depth: depth + 1,
                    nextID: &nextID,
                    taskIndex: taskIndex,
                    nodeStates: nodeStates
                )
                children.append(built.node)
                childStates.append(built.state)
            }

            if let inlineText {
                props["text"] = .string(inlineText)
            }

            var task: DevToolsTaskInfo?
            if type == .task, let nodeId = stringJSON(props["id"]) {
                let indexEntry = taskIndex.first { $0.nodeId == nodeId }
                task = DevToolsTaskInfo(
                    nodeId: nodeId,
                    kind: indexEntry?.kind ?? "agent",
                    agent: indexEntry?.agent,
                    label: indexEntry?.label,
                    outputTableName: indexEntry?.outputTableName,
                    iteration: indexEntry?.iteration
                )

                if stringJSON(props["state"])?.isEmpty ?? true {
                    if let stateEntry = nodeStates[nodeId] {
                        props["state"] = .string((try? normalizeNodeState(stateEntry.state)) ?? stateEntry.state)
                        if props["iteration"] == nil {
                            props["iteration"] = .string(String(stateEntry.iteration))
                        }
                    } else {
                        props["state"] = .string("pending")
                    }
                }
            }

            var stateForParent = stringJSON(props["state"]) ?? ""
            if !children.isEmpty, stateForParent.isEmpty,
               let rolled = try? rolledUpState(childStates: childStates) {
                props["state"] = .string(rolled)
                stateForParent = rolled
            }

            return (
                DevToolsNode(
                    id: id,
                    type: type,
                    name: name,
                    props: props,
                    task: task,
                    children: children,
                    depth: depth
                ),
                stateForParent
            )
        }

        private static func smithersType(_ tag: String) -> SmithersNodeType {
            switch tag {
            case "smithers:workflow": return .workflow
            case "smithers:sequence": return .sequence
            case "smithers:parallel": return .parallel
            case "smithers:task": return .task
            case "smithers:forEach", "smithers:foreach", "smithers:for-each": return .forEach
            case "smithers:conditional", "smithers:if": return .conditional
            default: return .unknown
            }
        }

        private static func derivedName(tag: String, props: [String: String]) -> String {
            for key in ["name", "id"] {
                if let value = props[key], !value.isEmpty {
                    return value
                }
            }
            if tag.hasPrefix("smithers:") {
                return String(tag.dropFirst("smithers:".count))
            }
            return tag.isEmpty ? "node" : tag
        }

        private static func applyFrameSet(
            path: [DevToolsFrameDelta.PathComponent],
            value: JSONValue?,
            to tree: inout DevToolsFrameXMLNode
        ) {
            guard !path.isEmpty else {
                if let value, let node = frameNode(from: value) {
                    tree = node
                }
                return
            }
            mutateFrameLeaf(path: path, in: &tree) { node in
                let last = path[path.count - 1]
                if case .key(let key) = last {
                    if key == "text" {
                        if case .string(let text)? = value {
                            node.text = text
                        }
                        return
                    }
                    if path.count >= 2,
                       case .key(let parentKey) = path[path.count - 2],
                       parentKey == "props" {
                        setFrameProp(key, value: value, on: &node)
                        return
                    }
                    if node.kind == "element" {
                        setFrameProp(key, value: value, on: &node)
                    }
                } else if case .index(let index) = last,
                          let value,
                          let replacement = frameNode(from: value),
                          node.children.indices.contains(index) {
                    node.children[index] = replacement
                }
            }
        }

        private static func applyFrameInsert(
            path: [DevToolsFrameDelta.PathComponent],
            value: JSONValue?,
            to tree: inout DevToolsFrameXMLNode
        ) {
            guard let last = path.last,
                  case .index(let rawIndex) = last,
                  let value,
                  let inserted = frameNode(from: value)
            else { return }
            mutateFrameLeaf(path: path, in: &tree) { node in
                let index = max(0, min(rawIndex, node.children.count))
                node.children.insert(inserted, at: index)
            }
        }

        private static func applyFrameRemove(
            path: [DevToolsFrameDelta.PathComponent],
            from tree: inout DevToolsFrameXMLNode
        ) {
            guard let last = path.last, case .index(let index) = last else { return }
            mutateFrameLeaf(path: path, in: &tree) { node in
                guard node.children.indices.contains(index) else { return }
                node.children.remove(at: index)
            }
        }

        private static func mutateFrameLeaf(
            path: [DevToolsFrameDelta.PathComponent],
            in tree: inout DevToolsFrameXMLNode,
            _ body: (inout DevToolsFrameXMLNode) -> Void
        ) {
            var indexes: [Int] = []
            var offset = 0
            while path.count - offset > 2 {
                guard case .key(let key) = path[offset],
                      key == "children",
                      case .index(let childIndex) = path[offset + 1]
                else { break }
                indexes.append(childIndex)
                offset += 2
            }
            mutateFrameNode(at: indexes[...], in: &tree, body)
        }

        private static func mutateFrameNode(
            at indexes: ArraySlice<Int>,
            in node: inout DevToolsFrameXMLNode,
            _ body: (inout DevToolsFrameXMLNode) -> Void
        ) {
            guard let first = indexes.first else {
                body(&node)
                return
            }
            guard node.children.indices.contains(first) else { return }
            mutateFrameNode(at: indexes.dropFirst(), in: &node.children[first], body)
        }

        private static func setFrameProp(
            _ key: String,
            value: JSONValue?,
            on node: inout DevToolsFrameXMLNode
        ) {
            guard let value else {
                node.props.removeValue(forKey: key)
                return
            }
            switch value {
            case .string(let text):
                node.props[key] = text
            case .number(let number):
                if number.rounded() == number, abs(number) < 1e15 {
                    node.props[key] = String(Int64(number))
                } else {
                    node.props[key] = String(number)
                }
            case .bool(let bool):
                node.props[key] = bool ? "true" : "false"
            case .null:
                node.props.removeValue(forKey: key)
            default:
                node.props[key] = value.compactJSONString
            }
        }

        private static func frameNode(from value: JSONValue) -> DevToolsFrameXMLNode? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return try? JSONDecoder().decode(DevToolsFrameXMLNode.self, from: data)
        }

        private static func stringJSON(_ value: JSONValue?) -> String? {
            guard let value else { return nil }
            if case .string(let text) = value {
                return text
            }
            return value.compactJSONString
        }

        private static func stringValue(_ value: Any?) -> String? {
            switch value {
            case let value as String:
                return value
            case let value as NSNumber:
                return value.stringValue
            default:
                return nil
            }
        }

        private static func intValue(_ value: Any?) -> Int? {
            switch value {
            case let value as Int:
                return value
            case let value as Int64:
                return Int(value)
            case let value as NSNumber:
                return value.intValue
            case let value as String:
                return Int(value)
            default:
                return nil
            }
        }

        private static func int64Value(_ value: Any?) -> Int64? {
            switch value {
            case let value as Int64:
                return value
            case let value as Int:
                return Int64(value)
            case let value as NSNumber:
                return value.int64Value
            case let value as String:
                return Int64(value)
            default:
                return nil
            }
        }
    }
}
