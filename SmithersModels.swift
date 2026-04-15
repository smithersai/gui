import Foundation
import CryptoKit

// MARK: - Run Types

enum RunStatus: String, Codable, CaseIterable {
    case running
    case waitingApproval = "waiting-approval"
    case finished
    case failed
    case cancelled

    var label: String {
        switch self {
        case .running: return "RUNNING"
        case .waitingApproval: return "APPROVAL"
        case .finished: return "FINISHED"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        }
    }
}

struct RunSummary: Identifiable, Codable {
    let runId: String
    let workflowName: String?
    let workflowPath: String?
    let status: RunStatus
    let startedAtMs: Int64?
    let finishedAtMs: Int64?
    let summary: [String: Int]?
    let errorJson: String?

    var id: String { runId }

    var startedAt: Date? {
        startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var finishedAt: Date? {
        finishedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var elapsedString: String {
        guard let start = startedAt else { return "" }
        let end = finishedAt ?? Date()
        let seconds = Int(end.timeIntervalSince(start))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    var totalNodes: Int { summary?["total"] ?? 0 }
    var finishedNodes: Int { summary?["finished"] ?? 0 }
    var failedNodes: Int { summary?["failed"] ?? 0 }
    var completedNodes: Int { finishedNodes + failedNodes }

    var progress: Double {
        guard totalNodes > 0 else { return 0 }
        return Double(completedNodes) / Double(totalNodes)
    }

    var finishedProgress: Double {
        guard totalNodes > 0 else { return 0 }
        return Double(finishedNodes) / Double(totalNodes)
    }

    var failedProgress: Double {
        guard totalNodes > 0 else { return 0 }
        return Double(failedNodes) / Double(totalNodes)
    }
}

extension Sequence where Element == RunSummary {
    func sortedByStartedAtDescending() -> [RunSummary] {
        enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.startedAtMs, rhs.element.startedAtMs) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }
}

struct RunTask: Identifiable, Codable {
    let nodeId: String
    let label: String?
    let iteration: Int?
    let state: String // pending, running, finished, failed, skipped, blocked
    let lastAttempt: Int?
    let updatedAtMs: Int64?

    var id: String {
        guard let iteration else { return nodeId }
        return "\(nodeId)-\(iteration)"
    }
}

struct RunInspection: Codable {
    let run: RunSummary
    let tasks: [RunTask]
}

// MARK: - Agent Types

struct SmithersAgent: Identifiable, Codable {
    let id: String
    let name: String
    let command: String
    let binaryPath: String
    let status: String // likely-subscription, api-key, binary-only, unavailable
    let hasAuth: Bool
    let hasAPIKey: Bool
    let usable: Bool
    let roles: [String]
    let version: String?
    let authExpired: Bool?
}

// MARK: - Workflow Types

enum WorkflowStatus: String, Codable {
    case draft, active, hot, archived
}

struct Workflow: Identifiable, Codable {
    let id: String
    let workspaceId: String?
    let name: String
    let relativePath: String?
    let status: WorkflowStatus?
    let updatedAt: String?
}

struct WorkflowLaunchField: Codable {
    let name: String
    let key: String
    let type: String?       // string, number, boolean
    let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case name, label, key, type
        case defaultValue = "default"
    }

    init(name: String, key: String, type: String?, defaultValue: String?) {
        self.name = name
        self.key = key
        self.type = type
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedLabel = try container.decodeIfPresent(String.self, forKey: .label)
        name = decodedName ?? decodedLabel ?? key
        type = try container.decodeIfPresent(String.self, forKey: .type)
        if let explicitDefault = try? container.decodeIfPresent(String.self, forKey: .defaultValue) {
            defaultValue = explicitDefault
        } else if let jsonDefault = try? container.decodeIfPresent(JSONValue.self, forKey: .defaultValue) {
            defaultValue = jsonDefault.workflowInputText
        } else {
            defaultValue = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
    }
}

struct WorkflowDAGXMLNode: Codable {
    let kind: String
    let tag: String?
    let props: [String: String]
    let children: [WorkflowDAGXMLNode]
    let text: String?

    init(kind: String, tag: String? = nil, props: [String: String] = [:], children: [WorkflowDAGXMLNode] = [], text: String? = nil) {
        self.kind = kind
        self.tag = tag
        self.props = props
        self.children = children
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case kind, tag, props, children, text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        tag = try container.decodeIfPresent(String.self, forKey: .tag)
        props = (try? container.decodeIfPresent([String: String].self, forKey: .props)) ?? [:]
        children = try container.decodeIfPresent([WorkflowDAGXMLNode].self, forKey: .children) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
    }
}

struct WorkflowDAGTask: Identifiable, Codable {
    let nodeId: String
    let ordinal: Int?
    let iteration: Int?
    let outputTableName: String?
    let needsApproval: Bool?
    let approvalMode: String?
    let retries: Int?
    let timeoutMs: Int64?
    let heartbeatTimeoutMs: Int64?
    let continueOnFail: Bool?
    let prompt: String?
    let parallelGroupId: String?

    var id: String { nodeId }

    enum CodingKeys: String, CodingKey {
        case nodeId, ordinal, iteration, outputTableName, needsApproval, approvalMode
        case retries, timeoutMs, heartbeatTimeoutMs, continueOnFail, prompt, parallelGroupId
    }

    init(
        nodeId: String,
        ordinal: Int? = nil,
        iteration: Int? = nil,
        outputTableName: String? = nil,
        needsApproval: Bool? = nil,
        approvalMode: String? = nil,
        retries: Int? = nil,
        timeoutMs: Int64? = nil,
        heartbeatTimeoutMs: Int64? = nil,
        continueOnFail: Bool? = nil,
        prompt: String? = nil,
        parallelGroupId: String? = nil
    ) {
        self.nodeId = nodeId
        self.ordinal = ordinal
        self.iteration = iteration
        self.outputTableName = outputTableName
        self.needsApproval = needsApproval
        self.approvalMode = approvalMode
        self.retries = retries
        self.timeoutMs = timeoutMs
        self.heartbeatTimeoutMs = heartbeatTimeoutMs
        self.continueOnFail = continueOnFail
        self.prompt = prompt
        self.parallelGroupId = parallelGroupId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodeId = try container.decode(String.self, forKey: .nodeId)
        ordinal = container.decodeLossyInt(forKey: .ordinal)
        iteration = container.decodeLossyInt(forKey: .iteration)
        outputTableName = try container.decodeIfPresent(String.self, forKey: .outputTableName)
        needsApproval = container.decodeLossyBool(forKey: .needsApproval)
        approvalMode = try container.decodeIfPresent(String.self, forKey: .approvalMode)
        retries = container.decodeLossyInt(forKey: .retries)
        timeoutMs = container.decodeLossyInt64(forKey: .timeoutMs)
        heartbeatTimeoutMs = container.decodeLossyInt64(forKey: .heartbeatTimeoutMs)
        continueOnFail = container.decodeLossyBool(forKey: .continueOnFail)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        parallelGroupId = try container.decodeIfPresent(String.self, forKey: .parallelGroupId)
    }
}

struct WorkflowDAGEdge: Identifiable, Codable, Equatable {
    let from: String
    let to: String

    var id: String { "\(from)->\(to)" }
}

struct WorkflowDAG: Codable {
    let workflowID: String?
    let mode: String?
    let runId: String?
    let frameNo: Int?
    let xml: WorkflowDAGXMLNode?
    let tasks: [WorkflowDAGTask]
    let entryTask: String?
    let entryTaskID: String?
    let fields: [WorkflowLaunchField]?
    let message: String?

    var nodes: [WorkflowDAGTask] {
        tasks.sorted {
            let lhs = $0.ordinal ?? Int.max
            let rhs = $1.ordinal ?? Int.max
            if lhs == rhs { return $0.nodeId < $1.nodeId }
            return lhs < rhs
        }
    }

    var edges: [WorkflowDAGEdge] {
        guard let xml else {
            return Self.sequentialEdges(for: nodes.map(\.nodeId))
        }

        let validNodeIds = Set(tasks.map(\.nodeId))
        let span = Self.graphSpan(for: xml, validNodeIds: validNodeIds.isEmpty ? nil : validNodeIds)
        return Self.uniqueEdges(span.edges)
    }

    var isEmpty: Bool {
        workflowID == nil &&
            mode == nil &&
            runId == nil &&
            frameNo == nil &&
            xml == nil &&
            tasks.isEmpty &&
            entryTask == nil &&
            entryTaskID == nil &&
            fields == nil &&
            message == nil
    }

    var resolvedEntryTaskID: String? {
        entryTaskID ?? entryTask
    }

    var launchFields: [WorkflowLaunchField] {
        fields ?? []
    }

    var isFallbackMode: Bool {
        mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fallback"
    }

    init(
        workflowID: String? = nil,
        mode: String? = nil,
        runId: String? = nil,
        frameNo: Int? = nil,
        xml: WorkflowDAGXMLNode? = nil,
        tasks: [WorkflowDAGTask] = [],
        entryTask: String? = nil,
        entryTaskID: String? = nil,
        fields: [WorkflowLaunchField]? = nil,
        message: String? = nil
    ) {
        self.workflowID = workflowID
        self.mode = mode
        self.runId = runId
        self.frameNo = frameNo
        self.xml = xml
        self.tasks = tasks
        self.entryTask = entryTask ?? Self.firstTaskId(in: xml) ?? tasks.sortedForWorkflowDAG.first?.nodeId
        self.entryTaskID = entryTaskID
        self.fields = fields
        self.message = message
    }

    init(
        entryTask: String?,
        fields: [WorkflowLaunchField]?,
        workflowID: String? = nil,
        mode: String? = nil,
        entryTaskID: String? = nil,
        message: String? = nil
    ) {
        self.init(
            workflowID: workflowID,
            mode: mode,
            runId: nil,
            frameNo: nil,
            xml: nil,
            tasks: [],
            entryTask: entryTask,
            entryTaskID: entryTaskID,
            fields: fields,
            message: message
        )
    }

    enum CodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case mode
        case runId
        case frameNo
        case xml
        case tasks
        case entryTask
        case entryTaskID = "entryTaskId"
        case fields
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workflowID = try container.decodeIfPresent(String.self, forKey: .workflowID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        frameNo = container.decodeLossyInt(forKey: .frameNo)
        xml = try container.decodeIfPresent(WorkflowDAGXMLNode.self, forKey: .xml)
        tasks = try container.decodeIfPresent([WorkflowDAGTask].self, forKey: .tasks) ?? []
        fields = try container.decodeIfPresent([WorkflowLaunchField].self, forKey: .fields)
        entryTaskID = try container.decodeIfPresent(String.self, forKey: .entryTaskID)
        message = try container.decodeIfPresent(String.self, forKey: .message)

        let decodedEntryTask = try container.decodeIfPresent(String.self, forKey: .entryTask)
        entryTask = decodedEntryTask ?? entryTaskID ?? Self.firstTaskId(in: xml) ?? tasks.sortedForWorkflowDAG.first?.nodeId
    }

    private struct GraphSpan {
        let starts: [String]
        let ends: [String]
        let edges: [WorkflowDAGEdge]

        var isEmpty: Bool {
            starts.isEmpty && ends.isEmpty && edges.isEmpty
        }
    }

    private static func firstTaskId(in node: WorkflowDAGXMLNode?) -> String? {
        guard let node else { return nil }
        if node.tag?.lowercased() == "smithers:task", let id = node.props["id"] {
            return id
        }
        for child in node.children {
            if let id = firstTaskId(in: child) {
                return id
            }
        }
        return nil
    }

    private static func graphSpan(for node: WorkflowDAGXMLNode, validNodeIds: Set<String>?) -> GraphSpan {
        guard node.kind == "element" else {
            return GraphSpan(starts: [], ends: [], edges: [])
        }

        let tag = node.tag?.lowercased()
        if tag == "smithers:task", let nodeId = node.props["id"], validNodeIds?.contains(nodeId) ?? true {
            return GraphSpan(starts: [nodeId], ends: [nodeId], edges: [])
        }

        let childSpans = node.children
            .map { graphSpan(for: $0, validNodeIds: validNodeIds) }
            .filter { !$0.isEmpty }

        if tag == "smithers:parallel" {
            return GraphSpan(
                starts: childSpans.flatMap(\.starts),
                ends: childSpans.flatMap(\.ends),
                edges: childSpans.flatMap(\.edges)
            )
        }

        return sequenceSpan(childSpans)
    }

    private static func sequenceSpan(_ spans: [GraphSpan]) -> GraphSpan {
        guard var current = spans.first else {
            return GraphSpan(starts: [], ends: [], edges: [])
        }

        for next in spans.dropFirst() {
            let connectingEdges = current.ends.flatMap { from in
                next.starts.map { to in WorkflowDAGEdge(from: from, to: to) }
            }
            current = GraphSpan(
                starts: current.starts.isEmpty ? next.starts : current.starts,
                ends: next.ends.isEmpty ? current.ends : next.ends,
                edges: current.edges + next.edges + connectingEdges
            )
        }

        return current
    }

    private static func sequentialEdges(for nodeIds: [String]) -> [WorkflowDAGEdge] {
        guard nodeIds.count > 1 else { return [] }
        return zip(nodeIds, nodeIds.dropFirst()).map { WorkflowDAGEdge(from: $0.0, to: $0.1) }
    }

    private static func uniqueEdges(_ edges: [WorkflowDAGEdge]) -> [WorkflowDAGEdge] {
        var seen = Set<String>()
        return edges.filter { edge in
            seen.insert(edge.id).inserted
        }
    }
}

struct WorkflowDoctorIssue: Identifiable, Codable {
    let severity: String   // ok, warning, error
    let check: String
    let message: String

    var id: String { "\(check):\(severity):\(message)" }
}

private extension Array where Element == WorkflowDAGTask {
    var sortedForWorkflowDAG: [WorkflowDAGTask] {
        sorted {
            let lhs = $0.ordinal ?? Int.max
            let rhs = $1.ordinal ?? Int.max
            if lhs == rhs { return $0.nodeId < $1.nodeId }
            return lhs < rhs
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Int(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    func decodeLossyInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Approval Types

struct Approval: Identifiable, Codable {
    let id: String
    let runId: String
    let nodeId: String
    let workflowPath: String?
    let gate: String?
    let status: String          // pending, approved, denied
    let payload: String?        // JSON context
    let requestedAt: Int64
    let resolvedAt: Int64?
    let resolvedBy: String?
    let source: String? = nil   // http, sqlite, exec, synthetic

    var requestedDate: Date {
        Date(timeIntervalSince1970: Double(requestedAt) / 1000)
    }

    var isPending: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "pending"
    }

    var waitTime: String {
        let seconds = Int(Date().timeIntervalSince(requestedDate))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    var isSyntheticFallback: Bool {
        source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "synthetic"
    }
}

extension Sequence where Element == Approval {
    func filterPendingApprovals() -> [Approval] {
        filter(\.isPending)
    }
}

struct ApprovalDecision: Identifiable, Codable {
    let id: String
    let runId: String
    let nodeId: String
    let action: String          // approved, denied
    let note: String?
    let reason: String?
    let resolvedAt: Int64?
    let resolvedBy: String?
    let workflowPath: String?
    let gate: String?
    let payload: String?
    let requestedAt: Int64?
    let source: String?         // http, sqlite, exec

    init(
        id: String,
        runId: String,
        nodeId: String,
        action: String,
        note: String? = nil,
        reason: String? = nil,
        resolvedAt: Int64? = nil,
        resolvedBy: String? = nil,
        workflowPath: String? = nil,
        gate: String? = nil,
        payload: String? = nil,
        requestedAt: Int64? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.nodeId = nodeId
        self.action = action
        self.note = note
        self.reason = reason
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.workflowPath = workflowPath
        self.gate = gate
        self.payload = payload
        self.requestedAt = requestedAt
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id
        case runId
        case nodeId
        case action
        case decision
        case status
        case note
        case reason
        case resolvedAt
        case resolvedBy
        case decidedAt
        case decidedBy
        case requestedAt
        case workflowPath
        case gate
        case payload
        case source
        case transportSource

        case runIDSnake = "run_id"
        case nodeIDSnake = "node_id"
        case resolvedAtSnake = "resolved_at"
        case resolvedBySnake = "resolved_by"
        case decidedAtSnake = "decided_at"
        case decidedBySnake = "decided_by"
        case requestedAtSnake = "requested_at"
        case workflowPathSnake = "workflow_path"
        case transportSourceSnake = "transport_source"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
            ?? container.decode(String.self, forKey: .runIDSnake)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
            ?? container.decode(String.self, forKey: .nodeIDSnake)
        action = try container.decodeIfPresent(String.self, forKey: .action)
            ?? container.decodeIfPresent(String.self, forKey: .decision)
            ?? container.decodeIfPresent(String.self, forKey: .status)
            ?? "approved"
        note = try container.decodeIfPresent(String.self, forKey: .note)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        resolvedAt = container.decodeLossyInt64(forKey: .resolvedAt)
            ?? container.decodeLossyInt64(forKey: .resolvedAtSnake)
            ?? container.decodeLossyInt64(forKey: .decidedAt)
            ?? container.decodeLossyInt64(forKey: .decidedAtSnake)
        resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)
            ?? container.decodeIfPresent(String.self, forKey: .resolvedBySnake)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBy)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBySnake)
        workflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath)
            ?? container.decodeIfPresent(String.self, forKey: .workflowPathSnake)
        gate = try container.decodeIfPresent(String.self, forKey: .gate)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        requestedAt = container.decodeLossyInt64(forKey: .requestedAt)
            ?? container.decodeLossyInt64(forKey: .requestedAtSnake)
        source = try container.decodeIfPresent(String.self, forKey: .source)
            ?? container.decodeIfPresent(String.self, forKey: .transportSource)
            ?? container.decodeIfPresent(String.self, forKey: .transportSourceSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(runId, forKey: .runId)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
        try container.encodeIfPresent(workflowPath, forKey: .workflowPath)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encodeIfPresent(requestedAt, forKey: .requestedAt)
        try container.encodeIfPresent(source, forKey: .source)
    }
}

// MARK: - Prompt Types

struct SmithersPrompt: Identifiable, Codable {
    let id: String
    let entryFile: String?
    let source: String?
    let inputs: [PromptInput]?
}

struct PromptInput: Identifiable, Codable {
    let name: String
    let type: String?
    let defaultValue: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, type
        case defaultValue = "default"
    }
}

// MARK: - Score Types

struct ScoreRow: Identifiable, Codable {
    let id: String
    let runId: String?
    let nodeId: String?
    let iteration: Int?
    let attempt: Int?
    let scorerId: String?
    let scorerName: String?
    let source: String?         // live, batch
    let score: Double
    let reason: String?
    let metaJson: String?
    let latencyMs: Int64?
    let scoredAtMs: Int64

    var scoredAt: Date {
        Date(timeIntervalSince1970: Double(scoredAtMs) / 1000)
    }

    var scorerDisplayName: String {
        for candidate in [scorerName, scorerId] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                return name
            }
        }
        return "Unknown"
    }
}

