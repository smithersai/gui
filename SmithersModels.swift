import Foundation
import CryptoKit

// MARK: - Run Types

enum RunStatus: String, Codable, CaseIterable {
    case running
    case waitingApproval = "waiting-approval"
    case finished
    case failed
    case cancelled
    case stale
    case orphaned
    case unknown

    var label: String {
        switch self {
        case .running: return "RUNNING"
        case .waitingApproval: return "APPROVAL"
        case .finished: return "FINISHED"
        case .failed: return "FAILED"
        case .cancelled: return "CANCELLED"
        case .stale: return "STALE"
        case .orphaned: return "ORPHANED"
        case .unknown: return "UNKNOWN"
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
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    var totalNodes: Int { summary?["total"] ?? 0 }
    var succeededNodes: Int { summary?["succeeded"] ?? summary?["finished"] ?? 0 }
    var finishedNodes: Int { succeededNodes }
    var failedNodes: Int { summary?["failed"] ?? 0 }
    var completedNodes: Int { succeededNodes + failedNodes }

    var progressIndicatorText: String {
        guard totalNodes > 0 else { return "0/0 nodes" }
        if failedNodes > 0 {
            return "\(succeededNodes) succeeded, \(failedNodes) failed / \(totalNodes) nodes"
        }
        return "\(completedNodes)/\(totalNodes) nodes"
    }

    var progress: Double {
        guard totalNodes > 0 else { return 0 }
        // Failed nodes are completed work and should advance progress.
        return Double(completedNodes) / Double(totalNodes)
    }

    var succeededProgress: Double {
        guard totalNodes > 0 else { return 0 }
        return Double(succeededNodes) / Double(totalNodes)
    }

    var finishedProgress: Double { succeededProgress }

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

extension RunStatus {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self.normalized(raw)
    }

    static func normalized(_ value: String?) -> RunStatus {
        switch normalizedInspectToken(value) {
        case "waiting-approval", "waitingapproval", "blocked", "paused":
            return .waitingApproval
        case "finished", "complete", "completed", "success", "succeeded", "done":
            return .finished
        case "failed", "failure", "error", "errored":
            return .failed
        case "cancelled", "canceled":
            return .cancelled
        case "running", "in-progress", "inprogress", "started", "recovering":
            return .running
        case "stale":
            return .stale
        case "orphaned":
            return .orphaned
        default:
            return .unknown
        }
    }
}

extension RunSummary {
    enum CodingKeys: String, CodingKey {
        case runId
        case id
        case workflowName
        case workflow
        case workflowPath
        case status
        case startedAtMs
        case startedAtMsSnake = "started_at_ms"
        case started
        case startedAt
        case startedAtSnake = "started_at"
        case finishedAtMs
        case finishedAtMsSnake = "finished_at_ms"
        case finished
        case finishedAt
        case finishedAtSnake = "finished_at"
        case summary
        case errorJson
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let runId = try container.decodeIfPresent(String.self, forKey: .runId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        guard let runId, !runId.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.runId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected run identifier")
            )
        }

        self.runId = runId
        self.workflowName = normalizeInspectString(
            try container.decodeIfPresent(String.self, forKey: .workflowName)
                ?? container.decodeIfPresent(String.self, forKey: .workflow)
        )
        self.workflowPath = normalizeInspectString(try container.decodeIfPresent(String.self, forKey: .workflowPath))
        let status = try container.decodeIfPresent(String.self, forKey: .status)
        self.status = RunStatus.normalized(status)

        let started = try container.decodeIfPresent(String.self, forKey: .started)
            ?? container.decodeIfPresent(String.self, forKey: .startedAt)
            ?? container.decodeIfPresent(String.self, forKey: .startedAtSnake)
        self.startedAtMs = container.decodeLossyInt64(forKey: .startedAtMs)
            ?? container.decodeLossyInt64(forKey: .startedAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .startedAt)
            ?? container.decodeLossyInt64(forKey: .startedAtSnake)
            ?? parseInspectTimestampMs(started)

        let finished = try container.decodeIfPresent(String.self, forKey: .finished)
            ?? container.decodeIfPresent(String.self, forKey: .finishedAt)
            ?? container.decodeIfPresent(String.self, forKey: .finishedAtSnake)
        self.finishedAtMs = container.decodeLossyInt64(forKey: .finishedAtMs)
            ?? container.decodeLossyInt64(forKey: .finishedAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .finishedAt)
            ?? container.decodeLossyInt64(forKey: .finishedAtSnake)
            ?? parseInspectTimestampMs(finished)

        self.summary = decodeRunSummaryMap(container, forKey: .summary)

        if let errorJson = normalizeInspectString(try container.decodeIfPresent(String.self, forKey: .errorJson)) {
            self.errorJson = errorJson
        } else if let errorValue = try? container.decodeIfPresent(JSONValue.self, forKey: .error) {
            self.errorJson = errorValue.compactJSONString
        } else {
            self.errorJson = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encodeIfPresent(workflowName, forKey: .workflowName)
        try container.encodeIfPresent(workflowPath, forKey: .workflowPath)
        try container.encode(status.rawValue, forKey: .status)
        try container.encodeIfPresent(startedAtMs, forKey: .startedAtMs)
        try container.encodeIfPresent(finishedAtMs, forKey: .finishedAtMs)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(errorJson, forKey: .errorJson)
    }
}

extension RunTask {
    enum CodingKeys: String, CodingKey {
        case nodeId
        case id
        case label
        case iteration
        case state
        case lastAttempt
        case attempt
        case updatedAtMs
        case updatedAt
        case startedAtMs
        case startedAt
        case finishedAtMs
        case finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let rawNodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
            ?? container.decodeIfPresent(String.self, forKey: .id)
        guard let rawNodeId, !rawNodeId.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.nodeId,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected inspect step id")
            )
        }

        let explicitIteration = container.decodeLossyInt(forKey: .iteration)
        let parsedNode = parseInspectNodeID(rawNodeId, fallbackIteration: explicitIteration)

        self.nodeId = parsedNode.nodeId
        self.label = normalizeInspectString(try container.decodeIfPresent(String.self, forKey: .label))
        self.iteration = parsedNode.iteration
        self.state = normalizeInspectTaskState(try container.decodeIfPresent(String.self, forKey: .state))

        self.lastAttempt = container.decodeLossyInt(forKey: .lastAttempt)
            ?? container.decodeLossyInt(forKey: .attempt)

        let updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        let finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
        let startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        self.updatedAtMs = container.decodeLossyInt64(forKey: .updatedAtMs)
            ?? parseInspectTimestampMs(updatedAt)
            ?? container.decodeLossyInt64(forKey: .finishedAtMs)
            ?? parseInspectTimestampMs(finishedAt)
            ?? container.decodeLossyInt64(forKey: .startedAtMs)
            ?? parseInspectTimestampMs(startedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(iteration, forKey: .iteration)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(lastAttempt, forKey: .lastAttempt)
        try container.encodeIfPresent(updatedAtMs, forKey: .updatedAtMs)
    }
}

extension RunInspection {
    enum CodingKeys: String, CodingKey {
        case run
        case tasks
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let run = try container.decode(RunSummary.self, forKey: .run)
        let tasks = try container.decodeIfPresent([RunTask].self, forKey: .tasks)
            ?? container.decodeIfPresent([RunTask].self, forKey: .steps)
            ?? []

        self.tasks = tasks
        if run.summary == nil {
            self.run = RunSummary(
                runId: run.runId,
                workflowName: run.workflowName,
                workflowPath: run.workflowPath,
                status: run.status,
                startedAtMs: run.startedAtMs,
                finishedAtMs: run.finishedAtMs,
                summary: summarizeInspectTasks(tasks),
                errorJson: run.errorJson
            )
        } else {
            self.run = run
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(run, forKey: .run)
        try container.encode(tasks, forKey: .tasks)
    }
}

private func normalizeInspectString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return (trimmed == "—" || trimmed == "-") ? nil : trimmed
}

private func normalizedInspectToken(_ value: String?) -> String {
    normalizeInspectString(value)?
        .lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
        ?? ""
}

private func normalizeInspectTaskState(_ state: String?) -> String {
    switch normalizedInspectToken(state) {
    case "in-progress", "inprogress", "started":
        return "running"
    case "waitingapproval", "waiting-approval":
        return "waiting-approval"
    case "complete", "completed", "done", "succeeded", "success":
        return "finished"
    case "error", "errored":
        return "failed"
    default:
        let normalized = normalizedInspectToken(state)
        return normalized.isEmpty ? "pending" : normalized
    }
}

private func parseInspectTimestampMs(_ value: String?) -> Int64? {
    guard let raw = normalizeInspectString(value) else { return nil }
    if let ms = Int64(raw) {
        return ms
    }
    if let date = DateFormatters.parseISO8601InternetDateTime(raw) {
        return Int64(date.timeIntervalSince1970 * 1000)
    }
    if let relativeMs = DateFormatters.parseRelativeAgoTimestampMs(raw) {
        return relativeMs
    }
    return nil
}

private func parseInspectNodeID(_ rawNodeId: String, fallbackIteration: Int?) -> (nodeId: String, iteration: Int?) {
    guard fallbackIteration == nil else {
        return (rawNodeId, fallbackIteration)
    }
    guard let splitIndex = rawNodeId.lastIndex(of: ":"),
          splitIndex < rawNodeId.index(before: rawNodeId.endIndex) else {
        return (rawNodeId, nil)
    }

    let base = String(rawNodeId[..<splitIndex])
    let suffix = String(rawNodeId[rawNodeId.index(after: splitIndex)...])
    guard !base.isEmpty, let iteration = Int(suffix) else {
        return (rawNodeId, nil)
    }
    return (base, iteration)
}

private func jsonValueString(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .string(let string):
        return string
    case .number(let number):
        let int = Int64(number)
        if Double(int) == number {
            return String(int)
        }
        return String(number)
    case .bool(let bool):
        return bool ? "true" : "false"
    default:
        return nil
    }
}

private func cronWorkflowPathString(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .object(let object):
        let keys = [
            "workflowPath",
            "workflow_path",
            "workflowFile",
            "workflow_file",
            "entryFile",
            "entry_file",
            "relativePath",
            "relative_path",
            "filePath",
            "file_path",
            "path",
            "file",
        ]
        for key in keys {
            if let resolvedPath = jsonValueString(object[key]) {
                return resolvedPath
            }
        }
        return nil
    default:
        return jsonValueString(value)
    }
}

private func cronPatternString(_ value: JSONValue?) -> String? {
    guard let value else { return nil }
    switch value {
    case .object(let object):
        let keys = [
            "pattern",
            "cronPattern",
            "cron_pattern",
            "cron",
            "schedule",
            "scheduleExpression",
            "schedule_expression",
            "cronExpression",
            "cron_expression",
            "expression",
            "expr",
            "value",
        ]
        for key in keys {
            if let pattern = jsonValueString(object[key]) {
                return pattern
            }
        }
        return nil
    default:
        return jsonValueString(value)
    }
}

private func summarizeInspectTasks(_ tasks: [RunTask]) -> [String: Int] {
    var summary = ["total": tasks.count]
    for task in tasks {
        summary[task.state, default: 0] += 1
    }
    return summary
}

private func decodeRunSummaryMap<K: CodingKey>(
    _ container: KeyedDecodingContainer<K>,
    forKey key: K
) -> [String: Int]? {
    if let value = try? container.decodeIfPresent([String: Int].self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent([String: String].self, forKey: key) {
        return value.reduce(into: [:]) { partialResult, pair in
            guard let intValue = Int(pair.value) else { return }
            partialResult[pair.key] = intValue
        }
    }
    if let value = try? container.decodeIfPresent([String: Double].self, forKey: key) {
        return value.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key] = Int(pair.value)
        }
    }
    return nil
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

struct CodexAuthState: Equatable {
    let hasCodexCLI: Bool
    let codexCLIPath: String?
    let hasAuthFile: Bool
    let hasAPIKey: Bool
    let authFilePath: String

    var isReady: Bool {
        hasAuthFile || hasAPIKey
    }

    var modeLabel: String {
        switch (hasAuthFile, hasAPIKey) {
        case (true, true):
            return "ChatGPT + API key"
        case (true, false):
            return "ChatGPT"
        case (false, true):
            return "API key"
        case (false, false):
            return "Not configured"
        }
    }
}

// MARK: - Workflow Types

