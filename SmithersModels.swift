import Foundation

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
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    var totalNodes: Int { summary?["total"] ?? 0 }
    var finishedNodes: Int { summary?["finished"] ?? 0 }
    var failedNodes: Int { summary?["failed"] ?? 0 }

    var progress: Double {
        guard totalNodes > 0 else { return 0 }
        return Double(finishedNodes) / Double(totalNodes)
    }
}

struct RunTask: Identifiable, Codable {
    let nodeId: String
    let label: String?
    let iteration: Int?
    let state: String // pending, running, finished, failed, skipped, blocked
    let lastAttempt: Int?
    let updatedAtMs: Int64?

    var id: String { nodeId }
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
        case name, key, type
        case defaultValue = "default"
    }
}

struct WorkflowDAG: Codable {
    let entryTask: String?
    let fields: [WorkflowLaunchField]?
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

    var requestedDate: Date {
        Date(timeIntervalSince1970: Double(requestedAt) / 1000)
    }

    var waitTime: String {
        let seconds = Int(Date().timeIntervalSince(requestedDate))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
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
}

struct AggregateScore: Identifiable, Codable {
    let scorerName: String
    let count: Int
    let mean: Double
    let min: Double
    let max: Double
    let p50: Double?

    var id: String { scorerName }
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

struct Snapshot: Identifiable, Codable {
    let id: String
    let runId: String
    let nodeId: String?
    let label: String?
    let kind: String?           // auto, manual, error, fork
    let parentId: String?
    let createdAtMs: Int64

    var createdAt: Date {
        Date(timeIntervalSince1970: Double(createdAtMs) / 1000)
    }
}

struct SnapshotDiff: Codable {
    let fromId: String
    let toId: String
    let changes: [String]?
}

// MARK: - Ticket Types

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
    let state: String?          // draft, ready, landed
    let targetBranch: String?
    let author: String?
    let createdAt: String?
    let reviewStatus: String?   // approved, changes_requested, pending
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
}

// MARK: - Workspace Types (JJHub)

struct Workspace: Identifiable, Codable {
    let id: String
    let name: String
    let status: String?         // active, suspended, stopped
    let createdAt: String?
}

struct WorkspaceSnapshot: Identifiable, Codable {
    let id: String
    let workspaceId: String
    let name: String?
    let createdAt: String?
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
    let runId: String?
    let nodeId: String?
    let attempt: Int?
    let role: String            // system, assistant, user
    let content: String
    let timestampMs: Int64?
    private let _fallbackId: String

    var stableId: String { id ?? _fallbackId }
    var attemptIndex: Int { max(0, attempt ?? 0) }

    enum CodingKeys: String, CodingKey {
        case id, runId, nodeId, attempt, role, content, timestampMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        nodeId = try container.decodeIfPresent(String.self, forKey: .nodeId)
        attempt = try container.decodeIfPresent(Int.self, forKey: .attempt)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestampMs = try container.decodeIfPresent(Int64.self, forKey: .timestampMs)
        _fallbackId = UUID().uuidString
    }

    init(
        id: String?,
        runId: String? = nil,
        nodeId: String? = nil,
        attempt: Int? = nil,
        role: String,
        content: String,
        timestampMs: Int64? = nil
    ) {
        self.id = id
        self.runId = runId
        self.nodeId = nodeId
        self.attempt = attempt
        self.role = role
        self.content = content
        self.timestampMs = timestampMs
        self._fallbackId = UUID().uuidString
    }
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
}

// MARK: - API Envelope (Legacy endpoints)

struct APIEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
}
