import Foundation

// MARK: - SmithersNodeType

enum SmithersNodeType: String, Codable, Hashable, Sendable {
    case workflow
    case sequence
    case parallel
    case task
    case forEach = "forEach"
    case conditional
    case mergeQueue = "merge-queue"
    case branch
    case loop
    case worktree
    case approval
    case timer
    case subflow
    case waitForEvent = "wait-for-event"
    case saga
    case tryCatch = "try-catch"
    case fragment
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
    let version: Int
    let runId: String
    let frameNo: Int
    let seq: Int
    let root: DevToolsNode
    let runState: RunStateView?

    private enum CodingKeys: String, CodingKey {
        case version
        case runId
        case frameNo
        case seq
        case root
        case runState
    }

    init(
        version: Int = 1,
        runId: String,
        frameNo: Int,
        seq: Int,
        root: DevToolsNode,
        runState: RunStateView? = nil
    ) {
        self.version = version
        self.runId = runId
        self.frameNo = frameNo
        self.seq = seq
        self.root = root
        self.runState = runState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        runId = try container.decode(String.self, forKey: .runId)
        frameNo = try container.decode(Int.self, forKey: .frameNo)
        seq = try container.decode(Int.self, forKey: .seq)
        root = try container.decode(DevToolsNode.self, forKey: .root)
        runState = try container.decodeIfPresent(RunStateView.self, forKey: .runState)
    }
}

struct RunStateView: Codable, Equatable, Sendable {
    let runId: String
    let state: String
    let blocked: JSONValue?
    let unhealthy: JSONValue?
    let computedAt: String

    var stateLabel: String {
        state
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    var reasonSummary: String? {
        if let blockedSummary = Self.summary(from: blocked) {
            return blockedSummary
        }
        return Self.summary(from: unhealthy)
    }

    private static func summary(from value: JSONValue?) -> String? {
        guard case .object(let object) = value else { return nil }
        guard case .string(let kind)? = object["kind"] else { return nil }

        switch kind {
        case "approval":
            if case .string(let nodeId)? = object["nodeId"] {
                return "Waiting approval (\(nodeId))"
            }
            return "Waiting approval"
        case "event":
            if case .string(let correlationKey)? = object["correlationKey"] {
                return "Waiting event (\(correlationKey))"
            }
            return "Waiting event"
        case "timer":
            if case .string(let wakeAt)? = object["wakeAt"] {
                return "Waiting timer (\(wakeAt))"
            }
            return "Waiting timer"
        case "provider":
            if case .string(let code)? = object["code"] {
                return "Provider blocked (\(code))"
            }
            return "Provider blocked"
        case "tool":
            if case .string(let toolName)? = object["toolName"] {
                return "Tool blocked (\(toolName))"
            }
            return "Tool blocked"
        case "engine-heartbeat-stale":
            return "Engine heartbeat stale"
        case "ui-heartbeat-stale":
            return "UI heartbeat stale"
        case "db-lock":
            return "DB lock"
        case "sandbox-unreachable":
            return "Sandbox unreachable"
        case "supervisor-backoff":
            return "Supervisor backoff"
        default:
            return kind.replacingOccurrences(of: "-", with: " ")
        }
    }
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
    case replaceRoot(node: DevToolsNode)

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
        case "replaceRoot":
            self = .replaceRoot(
                node: try container.decode(DevToolsNode.self, forKey: .node)
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
        case .replaceRoot(let node):
            try container.encode("replaceRoot", forKey: .op)
            try container.encode(node, forKey: .node)
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
        case (.replaceRoot(let lnode), .replaceRoot(let rnode)):
            return lnode.id == rnode.id
        default:
            return false
        }
    }
}

// MARK: - DevToolsDelta

struct DevToolsDelta: Codable, Sendable {
    let version: Int
    let baseSeq: Int
    let seq: Int
    let ops: [DevToolsDeltaOp]

    private enum CodingKeys: String, CodingKey {
        case version
        case baseSeq
        case seq
        case ops
    }

    init(version: Int = 1, baseSeq: Int, seq: Int, ops: [DevToolsDeltaOp]) {
        self.version = version
        self.baseSeq = baseSeq
        self.seq = seq
        self.ops = ops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        baseSeq = try container.decode(Int.self, forKey: .baseSeq)
        seq = try container.decode(Int.self, forKey: .seq)
        ops = try container.decode([DevToolsDeltaOp].self, forKey: .ops)
    }
}

struct DevToolsGapResync: Codable, Equatable, Sendable {
    let fromSeq: Int
    let toSeq: Int
}

// MARK: - DevToolsEvent

enum DevToolsEvent: Codable, Sendable {
    case snapshot(DevToolsSnapshot)
    case delta(DevToolsDelta)
    case gapResync(DevToolsGapResync)

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case kind
        case snapshot
        case delta
        case gapResync
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind) {
            switch kind {
            case "snapshot":
                self = .snapshot(try container.decode(DevToolsSnapshot.self, forKey: .snapshot))
                return
            case "delta":
                self = .delta(try container.decode(DevToolsDelta.self, forKey: .delta))
                return
            case "gapResync":
                self = .gapResync(try container.decode(DevToolsGapResync.self, forKey: .gapResync))
                return
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unknown DevToolsEvent kind: \(kind)"
                )
            }
        }

        if let type = try container.decodeIfPresent(String.self, forKey: .type) {
            let singleContainer = try decoder.singleValueContainer()
            switch type {
            case "snapshot":
                self = .snapshot(try singleContainer.decode(DevToolsSnapshot.self))
            case "delta":
                self = .delta(try singleContainer.decode(DevToolsDelta.self))
            case "gapResync":
                self = .gapResync(try singleContainer.decode(DevToolsGapResync.self))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type, in: container,
                    debugDescription: "Unknown DevToolsEvent type: \(type)"
                )
            }
            return
        }

        throw DecodingError.keyNotFound(
            CodingKeys.kind,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected either 'kind' or 'type' in DevToolsEvent"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let snapshot):
            try container.encode(1, forKey: .version)
            try container.encode("snapshot", forKey: .kind)
            try container.encode(snapshot, forKey: .snapshot)
        case .delta(let delta):
            try container.encode(1, forKey: .version)
            try container.encode("delta", forKey: .kind)
            try container.encode(delta, forKey: .delta)
        case .gapResync(let gapResync):
            try container.encode(1, forKey: .version)
            try container.encode("gapResync", forKey: .kind)
            try container.encode(gapResync, forKey: .gapResync)
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
        case .replaceRoot(let node):
            return node
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