enum WorkflowStatus: String, Codable {
    case draft, active, hot, archived, unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self = WorkflowStatus(rawValue: raw) ?? .unknown
    }
}

struct Workflow: Identifiable, Codable {
    let id: String
    let workspaceId: String?
    let name: String
    let relativePath: String?
    let status: WorkflowStatus?
    let updatedAt: String?

    /// Canonical on-disk workflow file path used by smithers graph/up commands.
    var filePath: String? {
        Self.normalizedPath(relativePath)
    }

    init(
        id: String,
        workspaceId: String?,
        name: String,
        relativePath: String?,
        status: WorkflowStatus?,
        updatedAt: String?
    ) {
        self.id = id
        self.workspaceId = Self.normalizedText(workspaceId)
        self.name = Self.normalizedText(name) ?? id
        self.relativePath = Self.normalizedPath(relativePath)
        self.status = status
        self.updatedAt = Self.normalizedText(updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, workspaceId, name, relativePath, status, updatedAt
        case workspaceIdSnake = "workspace_id"
        case displayName
        case entryFile
        case path
        case workflowPath
        case workflowPathSnake = "workflow_path"
        case updatedAtSnake = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)

        let camelWorkspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceId)
        let snakeWorkspaceId = try container.decodeIfPresent(String.self, forKey: .workspaceIdSnake)
        workspaceId = Self.normalizedText(camelWorkspaceId ?? snakeWorkspaceId)

        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedDisplayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        name = Self.normalizedText(decodedName ?? decodedDisplayName) ?? id

        let decodedRelativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
        let decodedEntryFile = try container.decodeIfPresent(String.self, forKey: .entryFile)
        let decodedPath = try container.decodeIfPresent(String.self, forKey: .path)
        let decodedWorkflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath)
        let decodedWorkflowPathSnake = try container.decodeIfPresent(String.self, forKey: .workflowPathSnake)
        relativePath = Self.normalizedPath(
            decodedRelativePath
                ?? decodedEntryFile
                ?? decodedPath
                ?? decodedWorkflowPath
                ?? decodedWorkflowPathSnake
        )

        status = try container.decodeIfPresent(WorkflowStatus.self, forKey: .status)

        let camelUpdatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        let snakeUpdatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAtSnake)
        updatedAt = Self.normalizedText(camelUpdatedAt ?? snakeUpdatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(relativePath, forKey: .relativePath)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    private static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedPath(_ value: String?) -> String? {
        normalizedText(value)
    }
}

struct WorkflowLaunchField: Codable {
    let name: String
    let key: String
    let type: String?       // string, number, boolean, object, array, json
    let defaultValue: String?
    let required: Bool

    enum CodingKeys: String, CodingKey {
        case name, label, title, key, id, type, required
        case isRequired
        case optional
        case defaultValue = "default"
        case schema
        case inputSchema
        case jsonSchema
    }

    init(name: String, key: String, type: String?, defaultValue: String?, required: Bool = false) {
        self.name = name
        self.key = key
        self.type = type
        self.defaultValue = defaultValue
        self.required = required
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(JSONValue.self, forKey: .schema)
            ?? container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
            ?? container.decodeIfPresent(JSONValue.self, forKey: .jsonSchema)

        let decodedPrimaryKey = try container.decodeIfPresent(String.self, forKey: .key)
            ?? (try container.decodeIfPresent(String.self, forKey: .id))
        let decodedFallbackKey = try container.decodeIfPresent(String.self, forKey: .name)
            ?? (try container.decodeIfPresent(String.self, forKey: .label))
            ?? (try container.decodeIfPresent(String.self, forKey: .title))
        let decodedKey = Self.normalizedString(decodedPrimaryKey)
            ?? Self.normalizedString(decodedFallbackKey)
        guard let resolvedKey = decodedKey else {
            throw DecodingError.keyNotFound(
                CodingKeys.key,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected launch input key")
            )
        }
        key = resolvedKey

        let decodedName = Self.normalizedString(try container.decodeIfPresent(String.self, forKey: .name))
        let decodedLabel = Self.normalizedString(try container.decodeIfPresent(String.self, forKey: .label))
        let decodedTitle = Self.normalizedString(try container.decodeIfPresent(String.self, forKey: .title))
        name = decodedName ?? decodedLabel ?? decodedTitle ?? key

        let explicitTypeString = Self.normalizedType(try container.decodeIfPresent(String.self, forKey: .type))
        let explicitTypeValue = try container.decodeIfPresent(JSONValue.self, forKey: .type)
        let inferredTypeFromTypeValue = explicitTypeValue.flatMap(Self.inferType(fromTypeToken:))
        let inferredTypeFromSchema = Self.inferType(fromSchema: decodedSchema)

        let decodedDefault = try container.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
            ?? Self.defaultFromSchema(decodedSchema)
        defaultValue = Self.textInputDefault(from: decodedDefault)

        let inferredTypeFromDefault = Self.inferType(fromDefault: decodedDefault)
        type = explicitTypeString
            ?? inferredTypeFromTypeValue
            ?? inferredTypeFromSchema
            ?? inferredTypeFromDefault

        if let explicitRequired = container.decodeLossyBool(forKey: .required)
            ?? container.decodeLossyBool(forKey: .isRequired) {
            required = explicitRequired
        } else if let explicitOptional = container.decodeLossyBool(forKey: .optional) {
            required = !explicitOptional
        } else {
            required = Self.requiredFromSchema(decodedSchema) ?? false
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        if required {
            try container.encode(required, forKey: .required)
        }
    }

    static func fields(fromInputSchema schema: JSONValue?) -> [WorkflowLaunchField]? {
        guard let schema else { return nil }
        return fields(fromInputSchema: schema, depth: 0)
    }

    private static func fields(fromInputSchema schema: JSONValue, depth: Int) -> [WorkflowLaunchField]? {
        guard depth <= 3, case .object(let object) = schema else { return nil }

        if let properties = objectValue(for: object["properties"]) ?? objectValue(for: object["shape"]) {
            let requiredKeys = requiredKeySet(from: object["required"])
            let fields = properties.keys.sorted().map { key in
                let propertySchema = properties[key]
                let inferredType = inferType(fromSchema: propertySchema)
                    ?? inferType(fromDefault: defaultFromSchema(propertySchema))
                let defaultValue = textInputDefault(from: defaultFromSchema(propertySchema))
                let propertyRequired = requiredFromSchema(propertySchema) ?? false
                let isRequired = requiredKeys.contains(key) || propertyRequired
                return WorkflowLaunchField(
                    name: displayName(for: key, schema: propertySchema),
                    key: key,
                    type: inferredType,
                    defaultValue: defaultValue,
                    required: isRequired
                )
            }
            return fields.isEmpty ? nil : fields
        }

        let wrapperKeys: [String] = ["inputSchema", "input_schema", "schema", "input"]
        for wrapperKey in wrapperKeys {
            guard let nested = object[wrapperKey] else { continue }
            if let nestedFields = fields(fromInputSchema: nested, depth: depth + 1),
               !nestedFields.isEmpty {
                return nestedFields
            }
        }

        return nil
    }

    private static func displayName(for key: String, schema: JSONValue?) -> String {
        guard case .object(let object) = schema else { return key }
        return normalizedString(string(from: object["title"]))
            ?? normalizedString(string(from: object["label"]))
            ?? normalizedString(string(from: object["name"]))
            ?? key
    }

    private static func requiredKeySet(from value: JSONValue?) -> Set<String> {
        guard case .array(let items) = value else { return [] }
        return Set(items.compactMap { normalizedString(string(from: $0)) })
    }

    private static func defaultFromSchema(_ schema: JSONValue?) -> JSONValue? {
        guard let schema else { return nil }
        switch schema {
        case .object(let object):
            if let explicitDefault = object["default"] {
                return explicitDefault
            }
            for key in ["anyOf", "oneOf", "allOf"] {
                guard case .array(let candidates) = object[key] else { continue }
                for candidate in candidates {
                    if let nestedDefault = defaultFromSchema(candidate) {
                        return nestedDefault
                    }
                }
            }
            if let nestedSchema = object["schema"] {
                return defaultFromSchema(nestedSchema)
            }
            return nil
        default:
            return nil
        }
    }

    private static func requiredFromSchema(_ schema: JSONValue?) -> Bool? {
        guard case .object(let object) = schema else { return nil }
        if let requiredValue = bool(from: object["required"]) {
            return requiredValue
        }
        if let requiredValue = bool(from: object["isRequired"]) {
            return requiredValue
        }
        if let optionalValue = bool(from: object["optional"]) {
            return !optionalValue
        }
        return nil
    }

    private static func inferType(fromDefault value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .bool:
            return "boolean"
        case .number:
            return "number"
        case .string:
            return "string"
        case .array:
            return "array"
        case .object:
            return "object"
        case .null:
            return nil
        }
    }