struct AggregateScore: Identifiable, Codable {
    let scorerName: String
    let count: Int
    let mean: Double
    let min: Double
    let max: Double
    let p50: Double?

    var id: String { scorerName }

    static func aggregate(_ scores: [ScoreRow]) -> [AggregateScore] {
        Dictionary(grouping: scores, by: \.scorerDisplayName)
            .map { scorerName, rows in
                let values = rows.map(\.score)
                let sorted = values.sorted()
                let middle = sorted.count / 2
                let p50 = sorted.isEmpty
                    ? nil
                    : sorted.count.isMultiple(of: 2)
                        ? (sorted[middle - 1] + sorted[middle]) / 2.0
                        : sorted[middle]

                return AggregateScore(
                    scorerName: scorerName,
                    count: values.count,
                    mean: values.reduce(0, +) / Double(values.count),
                    min: sorted.first ?? 0,
                    max: sorted.last ?? 0,
                    p50: p50
                )
            }
            .sorted { lhs, rhs in
                lhs.scorerName.localizedStandardCompare(rhs.scorerName) == .orderedAscending
            }
    }
}

// MARK: - Memory Types

struct MemoryFact: Identifiable, Codable {
    let namespace: String
    let key: String
    let valueJson: String
    let schemaSig: String?
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let ttlMs: Int64?

