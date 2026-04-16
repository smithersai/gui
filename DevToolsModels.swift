import Foundation

// MARK: - SmithersNodeType

enum SmithersNodeType: String, Codable, Hashable, Sendable {
    case workflow
    case sequence
    case parallel
    case task
    case forEach = "forEach"
    case conditional
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SmithersNodeType(rawValue: raw) ?? .unknown
    }
}

// MARK: - DevToolsTaskInfo

struct DevToolsTaskInfo: Codable, Equatable, Hashable, Sendable {
    let nodeId: String
    let kind: String
    let agent: String?
    let label: String?
    let outputTableName: String?
    let iteration: Int?
}

// MARK: - DevToolsNode

final class DevToolsNode: Identifiable, Codable, Hashable, @unchecked Sendable {
    let id: Int
    let type: SmithersNodeType
    let name: String
    var props: [String: JSONValue]
    var task: DevToolsTaskInfo?
    var children: [DevToolsNode]
    let depth: Int

    init(
        id: Int,
        type: SmithersNodeType,
        name: String,
        props: [String: JSONValue] = [:],
        task: DevToolsTaskInfo? = nil,
        children: [DevToolsNode] = [],
        depth: Int = 0
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.props = props
        self.task = task
        self.children = children
        self.depth = depth
    }

    static func == (lhs: DevToolsNode, rhs: DevToolsNode) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func findNode(byId targetId: Int) -> DevToolsNode? {
        if id == targetId { return self }
        for child in children {
            if let found = child.findNode(byId: targetId) { return found }
        }
        return nil
    }

    func findParent(ofNodeId targetId: Int) -> DevToolsNode? {
        for child in children {
            if child.id == targetId { return self }
            if let found = child.findParent(ofNodeId: targetId) { return found }
        }
        return nil
    }

    func removeNode(byId targetId: Int) -> Bool {
        if let index = children.firstIndex(where: { $0.id == targetId }) {
            children.remove(at: index)
            return true
        }
        for child in children {
            if child.removeNode(byId: targetId) { return true }
        }
        return false
    }

    func deepCopy() -> DevToolsNode {
        DevToolsNode(
            id: id,
            type: type,
            name: name,
            props: props,
            task: task,
            children: children.map { $0.deepCopy() },
            depth: depth
        )
    }
}

// MARK: - DevToolsSnapshot

struct DevToolsSnapshot: Codable, Sendable {
    let runId: String
    let frameNo: Int
    let seq: Int
    let root: DevToolsNode
}

// MARK: - DevToolsJumpResult

struct DevToolsJumpResult: Codable, Equatable, Sendable {
    let ok: Bool
    let newFrameNo: Int?
    let revertedSandboxes: Int?
    let deletedFrames: Int?
    let deletedAttempts: Int?
    let invalidatedDiffs: Int?
    let durationMs: Int?
}

// MARK: - NodeOutputResponse

enum OutputSchemaFieldType: String, Codable, Equatable, Sendable {
    case string
    case number
    case boolean
    case object
    case array
    case null
    case unknown
}

struct OutputSchemaFieldDescriptor: Codable, Equatable, Sendable {
    let name: String
    let type: OutputSchemaFieldType
    let optional: Bool
    let nullable: Bool
    let description: String?
    let enumValues: [JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case optional
        case nullable
        case description
        case enumValues = "enum"
    }
}

struct OutputSchemaDescriptor: Codable, Equatable, Sendable {
    let fields: [OutputSchemaFieldDescriptor]
}

enum NodeOutputStatus: String, Codable, Equatable, Sendable {
    case produced
    case pending
    case failed
}

