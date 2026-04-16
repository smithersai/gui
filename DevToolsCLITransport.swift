import Foundation

// MARK: - Input validation

enum DevToolsInputValidator {
    private static let runIdRegex = try? NSRegularExpression(
        pattern: "^[A-Za-z0-9_-]{1,64}$"
    )
    private static let nodeIdRegex = try? NSRegularExpression(
        pattern: "^[A-Za-z0-9:_-]{1,128}$"
    )

    static func validate(runId: String) throws {
        guard let regex = runIdRegex else {
            throw DevToolsClientError.invalidRunId(runId)
        }
        let range = NSRange(runId.startIndex..., in: runId)
        if regex.firstMatch(in: runId, options: [], range: range) == nil {
            throw DevToolsClientError.invalidRunId(runId)
        }
    }

    static func validate(nodeId: String) throws {
        guard let regex = nodeIdRegex else {
            throw DevToolsClientError.invalidNodeId(nodeId)
        }
        let range = NSRange(nodeId.startIndex..., in: nodeId)
        if regex.firstMatch(in: nodeId, options: [], range: range) == nil {
            throw DevToolsClientError.invalidNodeId(nodeId)
        }
    }

    static func validate(iteration: Int) throws {
        if iteration < 0 {
            throw DevToolsClientError.invalidIteration(iteration)
        }
    }

    static func validate(frameNo: Int) throws {
        if frameNo < 0 {
            throw DevToolsClientError.invalidFrameNo(frameNo)
        }
    }
}

// MARK: - SQL escaping

enum DevToolsSQL {
    /// Escape a string value for SQLite inlining.
    /// Only used after regex validation; double-escapes apostrophes defensively.
    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

// MARK: - Frame XML structures

/// Intermediate representation decoded from the `xml_json` column of `_smithers_frames`
/// (keyframes). Mirrors `WorkflowDAGXMLNode` but with child-array ergonomics we need
/// for the delta applier.
struct DevToolsFrameXMLNode: Codable {
    enum Kind: String, Codable {
        case element
        case text
        case cdata
    }

    let kind: String
    let tag: String?
    var props: [String: String]
    var children: [DevToolsFrameXMLNode]
    var text: String?

    enum CodingKeys: String, CodingKey {
        case kind, tag, props, children, text
    }

    init(
        kind: String,
        tag: String? = nil,
        props: [String: String] = [:],
        children: [DevToolsFrameXMLNode] = [],
        text: String? = nil
    ) {
        self.kind = kind
        self.tag = tag
        self.props = props
        self.children = children
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "element"
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        // props may appear with non-string values; stringify everything.
        if let dict = (try? container.decodeIfPresent([String: String].self, forKey: .props)) ?? nil {
            props = dict
        } else if let rawDict = (try? container.decodeIfPresent([String: JSONValue].self, forKey: .props)) ?? nil {
            var converted: [String: String] = [:]
            for (key, value) in rawDict {
                switch value {
                case .string(let s): converted[key] = s
                case .number(let n):
                    if n == n.rounded() && abs(n) < 1e15 {
                        converted[key] = String(Int64(n))
                    } else {
                        converted[key] = String(n)
                    }
                case .bool(let b): converted[key] = b ? "true" : "false"
                case .null: converted[key] = ""
                default:
                    if let data = try? JSONEncoder().encode(value),
                       let text = String(data: data, encoding: .utf8) {
                        converted[key] = text
                    }
                }
            }
            props = converted
        } else {
            props = [:]
        }
        children = try container.decodeIfPresent([DevToolsFrameXMLNode].self, forKey: .children) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

// MARK: - Frame delta

/// Path-based delta as stored in non-keyframe `_smithers_frames.xml_json` rows.
/// Paths are arrays whose elements are either strings (property name) or ints (child index).
struct DevToolsFrameDelta: Decodable {
    struct Op: Decodable {
        let op: String
        let path: [PathComponent]
        let value: JSONValue?
    }

    enum PathComponent: Decodable {
        case key(String)
        case index(Int)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let intValue = try? container.decode(Int.self) {
                self = .index(intValue)
            } else if let stringValue = try? container.decode(String.self) {
                self = .key(stringValue)
            } else {
                throw DecodingError.typeMismatch(
                    PathComponent.self,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "PathComponent must be String or Int"
                    )
                )
            }
        }
    }