    var id: String { "\(namespace):\(key)" }

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
    }

    var updatedAt: Date {
        Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
    }
}

struct MemoryRecallResult: Identifiable, Codable {
    let score: Double
    let content: String
    let metadata: String?

    var id: String { "\(score):\(content.prefix(20))" }
}

// MARK: - Snapshot Types

struct Timeline: Codable {
    let runId: String
    let branch: TimelineBranch?
    let frames: [TimelineFrame]
    let children: [Timeline]?

    func snapshots(workflowPath: String? = nil) -> [Snapshot] {
        frames.map { frame in
            Snapshot(
                runId: runId,
                nodeId: nil,
                label: "Frame \(frame.frameNo)",
                kind: "frame",
                parentId: nil,
                createdAtMs: frame.createdAtMs,
                frameNo: frame.frameNo,
                contentHash: frame.contentHash,
                forks: frame.forks,
                workflowPath: workflowPath
            )
        }
    }
}

struct TimelineBranch: Codable, Equatable {
    let runId: String
    let parentRunId: String
    let parentFrameNo: Int
    let branchLabel: String?
    let forkDescription: String?
    let createdAtMs: Int64
}

struct TimelineFrame: Codable, Equatable {
    let frameNo: Int
    let createdAtMs: Int64
    let contentHash: String
    let forks: [TimelineFork]
}