struct NodeOutputResponse: Codable, Equatable, Sendable {
    let status: NodeOutputStatus
    let row: [String: JSONValue]?
    let schema: OutputSchemaDescriptor?
    let partial: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case status
        case row
        case schema
        case partial
    }

    init(
        status: NodeOutputStatus,
        row: [String: JSONValue]?,
        schema: OutputSchemaDescriptor?,
        partial: [String: JSONValue]? = nil
    ) {
        self.status = status
        self.row = row
        self.schema = schema
        self.partial = partial
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(NodeOutputStatus.self, forKey: .status)
        schema = try container.decodeIfPresent(OutputSchemaDescriptor.self, forKey: .schema)
        row = try Self.decodeJSONObject(from: container, key: .row)
        partial = try Self.decodeJSONObject(from: container, key: .partial)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encode(jsonObjectValue(row), forKey: .row)
        try container.encodeIfPresent(jsonObjectValue(partial), forKey: .partial)
    }

    private static func decodeJSONObject(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> [String: JSONValue]? {
        guard let value = try container.decodeIfPresent(JSONValue.self, forKey: key) else {
            return nil
        }
        switch value {
        case .null:
            return nil
        case .object(let object):
            return object
        default:
            throw DecodingError.typeMismatch(
                [String: JSONValue].self,
                DecodingError.Context(
                    codingPath: container.codingPath + [key],
                    debugDescription: "\(key.stringValue) must decode to a JSON object or null"
                )
            )
        }
    }

    private func jsonObjectValue(_ object: [String: JSONValue]?) -> JSONValue {
        guard let object else { return .null }
        return .object(object)
    }
}

@MainActor
protocol NodeOutputProvider {
    func getNodeOutput(runId: String, nodeId: String, iteration: Int?) async throws -> NodeOutputResponse
}

// MARK: - DevToolsDeltaOp

enum DevToolsDeltaOp: Codable, Equatable, Sendable {
    case addNode(parentId: Int, index: Int, node: DevToolsNode)
    case removeNode(id: Int)
    case updateProps(id: Int, props: [String: JSONValue])
    case updateTask(id: Int, task: DevToolsTaskInfo?)

    private enum CodingKeys: String, CodingKey {
        case op, parentId, index, node, id, props, task
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let op = try container.decode(String.self, forKey: .op)
        switch op {
        case "addNode":
            self = .addNode(
                parentId: try container.decode(Int.self, forKey: .parentId),
                index: try container.decode(Int.self, forKey: .index),
                node: try container.decode(DevToolsNode.self, forKey: .node)
            )
        case "removeNode":
            self = .removeNode(id: try container.decode(Int.self, forKey: .id))
        case "updateProps":
            self = .updateProps(
                id: try container.decode(Int.self, forKey: .id),
                props: try container.decode([String: JSONValue].self, forKey: .props)
            )
        case "updateTask":
            self = .updateTask(
                id: try container.decode(Int.self, forKey: .id),
                task: try container.decodeIfPresent(DevToolsTaskInfo.self, forKey: .task)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .op, in: container,
                debugDescription: "Unknown delta op: \(op)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addNode(let parentId, let index, let node):
            try container.encode("addNode", forKey: .op)
            try container.encode(parentId, forKey: .parentId)
            try container.encode(index, forKey: .index)
            try container.encode(node, forKey: .node)
        case .removeNode(let id):
            try container.encode("removeNode", forKey: .op)
            try container.encode(id, forKey: .id)
        case .updateProps(let id, let props):
            try container.encode("updateProps", forKey: .op)
            try container.encode(id, forKey: .id)
            try container.encode(props, forKey: .props)
        case .updateTask(let id, let task):
            try container.encode("updateTask", forKey: .op)
            try container.encode(id, forKey: .id)
            try container.encode(task, forKey: .task)
        }
    }

