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
        // Walk "children" + index pairs; stop right before the final "leaf" edit-target.
        // path layout examples:
        //   ["children", 0, "children", 1, "text"]         → leaf with path.last == "text"
        //   ["children", 0, "children", 2]                  → leaf op on children[2]
        //   ["children", 0, "children", 1, "props", "key"]  → leaf with props key at depth 2
        if index >= path.count - 1 {
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

// MARK: - XML → DevToolsNode conversion

enum DevToolsTreeBuilder {
    /// Convert a decoded frame tree + task index into a `DevToolsNode` tree suitable for the gui.
    /// Integer ids are assigned depth-first so they're stable within a single snapshot.
    static func build(
        xml: DevToolsFrameXMLNode,
        taskIndex: [DevToolsTaskIndexEntry]
    ) -> DevToolsNode {
        let indexByNodeId: [String: DevToolsTaskIndexEntry] = Dictionary(
            taskIndex.map { ($0.nodeId, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nextId = 0
        return convert(xml: xml, depth: 0, idGenerator: { () -> Int in
            defer { nextId += 1 }
            return nextId
        }, taskIndex: indexByNodeId)
    }

    private static func convert(
        xml: DevToolsFrameXMLNode,
        depth: Int,
        idGenerator: () -> Int,
        taskIndex: [String: DevToolsTaskIndexEntry]
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
                        taskIndex: taskIndex
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