struct TimelineFork: Codable, Equatable {
    let runId: String
    let branchLabel: String?
    let forkDescription: String?
}

struct Snapshot: Identifiable, Codable {
    let id: String
    let runId: String
    let nodeId: String?
    let label: String?
    let kind: String?           // auto, manual, error, fork
    let parentId: String?
    let createdAtMs: Int64
    let frameNo: Int?
    let contentHash: String?
    let forks: [TimelineFork]?
    let workflowPath: String?

    init(
        id: String? = nil,
        runId: String,
        nodeId: String? = nil,
        label: String? = nil,
        kind: String? = nil,
        parentId: String? = nil,
        createdAtMs: Int64,
        frameNo: Int? = nil,
        contentHash: String? = nil,
        forks: [TimelineFork]? = nil,
        workflowPath: String? = nil
    ) {
        self.runId = runId
        self.nodeId = nodeId
        self.label = label
        self.kind = kind
        self.parentId = parentId
        self.createdAtMs = createdAtMs
        self.frameNo = frameNo
        self.contentHash = contentHash
        self.forks = forks
        self.workflowPath = workflowPath
        self.id = id ?? frameNo.map { "\(runId):\($0)" } ?? runId
    }

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
    }

    enum CodingKeys: String, CodingKey {
        case id, runId, nodeId, label, kind, parentId, createdAtMs
        case frameNo, contentHash, forks, workflowPath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let frameNo = try container.decodeIfPresent(Int.self, forKey: .frameNo)
        let runId = try container.decodeIfPresent(String.self, forKey: .runId) ?? ""
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            runId: runId,
            nodeId: try container.decodeIfPresent(String.self, forKey: .nodeId),
            label: try container.decodeIfPresent(String.self, forKey: .label),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            parentId: try container.decodeIfPresent(String.self, forKey: .parentId),
            createdAtMs: try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0,
            frameNo: frameNo,
            contentHash: try container.decodeIfPresent(String.self, forKey: .contentHash),
            forks: try container.decodeIfPresent([TimelineFork].self, forKey: .forks),
            workflowPath: try container.decodeIfPresent(String.self, forKey: .workflowPath)
        )
    }
}

struct SnapshotDiff: Codable {
    let fromId: String?
    let toId: String?
    let changes: [String]?
    let nodesAdded: [String]
    let nodesRemoved: [String]
    let nodesChanged: [SnapshotNodeChange]
    let outputsAdded: [String]
    let outputsRemoved: [String]
    let outputsChanged: [SnapshotOutputChange]
    let ralphChanged: [SnapshotRalphChange]
    let inputChanged: Bool
    let vcsPointerChanged: Bool

    init(
        fromId: String? = nil,
        toId: String? = nil,
        changes: [String]? = nil,
        nodesAdded: [String] = [],
        nodesRemoved: [String] = [],
        nodesChanged: [SnapshotNodeChange] = [],
        outputsAdded: [String] = [],
        outputsRemoved: [String] = [],
        outputsChanged: [SnapshotOutputChange] = [],
        ralphChanged: [SnapshotRalphChange] = [],
        inputChanged: Bool = false,
        vcsPointerChanged: Bool = false
    ) {
        self.fromId = fromId
        self.toId = toId
        self.changes = changes
        self.nodesAdded = nodesAdded
        self.nodesRemoved = nodesRemoved
        self.nodesChanged = nodesChanged
        self.outputsAdded = outputsAdded
        self.outputsRemoved = outputsRemoved
        self.outputsChanged = outputsChanged
        self.ralphChanged = ralphChanged
        self.inputChanged = inputChanged
        self.vcsPointerChanged = vcsPointerChanged
    }

    enum CodingKeys: String, CodingKey {
        case fromId, toId, changes
        case nodesAdded, nodesRemoved, nodesChanged
        case outputsAdded, outputsRemoved, outputsChanged
        case ralphChanged, inputChanged, vcsPointerChanged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            fromId: try container.decodeIfPresent(String.self, forKey: .fromId),
            toId: try container.decodeIfPresent(String.self, forKey: .toId),
            changes: try container.decodeIfPresent([String].self, forKey: .changes),
            nodesAdded: try container.decodeIfPresent([String].self, forKey: .nodesAdded) ?? [],
            nodesRemoved: try container.decodeIfPresent([String].self, forKey: .nodesRemoved) ?? [],
            nodesChanged: try container.decodeIfPresent([SnapshotNodeChange].self, forKey: .nodesChanged) ?? [],
            outputsAdded: try container.decodeIfPresent([String].self, forKey: .outputsAdded) ?? [],
            outputsRemoved: try container.decodeIfPresent([String].self, forKey: .outputsRemoved) ?? [],
            outputsChanged: try container.decodeIfPresent([SnapshotOutputChange].self, forKey: .outputsChanged) ?? [],
            ralphChanged: try container.decodeIfPresent([SnapshotRalphChange].self, forKey: .ralphChanged) ?? [],
            inputChanged: try container.decodeIfPresent(Bool.self, forKey: .inputChanged) ?? false,
            vcsPointerChanged: try container.decodeIfPresent(Bool.self, forKey: .vcsPointerChanged) ?? false
        )
    }
}