    let version: Int
    let ops: [Op]
}

// MARK: - Frame applier

/// Applies path-based deltas to a keyframe tree.
enum DevToolsFrameApplier {
    /// Apply a set of deltas in order to the given base tree.
    /// Mutations happen in a copy; the original tree is left unchanged.
    static func apply(
        deltas: [DevToolsFrameDelta],
        toKeyframe keyframe: DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        var tree = keyframe
        for delta in deltas {
            for op in delta.ops {
                switch op.op {
                case "set":
                    tree = try applySet(path: op.path, value: op.value, to: tree)
                case "insert":
                    tree = try applyInsert(path: op.path, value: op.value, to: tree)
                case "remove":
                    tree = try applyRemove(path: op.path, to: tree)
                default:
                    // Unknown ops are ignored to stay forward-compatible with server-side changes.
                    continue
                }
            }
        }
        return tree
    }

    private static func applySet(
        path: [DevToolsFrameDelta.PathComponent],
        value: JSONValue?,
        to tree: DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        try mutate(path: path, tree: tree) { node, tail in
            var node = node
            guard let last = tail.last else {
                if let decoded = decodeNode(from: value) {
                    return decoded
                }
                return node
            }
            switch last {
            case .key(let key):
                if key == "text", case .string(let s) = value {
                    node.text = s
                } else if tail.count >= 2,
                          case .key("props") = tail[tail.count - 2],
                          case .string(let s) = value {
                    node.props[key] = s
                } else if node.kind == "element" {
                    // Direct prop on element (e.g. when path is [..., "props", "name"] and
                    // we already drilled past children).
                    switch value {
                    case .some(.string(let s)): node.props[key] = s
                    case .some(.number(let n)):
                        node.props[key] = (n == n.rounded() && abs(n) < 1e15) ? String(Int64(n)) : String(n)
                    case .some(.bool(let b)): node.props[key] = b ? "true" : "false"
                    case .some(.null), .none: node.props.removeValue(forKey: key)
                    default: break
                    }
                }
            case .index(let idx):
                if let newChild = decodeNode(from: value), idx >= 0, idx < node.children.count {
                    node.children[idx] = newChild
                }
            }
            return node
        }
    }

    private static func applyInsert(
        path: [DevToolsFrameDelta.PathComponent],
        value: JSONValue?,
        to tree: DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        try mutate(path: path, tree: tree) { node, tail in
            guard case .index(let idx) = tail.last else {
                return node
            }
            guard let newChild = decodeNode(from: value) else {
                return node
            }
            var node = node
            let clampedIdx = min(max(idx, 0), node.children.count)
            node.children.insert(newChild, at: clampedIdx)
            return node
        }
    }

    private static func applyRemove(
        path: [DevToolsFrameDelta.PathComponent],
        to tree: DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        try mutate(path: path, tree: tree) { node, tail in
            guard case .index(let idx) = tail.last else {
                return node
            }
            var node = node
            if idx >= 0, idx < node.children.count {
                node.children.remove(at: idx)
            }
            return node
        }
    }

    /// Walks `path` (all but the last component) down the tree, then calls `update(node, path)`
    /// on the parent node that owns the final path component. Returns the updated tree.
    private static func mutate(
        path: [DevToolsFrameDelta.PathComponent],
        tree: DevToolsFrameXMLNode,
        update: (DevToolsFrameXMLNode, [DevToolsFrameDelta.PathComponent]) -> DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        guard !path.isEmpty else {
            return update(tree, path)
        }
        return try descend(path: path, index: 0, into: tree, leaf: update)
    }