    private static func inferType(fromTypeToken value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            if let token = canonicalTypeToken(raw), token != "null" {
                return token
            }
            return nil
        case .array(let values):
            let tokens = values.compactMap(typeToken)
            return mergedType(fromTokens: tokens)
        default:
            return nil
        }
    }

    private static func inferType(fromSchema schema: JSONValue?) -> String? {
        guard let schema else { return nil }

        switch schema {
        case .string:
            return inferType(fromTypeToken: schema)
        case .object(let object):
            if let directType = object["type"].flatMap(inferType(fromTypeToken:)) {
                return directType
            }

            for key in ["anyOf", "oneOf", "allOf"] {
                guard case .array(let variants) = object[key] else { continue }
                let variantTypes = variants.compactMap { inferType(fromSchema: $0) }
                if let merged = mergedType(fromTokens: variantTypes) {
                    return merged
                }
            }

            if objectValue(for: object["properties"]) != nil || object["additionalProperties"] != nil {
                return "object"
            }
            if object["items"] != nil || object["prefixItems"] != nil {
                return "array"
            }
            if let constValue = object["const"] {
                return inferType(fromDefault: constValue)
            }
            if case .array(let enumValues)? = object["enum"] {
                let enumTypes = enumValues.compactMap(typeToken)
                if let merged = mergedType(fromTokens: enumTypes) {
                    return merged
                }
            }
            if let nestedSchema = object["schema"], let nestedType = inferType(fromSchema: nestedSchema) {
                return nestedType
            }
            if let inferredDefaultType = inferType(fromDefault: object["default"]) {
                return inferredDefaultType
            }
            return nil
        case .array(let values):
            let inferredTypes = values.compactMap { inferType(fromSchema: $0) }
            return mergedType(fromTokens: inferredTypes)
        default:
            return inferType(fromDefault: schema)
        }
    }

    private static func mergedType(fromTokens tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        let unique = Set(tokens)
        let nonNull = unique.filter { $0 != "null" }
        if nonNull.count == 1 {
            return nonNull.first
        }
        if nonNull.isEmpty {
            return nil
        }
        return "json"
    }

    private static func typeToken(from value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            return canonicalTypeToken(raw)
        case .null:
            return "null"
        case .bool:
            return "boolean"
        case .number:
            return "number"
        case .array:
            return "array"
        case .object:
            return inferType(fromSchema: value) ?? "object"
        }
    }

    private static func normalizedType(_ rawType: String?) -> String? {
        guard let token = canonicalTypeToken(rawType), token != "null" else { return nil }
        return token
    }

    private static func canonicalTypeToken(_ rawType: String?) -> String? {
        guard let rawType else { return nil }
        let normalized = rawType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "string", "str", "text":
            return "string"
        case "number", "integer", "int", "float", "double", "decimal":
            return "number"
        case "boolean", "bool":
            return "boolean"
        case "object", "record", "map":
            return "object"
        case "array", "list", "tuple", "set":
            return "array"
        case "json", "any", "unknown", "mixed":
            return "json"
        case "null", "nil":
            return "null"
        default:
            return nil
        }
    }

    private static func textInputDefault(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        if case .null = value { return nil }
        return value.workflowInputText
    }

    private static func normalizedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func objectValue(for value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object) = value else { return nil }
        return object
    }

    private static func string(from value: JSONValue?) -> String? {
        guard case .string(let string) = value else { return nil }
        return string
    }

    private static func bool(from value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let boolValue):
            return boolValue
        case .number(let numberValue):
            return numberValue != 0
        case .string(let stringValue):
            let normalized = stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
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

    var id: String { "\(nodeId):\(iteration ?? 0)" }

    enum CodingKeys: String, CodingKey {
        case nodeId
        case ordinal
        case iteration
        case outputTableName
        case needsApproval
        case approvalMode
        case retries
        case timeoutMs
        case heartbeatTimeoutMs
        case continueOnFail
        case prompt
        case parallelGroupId
    }

    private enum DecodingKeys: String, CodingKey {
        case nodeId
        case nodeIDSnake = "node_id"
        case nodeIDPascal = "nodeID"
        case node
        case id
        case taskId
        case taskIDSnake = "task_id"
        case taskIDPascal = "taskID"
        case name
        case ordinal
        case index
        case order
        case iteration
        case outputTableName
        case outputTableNameSnake = "output_table_name"
        case outputTable
        case outputTableSnake = "output_table"
        case needsApproval
        case needsApprovalSnake = "needs_approval"
        case requiresApproval
        case requiresApprovalSnake = "requires_approval"
        case approvalMode
        case approvalModeSnake = "approval_mode"
        case retries
        case maxRetries
        case maxRetriesSnake = "max_retries"
        case timeoutMs
        case timeoutMsSnake = "timeout_ms"
        case heartbeatTimeoutMs
        case heartbeatTimeoutMsSnake = "heartbeat_timeout_ms"
        case continueOnFail
        case continueOnFailSnake = "continue_on_fail"
        case prompt
        case parallelGroupId
        case parallelGroupIDSnake = "parallel_group_id"
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
        if let singleValueContainer = try? decoder.singleValueContainer(),
           let rawNodeID = try? singleValueContainer.decode(String.self),
           !rawNodeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = WorkflowDAGTask(nodeId: rawNodeID)
            return
        }

        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let decodedNodeID = Self.firstPresentString(
            in: container,
            keys: [
                .nodeId,
                .nodeIDSnake,
                .nodeIDPascal,
                .id,
                .taskId,
                .taskIDSnake,
                .taskIDPascal,
                .node,
                .name,
            ]
        )
        guard let decodedNodeID, !decodedNodeID.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Workflow DAG node is missing an identifier"
                )
            )
        }

        let decodedOrdinal = container.decodeLossyInt(forKey: .ordinal)
            ?? container.decodeLossyInt(forKey: .index)
            ?? container.decodeLossyInt(forKey: .order)
        let decodedIteration = container.decodeLossyInt(forKey: .iteration)
        let decodedOutputTableName = Self.firstPresentString(
            in: container,
            keys: [.outputTableName, .outputTableNameSnake, .outputTable, .outputTableSnake]
        ) ?? Self.outputTableName(
            from: (try? container.decodeIfPresent(JSONValue.self, forKey: .outputTable))
                ?? (try? container.decodeIfPresent(JSONValue.self, forKey: .outputTableSnake))
        )
        let decodedNeedsApproval = container.decodeLossyBool(forKey: .needsApproval)
            ?? container.decodeLossyBool(forKey: .needsApprovalSnake)
            ?? container.decodeLossyBool(forKey: .requiresApproval)
            ?? container.decodeLossyBool(forKey: .requiresApprovalSnake)
        let decodedApprovalMode = Self.firstPresentString(in: container, keys: [.approvalMode, .approvalModeSnake])
        let decodedRetries = container.decodeLossyInt(forKey: .retries)
            ?? container.decodeLossyInt(forKey: .maxRetries)
            ?? container.decodeLossyInt(forKey: .maxRetriesSnake)
        let decodedTimeoutMs = container.decodeLossyInt64(forKey: .timeoutMs)
            ?? container.decodeLossyInt64(forKey: .timeoutMsSnake)
        let decodedHeartbeatTimeoutMs = container.decodeLossyInt64(forKey: .heartbeatTimeoutMs)
            ?? container.decodeLossyInt64(forKey: .heartbeatTimeoutMsSnake)
        let decodedContinueOnFail = container.decodeLossyBool(forKey: .continueOnFail)
            ?? container.decodeLossyBool(forKey: .continueOnFailSnake)
        let decodedPrompt = Self.firstPresentString(in: container, keys: [.prompt])
        let decodedParallelGroupID = Self.firstPresentString(in: container, keys: [.parallelGroupId, .parallelGroupIDSnake])

        self = WorkflowDAGTask(
            nodeId: decodedNodeID,
            ordinal: decodedOrdinal,
            iteration: decodedIteration,
            outputTableName: decodedOutputTableName,
            needsApproval: decodedNeedsApproval,
            approvalMode: decodedApprovalMode,
            retries: decodedRetries,
            timeoutMs: decodedTimeoutMs,
            heartbeatTimeoutMs: decodedHeartbeatTimeoutMs,
            continueOnFail: decodedContinueOnFail,
            prompt: decodedPrompt,
            parallelGroupId: decodedParallelGroupID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(ordinal, forKey: .ordinal)
        try container.encodeIfPresent(iteration, forKey: .iteration)
        try container.encodeIfPresent(outputTableName, forKey: .outputTableName)
        try container.encodeIfPresent(needsApproval, forKey: .needsApproval)
        try container.encodeIfPresent(approvalMode, forKey: .approvalMode)
        try container.encodeIfPresent(retries, forKey: .retries)
        try container.encodeIfPresent(timeoutMs, forKey: .timeoutMs)
        try container.encodeIfPresent(heartbeatTimeoutMs, forKey: .heartbeatTimeoutMs)
        try container.encodeIfPresent(continueOnFail, forKey: .continueOnFail)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(parallelGroupId, forKey: .parallelGroupId)
    }

    private static func firstPresentString(
        in container: KeyedDecodingContainer<DecodingKeys>,
        keys: [DecodingKeys]
    ) -> String? {
        for key in keys {
            if let value = decodeLossyString(in: container, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeLossyString(
        in container: KeyedDecodingContainer<DecodingKeys>,
        forKey key: DecodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(JSONValue.self, forKey: key) {
            return nodeIdentifier(from: value)
        }
        return nil
    }

    private static func outputTableName(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            return jsonValueString(object["name"])
                ?? jsonValueString(object["table"])
                ?? jsonValueString(object["tableName"])
                ?? jsonValueString(object["table_name"])
                ?? jsonValueString(object["id"])
                ?? jsonValueString(object["key"])
        default:
            return jsonValueString(value)
        }
    }

    private static func nodeIdentifier(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            return jsonValueString(object["nodeId"])
                ?? jsonValueString(object["node_id"])
                ?? jsonValueString(object["id"])
                ?? jsonValueString(object["taskId"])
                ?? jsonValueString(object["task_id"])
                ?? jsonValueString(object["name"])
                ?? jsonValueString(object["key"])
        default:
            return jsonValueString(value)
        }
    }
}

struct WorkflowDAGEdge: Identifiable, Codable, Equatable {
    let from: String
    let to: String

    var id: String { "\(from)->\(to)" }

    enum CodingKeys: String, CodingKey {
        case from
        case to
    }

    private enum DecodingKeys: String, CodingKey {
        case from
        case to
        case source
        case target
        case sourceId
        case targetId
        case fromId
        case toId
        case fromNode
        case fromNodeSnake = "from_node"
        case fromNodeId
        case fromNodeIDSnake = "from_node_id"
        case fromTaskId
        case fromTaskIDSnake = "from_task_id"
        case toNode
        case toNodeSnake = "to_node"
        case toNodeId
        case toNodeIDSnake = "to_node_id"
        case toTaskId
        case toTaskIDSnake = "to_task_id"
        case start
        case end
        case parent
        case child
        case src
        case dst
        case tail
        case head
        case u
        case v
    }

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            let first = try Self.decodeLossyString(from: &unkeyed)
            let second = try Self.decodeLossyString(from: &unkeyed)
            if let first = first?.trimmingCharacters(in: .whitespacesAndNewlines),
               let second = second?.trimmingCharacters(in: .whitespacesAndNewlines),
               !first.isEmpty,
               !second.isEmpty {
                self.from = first
                self.to = second
                return
            }
        }

        if let singleValue = try? decoder.singleValueContainer(),
           let text = try? singleValue.decode(String.self),
           let edge = Self.parseInlineEdge(text) {
            self = edge
            return
        }

        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let decodedFrom = Self.firstLossyString(
            in: container,
            keys: [
                .from,
                .source,
                .sourceId,
                .fromId,
                .fromNode,
                .fromNodeSnake,
                .fromNodeId,
                .fromNodeIDSnake,
                .fromTaskId,
                .fromTaskIDSnake,
                .start,
                .parent,
                .src,
                .tail,
                .u,
            ]
        )
        let decodedTo = Self.firstLossyString(
            in: container,
            keys: [
                .to,
                .target,
                .targetId,
                .toId,
                .toNode,
                .toNodeSnake,
                .toNodeId,
                .toNodeIDSnake,
                .toTaskId,
                .toTaskIDSnake,
                .end,
                .child,
                .dst,
                .head,
                .v,
            ]
        )

        guard let decodedFrom = decodedFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !decodedFrom.isEmpty,
              let decodedTo = decodedTo?.trimmingCharacters(in: .whitespacesAndNewlines), !decodedTo.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Workflow DAG edge must include both source and target node IDs"
                )
            )
        }

        from = decodedFrom
        to = decodedTo
    }

    private static func parseInlineEdge(_ text: String) -> WorkflowDAGEdge? {
        for separator in ["->", "=>"] {
            if let range = text.range(of: separator) {
                let from = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let to = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !from.isEmpty, !to.isEmpty {
                    return WorkflowDAGEdge(from: from, to: to)
                }
            }
        }
        return nil
    }

    private static func firstLossyString(
        in container: KeyedDecodingContainer<DecodingKeys>,
        keys: [DecodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return String(value)
            }
            if let value = try? container.decodeIfPresent(JSONValue.self, forKey: key) {
                if let decoded = nodeIdentifier(from: value) {
                    return decoded
                }
            }
        }
        return nil
    }

    private static func decodeLossyString(from container: inout UnkeyedDecodingContainer) throws -> String? {
        if let value = try? container.decode(String.self) {
            return value
        }
        if let value = try? container.decode(Int.self) {
            return String(value)
        }
        if let value = try? container.decode(Int64.self) {
            return String(value)
        }
        if let value = try? container.decode(Double.self) {
            return String(value)
        }
        if let value = try? container.decode(JSONValue.self) {
            return nodeIdentifier(from: value)
        }
        return nil
    }

    private static func nodeIdentifier(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .object(let object):
            let preferredKeys = [
                "nodeId",
                "node_id",
                "id",
                "taskId",
                "task_id",
                "name",
                "key",
                "index",
                "ordinal",
            ]
            for key in preferredKeys {
                if let identifier = jsonValueString(object[key]) {
                    return identifier
                }
            }
            return nil
        default:
            return jsonValueString(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(from, forKey: .from)
        try container.encode(to, forKey: .to)
    }
}

struct WorkflowDAG: Codable {
    let workflowID: String?
    let mode: String?
    let runId: String?
    let frameNo: Int?
    let xml: WorkflowDAGXMLNode?
    let tasks: [WorkflowDAGTask]
    let graphEdges: [WorkflowDAGEdge]?
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
        if let graphEdges, !graphEdges.isEmpty {
            let validNodeIDs = Set(nodes.map(\.nodeId))
            return Self.filteredAndUniqueEdges(graphEdges, validNodeIds: validNodeIDs.isEmpty ? nil : validNodeIDs)
        }

        guard let xml else {
            return Self.sequentialEdges(for: nodes.map(\.nodeId))
        }