struct SnapshotNodeChange: Codable, Equatable {
    let nodeId: String
    let from: SnapshotNodeState
    let to: SnapshotNodeState
}

struct SnapshotNodeState: Codable, Equatable {
    let nodeId: String
    let iteration: Int
    let state: String
    let lastAttempt: Int?
    let outputTable: String?
    let label: String?
}

struct SnapshotOutputChange: Codable, Equatable {
    let key: String
    let from: JSONValue
    let to: JSONValue
}

struct SnapshotRalphChange: Codable, Equatable {
    let ralphId: String
    let from: SnapshotRalphState
    let to: SnapshotRalphState
}

struct SnapshotRalphState: Codable, Equatable {
    let ralphId: String
    let iteration: Int
    let done: Bool
}

enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var workflowInputText: String {
        switch self {
        case .string(let value):
            return value
        default:
            return compactJSONString ?? ""
        }
    }

    var compactJSONString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Ticket Types

struct CreateTicketInput: Codable {
    let id: String
    let content: String?
}

struct UpdateTicketInput: Codable {
    let content: String
}

struct Ticket: Identifiable, Codable {
    let id: String
    let content: String?
    let status: String?
    let createdAtMs: Int64?
    let updatedAtMs: Int64?

    var createdAt: Date? {
        createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

// MARK: - Landing Types (JJHub)

struct Landing: Identifiable, Codable {
    let id: String
    let number: Int?
    let title: String
    let description: String?
    let state: String?          // open, draft, merged, closed
    let targetBranch: String?
    let author: String?
    let createdAt: String?
    let reviewStatus: String?   // approved, changes_requested, pending

    init(
        id: String,
        number: Int?,
        title: String,
        description: String?,
        state: String?,
        targetBranch: String?,
        author: String?,
        createdAt: String?,
        reviewStatus: String?
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.description = description
        self.state = state
        self.targetBranch = targetBranch
        self.author = author
        self.createdAt = createdAt
        self.reviewStatus = reviewStatus
    }

    enum CodingKeys: String, CodingKey {
        case id, number, title, description, state, author
        case body
        case targetBranch
        case targetBookmark
        case targetBookmarkSnake = "target_bookmark"
        case createdAt
        case createdAtSnake = "created_at"
        case reviewStatus
        case reviewStatusSnake = "review_status"
    }

    enum AuthorKeys: String, CodingKey {
        case login, name, email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description) ??
            container.decodeIfPresent(String.self, forKey: .body)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch) ??
            container.decodeIfPresent(String.self, forKey: .targetBookmark) ??
            container.decodeIfPresent(String.self, forKey: .targetBookmarkSnake)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ??
            container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        reviewStatus = try container.decodeIfPresent(String.self, forKey: .reviewStatus) ??
            container.decodeIfPresent(String.self, forKey: .reviewStatusSnake)

        if let authorString = try? container.decodeIfPresent(String.self, forKey: .author) {
            author = authorString
        } else if let authorObject = try? container.nestedContainer(keyedBy: AuthorKeys.self, forKey: .author) {
            author = try authorObject.decodeIfPresent(String.self, forKey: .login) ??
                authorObject.decodeIfPresent(String.self, forKey: .name) ??
                authorObject.decodeIfPresent(String.self, forKey: .email)
        } else {
            author = nil
        }

        id = try container.decodeIfPresent(String.self, forKey: .id) ??
            number.map { "landing-\($0)" } ??
            title
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(targetBranch, forKey: .targetBranch)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(reviewStatus, forKey: .reviewStatus)
    }
}

// MARK: - Issue Types (JJHub)

struct SmithersIssue: Identifiable, Codable {
    let id: String
    let number: Int?
    let title: String
    let body: String?
    let state: String?          // open, closed
    let labels: [String]?
    let assignees: [String]?
    let commentCount: Int?