    static func == (lhs: DevToolsDeltaOp, rhs: DevToolsDeltaOp) -> Bool {
        switch (lhs, rhs) {
        case (.addNode(let lp, let li, let ln), .addNode(let rp, let ri, let rn)):
            return lp == rp && li == ri && ln.id == rn.id
        case (.removeNode(let lid), .removeNode(let rid)):
            return lid == rid
        case (.updateProps(let lid, let lp), .updateProps(let rid, let rp)):
            return lid == rid && lp == rp
        case (.updateTask(let lid, let lt), .updateTask(let rid, let rt)):
            return lid == rid && lt == rt
        default:
            return false
        }
    }
}

// MARK: - DevToolsDelta

struct DevToolsDelta: Codable, Sendable {
    let baseSeq: Int
    let seq: Int
    let ops: [DevToolsDeltaOp]
}

// MARK: - DevToolsEvent

enum DevToolsEvent: Codable, Sendable {
    case snapshot(DevToolsSnapshot)
    case delta(DevToolsDelta)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let singleContainer = try decoder.singleValueContainer()
        switch type {
        case "snapshot":
            self = .snapshot(try singleContainer.decode(DevToolsSnapshot.self))
        case "delta":
            self = .delta(try singleContainer.decode(DevToolsDelta.self))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown DevToolsEvent type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .snapshot(let snapshot):
            try snapshot.encode(to: encoder)
        case .delta(let delta):
            try delta.encode(to: encoder)
        }
    }
}

// MARK: - ApplyDelta

enum ApplyDeltaError: Error, Equatable {
    case unknownParent(Int)
    case unknownNode(Int)
    case indexOutOfBounds(parentId: Int, index: Int, childCount: Int)
}

enum DevToolsDeltaApplier {
    static func applyDelta(_ delta: DevToolsDelta, to tree: DevToolsNode?) throws -> DevToolsNode? {
        var currentTree = tree
        for op in delta.ops {
            currentTree = try applyOp(op, to: currentTree)
        }
        return currentTree
    }

    static func applyOp(_ op: DevToolsDeltaOp, to tree: DevToolsNode?) throws -> DevToolsNode? {
        switch op {
        case .addNode(let parentId, let index, let node):
            guard let tree else {
                if parentId == -1 && index == 0 {
                    return node
                }
                throw ApplyDeltaError.unknownParent(parentId)
            }
            guard let parent = tree.findNode(byId: parentId) else {
                throw ApplyDeltaError.unknownParent(parentId)
            }
            guard index >= 0, index <= parent.children.count else {
                throw ApplyDeltaError.indexOutOfBounds(
                    parentId: parentId, index: index, childCount: parent.children.count
                )
            }
            parent.children.insert(node, at: index)
            return tree

        case .removeNode(let id):
            guard let tree else {
                throw ApplyDeltaError.unknownNode(id)
            }
            if tree.id == id {
                return nil
            }
            guard tree.removeNode(byId: id) else {
                throw ApplyDeltaError.unknownNode(id)
            }
            return tree

        case .updateProps(let id, let props):
            guard let tree, let node = tree.findNode(byId: id) else {
                throw ApplyDeltaError.unknownNode(id)
            }
            for (key, value) in props {
                node.props[key] = value
            }
            return tree

        case .updateTask(let id, let task):
            guard let tree, let node = tree.findNode(byId: id) else {
                throw ApplyDeltaError.unknownNode(id)
            }
            node.task = task
            return tree
        }
    }
}

// MARK: - NodeDiffBundle

struct NodeDiffBundle: Codable, Equatable, Sendable {
    let seq: Int
    let baseRef: String
    let patches: [NodeDiffPatch]
}

struct NodeDiffPatch: Codable, Equatable, Identifiable, Sendable {
    enum Operation: String, Codable, Equatable, Sendable {
        case add
        case modify
        case delete
        case rename
        case unknown

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            self = Operation(rawValue: raw) ?? .unknown
        }
    }

    let path: String
    let oldPath: String?
    let operation: Operation
    let diff: String
    let binaryContent: String?

    var id: String {
        if let oldPath, !oldPath.isEmpty, oldPath != path {
            return "\(oldPath)->\(path)"
        }
        return path
    }

    var isBinary: Bool {
        if binaryContent != nil { return true }
        return diff.contains("GIT binary patch") || diff.contains("Binary files ")
    }

    var binarySizeBytes: Int? {
        guard let binaryContent, !binaryContent.isEmpty else { return nil }
        if let decoded = Data(base64Encoded: binaryContent) {
            return decoded.count
        }
        return binaryContent.utf8.count
    }
}