        let validNodeIds = Set(nodes.map(\.nodeId))
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
            (graphEdges?.isEmpty ?? true) &&
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
        graphEdges: [WorkflowDAGEdge]? = nil,
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
        let resolvedEdges = graphEdges ?? []
        let resolvedTasks = Self.synthesizedTasks(from: resolvedEdges, existing: tasks)
        self.tasks = resolvedTasks
        self.graphEdges = resolvedEdges.isEmpty ? nil : resolvedEdges
        self.entryTask = entryTask ?? Self.firstTaskId(in: xml) ?? resolvedTasks.sortedForWorkflowDAG.first?.nodeId
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
            graphEdges: nil,
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
        case graphEdges = "edges"
        case entryTask
        case entryTaskID = "entryTaskId"
        case fields
        case message
    }

    private enum DecodingKeys: String, CodingKey {
        case workflowID = "workflowId"
        case workflowIDSnake = "workflow_id"
        case workflowIDLegacy = "workflowID"
        case graph
        case dag
        case mode
        case runId
        case runIdSnake = "run_id"
        case frameNo
        case frameNoSnake = "frame_no"
        case xml
        case tasks
        case nodes
        case graphEdges = "edges"
        case links
        case entryTask
        case entryTaskSnake = "entry_task"
        case entryTaskID = "entryTaskId"
        case entryTaskIDSnake = "entry_task_id"
        case fields
        case launchFields
        case inputFields
        case inputSchema
        case inputSchemaSnake = "input_schema"
        case input
        case schema
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodingKeys.self)
        let graphValue = (try? container.decodeIfPresent(JSONValue.self, forKey: .graph))
            ?? (try? container.decodeIfPresent(JSONValue.self, forKey: .dag))

        let workflowIDDirect = try? container.decodeIfPresent(String.self, forKey: .workflowID)
        let workflowIDSnake = try? container.decodeIfPresent(String.self, forKey: .workflowIDSnake)
        let workflowIDLegacy = try? container.decodeIfPresent(String.self, forKey: .workflowIDLegacy)
        let workflowIDFromGraph = Self.stringValue(in: graphValue, keys: ["workflowId", "workflow_id", "workflowID"])
        workflowID = workflowIDDirect ?? workflowIDSnake ?? workflowIDLegacy ?? workflowIDFromGraph

        let modeDirect = try? container.decodeIfPresent(String.self, forKey: .mode)
        mode = modeDirect ?? Self.stringValue(in: graphValue, keys: ["mode"])

        let runIDDirect = try? container.decodeIfPresent(String.self, forKey: .runId)
        let runIDSnake = try? container.decodeIfPresent(String.self, forKey: .runIdSnake)
        let runIDFromGraph = Self.stringValue(in: graphValue, keys: ["runId", "run_id"])
        runId = runIDDirect ?? runIDSnake ?? runIDFromGraph

        frameNo = container.decodeLossyInt(forKey: .frameNo)
            ?? container.decodeLossyInt(forKey: .frameNoSnake)

        let xmlDirect = try? container.decodeIfPresent(WorkflowDAGXMLNode.self, forKey: .xml)
        let xmlFromGraph = Self.decodeFromJSONValue(
            WorkflowDAGXMLNode.self,
            value: Self.value(in: graphValue, keys: ["xml"])
        )
        xml = xmlDirect ?? xmlFromGraph

        let graphEdgesValue = try? container.decodeIfPresent(JSONValue.self, forKey: .graphEdges)
        let linksValue = try? container.decodeIfPresent(JSONValue.self, forKey: .links)
        let fallbackEdgesValue = Self.value(in: graphValue, keys: ["edges", "links", "connections"])
        let edgesValue = graphEdgesValue ?? linksValue ?? fallbackEdgesValue

        let explicitEdges = try? container.decodeIfPresent([WorkflowDAGEdge].self, forKey: .graphEdges)
        let legacyEdges = try? container.decodeIfPresent([WorkflowDAGEdge].self, forKey: .links)
        let decodedEdges = explicitEdges ?? legacyEdges ?? Self.decodeEdges(from: edgesValue) ?? []

        let tasksJSON = try? container.decodeIfPresent(JSONValue.self, forKey: .tasks)
        let nodesJSON = try? container.decodeIfPresent(JSONValue.self, forKey: .nodes)
        let fallbackTasksJSON = Self.value(in: graphValue, keys: ["tasks", "nodes", "vertices"])
        let tasksValue = tasksJSON ?? nodesJSON ?? fallbackTasksJSON

        let explicitTasks = try? container.decodeIfPresent([WorkflowDAGTask].self, forKey: .tasks)
        let legacyTasks = try? container.decodeIfPresent([WorkflowDAGTask].self, forKey: .nodes)
        let decodedTasks = explicitTasks ?? legacyTasks ?? Self.decodeTasks(from: tasksValue) ?? []

        let normalizedEdges = Self.normalizedEdgeEndpoints(decodedEdges, tasks: decodedTasks)
        let resolvedTasks = Self.synthesizedTasks(from: normalizedEdges, existing: decodedTasks)
        tasks = resolvedTasks
        graphEdges = normalizedEdges.isEmpty ? nil : normalizedEdges

        let fieldsJSON = try? container.decodeIfPresent(JSONValue.self, forKey: .fields)
        let launchFieldsJSON = try? container.decodeIfPresent(JSONValue.self, forKey: .launchFields)
        let inputFieldsJSON = try? container.decodeIfPresent(JSONValue.self, forKey: .inputFields)
        let fallbackFieldsJSON = Self.value(in: graphValue, keys: ["fields", "launchFields", "inputFields"])
        let fieldsValue = fieldsJSON ?? launchFieldsJSON ?? inputFieldsJSON ?? fallbackFieldsJSON

        let explicitFields = try? container.decodeIfPresent([WorkflowLaunchField].self, forKey: .fields)
        let launchFields = try? container.decodeIfPresent([WorkflowLaunchField].self, forKey: .launchFields)
        let inputFields = try? container.decodeIfPresent([WorkflowLaunchField].self, forKey: .inputFields)
        let decodedFields = explicitFields
            ?? launchFields
            ?? inputFields
            ?? Self.decodeFromJSONValue([WorkflowLaunchField].self, value: fieldsValue)

        let inputSchema = try? container.decodeIfPresent(JSONValue.self, forKey: .inputSchema)
        let inputSchemaSnake = try? container.decodeIfPresent(JSONValue.self, forKey: .inputSchemaSnake)
        let inputValue = try? container.decodeIfPresent(JSONValue.self, forKey: .input)
        let schemaValue = try? container.decodeIfPresent(JSONValue.self, forKey: .schema)
        let fallbackInputSchema = Self.value(in: graphValue, keys: ["inputSchema", "input_schema", "input", "schema"])
        let decodedInputSchema = inputSchema ?? inputSchemaSnake ?? inputValue ?? schemaValue ?? fallbackInputSchema
        let inferredFields = WorkflowLaunchField.fields(fromInputSchema: decodedInputSchema)
        fields = Self.mergedLaunchFields(decodedFields: decodedFields, inferredFields: inferredFields)

        let entryTaskIDDirect = try? container.decodeIfPresent(String.self, forKey: .entryTaskID)
        let entryTaskIDSnake = try? container.decodeIfPresent(String.self, forKey: .entryTaskIDSnake)
        let entryTaskIDFromGraph = Self.stringValue(in: graphValue, keys: ["entryTaskId", "entry_task_id"])
        entryTaskID = entryTaskIDDirect ?? entryTaskIDSnake ?? entryTaskIDFromGraph

        let messageDirect = try? container.decodeIfPresent(String.self, forKey: .message)
        message = messageDirect ?? Self.stringValue(in: graphValue, keys: ["message"])

        let entryTaskDirect = try? container.decodeIfPresent(String.self, forKey: .entryTask)
        let entryTaskSnake = try? container.decodeIfPresent(String.self, forKey: .entryTaskSnake)
        let entryTaskFromGraph = Self.stringValue(in: graphValue, keys: ["entryTask", "entry_task"])
        let decodedEntryTask = entryTaskDirect ?? entryTaskSnake ?? entryTaskFromGraph
        entryTask = decodedEntryTask ?? entryTaskID ?? Self.firstTaskId(in: xml) ?? resolvedTasks.sortedForWorkflowDAG.first?.nodeId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(workflowID, forKey: .workflowID)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encodeIfPresent(frameNo, forKey: .frameNo)
        try container.encodeIfPresent(xml, forKey: .xml)
        try container.encode(tasks, forKey: .tasks)
        try container.encodeIfPresent(graphEdges, forKey: .graphEdges)
        try container.encodeIfPresent(entryTask, forKey: .entryTask)
        try container.encodeIfPresent(entryTaskID, forKey: .entryTaskID)
        try container.encodeIfPresent(fields, forKey: .fields)
        try container.encodeIfPresent(message, forKey: .message)
    }

    private struct GraphSpan {
        let starts: [String]
        let ends: [String]
        let edges: [WorkflowDAGEdge]

        var isEmpty: Bool {
            starts.isEmpty && ends.isEmpty && edges.isEmpty
        }
    }

    private static func mergedLaunchFields(
        decodedFields: [WorkflowLaunchField]?,
        inferredFields: [WorkflowLaunchField]?
    ) -> [WorkflowLaunchField]? {
        let explicit = decodedFields.flatMap { $0.isEmpty ? nil : $0 }
        let inferred = inferredFields.flatMap { $0.isEmpty ? nil : $0 }

        guard let explicit else {
            return inferred ?? decodedFields ?? inferredFields
        }
        guard let inferred else {
            return explicit
        }

        let inferredByKey = Dictionary(uniqueKeysWithValues: inferred.map { ($0.key, $0) })
        var merged: [WorkflowLaunchField] = []
        merged.reserveCapacity(max(explicit.count, inferred.count))

        var seenKeys = Set<String>()
        for field in explicit {
            guard seenKeys.insert(field.key).inserted else { continue }

            guard let inferredField = inferredByKey[field.key] else {
                merged.append(field)
                continue
            }

            let resolvedName: String
            if field.name == field.key, inferredField.name != inferredField.key {
                resolvedName = inferredField.name
            } else {
                resolvedName = field.name
            }

            merged.append(
                WorkflowLaunchField(
                    name: resolvedName,
                    key: field.key,
                    type: field.type ?? inferredField.type,
                    defaultValue: field.defaultValue ?? inferredField.defaultValue,
                    required: field.required || inferredField.required
                )
            )
        }

        for field in inferred where seenKeys.insert(field.key).inserted {
            merged.append(field)
        }

        return merged.isEmpty ? nil : merged
    }

    private static func value(in payload: JSONValue?, keys: [String]) -> JSONValue? {
        guard case .object(let object) = payload else { return nil }
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private static func stringValue(in payload: JSONValue?, keys: [String]) -> String? {
        jsonValueString(value(in: payload, keys: keys))
    }

    private static func decodeFromJSONValue<T: Decodable>(_ type: T.Type, value: JSONValue?) -> T? {
        guard let value else { return nil }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func decodeTasks(from value: JSONValue?) -> [WorkflowDAGTask]? {
        guard let value else { return nil }

        if let decoded = decodeFromJSONValue([WorkflowDAGTask].self, value: value), !decoded.isEmpty {
            return decoded
        }

        switch value {
        case .array(let entries):
            let tasks = entries.compactMap { decodeFromJSONValue(WorkflowDAGTask.self, value: $0) }
            return tasks.isEmpty ? nil : tasks
        case .object(let entries):
            var tasks: [WorkflowDAGTask] = []
            tasks.reserveCapacity(entries.count)
            for (key, entry) in entries {
                if case .object(var object) = entry {
                    let hasExplicitNodeID = [
                        "nodeId",
                        "node_id",
                        "nodeID",
                        "id",
                        "taskId",
                        "task_id",
                        "taskID",
                        "node",
                        "name",
                    ].contains(where: { object[$0] != nil })
                    if !hasExplicitNodeID {
                        object["nodeId"] = .string(key)
                    }
                    if let task = decodeFromJSONValue(WorkflowDAGTask.self, value: .object(object)) {
                        tasks.append(task)
                        continue
                    }
                }
                if let task = decodeFromJSONValue(WorkflowDAGTask.self, value: entry) {
                    tasks.append(task)
                    continue
                }
                if let nodeID = jsonValueString(entry), !nodeID.isEmpty {
                    tasks.append(WorkflowDAGTask(nodeId: nodeID))
                    continue
                }
                if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tasks.append(WorkflowDAGTask(nodeId: key))
                }
            }
            return tasks.isEmpty ? nil : tasks
        default:
            return nil
        }
    }

    private static func decodeEdges(from value: JSONValue?) -> [WorkflowDAGEdge]? {
        guard let value else { return nil }

        if let decoded = decodeFromJSONValue([WorkflowDAGEdge].self, value: value), !decoded.isEmpty {
            return decoded
        }
        if let decodedSingle = decodeFromJSONValue(WorkflowDAGEdge.self, value: value) {
            return [decodedSingle]
        }

        switch value {
        case .array(let entries):
            let edges = entries.compactMap { decodeFromJSONValue(WorkflowDAGEdge.self, value: $0) }
            return edges.isEmpty ? nil : edges
        case .object(let entries):
            if let decoded = decodeFromJSONValue(WorkflowDAGEdge.self, value: value) {
                return [decoded]
            }
            var edges: [WorkflowDAGEdge] = []
            for from in entries.keys.sorted() {
                guard let targetsValue = entries[from] else { continue }
                let source = from.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !source.isEmpty else { continue }
                let targets = decodeEdgeTargets(from: targetsValue)
                for target in targets where !target.isEmpty {
                    edges.append(WorkflowDAGEdge(from: source, to: target))
                }
            }
            return edges.isEmpty ? nil : edges
        default:
            return nil
        }
    }

    private static func decodeEdgeTargets(from value: JSONValue?) -> [String] {
        guard let value else { return [] }
        switch value {
        case .array(let entries):
            return entries.compactMap { jsonValueString($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .object(let object):
            if let direct = jsonValueString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
                return [direct]
            }
            let nestedTargets = Self.value(in: value, keys: ["to", "target", "targets", "children", "next"])
            if let nestedTargets {
                return decodeEdgeTargets(from: nestedTargets)
            }
            if let nodeID = jsonValueString(object["nodeId"])?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeID.isEmpty {
                return [nodeID]
            }
            if let nodeID = jsonValueString(object["node_id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeID.isEmpty {
                return [nodeID]
            }
            if let nodeID = jsonValueString(object["id"])?.trimmingCharacters(in: .whitespacesAndNewlines), !nodeID.isEmpty {
                return [nodeID]
            }
            return []
        default:
            if let target = jsonValueString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty {
                return [target]
            }
            return []
        }
    }

    private static func normalizedEdgeEndpoints(_ edges: [WorkflowDAGEdge], tasks: [WorkflowDAGTask]) -> [WorkflowDAGEdge] {
        guard !edges.isEmpty, !tasks.isEmpty else { return edges }

        let directNodeIDs = Set(tasks.map(\.nodeId))
        let orderedNodeIDs = tasks.sortedForWorkflowDAG.map(\.nodeId)
        let nodeIDsByOrdinal = Dictionary(
            uniqueKeysWithValues: tasks.compactMap { task -> (Int, String)? in
                guard let ordinal = task.ordinal else { return nil }
                return (ordinal, task.nodeId)
            }
        )

        return edges.map { edge in
            let from = normalizedNodeID(
                edge.from,
                directNodeIDs: directNodeIDs,
                orderedNodeIDs: orderedNodeIDs,
                nodeIDsByOrdinal: nodeIDsByOrdinal
            )
            let to = normalizedNodeID(
                edge.to,
                directNodeIDs: directNodeIDs,
                orderedNodeIDs: orderedNodeIDs,
                nodeIDsByOrdinal: nodeIDsByOrdinal
            )
            return WorkflowDAGEdge(from: from, to: to)
        }
    }

    private static func normalizedNodeID(
        _ rawValue: String,
        directNodeIDs: Set<String>,
        orderedNodeIDs: [String],
        nodeIDsByOrdinal: [Int: String]
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if directNodeIDs.contains(trimmed) {
            return trimmed
        }
        guard let numeric = Int(trimmed) else {
            return trimmed
        }
        if let mapped = nodeIDsByOrdinal[numeric] {
            return mapped
        }
        if numeric >= 0, numeric < orderedNodeIDs.count {
            return orderedNodeIDs[numeric]
        }
        return trimmed
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

    private static func filteredAndUniqueEdges(_ edges: [WorkflowDAGEdge], validNodeIds: Set<String>?) -> [WorkflowDAGEdge] {
        let filtered = edges.filter { edge in
            let from = edge.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = edge.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty, !to.isEmpty else { return false }
            guard let validNodeIds else { return true }
            return validNodeIds.contains(from) && validNodeIds.contains(to)
        }
        return uniqueEdges(filtered)
    }

    private static func synthesizedTasks(from edges: [WorkflowDAGEdge], existing tasks: [WorkflowDAGTask]) -> [WorkflowDAGTask] {
        guard tasks.isEmpty, !edges.isEmpty else { return tasks }
        var orderedNodeIds: [String] = []
        var seen = Set<String>()
        for edge in edges {
            for rawNodeID in [edge.from, edge.to] {
                let nodeID = rawNodeID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nodeID.isEmpty, seen.insert(nodeID).inserted else { continue }
                orderedNodeIds.append(nodeID)
            }
        }
        return orderedNodeIds.enumerated().map { ordinal, nodeID in
            WorkflowDAGTask(nodeId: nodeID, ordinal: ordinal)
        }
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
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value != 0
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

    func decodeLossyDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return Double(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

// MARK: - Approval Types

struct Approval: Identifiable, Codable {
    let id: String
    let runId: String
    let nodeId: String
    let iteration: Int?
    let workflowPath: String?
    let gate: String?
    let status: String          // pending, approved, denied
    let payload: String?        // JSON context
    let requestedAt: Int64
    let resolvedAt: Int64?
    let resolvedBy: String?
    let source: String?         // http, sqlite, exec, synthetic

    init(
        id: String,
        runId: String,
        nodeId: String,
        iteration: Int? = nil,
        workflowPath: String? = nil,
        gate: String? = nil,
        status: String,
        payload: String? = nil,
        requestedAt: Int64,
        resolvedAt: Int64? = nil,
        resolvedBy: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.runId = runId
        self.nodeId = nodeId
        self.iteration = iteration
        self.workflowPath = workflowPath
        self.gate = gate
        self.status = status
        self.payload = payload
        self.requestedAt = requestedAt
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.source = source
    }

    enum CodingKeys: String, CodingKey {
        case id
        case runId
        case nodeId
        case iteration
        case attempt
        case workflowPath
        case gate
        case status
        case payload
        case requestedAt
        case requestedAtMs
        case resolvedAt
        case resolvedAtMs
        case resolvedBy
        case decidedAt
        case decidedAtMs
        case decidedBy
        case source
        case transportSource

        case runIDSnake = "run_id"
        case nodeIDSnake = "node_id"
        case workflowPathSnake = "workflow_path"
        case requestedAtSnake = "requested_at"
        case requestedAtMsSnake = "requested_at_ms"
        case resolvedAtSnake = "resolved_at"
        case resolvedAtMsSnake = "resolved_at_ms"
        case resolvedBySnake = "resolved_by"
        case decidedAtSnake = "decided_at"
        case decidedAtMsSnake = "decided_at_ms"
        case decidedBySnake = "decided_by"
        case transportSourceSnake = "transport_source"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
            ?? container.decode(String.self, forKey: .runIDSnake)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
            ?? container.decode(String.self, forKey: .nodeIDSnake)
        iteration = container.decodeLossyInt(forKey: .iteration)
            ?? container.decodeLossyInt(forKey: .attempt)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "\(runId):\(nodeId):\(iteration ?? 0)"
        workflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath)
            ?? container.decodeIfPresent(String.self, forKey: .workflowPathSnake)
        gate = try container.decodeIfPresent(String.self, forKey: .gate)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        requestedAt = container.decodeLossyInt64(forKey: .requestedAt)
            ?? container.decodeLossyInt64(forKey: .requestedAtMs)
            ?? container.decodeLossyInt64(forKey: .requestedAtSnake)
            ?? container.decodeLossyInt64(forKey: .requestedAtMsSnake)
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        resolvedAt = container.decodeLossyInt64(forKey: .resolvedAt)
            ?? container.decodeLossyInt64(forKey: .resolvedAtMs)
            ?? container.decodeLossyInt64(forKey: .resolvedAtSnake)
            ?? container.decodeLossyInt64(forKey: .resolvedAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .decidedAt)
            ?? container.decodeLossyInt64(forKey: .decidedAtMs)
            ?? container.decodeLossyInt64(forKey: .decidedAtSnake)
            ?? container.decodeLossyInt64(forKey: .decidedAtMsSnake)
        resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)
            ?? container.decodeIfPresent(String.self, forKey: .resolvedBySnake)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBy)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBySnake)
        source = try container.decodeIfPresent(String.self, forKey: .source)
            ?? container.decodeIfPresent(String.self, forKey: .transportSource)
            ?? container.decodeIfPresent(String.self, forKey: .transportSourceSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(runId, forKey: .runId)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(iteration, forKey: .iteration)
        try container.encodeIfPresent(workflowPath, forKey: .workflowPath)
        try container.encodeIfPresent(gate, forKey: .gate)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encode(requestedAt, forKey: .requestedAt)
        try container.encodeIfPresent(resolvedAt, forKey: .resolvedAt)
        try container.encodeIfPresent(resolvedBy, forKey: .resolvedBy)
        try container.encodeIfPresent(source, forKey: .source)
    }

    var requestedDate: Date {
        Date(timeIntervalSince1970: Double(requestedAt) / 1000)
    }

    var isPending: Bool {
        switch status
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-") {
        case "", "pending", "waiting", "waiting-approval", "waitingapproval", "blocked", "paused":
            return true
        default:
            return false
        }
    }

    var waitTime: String {
        waitTime(at: Date())
    }

    func waitTime(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(requestedDate)))
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
    let iteration: Int?
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
        iteration: Int? = nil,
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
        self.iteration = iteration
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
        case iteration
        case attempt
        case action
        case decision
        case status
        case note
        case reason
        case resolvedAt
        case resolvedAtMs
        case resolvedBy
        case decidedAt
        case decidedAtMs
        case decidedBy
        case requestedAt
        case requestedAtMs
        case workflowPath
        case gate
        case payload
        case source
        case transportSource

        case runIDSnake = "run_id"
        case nodeIDSnake = "node_id"
        case resolvedAtSnake = "resolved_at"
        case resolvedAtMsSnake = "resolved_at_ms"
        case resolvedBySnake = "resolved_by"
        case decidedAtSnake = "decided_at"
        case decidedAtMsSnake = "decided_at_ms"
        case decidedBySnake = "decided_by"
        case requestedAtSnake = "requested_at"
        case requestedAtMsSnake = "requested_at_ms"
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
        iteration = container.decodeLossyInt(forKey: .iteration)
            ?? container.decodeLossyInt(forKey: .attempt)
        action = Self.normalizedAction(
            try container.decodeIfPresent(String.self, forKey: .action)
                ?? container.decodeIfPresent(String.self, forKey: .decision)
                ?? container.decodeIfPresent(String.self, forKey: .status)
        )
        note = try container.decodeIfPresent(String.self, forKey: .note)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        resolvedAt = container.decodeLossyInt64(forKey: .resolvedAt)
            ?? container.decodeLossyInt64(forKey: .resolvedAtMs)
            ?? container.decodeLossyInt64(forKey: .resolvedAtSnake)
            ?? container.decodeLossyInt64(forKey: .resolvedAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .decidedAt)
            ?? container.decodeLossyInt64(forKey: .decidedAtMs)
            ?? container.decodeLossyInt64(forKey: .decidedAtSnake)
            ?? container.decodeLossyInt64(forKey: .decidedAtMsSnake)
        resolvedBy = try container.decodeIfPresent(String.self, forKey: .resolvedBy)
            ?? container.decodeIfPresent(String.self, forKey: .resolvedBySnake)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBy)
            ?? container.decodeIfPresent(String.self, forKey: .decidedBySnake)
        workflowPath = try container.decodeIfPresent(String.self, forKey: .workflowPath)
            ?? container.decodeIfPresent(String.self, forKey: .workflowPathSnake)
        gate = try container.decodeIfPresent(String.self, forKey: .gate)
        payload = try container.decodeIfPresent(String.self, forKey: .payload)
        requestedAt = container.decodeLossyInt64(forKey: .requestedAt)
            ?? container.decodeLossyInt64(forKey: .requestedAtMs)
            ?? container.decodeLossyInt64(forKey: .requestedAtSnake)
            ?? container.decodeLossyInt64(forKey: .requestedAtMsSnake)
        source = try container.decodeIfPresent(String.self, forKey: .source)
            ?? container.decodeIfPresent(String.self, forKey: .transportSource)
            ?? container.decodeIfPresent(String.self, forKey: .transportSourceSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(runId, forKey: .runId)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(iteration, forKey: .iteration)
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

    private static func normalizedAction(_ rawAction: String?) -> String {
        let normalized = rawAction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "approve", "approved":
            return "approved"
        case "deny", "denied":
            return "denied"
        case "pending", "waiting", "waiting-approval", "blocked", "":
            return "pending"
        default:
            return "unknown"
        }
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
        case defaultValueAlt = "defaultValue"
    }

    init(name: String, type: String?, defaultValue: String?) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
            ?? container.decodeIfPresent(String.self, forKey: .defaultValueAlt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
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

extension ScoreRow {
    enum CodingKeys: String, CodingKey {
        case id
        case runId
        case runIdSnake = "run_id"
        case nodeId
        case nodeIdSnake = "node_id"
        case iteration
        case attempt
        case scorerId
        case scorerIdSnake = "scorer_id"
        case scorerName
        case scorerNameSnake = "scorer_name"
        case source
        case score
        case reason
        case metaJson
        case metaJsonSnake = "meta_json"
        case latencyMs
        case latencyMsSnake = "latency_ms"
        case scoredAtMs
        case scoredAtMsSnake = "scored_at_ms"
        case scoredAt
        case scoredAtSnake = "scored_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = try container.decodeIfPresent(String.self, forKey: .id),
              !decodedID.isEmpty else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected score identifier")
            )
        }

        guard let decodedScore = container.decodeLossyDouble(forKey: .score) else {
            throw DecodingError.keyNotFound(
                CodingKeys.score,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected score value")
            )
        }

        let decodedScoredAt = try container.decodeIfPresent(String.self, forKey: .scoredAt)
        let decodedScoredAtSnake = try container.decodeIfPresent(String.self, forKey: .scoredAtSnake)
        let decodedScoredAtMs = container.decodeLossyInt64(forKey: .scoredAtMs)
            ?? container.decodeLossyInt64(forKey: .scoredAtMsSnake)
            ?? parseInspectTimestampMs(decodedScoredAt)
            ?? parseInspectTimestampMs(decodedScoredAtSnake)
        guard let decodedScoredAtMs else {
            throw DecodingError.keyNotFound(
                CodingKeys.scoredAtMs,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected score timestamp")
            )
        }

        id = decodedID
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
            ?? container.decodeIfPresent(String.self, forKey: .runIdSnake)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
            ?? container.decodeIfPresent(String.self, forKey: .nodeIdSnake)
        iteration = container.decodeLossyInt(forKey: .iteration)
        attempt = container.decodeLossyInt(forKey: .attempt)
        scorerId = try container.decodeIfPresent(String.self, forKey: .scorerId)
            ?? container.decodeIfPresent(String.self, forKey: .scorerIdSnake)
        scorerName = try container.decodeIfPresent(String.self, forKey: .scorerName)
            ?? container.decodeIfPresent(String.self, forKey: .scorerNameSnake)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        score = decodedScore
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        metaJson = try container.decodeIfPresent(String.self, forKey: .metaJson)
            ?? container.decodeIfPresent(String.self, forKey: .metaJsonSnake)
        latencyMs = container.decodeLossyInt64(forKey: .latencyMs)
            ?? container.decodeLossyInt64(forKey: .latencyMsSnake)
        scoredAtMs = decodedScoredAtMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encodeIfPresent(nodeId, forKey: .nodeId)
        try container.encodeIfPresent(iteration, forKey: .iteration)
        try container.encodeIfPresent(attempt, forKey: .attempt)
        try container.encodeIfPresent(scorerId, forKey: .scorerId)
        try container.encodeIfPresent(scorerName, forKey: .scorerName)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(score, forKey: .score)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(metaJson, forKey: .metaJson)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(scoredAtMs, forKey: .scoredAtMs)
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
        (try? Smithers.Models.aggregateScores(scores)) ?? []
    }
}