    private static func descend(
        path: [DevToolsFrameDelta.PathComponent],
        index: Int,
        into node: DevToolsFrameXMLNode,
        leaf: (DevToolsFrameXMLNode, [DevToolsFrameDelta.PathComponent]) -> DevToolsFrameXMLNode
    ) throws -> DevToolsFrameXMLNode {
        // path layout examples:
        //   ["children", 0, "children", 1, "text"]         → leaf called on grandchild, path.last=="text"
        //   ["children", 0, "children", 2]                   → leaf called on root.children[0], last=2
        //   ["children", 0, "children", 1, "props", "key"]   → leaf called on grandchild, last=="key"
        //
        // We descend only when the next two components are ("children", Int) AND there are more
        // components after them — otherwise the final ("children", idx) pair identifies the leaf
        // to act on *within the current node* (e.g. insert/remove on children[idx]).
        let remaining = path.count - index
        if remaining <= 2 {
            return leaf(node, path)
        }
        guard case .key(let k) = path[index], k == "children",
              case .index(let childIdx) = path[index + 1] else {
            return leaf(node, path)
        }
        guard childIdx >= 0, childIdx < node.children.count else {
            return leaf(node, path)
        }
        var updated = node
        let descended = try descend(
            path: path,
            index: index + 2,
            into: updated.children[childIdx],
            leaf: leaf
        )
        updated.children[childIdx] = descended
        return updated
    }

    private static func decodeNode(from value: JSONValue?) -> DevToolsFrameXMLNode? {
        guard let value, case .object = value else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONDecoder().decode(DevToolsFrameXMLNode.self, from: data)
    }
}

// MARK: - Task index

struct DevToolsTaskIndexEntry: Decodable {
    let nodeId: String
    let ordinal: Int?
    let iteration: Int?
    let outputTableName: String?
    let kind: String?
    let agent: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case nodeId
        case ordinal
        case iteration
        case outputTableName
        case kind
        case agent
        case label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try c.decode(String.self, forKey: .nodeId)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
        iteration = try c.decodeIfPresent(Int.self, forKey: .iteration)
        outputTableName = try c.decodeIfPresent(String.self, forKey: .outputTableName)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        label = try c.decodeIfPresent(String.self, forKey: .label)
    }
}

// MARK: - Node execution state (from _smithers_nodes)

/// Per-node execution state loaded from `_smithers_nodes`. Populated by a lightweight
/// SQL query in the transport layer and threaded into `DevToolsTreeBuilder.build`
/// so the tree rows can render a real state badge instead of "Unknown".
struct DevToolsNodeStateEntry: Equatable, Sendable {
    let nodeId: String
    let state: String
    let iteration: Int
    let lastAttempt: Int?
}

/// Normalizes a raw `_smithers_nodes.state` value onto a `TaskExecutionState.rawValue`.
/// The DB emits values like `in-progress` / `skipped` / `complete` that need to map
/// onto the enum cases the UI knows about (`running`, `cancelled`, `finished`, …).
/// Unknown / empty values fall back to `pending` so structural nodes never render
/// as "Unknown" when the underlying data just hasn't populated yet — mirrors the
/// existing normalizer pattern used in `normalizeInspectTaskState`.
func normalizeDevToolsNodeState(_ raw: String) -> String {
    let token = raw
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return token
    }
}

/// Parent-node rollup precedence. Matches the UX contract described in the ticket:
/// `failed > running > blocked > waitingApproval > pending > finished`. Cancelled is
/// treated as "background noise" and does not override a finished sibling.
private let devToolsRollupPrecedence: [String: Int] = [
    "failed": 6,
    "running": 5,
    "blocked": 4,
    "waitingApproval": 3,
    "pending": 2,
    "finished": 1,
    "cancelled": 0,
]

/// Computes the rolled-up state of a parent node from its already-normalized
/// child states. Returns `nil` when no child carries a state (caller keeps the
/// parent's existing value).
func devToolsRolledUpState(childStates: [String]) -> String? {
    var best: (state: String, rank: Int)?
    for state in childStates where !state.isEmpty {
        let rank = devToolsRollupPrecedence[state] ?? -1
        if best == nil || rank > best!.rank {
            best = (state, rank)
        }
    }
    return best?.state
}

