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

// MARK: - Chat Block (Run Chat)

struct ChatBlock: Identifiable, Codable {
    let id: String?
    let role: String            // system, assistant, user
    let content: String

    var stableId: String { id ?? UUID().uuidString }
}

// MARK: - Cron Schedule

struct CronSchedule: Identifiable, Codable {
    let id: String
    let pattern: String
    let workflowPath: String
    let enabled: Bool
}

// MARK: - SQL Result

struct SQLResult: Codable {
    let columns: [String]?
    let rows: [[String]]?
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