struct MetricsFilter: Codable, Equatable {
    let workflowPath: String?
    let runId: String?
    let nodeId: String?
    let startMs: Int64?
    let endMs: Int64?
    let groupBy: String?

    init(
        workflowPath: String? = nil,
        runId: String? = nil,
        nodeId: String? = nil,
        startMs: Int64? = nil,
        endMs: Int64? = nil,
        groupBy: String? = nil
    ) {
        self.workflowPath = workflowPath
        self.runId = runId
        self.nodeId = nodeId
        self.startMs = startMs
        self.endMs = endMs
        self.groupBy = groupBy
    }
}

struct TokenMetrics: Decodable, Equatable {
    let totalInputTokens: Int64
    let totalOutputTokens: Int64
    let totalTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64
    let byPeriod: [TokenPeriodBatch]

    init(
        totalInputTokens: Int64 = 0,
        totalOutputTokens: Int64 = 0,
        totalTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        byPeriod: [TokenPeriodBatch] = []
    ) {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.byPeriod = byPeriod
    }

    enum CodingKeys: String, CodingKey {
        case totalInputTokens
        case totalOutputTokens
        case totalTokens
        case cacheReadTokens
        case cacheWriteTokens
        case byPeriod
        case totalInputTokensSnake = "total_input_tokens"
        case totalOutputTokensSnake = "total_output_tokens"
        case totalTokensSnake = "total_tokens"
        case cacheReadTokensSnake = "cache_read_tokens"
        case cacheWriteTokensSnake = "cache_write_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalInputTokens = container.decodeLossyInt64(forKey: .totalInputTokens)
            ?? container.decodeLossyInt64(forKey: .totalInputTokensSnake)
            ?? 0
        totalOutputTokens = container.decodeLossyInt64(forKey: .totalOutputTokens)
            ?? container.decodeLossyInt64(forKey: .totalOutputTokensSnake)
            ?? 0
        let decodedTotalTokens = container.decodeLossyInt64(forKey: .totalTokens)
            ?? container.decodeLossyInt64(forKey: .totalTokensSnake)
        totalTokens = decodedTotalTokens ?? (totalInputTokens + totalOutputTokens)
        cacheReadTokens = container.decodeLossyInt64(forKey: .cacheReadTokens)
            ?? container.decodeLossyInt64(forKey: .cacheReadTokensSnake)
            ?? 0
        cacheWriteTokens = container.decodeLossyInt64(forKey: .cacheWriteTokens)
            ?? container.decodeLossyInt64(forKey: .cacheWriteTokensSnake)
            ?? 0
        byPeriod = (try? container.decode([TokenPeriodBatch].self, forKey: .byPeriod)) ?? []
    }