    init(
        id: String,
        number: Int? = nil,
        title: String,
        body: String? = nil,
        state: String? = nil,
        labels: [String]? = nil,
        assignees: [String]? = nil,
        commentCount: Int? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.labels = labels
        self.assignees = assignees
        self.commentCount = commentCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case body
        case state
        case labels
        case assignees
        case commentCount
        case commentCountSnake = "comment_count"
        case commentsCountSnake = "comments_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = Self.decodeInt(from: container, forKey: .number)
        id = Self.decodeString(from: container, forKey: .id)
            ?? number.map { "issue-\($0)" }
            ?? "issue"
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        body = try? container.decodeIfPresent(String.self, forKey: .body)
        state = try? container.decodeIfPresent(String.self, forKey: .state)
        labels = Self.decodeNameList(from: container, forKey: .labels)
        assignees = Self.decodeNameList(from: container, forKey: .assignees)
        commentCount = Self.decodeInt(from: container, forKey: .commentCount)
            ?? Self.decodeInt(from: container, forKey: .commentCountSnake)
            ?? Self.decodeInt(from: container, forKey: .commentsCountSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(state, forKey: .state)
        try container.encodeIfPresent(labels, forKey: .labels)
        try container.encodeIfPresent(assignees, forKey: .assignees)
        try container.encodeIfPresent(commentCount, forKey: .commentCount)
    }

    private static func decodeString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decode(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    private static func decodeInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeNameList(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String]? {
        if let values = try? container.decode([String].self, forKey: key) {
            return values
        }
        if let values = try? container.decode([SmithersIssueNameRef].self, forKey: key) {
            return values.compactMap(\.displayName)
        }
        return nil
    }
}

private struct SmithersIssueNameRef: Codable {
    let name: String?
    let login: String?
    let username: String?

    var displayName: String? {
        for candidate in [name, login, username] {
            if let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - Workspace Types (JJHub)

struct Workspace: Identifiable, Codable {
    let id: String
    let name: String
    let status: String?         // active/running, suspended, stopped
    let createdAt: String?

    init(id: String, name: String, status: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, status, createdAt
        case createdAtSnake = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        status = try container.decodeIfPresent(String.self, forKey: .status)
        let camelCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let snakeCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        createdAt = camelCreatedAt ?? snakeCreatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

struct WorkspaceSnapshot: Identifiable, Codable {
    let id: String
    let workspaceId: String
    let name: String?
    let createdAt: String?

    init(id: String, workspaceId: String, name: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceId, name, createdAt
        case workspaceIdSnake = "workspace_id"
        case createdAtSnake = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let camelWorkspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        let snakeWorkspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceIdSnake)
        workspaceId = camelWorkspaceId ?? snakeWorkspaceId ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        let camelCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let snakeCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        createdAt = camelCreatedAt ?? snakeCreatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

// MARK: - JJHub Workflow Types

struct JJHubWorkflow: Identifiable, Codable {
    let id: Int
    let repositoryID: Int?
    let name: String
    let path: String
    let isActive: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, path
        case repositoryID = "repository_id"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct JJHubWorkflowRun: Codable {
    let id: Int?
    let workflowDefinitionID: Int?
    let status: String?
    let triggerEvent: String?
    let triggerRef: String?
    let triggerCommitSHA: String?
    let startedAt: String?
    let completedAt: String?
    let sessionID: String?
    let steps: [String]?

    enum CodingKeys: String, CodingKey {
        case id, status, steps
        case workflowDefinitionID = "workflow_definition_id"
        case triggerEvent = "trigger_event"
        case triggerRef = "trigger_ref"
        case triggerCommitSHA = "trigger_commit_sha"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case sessionID = "session_id"
    }
}

// MARK: - Changes / Status Types (JJHub)

struct JJHubRepo: Codable {
    let id: Int?
    let name: String?
    let fullName: String?
    let owner: String?
    let description: String?
    let defaultBookmark: String?
    let isPublic: Bool?
    let isArchived: Bool?
    let numIssues: Int?
    let numStars: Int?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, owner, description
        case fullName = "full_name"
        case defaultBookmark = "default_bookmark"
        case isPublic = "is_public"
        case isArchived = "is_archived"
        case numIssues = "num_issues"
        case numStars = "num_stars"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct JJHubAuthor: Codable {
    let name: String?
    let email: String?
}

struct JJHubChange: Identifiable, Codable {
    let changeID: String
    let commitID: String?
    let description: String?
    let author: JJHubAuthor?
    let timestamp: String?
    let isEmpty: Bool?
    let isWorkingCopy: Bool?
    let bookmarks: [String]?

    var id: String { changeID }

    enum CodingKeys: String, CodingKey {
        case description, author, timestamp, bookmarks
        case changeID = "change_id"
        case commitID = "commit_id"
        case isEmpty = "is_empty"
        case isWorkingCopy = "is_working_copy"
    }
}

struct JJHubBookmark: Identifiable, Codable {
    let name: String
    let targetChangeID: String?
    let targetCommitID: String?
    let isTrackingRemote: Bool?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case targetChangeID = "target_change_id"
        case targetCommitID = "target_commit_id"
        case isTrackingRemote = "is_tracking_remote"
    }
}

// MARK: - Chat Block (Run Chat)

struct ChatBlock: Identifiable, Codable {
    let id: String?
    let itemId: String?
    let runId: String?
    let nodeId: String?
    let attempt: Int?
    let role: String            // system, assistant, user
    let content: String
    let timestampMs: Int64?
    private let _fallbackId: String

    var stableId: String {
        lifecycleId ?? _fallbackId
    }
    var lifecycleId: String? {
        if let id, !id.isEmpty { return id }
        if let itemId, !itemId.isEmpty { return itemId }
        return nil
    }
    var attemptIndex: Int { max(0, attempt ?? 0) }
    var isAssistantLike: Bool {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedRole == "assistant" || normalizedRole == "agent"
    }

    enum CodingKeys: String, CodingKey {
        case id, itemId, runId, nodeId, attempt, role, content, timestampMs
    }

    enum AlternateCodingKeys: String, CodingKey {
        case itemId = "item_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let alternateContainer = try decoder.container(keyedBy: AlternateCodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedItemId = try container.decodeIfPresent(String.self, forKey: .itemId)
        let decodedSnakeItemId = try alternateContainer.decodeIfPresent(String.self, forKey: .itemId)
        itemId = decodedItemId ?? decodedSnakeItemId
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestampMs = try container.decodeIfPresent(Int64.self, forKey: .timestampMs)
        _fallbackId = Self.fallbackId(
            itemId: itemId,
            runId: runId,
            nodeId: nodeId,
            attempt: attempt,
            role: role,
            content: content,
            timestampMs: timestampMs,
            decodeIndex: decoder.codingPath.compactMap(\.intValue).last
        )
    }

    init(
        id: String?,
        itemId: String? = nil,
        runId: String? = nil,
        nodeId: String? = nil,
        attempt: Int? = nil,
        role: String,
        content: String,
        timestampMs: Int64? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.runId = runId
        self.nodeId = nodeId
        self.attempt = attempt
        self.role = role
        self.content = content
        self.timestampMs = timestampMs
        self._fallbackId = Self.fallbackId(
            itemId: itemId,
            runId: runId,
            nodeId: nodeId,
            attempt: attempt,
            role: role,
            content: content,
            timestampMs: timestampMs,
            decodeIndex: nil
        )
    }

    private static func fallbackId(
        itemId: String?,
        runId: String?,
        nodeId: String?,
        attempt: Int?,
        role: String,
        content: String,
        timestampMs: Int64?,
        decodeIndex: Int?
    ) -> String {
        var data = Data("smithers.chatblock.fallback.v1\n".utf8)
        appendField(itemId, named: "itemId", to: &data)
        appendField(runId, named: "runId", to: &data)
        appendField(nodeId, named: "nodeId", to: &data)
        appendField(attempt.map(String.init), named: "attempt", to: &data)
        appendField(role, named: "role", to: &data)
        appendField(content, named: "content", to: &data)
        appendField(timestampMs.map(String.init), named: "timestampMs", to: &data)
        appendField(decodeIndex.map(String.init), named: "decodeIndex", to: &data)

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "chatblock-\(hex)"
    }

    private static func appendField(_ value: String?, named name: String, to data: inout Data) {
        data.append(contentsOf: "\(name)=".utf8)
        guard let value else {
            data.append(contentsOf: "-1:".utf8)
            data.append(0x0A)
            return
        }

        let bytes = Array(value.utf8)
        data.append(contentsOf: "\(bytes.count):".utf8)
        data.append(contentsOf: bytes)
        data.append(0x0A)
    }

    func canMergeAssistantStream(with incoming: ChatBlock) -> Bool {
        guard isAssistantLike, incoming.isAssistantLike else { return false }
        guard attemptIndex == incoming.attemptIndex else { return false }
        if !Self.compatibleIdentifier(runId, incoming.runId) { return false }
        if !Self.compatibleIdentifier(nodeId, incoming.nodeId) { return false }
        return true
    }

    func hasStreamingContentOverlap(with incoming: ChatBlock) -> Bool {
        Self.hasStreamingContentOverlap(existing: content, incoming: incoming.content)
    }

    func mergingAssistantStream(with incoming: ChatBlock) -> ChatBlock {
        let shouldMergeContent = hasStreamingContentOverlap(with: incoming)
            || (timestampMs != nil && incoming.timestampMs != nil)
        let mergedContent = shouldMergeContent
            ? Self.mergedStreamingContent(
                existing: content,
                incoming: incoming.content,
                existingTimestampMs: timestampMs,
                incomingTimestampMs: incoming.timestampMs
            )
            : incoming.content

        return ChatBlock(
            id: incoming.id ?? id,
            itemId: incoming.itemId ?? itemId,
            runId: incoming.runId ?? runId,
            nodeId: incoming.nodeId ?? nodeId,
            attempt: incoming.attempt ?? attempt,
            role: incoming.role,
            content: mergedContent,
            timestampMs: incoming.timestampMs ?? timestampMs
        )
    }

    static func mergedStreamingContent(
        existing: String,
        incoming: String,
        existingTimestampMs: Int64? = nil,
        incomingTimestampMs: Int64? = nil
    ) -> String {
        if existing.isEmpty { return incoming }
        if incoming.isEmpty { return existing }
        if existing == incoming { return existing }
        if incoming.hasPrefix(existing) { return incoming }
        if existing.hasPrefix(incoming) { return existing }
        if existing.contains(incoming) { return existing }
        if incoming.contains(existing) { return incoming }

        let forwardOverlap = suffixPrefixOverlap(existing, incoming)
        let reverseOverlap = suffixPrefixOverlap(incoming, existing)
        if forwardOverlap > 0 || reverseOverlap > 0 {
            if reverseOverlap > forwardOverlap {
                return incoming + String(existing.dropFirst(reverseOverlap))
            }
            return existing + String(incoming.dropFirst(forwardOverlap))
        }

        if let existingTimestampMs,
           let incomingTimestampMs,
           incomingTimestampMs < existingTimestampMs {
            return incoming + existing
        }

        return existing + incoming
    }

    private static func hasStreamingContentOverlap(existing: String, incoming: String) -> Bool {
        if existing.isEmpty || incoming.isEmpty { return false }
        if existing == incoming { return true }
        if existing.hasPrefix(incoming) || incoming.hasPrefix(existing) { return true }
        if existing.contains(incoming) || incoming.contains(existing) { return true }
        return suffixPrefixOverlap(existing, incoming) > 0 || suffixPrefixOverlap(incoming, existing) > 0
    }

    private static func suffixPrefixOverlap(_ lhs: String, _ rhs: String) -> Int {
        let maxLength = min(lhs.count, rhs.count)
        guard maxLength > 0 else { return 0 }

        for length in stride(from: maxLength, through: 1, by: -1) {
            if lhs.suffix(length) == rhs.prefix(length) {
                return length
            }
        }
        return 0
    }

    private static func compatibleIdentifier(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, !lhs.isEmpty, let rhs, !rhs.isEmpty else { return true }
        return lhs == rhs
    }
}

func deduplicatedChatBlocks(_ blocks: [ChatBlock]) -> [ChatBlock] {
    var result: [ChatBlock] = []
    var indexByLifecycleId: [String: Int] = [:]

    for block in blocks {
        guard let lifecycleId = block.lifecycleId, !lifecycleId.isEmpty else {
            result.append(block)
            continue
        }

        if let existingIndex = indexByLifecycleId[lifecycleId] {
            let existing = result[existingIndex]
            if existing.canMergeAssistantStream(with: block) {
                result[existingIndex] = existing.mergingAssistantStream(with: block)
            } else {
                result[existingIndex] = block
            }
        } else {
            indexByLifecycleId[lifecycleId] = result.count
            result.append(block)
        }
    }

    return result
}

// MARK: - Run Hijack Session

struct HijackSession: Codable {
    let runId: String
    let agentEngine: String
    let agentBinary: String
    let resumeToken: String
    let cwd: String
    let supportsResume: Bool

    enum CodingKeys: String, CodingKey {
        case runId, agentEngine, agentBinary, resumeToken, cwd, supportsResume
    }

    init(
        runId: String,
        agentEngine: String,
        agentBinary: String,
        resumeToken: String,
        cwd: String,
        supportsResume: Bool
    ) {
        self.runId = runId
        self.agentEngine = agentEngine
        self.agentBinary = agentBinary
        self.resumeToken = resumeToken
        self.cwd = cwd
        self.supportsResume = supportsResume
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decodeIfPresent(String.self, forKey: .runId) ?? ""
        agentEngine = try container.decodeIfPresent(String.self, forKey: .agentEngine) ?? ""
        agentBinary = try container.decodeIfPresent(String.self, forKey: .agentBinary) ?? ""
        resumeToken = try container.decodeIfPresent(String.self, forKey: .resumeToken) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        supportsResume = try container.decodeIfPresent(Bool.self, forKey: .supportsResume) ?? false
    }

    func resumeArgs() -> [String] {
        guard supportsResume, !resumeToken.isEmpty else { return [] }
        switch agentEngine {
        case "codex":
            return ["--session-id", resumeToken]
        case "gemini":
            return ["--session", resumeToken]
        default:
            return ["--resume", resumeToken]
        }
    }
}

// MARK: - Cron Schedule

struct CronSchedule: Identifiable, Codable {
    let id: String
    let pattern: String
    let workflowPath: String
    let enabled: Bool
    let createdAtMs: Int64?
    let lastRunAtMs: Int64?
    let nextRunAtMs: Int64?
    let errorJson: String?

    var createdAt: Date? {
        createdAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var lastRunAt: Date? {
        lastRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var nextRunAt: Date? {
        nextRunAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cronId
        case pattern
        case workflowPath
        case enabled
        case createdAtMs
        case lastRunAtMs
        case nextRunAtMs
        case errorJson
    }

    init(
        id: String,
        pattern: String,
        workflowPath: String,
        enabled: Bool,
        createdAtMs: Int64? = nil,
        lastRunAtMs: Int64? = nil,
        nextRunAtMs: Int64? = nil,
        errorJson: String? = nil
    ) {
        self.id = id
        self.pattern = pattern
        self.workflowPath = workflowPath
        self.enabled = enabled
        self.createdAtMs = createdAtMs
        self.lastRunAtMs = lastRunAtMs
        self.nextRunAtMs = nextRunAtMs
        self.errorJson = errorJson
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        workflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs)
        lastRunAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastRunAtMs)
        nextRunAtMs = try container.decodeIfPresent(Int64.self, forKey: .nextRunAtMs)
        errorJson = try container.decodeIfPresent(String.self, forKey: .errorJson)

        let resolvedID = Self.resolvedID(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            cronId: try container.decodeIfPresent(String.self, forKey: .cronId),
            pattern: pattern,
            workflowPath: workflowPath
        )
        guard !resolvedID.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "CronSchedule id resolved to an empty string"
            )
        }
        id = resolvedID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pattern, forKey: .pattern)
        try container.encode(workflowPath, forKey: .workflowPath)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(createdAtMs, forKey: .createdAtMs)
        try container.encodeIfPresent(lastRunAtMs, forKey: .lastRunAtMs)
        try container.encodeIfPresent(nextRunAtMs, forKey: .nextRunAtMs)
        try container.encodeIfPresent(errorJson, forKey: .errorJson)
    }

    private static func resolvedID(
        id: String?,
        cronId: String?,
        pattern: String,
        workflowPath: String
    ) -> String {
        if let id = nonEmpty(id) { return id }
        if let cronId = nonEmpty(cronId) { return cronId }
        return fallbackID(pattern: pattern, workflowPath: workflowPath)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func fallbackID(pattern: String, workflowPath: String) -> String {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkflowPath = workflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty, !normalizedWorkflowPath.isEmpty else { return "" }

        var data = Data("smithers.cronschedule.fallback.v1\n".utf8)
        appendField(normalizedPattern, named: "pattern", to: &data)
        appendField(normalizedWorkflowPath, named: "workflowPath", to: &data)

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cron-\(hex)"
    }

    private static func appendField(_ value: String, named name: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        data.append(contentsOf: "\(name)=".utf8)
        data.append(contentsOf: "\(bytes.count):".utf8)
        data.append(contentsOf: bytes)
        data.append(0x0A)
    }
}

struct CronResponse: Codable {
    let crons: [CronSchedule]
}

// MARK: - SQL Result

struct SQLTableInfo: Identifiable, Codable, Hashable {
    let name: String
    let rowCount: Int64
    let type: String

    var id: String { name }

    init(name: String, rowCount: Int64 = 0, type: String) {
        self.name = name
        self.rowCount = rowCount
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case rowCount
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        rowCount = try container.decodeIfPresent(Int64.self, forKey: .rowCount) ?? 0
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "table"
    }
}

struct SQLTableColumn: Identifiable, Codable, Hashable {
    let cid: Int
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKey: Bool

    var id: String { "\(cid):\(name)" }

    init(
        cid: Int,
        name: String,
        type: String,
        notNull: Bool,
        defaultValue: String?,
        primaryKey: Bool
    ) {
        self.cid = cid
        self.name = name
        self.type = type
        self.notNull = notNull
        self.defaultValue = defaultValue
        self.primaryKey = primaryKey
    }

    private enum CodingKeys: String, CodingKey {
        case cid
        case name
        case type
        case notNull
        case notnull
        case defaultValue
        case dfltValue = "dflt_value"
        case primaryKey
        case pk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try container.decodeIfPresent(Int.self, forKey: .cid) ?? 0
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""

        if let notNullBool = try container.decodeIfPresent(Bool.self, forKey: .notNull) {
            notNull = notNullBool
        } else if let notNullInt = try container.decodeIfPresent(Int.self, forKey: .notnull) {
            notNull = notNullInt != 0
        } else {
            notNull = false
        }

        if let explicitDefault = try container.decodeIfPresent(String.self, forKey: .defaultValue) {
            defaultValue = explicitDefault
        } else {
            defaultValue = try container.decodeIfPresent(String.self, forKey: .dfltValue)
        }

        if let primaryKeyBool = try container.decodeIfPresent(Bool.self, forKey: .primaryKey) {
            primaryKey = primaryKeyBool
        } else if let primaryKeyInt = try container.decodeIfPresent(Int.self, forKey: .pk) {
            primaryKey = primaryKeyInt != 0
        } else {
            primaryKey = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cid, forKey: .cid)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(notNull, forKey: .notNull)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encode(primaryKey, forKey: .primaryKey)
    }
}

struct SQLTableSchema: Codable, Hashable {
    let tableName: String
    let columns: [SQLTableColumn]
}

struct SQLResult: Codable {
    let columns: [String]
    let rows: [[String]]

    init(columns: [String] = [], rows: [[String]] = []) {
        self.columns = columns
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case columns
        case rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decodeIfPresent([String].self, forKey: .columns) ?? []

        if let stringRows = try? container.decode([[String]].self, forKey: .rows) {
            rows = stringRows
            return
        }

        if let mixedRows = try? container.decode([[SQLCellValue]].self, forKey: .rows) {
            rows = mixedRows.map { row in row.map(\.displayString) }
            return
        }

        rows = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(columns, forKey: .columns)
        try container.encode(rows, forKey: .rows)
    }
}

private enum SQLCellValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value {
                return String(Int64(value))
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .null:
            return "NULL"
        }
    }
}

// MARK: - Search Results

struct SearchResult: Identifiable, Codable {
    let id: String
    let title: String
    let description: String?
    let snippet: String?
    let filePath: String?
    let lineNumber: Int?
    let kind: String?           // repo, issue, code
}

// MARK: - SSE Event

struct SSEEvent {
    let event: String?
    let data: String
    let runId: String?

    init(event: String?, data: String, runId: String? = nil) {
        self.event = event
        self.data = data
        self.runId = Self.normalizedRunId(runId) ?? Self.extractRunId(from: data)
    }

    static func filtered(event: String?, data: String, expectedRunId: String?) -> SSEEvent? {
        let payloadRunId = extractRunId(from: data)
        guard runId(payloadRunId, matches: expectedRunId) else { return nil }
        return SSEEvent(event: event, data: data, runId: payloadRunId ?? normalizedRunId(expectedRunId))
    }

    func matches(runId expectedRunId: String?) -> Bool {
        Self.runId(runId, matches: expectedRunId)
    }

    static func runId(_ actualRunId: String?, matches expectedRunId: String?) -> Bool {
        guard let expected = normalizedRunId(expectedRunId) else { return true }
        guard let actual = normalizedRunId(actualRunId) else { return true }
        return actual == expected
    }

    static func extractRunId(from data: String) -> String? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let bytes = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) else {
            return nil
        }
        return extractRunId(fromJSONObject: object)
    }

    static func normalizedRunId(_ runId: String?) -> String? {
        guard let runId else { return nil }
        let trimmed = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let runIdKeys: Set<String> = [
        "runId",
        "run_id",
        "workflowRunId",
        "workflow_run_id",
    ]

    private static let preferredNestedRunIdKeys = [
        "event",
        "data",
        "block",
        "payload",
        "message",
    ]

    private static func extractRunId(fromJSONObject object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in runIdKeys {
                if let runId = normalizedRunIdValue(dictionary[key]) {
                    return runId
                }
            }

            for key in preferredNestedRunIdKeys {
                guard let nested = dictionary[key],
                      let runId = extractRunId(fromJSONObject: nested) else {
                    continue
                }
                return runId
            }

            for (key, nested) in dictionary where !preferredNestedRunIdKeys.contains(key) {
                if let runId = extractRunId(fromJSONObject: nested) {
                    return runId
                }
            }
        }

        if let array = object as? [Any] {
            for nested in array {
                if let runId = extractRunId(fromJSONObject: nested) {
                    return runId
                }
            }
        }

        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.first == "{" || trimmed.first == "[" else { return nil }
            return extractRunId(from: trimmed)
        }

        return nil
    }

    private static func normalizedRunIdValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return normalizedRunId(string)
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return normalizedRunId(number.stringValue)
        }
        return nil
    }
}

// MARK: - API Envelope (Legacy endpoints)

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}