// MARK: - XML → DevToolsNode conversion

enum DevToolsTreeBuilder {
    /// Convert a decoded frame tree + task index into a `DevToolsNode` tree suitable for the gui.
    /// Integer ids are assigned depth-first so they're stable within a single snapshot.
    ///
    /// - Parameter nodeStates: optional dictionary keyed by `task.nodeId`. When provided,
    ///   task nodes get their `props["state"]` populated (normalized) and structural nodes
    ///   roll up their descendants' states. Pass `[:]` or omit for the legacy behaviour.
    ///
    /// NOTE: the state map reflects the *final* known state from `_smithers_nodes`, not a
    /// per-frame snapshot — so when the scrubber is rewound to a historical frame, rollups
    /// will reflect the current DB state rather than the state at that frame. This is a
    /// documented v1 simplification and is still a strict upgrade over the previous
    /// "Unknown" fallback.
    static func build(
        xml: DevToolsFrameXMLNode,
        taskIndex: [DevToolsTaskIndexEntry],
        nodeStates: [String: DevToolsNodeStateEntry] = [:]
    ) -> DevToolsNode {
        let indexByNodeId: [String: DevToolsTaskIndexEntry] = Dictionary(
            taskIndex.map { ($0.nodeId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nextId = 0
        let root = convert(xml: xml, depth: 0, idGenerator: { () -> Int in
            defer { nextId += 1 }
            return nextId
        }, taskIndex: indexByNodeId, nodeStates: nodeStates)
        // Second pass: compute rollup state for structural nodes now that all descendants
        // know their state. Task nodes already had their state stamped during `convert`.
        _ = populateRollupStates(root)
        return root
    }

    /// Walk the tree post-order and assign a rollup `state` prop to any non-task node
    /// whose state isn't already set from the XML. Returns the state the caller should
    /// treat this node as contributing to *its* parent's rollup.
    @discardableResult
    private static func populateRollupStates(_ node: DevToolsNode) -> String {
        // If this is a leaf task, its state was set during `convert` (or defaults to
        // "pending" per the contract). Nothing to compute.
        if node.children.isEmpty {
            if case .string(let s) = node.props["state"], !s.isEmpty {
                return s
            }
            return ""
        }

        var childStates: [String] = []
        childStates.reserveCapacity(node.children.count)
        for child in node.children {
            let childState = populateRollupStates(child)
            if !childState.isEmpty { childStates.append(childState) }
        }

        // Respect an already-set state from XML props (e.g. a delta that wrote `state="running"`
        // onto a sequence node). Only compute rollup when the parent is stateless.
        if case .string(let existing) = node.props["state"], !existing.isEmpty {
            return existing
        }

        if let rolled = devToolsRolledUpState(childStates: childStates) {
            node.props["state"] = .string(rolled)
            return rolled
        }
        return ""
    }

    private static func convert(
        xml: DevToolsFrameXMLNode,
        depth: Int,
        idGenerator: () -> Int,
        taskIndex: [String: DevToolsTaskIndexEntry],
        nodeStates: [String: DevToolsNodeStateEntry]
    ) -> DevToolsNode {
        let id = idGenerator()
        let tag = xml.tag ?? ""
        let type = smithersType(from: tag)
        let name = derivedName(tag: tag, props: xml.props)

        // Collect children skipping text-kind nodes (text stays on the parent).
        var childNodes: [DevToolsNode] = []
        var inlineText = xml.text ?? ""
        for child in xml.children {
            switch (child.kind, child.tag) {
            case ("text", _), ("cdata", _):
                if let t = child.text, !t.isEmpty {
                    inlineText += inlineText.isEmpty ? t : "\n" + t
                }
            default:
                childNodes.append(
                    convert(
                        xml: child,
                        depth: depth + 1,
                        idGenerator: idGenerator,
                        taskIndex: taskIndex,
                        nodeStates: nodeStates
                    )
                )
            }
        }

        // Props → JSONValue.string map.
        var jsonProps: [String: JSONValue] = [:]
        for (key, value) in xml.props {
            jsonProps[key] = .string(value)
        }
        if !inlineText.isEmpty {
            jsonProps["text"] = .string(inlineText)
        }

        // Hoist task metadata if this is a task node with an `id` prop.
        var taskInfo: DevToolsTaskInfo?
        if type == .task, let nodeId = xml.props["id"] {
            let indexEntry = taskIndex[nodeId]
            taskInfo = DevToolsTaskInfo(
                nodeId: nodeId,
                kind: indexEntry?.kind ?? "agent",
                agent: indexEntry?.agent,
                label: indexEntry?.label,
                outputTableName: indexEntry?.outputTableName,
                iteration: indexEntry?.iteration
            )

            // Stamp execution state onto this task node so `extractState(from:)` returns
            // something other than `.unknown`. Absent entries default to "pending" per
            // the contract in the ticket ("state stays pending, not unknown").
            // Prefer not to overwrite an explicit state already in the XML props
            // (useful for delta-driven transitions that ran ahead of the node table).
            if case .string(let existing) = jsonProps["state"], !existing.isEmpty {
                // keep XML-sourced state
            } else if let entry = nodeStates[nodeId] {
                jsonProps["state"] = .string(normalizeDevToolsNodeState(entry.state))
                if jsonProps["iteration"] == nil {
                    jsonProps["iteration"] = .string(String(entry.iteration))
                }
            } else {
                jsonProps["state"] = .string("pending")
            }
        }

        return DevToolsNode(
            id: id,
            type: type,
            name: name,
            props: jsonProps,
            task: taskInfo,
            children: childNodes,
            depth: depth
        )
    }

    private static func smithersType(from tag: String) -> SmithersNodeType {
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
        if let name = props["name"], !name.isEmpty { return name }
        if let id = props["id"], !id.isEmpty { return id }
        // Strip the "smithers:" prefix for a readable fallback.
        if tag.hasPrefix("smithers:") {
            return String(tag.dropFirst("smithers:".count))
        }
        return tag.isEmpty ? "node" : tag
    }
}

// MARK: - Node state query

/// SQL helper shared by the live transport and the snapshot loader. Returns the
/// latest (highest iteration) row per `node_id` so a re-run replaces stale state.
enum DevToolsNodeStateQuery {
    /// SQL query text for `_smithers_nodes` loading. Exposed so the caller can pass
    /// it to the existing sqlite3 subprocess runner in `SmithersClient`.
    static func query(runId: String) -> String {
        let quoted = DevToolsSQL.quote(runId)
        return """
        SELECT node_id, state, iteration, last_attempt
        FROM _smithers_nodes
        WHERE run_id=\(quoted)
        ORDER BY iteration ASC;
        """
    }

    /// Converts the raw row dicts produced by `execSQLite` into a node-id → entry
    /// dictionary, choosing the highest-iteration row per node_id.
    static func makeDict(fromRows rows: [[String: Any]]) -> [String: DevToolsNodeStateEntry] {
        var result: [String: DevToolsNodeStateEntry] = [:]
        for row in rows {
            guard let nodeId = row["node_id"] as? String,
                  let state = row["state"] as? String else { continue }
            let iterationInt = (row["iteration"] as? NSNumber)?.intValue
                ?? (row["iteration"] as? Int)
                ?? Int((row["iteration"] as? String) ?? "0") ?? 0
            let lastAttemptInt: Int? = {
                if let n = row["last_attempt"] as? NSNumber { return n.intValue }
                if let i = row["last_attempt"] as? Int { return i }
                if let s = row["last_attempt"] as? String, let parsed = Int(s) { return parsed }
                return nil
            }()
            let entry = DevToolsNodeStateEntry(
                nodeId: nodeId,
                state: state,
                iteration: iterationInt,
                lastAttempt: lastAttemptInt
            )
            if let existing = result[nodeId] {
                if iterationInt > existing.iteration {
                    result[nodeId] = entry
                }
            } else {
                result[nodeId] = entry
            }
        }
        return result
    }
}