    var cacheHitRate: Double? {
        guard totalTokens > 0 else { return nil }
        return Double(cacheReadTokens) / Double(totalTokens)
    }
}

struct TokenPeriodBatch: Decodable, Equatable {
    let label: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
    let cacheWriteTokens: Int64

    init(
        label: String,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0
    ) {
        self.label = label
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    enum CodingKeys: String, CodingKey {
        case label
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case cacheWriteTokens
        case inputTokensSnake = "input_tokens"
        case outputTokensSnake = "output_tokens"
        case cacheReadTokensSnake = "cache_read_tokens"
        case cacheWriteTokensSnake = "cache_write_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        inputTokens = container.decodeLossyInt64(forKey: .inputTokens)
            ?? container.decodeLossyInt64(forKey: .inputTokensSnake)
            ?? 0
        outputTokens = container.decodeLossyInt64(forKey: .outputTokens)
            ?? container.decodeLossyInt64(forKey: .outputTokensSnake)
            ?? 0
        cacheReadTokens = container.decodeLossyInt64(forKey: .cacheReadTokens)
            ?? container.decodeLossyInt64(forKey: .cacheReadTokensSnake)
            ?? 0
        cacheWriteTokens = container.decodeLossyInt64(forKey: .cacheWriteTokens)
            ?? container.decodeLossyInt64(forKey: .cacheWriteTokensSnake)
            ?? 0
    }
}

struct LatencyMetrics: Decodable, Equatable {
    let count: Int
    let meanMs: Double
    let minMs: Double
    let maxMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let byPeriod: [LatencyPeriodBatch]

    init(
        count: Int = 0,
        meanMs: Double = 0,
        minMs: Double = 0,
        maxMs: Double = 0,
        p50Ms: Double = 0,
        p95Ms: Double = 0,
        byPeriod: [LatencyPeriodBatch] = []
    ) {
        self.count = count
        self.meanMs = meanMs
        self.minMs = minMs
        self.maxMs = maxMs
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
        self.byPeriod = byPeriod
    }

    enum CodingKeys: String, CodingKey {
        case count
        case meanMs
        case minMs
        case maxMs
        case p50Ms
        case p95Ms
        case byPeriod
        case meanMsSnake = "mean_ms"
        case minMsSnake = "min_ms"
        case maxMsSnake = "max_ms"
        case p50MsSnake = "p50_ms"
        case p95MsSnake = "p95_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = container.decodeLossyInt(forKey: .count) ?? 0
        meanMs = (try? container.decode(Double.self, forKey: .meanMs))
            ?? (try? container.decode(Double.self, forKey: .meanMsSnake))
            ?? 0
        minMs = (try? container.decode(Double.self, forKey: .minMs))
            ?? (try? container.decode(Double.self, forKey: .minMsSnake))
            ?? 0
        maxMs = (try? container.decode(Double.self, forKey: .maxMs))
            ?? (try? container.decode(Double.self, forKey: .maxMsSnake))
            ?? 0
        p50Ms = (try? container.decode(Double.self, forKey: .p50Ms))
            ?? (try? container.decode(Double.self, forKey: .p50MsSnake))
            ?? 0
        p95Ms = (try? container.decode(Double.self, forKey: .p95Ms))
            ?? (try? container.decode(Double.self, forKey: .p95MsSnake))
            ?? 0
        byPeriod = (try? container.decode([LatencyPeriodBatch].self, forKey: .byPeriod)) ?? []
    }
}

struct LatencyPeriodBatch: Decodable, Equatable {
    let label: String
    let count: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double

    init(
        label: String,
        count: Int = 0,
        meanMs: Double = 0,
        p50Ms: Double = 0,
        p95Ms: Double = 0
    ) {
        self.label = label
        self.count = count
        self.meanMs = meanMs
        self.p50Ms = p50Ms
        self.p95Ms = p95Ms
    }
}

struct CostReport: Decodable, Equatable {
    let totalCostUSD: Double
    let inputCostUSD: Double
    let outputCostUSD: Double
    let runCount: Int
    let byPeriod: [CostPeriodBatch]

    init(
        totalCostUSD: Double = 0,
        inputCostUSD: Double = 0,
        outputCostUSD: Double = 0,
        runCount: Int = 0,
        byPeriod: [CostPeriodBatch] = []
    ) {
        self.totalCostUSD = totalCostUSD
        self.inputCostUSD = inputCostUSD
        self.outputCostUSD = outputCostUSD
        self.runCount = runCount
        self.byPeriod = byPeriod
    }

    enum CodingKeys: String, CodingKey {
        case totalCostUSD = "totalCostUsd"
        case inputCostUSD = "inputCostUsd"
        case outputCostUSD = "outputCostUsd"
        case runCount
        case byPeriod
        case totalCostUSDSnake = "total_cost_usd"
        case inputCostUSDSnake = "input_cost_usd"
        case outputCostUSDSnake = "output_cost_usd"
        case runCountSnake = "run_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalCostUSD = (try? container.decode(Double.self, forKey: .totalCostUSD))
            ?? (try? container.decode(Double.self, forKey: .totalCostUSDSnake))
            ?? 0
        inputCostUSD = (try? container.decode(Double.self, forKey: .inputCostUSD))
            ?? (try? container.decode(Double.self, forKey: .inputCostUSDSnake))
            ?? 0
        outputCostUSD = (try? container.decode(Double.self, forKey: .outputCostUSD))
            ?? (try? container.decode(Double.self, forKey: .outputCostUSDSnake))
            ?? 0
        runCount = container.decodeLossyInt(forKey: .runCount)
            ?? container.decodeLossyInt(forKey: .runCountSnake)
            ?? 0
        byPeriod = (try? container.decode([CostPeriodBatch].self, forKey: .byPeriod)) ?? []
    }
}

struct CostPeriodBatch: Decodable, Equatable {
    let label: String
    let totalCostUSD: Double
    let inputCostUSD: Double
    let outputCostUSD: Double
    let runCount: Int

    init(
        label: String,
        totalCostUSD: Double = 0,
        inputCostUSD: Double = 0,
        outputCostUSD: Double = 0,
        runCount: Int = 0
    ) {
        self.label = label
        self.totalCostUSD = totalCostUSD
        self.inputCostUSD = inputCostUSD
        self.outputCostUSD = outputCostUSD
        self.runCount = runCount
    }

    enum CodingKeys: String, CodingKey {
        case label
        case totalCostUSD = "totalCostUsd"
        case inputCostUSD = "inputCostUsd"
        case outputCostUSD = "outputCostUsd"
        case runCount
        case totalCostUSDSnake = "total_cost_usd"
        case inputCostUSDSnake = "input_cost_usd"
        case outputCostUSDSnake = "output_cost_usd"
        case runCountSnake = "run_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? container.decode(String.self, forKey: .label)) ?? ""
        totalCostUSD = (try? container.decode(Double.self, forKey: .totalCostUSD))
            ?? (try? container.decode(Double.self, forKey: .totalCostUSDSnake))
            ?? 0
        inputCostUSD = (try? container.decode(Double.self, forKey: .inputCostUSD))
            ?? (try? container.decode(Double.self, forKey: .inputCostUSDSnake))
            ?? 0
        outputCostUSD = (try? container.decode(Double.self, forKey: .outputCostUSD))
            ?? (try? container.decode(Double.self, forKey: .outputCostUSDSnake))
            ?? 0
        runCount = container.decodeLossyInt(forKey: .runCount)
            ?? container.decodeLossyInt(forKey: .runCountSnake)
            ?? 0
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

    enum CodingKeys: String, CodingKey {
        case namespace
        case key
        case valueJson
        case value = "value"
        case valueJsonSnake = "value_json"
        case schemaSig
        case schemaSigSnake = "schema_sig"
        case createdAtMs
        case createdAtMsSnake = "created_at_ms"
        case updatedAtMs
        case updatedAtMsSnake = "updated_at_ms"
        case ttlMs
        case ttlMsSnake = "ttl_ms"
    }

    init(
        namespace: String,
        key: String,
        valueJson: String,
        schemaSig: String?,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        ttlMs: Int64?
    ) {
        self.namespace = namespace
        self.key = key
        self.valueJson = valueJson
        self.schemaSig = schemaSig
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.ttlMs = ttlMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let decodedNamespace = try container.decodeIfPresent(String.self, forKey: .namespace)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedKey = try container.decodeIfPresent(String.self, forKey: .key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let namespace = decodedNamespace,
            !namespace.isEmpty,
            let key = decodedKey,
            !key.isEmpty
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Memory fact requires namespace and key")
            )
        }

        let valueJson = try container.decodeIfPresent(String.self, forKey: .valueJson)
            ?? container.decodeIfPresent(String.self, forKey: .valueJsonSnake)
            ?? container.decodeIfPresent(String.self, forKey: .value)
        guard let valueJson else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Memory fact requires valueJson")
            )
        }

        guard
            let createdAtMs = container.decodeLossyInt64(forKey: .createdAtMs)
                ?? container.decodeLossyInt64(forKey: .createdAtMsSnake),
            let updatedAtMs = container.decodeLossyInt64(forKey: .updatedAtMs)
                ?? container.decodeLossyInt64(forKey: .updatedAtMsSnake)
        else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Memory fact requires createdAtMs and updatedAtMs")
            )
        }

        self.namespace = namespace
        self.key = key
        self.valueJson = valueJson
        self.schemaSig = try container.decodeIfPresent(String.self, forKey: .schemaSig)
            ?? container.decodeIfPresent(String.self, forKey: .schemaSigSnake)
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.ttlMs = container.decodeLossyInt64(forKey: .ttlMs)
            ?? container.decodeLossyInt64(forKey: .ttlMsSnake)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(namespace, forKey: .namespace)
        try container.encode(key, forKey: .key)
        try container.encode(valueJson, forKey: .valueJson)
        try container.encodeIfPresent(schemaSig, forKey: .schemaSig)
        try container.encode(createdAtMs, forKey: .createdAtMs)
        try container.encode(updatedAtMs, forKey: .updatedAtMs)
        try container.encodeIfPresent(ttlMs, forKey: .ttlMs)
    }

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

struct TimelineResponse: Codable {
    let timeline: Timeline
}

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

struct SnapshotDiffResponse: Codable {
    let diff: SnapshotDiff
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
        case description
        case state
        case status
        case labels
        case assignees
        case commentCount
        case comments
        case commentCountSnake = "comment_count"
        case commentsCountSnake = "comments_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = Self.decodeInt(from: container, forKey: .number)
        id = Self.decodeString(from: container, forKey: .id)
            ?? number.map { "issue-\($0)" }
            ?? "issue"
        title = Self.decodeNormalizedString(from: container, forKey: .title) ?? ""
        body = Self.decodeNormalizedString(from: container, forKey: .body)
            ?? Self.decodeNormalizedString(from: container, forKey: .description)
        state = Self.decodeNormalizedString(from: container, forKey: .state)
            ?? Self.decodeNormalizedString(from: container, forKey: .status)
        labels = Self.decodeNameList(from: container, forKey: .labels)
        assignees = Self.decodeNameList(from: container, forKey: .assignees)
        commentCount = Self.decodeInt(from: container, forKey: .commentCount)
            ?? Self.decodeInt(from: container, forKey: .comments)
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

    private static func decodeNormalizedString(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        guard let value = decodeString(from: container, forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
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
        case state
        case displayName
        case createdAtSnake = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decodedID = Self.decodeString(from: container, forKey: .id).flatMap(Self.normalizedText) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Workspace id is required")
        }
        id = decodedID
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decodeIfPresent(String.self, forKey: .displayName)
        name = Self.normalizedText(decodedName) ?? id
        let decodedStatus = try container.decodeIfPresent(String.self, forKey: .status)
            ?? container.decodeIfPresent(String.self, forKey: .state)
        status = Self.normalizedText(decodedStatus)
        let camelCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let snakeCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        createdAt = Self.normalizedText(camelCreatedAt ?? snakeCreatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
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

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
        guard let decodedID = Self.decodeString(from: container, forKey: .id).flatMap(Self.normalizedText) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Workspace snapshot id is required")
        }
        id = decodedID
        let camelWorkspaceId = Self.decodeString(from: container, forKey: .workspaceId)
        let snakeWorkspaceId = Self.decodeString(from: container, forKey: .workspaceIdSnake)
        guard let decodedWorkspaceId = Self.normalizedText(camelWorkspaceId ?? snakeWorkspaceId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .workspaceId,
                in: container,
                debugDescription: "Workspace snapshot workspaceId is required"
            )
        }
        workspaceId = decodedWorkspaceId
        name = Self.normalizedText(try container.decodeIfPresent(String.self, forKey: .name))
        let camelCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        let snakeCreatedAt = try container.decodeIfPresent(String.self, forKey: .createdAtSnake)
        createdAt = Self.normalizedText(camelCreatedAt ?? snakeCreatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
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

    private static func normalizedText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
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
        if let itemId, !itemId.isEmpty { return itemId }
        if let id, !id.isEmpty { return id }
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
        timestampMs: Int64? = nil,
        fallbackId: String? = nil
    ) {
        self.id = id
        self.itemId = itemId
        self.runId = runId
        self.nodeId = nodeId
        self.attempt = attempt
        self.role = role
        self.content = content
        self.timestampMs = timestampMs
        self._fallbackId = fallbackId ?? Self.fallbackId(
            itemId: itemId,
            runId: runId,
            nodeId: nodeId,
            attempt: attempt,
            role: role,
            content: content,
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
        decodeIndex: Int?
    ) -> String {
        var data = Data("smithers.chatblock.fallback.v2\n".utf8)
        appendField(itemId, named: "itemId", to: &data)
        appendField(runId, named: "runId", to: &data)
        appendField(nodeId, named: "nodeId", to: &data)
        appendField(attempt.map(String.init), named: "attempt", to: &data)
        appendField(normalizedRole(role), named: "role", to: &data)
        appendField(contentPrefix(content), named: "contentPrefix", to: &data)
        appendField(decodeIndex.map(String.init), named: "decodeIndex", to: &data)

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "chatblock-\(hex)"
    }

    private static func normalizedRole(_ role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func contentPrefix(_ content: String) -> String {
        String(content.prefix(96))
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
        (try? Smithers.Models.chatBlockCanMerge(self, with: incoming)) ?? false
    }

    func hasStreamingContentOverlap(with incoming: ChatBlock) -> Bool {
        (try? Smithers.Models.chatBlockHasOverlap(self, with: incoming)) ?? false
    }

    func mergingAssistantStream(with incoming: ChatBlock) -> ChatBlock {
        guard let merged = try? Smithers.Models.chatBlockMerge(self, with: incoming) else {
            return incoming
        }
        guard merged.lifecycleId == nil else { return merged }
        return ChatBlock(
            id: merged.id,
            itemId: merged.itemId,
            runId: merged.runId,
            nodeId: merged.nodeId,
            attempt: merged.attempt,
            role: merged.role,
            content: merged.content,
            timestampMs: merged.timestampMs,
            fallbackId: _fallbackId
        )
    }

    static func mergedStreamingContent(
        existing: String,
        incoming: String,
        existingTimestampMs: Int64? = nil,
        incomingTimestampMs: Int64? = nil
    ) -> String {
        (try? Smithers.Models.mergedStreamingContent(
            existing: existing,
            incoming: incoming,
            existingTimestampMs: existingTimestampMs,
            incomingTimestampMs: incomingTimestampMs
        )) ?? incoming
    }
}

func deduplicatedChatBlocks(_ blocks: [ChatBlock]) -> [ChatBlock] {
    (try? Smithers.Models.deduplicatedChatBlocks(blocks)) ?? blocks
}

// MARK: - Run Hijack Session

struct HijackLaunchInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let workingDirectory: String
}

struct HijackSession: Codable {
    let runId: String
    let agentEngine: String
    let agentBinary: String
    let resumeToken: String
    let cwd: String
    let supportsResume: Bool
    let launchCommand: String?
    let launchArgs: [String]
    let mode: String?
    let resumeCommand: String?

    enum CodingKeys: String, CodingKey {
        case runId, agentEngine, agentBinary, resumeToken, cwd, supportsResume
        case engine, mode, resume, launch, resumeCommand
    }

    private struct LaunchSpec: Codable {
        let command: String
        let args: [String]
        let cwd: String?
    }

    init(
        runId: String,
        agentEngine: String,
        agentBinary: String,
        resumeToken: String,
        cwd: String,
        supportsResume: Bool,
        launchCommand: String? = nil,
        launchArgs: [String] = [],
        mode: String? = nil,
        resumeCommand: String? = nil
    ) {
        self.runId = runId
        self.agentEngine = agentEngine
        self.agentBinary = agentBinary
        self.resumeToken = resumeToken
        self.cwd = cwd
        self.supportsResume = supportsResume
        self.launchCommand = launchCommand
        self.launchArgs = launchArgs
        self.mode = mode
        self.resumeCommand = resumeCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let launch = try container.decodeIfPresent(LaunchSpec.self, forKey: .launch)

        runId = try container.decodeIfPresent(String.self, forKey: .runId) ?? ""
        agentEngine = try container.decodeIfPresent(String.self, forKey: .agentEngine)
            ?? container.decodeIfPresent(String.self, forKey: .engine)
            ?? ""
        agentBinary = try container.decodeIfPresent(String.self, forKey: .agentBinary)
            ?? launch?.command
            ?? Self.defaultAgentBinary(for: agentEngine)
        resumeToken = try container.decodeIfPresent(String.self, forKey: .resumeToken)
            ?? container.decodeIfPresent(String.self, forKey: .resume)
            ?? ""
        let decodedCWD = try container.decodeIfPresent(String.self, forKey: .cwd)
        cwd = launch?.cwd ?? decodedCWD ?? ""
        launchCommand = launch?.command
        launchArgs = launch?.args ?? []
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        resumeCommand = try container.decodeIfPresent(String.self, forKey: .resumeCommand)

        if let explicit = try container.decodeIfPresent(Bool.self, forKey: .supportsResume) {
            supportsResume = explicit
        } else if mode == "conversation" {
            supportsResume = false
        } else {
            supportsResume = launch != nil || !resumeToken.isEmpty
        }

        guard !runId.isEmpty || !agentEngine.isEmpty || launch != nil || !resumeToken.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .runId,
                in: container,
                debugDescription: "Missing hijack session payload"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(runId, forKey: .runId)
        try container.encode(agentEngine, forKey: .agentEngine)
        try container.encode(agentBinary, forKey: .agentBinary)
        try container.encode(resumeToken, forKey: .resumeToken)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(supportsResume, forKey: .supportsResume)
        try container.encodeIfPresent(mode, forKey: .mode)
        try container.encodeIfPresent(resumeCommand, forKey: .resumeCommand)

        if let launchCommand {
            try container.encode(
                LaunchSpec(command: launchCommand, args: launchArgs, cwd: cwd.isEmpty ? nil : cwd),
                forKey: .launch
            )
        }
    }

    func resumeArgs() -> [String] {
        guard supportsResume, !resumeToken.isEmpty else { return [] }
        switch agentEngine {
        case "claude-code", "claude":
            return ["--resume", resumeToken]
        case "codex":
            return cwd.isEmpty ? ["resume", resumeToken] : ["resume", resumeToken, "-C", cwd]
        case "gemini":
            return ["--resume", resumeToken]
        case "pi":
            return ["--session", resumeToken]
        case "kimi":
            return cwd.isEmpty ? ["--session", resumeToken] : ["--session", resumeToken, "--work-dir", cwd]
        case "forge":
            return cwd.isEmpty ? ["--conversation-id", resumeToken] : ["--conversation-id", resumeToken, "-C", cwd]
        case "amp":
            return ["threads", "continue", resumeToken]
        default:
            return ["--resume", resumeToken]
        }
    }

    func launchInvocation(defaultWorkingDirectory: String = FileManager.default.currentDirectoryPath) -> HijackLaunchInvocation? {
        guard supportsResume else { return nil }

        let configuredExecutable = (launchCommand ?? agentBinary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executable = configuredExecutable.isEmpty ? Self.defaultAgentBinary(for: agentEngine) : configuredExecutable
        let arguments = launchArgs.isEmpty ? resumeArgs() : launchArgs
        guard !executable.isEmpty, !arguments.isEmpty else { return nil }

        let workingDirectory = cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultWorkingDirectory
            : cwd
        return HijackLaunchInvocation(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory
        )
    }

    private static func defaultAgentBinary(for engine: String) -> String {
        switch engine {
        case "claude-code", "claude":
            return "claude"
        case "codex":
            return "codex"
        case "gemini":
            return "gemini"
        case "pi":
            return "pi"
        case "kimi":
            return "kimi"
        case "forge":
            return "forge"
        case "amp":
            return "amp"
        default:
            return engine
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
        case cronIdSnake = "cron_id"
        case cronID
        case scheduleId
        case scheduleIdSnake = "schedule_id"
        case scheduleID
        case pattern
        case cronPattern
        case cronPatternSnake = "cron_pattern"
        case cron
        case cronExpression
        case cronExpressionSnake = "cron_expression"
        case schedule
        case scheduleExpression
        case scheduleExpressionSnake = "schedule_expression"
        case expression
        case expr
        case workflowPath
        case workflowPathSnake = "workflow_path"
        case workflowFile
        case workflowFileSnake = "workflow_file"
        case entryFile
        case entryFileSnake = "entry_file"
        case relativePath
        case relativePathSnake = "relative_path"
        case filePath
        case filePathSnake = "file_path"
        case workflow
        case path
        case enabled
        case isEnabled
        case enabledSnake = "is_enabled"
        case createdAtMs
        case createdAtMsSnake = "created_at_ms"
        case createdAt
        case createdAtSnake = "created_at"
        case lastRunAtMs
        case lastRunAtMsSnake = "last_run_at_ms"
        case lastRunAt
        case lastRunAtSnake = "last_run_at"
        case nextRunAtMs
        case nextRunAtMsSnake = "next_run_at_ms"
        case nextRunAt
        case nextRunAtSnake = "next_run_at"
        case errorJson
        case errorJsonSnake = "error_json"
        case error
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
        func decodeString(_ key: CodingKeys) -> String? {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
            if let value = container.decodeLossyInt64(forKey: key) {
                return String(value)
            }
            if let value = container.decodeLossyBool(forKey: key) {
                return value ? "true" : "false"
            }
            return nil
        }

        let scheduleJSONValue = try? container.decodeIfPresent(JSONValue.self, forKey: .schedule)
        let decodedPatternCandidates = [
            Self.nonEmpty(decodeString(.pattern)),
            Self.nonEmpty(decodeString(.cronPattern)),
            Self.nonEmpty(decodeString(.cronPatternSnake)),
            Self.nonEmpty(decodeString(.cron)),
            Self.nonEmpty(decodeString(.cronExpression)),
            Self.nonEmpty(decodeString(.cronExpressionSnake)),
            Self.nonEmpty(decodeString(.schedule)),
            Self.nonEmpty(decodeString(.scheduleExpression)),
            Self.nonEmpty(decodeString(.scheduleExpressionSnake)),
            Self.nonEmpty(decodeString(.expression)),
            Self.nonEmpty(decodeString(.expr)),
            Self.nonEmpty(cronPatternString(scheduleJSONValue)),
        ]
        let decodedPattern = decodedPatternCandidates.compactMap { $0 }.first
        pattern = decodedPattern ?? ""

        let workflowJSONValue = try? container.decodeIfPresent(JSONValue.self, forKey: .workflow)
        let workflowPathCandidates = [
            Self.nonEmpty(decodeString(.workflowPath)),
            Self.nonEmpty(decodeString(.workflowPathSnake)),
            Self.nonEmpty(decodeString(.workflowFile)),
            Self.nonEmpty(decodeString(.workflowFileSnake)),
            Self.nonEmpty(decodeString(.entryFile)),
            Self.nonEmpty(decodeString(.entryFileSnake)),
            Self.nonEmpty(decodeString(.relativePath)),
            Self.nonEmpty(decodeString(.relativePathSnake)),
            Self.nonEmpty(decodeString(.filePath)),
            Self.nonEmpty(decodeString(.filePathSnake)),
            Self.nonEmpty(decodeString(.workflow)),
            Self.nonEmpty(decodeString(.path)),
            Self.nonEmpty(cronWorkflowPathString(workflowJSONValue)),
        ]
        workflowPath = workflowPathCandidates.compactMap { $0 }.first ?? ""

        enabled = container.decodeLossyBool(forKey: .enabled)
            ?? container.decodeLossyBool(forKey: .isEnabled)
            ?? container.decodeLossyBool(forKey: .enabledSnake)
            ?? true

        createdAtMs = container.decodeLossyInt64(forKey: .createdAtMs)
            ?? container.decodeLossyInt64(forKey: .createdAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .createdAt)
            ?? container.decodeLossyInt64(forKey: .createdAtSnake)
            ?? parseInspectTimestampMs(decodeString(.createdAt))
            ?? parseInspectTimestampMs(decodeString(.createdAtSnake))

        lastRunAtMs = container.decodeLossyInt64(forKey: .lastRunAtMs)
            ?? container.decodeLossyInt64(forKey: .lastRunAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .lastRunAt)
            ?? container.decodeLossyInt64(forKey: .lastRunAtSnake)
            ?? parseInspectTimestampMs(decodeString(.lastRunAt))
            ?? parseInspectTimestampMs(decodeString(.lastRunAtSnake))

        nextRunAtMs = container.decodeLossyInt64(forKey: .nextRunAtMs)
            ?? container.decodeLossyInt64(forKey: .nextRunAtMsSnake)
            ?? container.decodeLossyInt64(forKey: .nextRunAt)
            ?? container.decodeLossyInt64(forKey: .nextRunAtSnake)
            ?? parseInspectTimestampMs(decodeString(.nextRunAt))
            ?? parseInspectTimestampMs(decodeString(.nextRunAtSnake))

        let errorValue = try? container.decodeIfPresent(JSONValue.self, forKey: .error)
        if let encoded = Self.nonEmpty(decodeString(.errorJson))
            ?? Self.nonEmpty(decodeString(.errorJsonSnake))
            ?? Self.nonEmpty(jsonValueString(errorValue)) {
            errorJson = encoded
        } else if let errorValue {
            errorJson = errorValue.compactJSONString
        } else {
            errorJson = nil
        }

        let decodedID = decodeString(.id)
        let decodedCronID = decodeString(.cronId)
            ?? decodeString(.cronIdSnake)
            ?? decodeString(.cronID)
            ?? decodeString(.scheduleId)
            ?? decodeString(.scheduleIdSnake)
            ?? decodeString(.scheduleID)

        let resolvedID = Self.resolvedID(
            id: decodedID,
            cronId: decodedCronID,
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
        guard !normalizedPattern.isEmpty || !normalizedWorkflowPath.isEmpty else { return "" }

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

    private enum CodingKeys: String, CodingKey {
        case crons
        case cronSchedules
        case cronSchedulesSnake = "cron_schedules"
        case schedules
        case items
        case entries
        case results
        case data
    }

    init(crons: [CronSchedule]) {
        self.crons = crons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func decodeCronList(_ key: CodingKeys) -> [CronSchedule]? {
            if let crons = try? container.decodeIfPresent([CronSchedule].self, forKey: key) {
                return crons
            }
            if let mapped = try? container.decodeIfPresent([String: CronSchedule].self, forKey: key) {
                return mapped.keys.sorted().compactMap { mapped[$0] }
            }
            return nil
        }

        for key in [
            CodingKeys.crons,
            .cronSchedules,
            .cronSchedulesSnake,
            .schedules,
            .items,
            .entries,
            .results,
            .data,
        ] {
            if let crons = decodeCronList(key) {
                self.crons = crons
                return
            }
        }
        if let nested = try? container.decode(CronResponse.self, forKey: .data) {
            self.crons = nested.crons
            return
        }
        if let single = try? container.decodeIfPresent(CronSchedule.self, forKey: .data) {
            self.crons = [single]
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .crons,
            in: container,
            debugDescription: "Expected cron schedules under crons/cronSchedules/schedules/items/entries/results/data"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(crons, forKey: .crons)
    }
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

enum SearchScope: String, Codable, CaseIterable, Sendable {
    case code
    case issues
    case repos

    var displayName: String {
        switch self {
        case .code:
            return "Code"
        case .issues:
            return "Issues"
        case .repos:
            return "Repos"
        }
    }

    var resultKind: String {
        switch self {
        case .code:
            return "code"
        case .issues:
            return "issue"
        case .repos:
            return "repo"
        }
    }
}

struct SearchSnippetRange: Codable, Equatable {
    let content: String
    let startLine: Int?
}

struct SearchResult: Identifiable, Codable {
    let id: String
    let title: String
    let description: String?
    let snippet: String?
    let filePath: String?
    let lineNumber: Int?
    let kind: String?           // repo, issue, code

    let snippetRanges: [SearchSnippetRange]?

    init(
        id: String,
        title: String,
        description: String?,
        snippet: String?,
        filePath: String?,
        lineNumber: Int?,
        kind: String?,
        snippetRanges: [SearchSnippetRange]? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.snippet = snippet
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.kind = kind
        self.snippetRanges = snippetRanges
    }

    var displaySnippet: String? {
        if let snippetRanges {
            let rendered = snippetRanges
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .flatMap { Self.displayLines(for: $0) }
                .joined(separator: "\n")
            if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return rendered
            }
        }

        guard let snippet, !snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let lineNumber else {
            return snippet
        }
        let range = SearchSnippetRange(content: snippet, startLine: lineNumber)
        return Self.displayLines(for: range).joined(separator: "\n")
    }

    private static func displayLines(for range: SearchSnippetRange) -> [String] {
        let lines = range.content.components(separatedBy: "\n")
        guard let startLine = range.startLine else {
            return lines
        }
        return lines.enumerated().map { offset, line in
            "L\(startLine + offset): \(line)"
        }
    }
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

    static func filtered(
        event: String?,
        data: String,
        eventRunId: String? = nil,
        expectedRunId: String?,
        requireAttributedRunId: Bool = false
    ) -> SSEEvent? {
        try? Smithers.Models.filteredSSEEvent(
            event: event,
            data: data,
            eventRunId: eventRunId,
            expectedRunId: expectedRunId,
            requireAttributedRunId: requireAttributedRunId
        )
    }

    func matches(runId expectedRunId: String?) -> Bool {
        Self.runId(runId, matches: expectedRunId)
    }

    static func runId(_ actualRunId: String?, matches expectedRunId: String?) -> Bool {
        (try? Smithers.Models.sseRunId(actualRunId, matches: expectedRunId)) ?? true
    }

    static func extractRunId(from data: String) -> String? {
        try? Smithers.Models.sseExtractRunId(from: data)
    }

    static func normalizedRunId(_ runId: String?) -> String? {
        try? Smithers.Models.sseNormalizedRunId(runId)
    }
}

// MARK: - API Envelope (Legacy endpoints)

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}
