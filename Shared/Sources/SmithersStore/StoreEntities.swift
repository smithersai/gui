// StoreEntities.swift — DTO shapes for the production Electric shapes.
//
// Ticket 0124. These types are the entity surface the SwiftUI view layer
// consumes. They are DECODED from JSON the runtime's cache layer emits via
// `smithers_core_cache_query`. The exact wire field names match the
// shape slices defined in tickets 0110, 0111, 0114–0118, 0107.
//
// Keep these types:
//   - Sendable + Codable + Equatable + Hashable where cheap
//   - entity-oriented (no per-platform view shapes)
//   - decoupled from `SmithersGUI` DTOs (those are the UI-facing projections
//     and live in `SmithersModels.swift`); mapping happens in the view-
//     level adapters that consume these stores.
//
// NOTE: these shapes intentionally use `Date` in the Swift layer even though
// the wire representation is unix-millis; `StoreDecoder` below installs a
// `millisecondsSince1970` strategy.

import Foundation
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public struct WorkflowRunRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { runId }
    public let runId: String
    public let engineId: String?
    public let workspaceId: String?
    public let workflowSlug: String?
    public let status: String
    public let createdAt: Date?
    public let updatedAt: Date?
    public let startedAt: Date?
    public let finishedAt: Date?
    public let summary: String?

    public init(
        runId: String,
        engineId: String? = nil,
        workspaceId: String? = nil,
        workflowSlug: String? = nil,
        status: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        summary: String? = nil
    ) {
        self.runId = runId
        self.engineId = engineId
        self.workspaceId = workspaceId
        self.workflowSlug = workflowSlug
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case engineId = "engine_id"
        case workspaceId = "workspace_id"
        case workflowSlug = "workflow_slug"
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case summary
    }
}

public struct ApprovalShapeRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { approvalId }
    public let approvalId: String
    public let runId: String
    public let nodeId: String
    public let iteration: Int?
    public let status: String
    public let reason: String?
    public let createdAt: Date?
    public let decidedAt: Date?
    public let decidedBy: String?

    private enum CodingKeys: String, CodingKey {
        case approvalId = "approval_id"
        case runId = "run_id"
        case nodeId = "node_id"
        case iteration
        case status
        case reason
        case createdAt = "created_at"
        case decidedAt = "decided_at"
        case decidedBy = "decided_by"
    }
}

public struct WorkspaceRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { workspaceId }
    public let workspaceId: String
    public let name: String
    public let status: String
    public let engineId: String?
    public let createdAt: Date?
    public let updatedAt: Date?
    public let suspendedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case name
        case status
        case engineId = "engine_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case suspendedAt = "suspended_at"
    }
}

public struct WorkspaceSessionRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let workspaceId: String
    public let runId: String?
    public let kind: String
    public let status: String
    public let attachedAt: Date?
    public let closedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case workspaceId = "workspace_id"
        case runId = "run_id"
        case kind
        case status
        case attachedAt = "attached_at"
        case closedAt = "closed_at"
    }
}

public struct AgentSessionRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let workspaceId: String?
    public let runId: String?
    public let agentSlug: String?
    public let title: String?
    public let createdAt: Date?
    public let updatedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case workspaceId = "workspace_id"
        case runId = "run_id"
        case agentSlug = "agent_slug"
        case title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct AgentMessageRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { messageId }
    public let messageId: String
    public let sessionId: String
    public let role: String
    public let sequence: Int
    public let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case role
        case sequence
        case createdAt = "created_at"
    }
}

public struct AgentPartRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { partId }
    public let partId: String
    public let messageId: String
    public let sessionId: String
    public let ordinal: Int
    public let kind: String
    public let contentText: String?
    public let contentJSON: String?

    private enum CodingKeys: String, CodingKey {
        case partId = "part_id"
        case messageId = "message_id"
        case sessionId = "session_id"
        case ordinal
        case kind
        case contentText = "content_text"
        case contentJSON = "content_json"
    }
}

public struct DevToolsSnapshotRow: Sendable, Codable, Equatable, Hashable, Identifiable {
    public var id: String { snapshotId }
    public let snapshotId: String
    public let runId: String
    public let nodeId: String?
    public let createdAt: Date?
    public let summary: String?

    private enum CodingKeys: String, CodingKey {
        case snapshotId = "snapshot_id"
        case runId = "run_id"
        case nodeId = "node_id"
        case createdAt = "created_at"
        case summary
    }
}

/// Shared decoder. Wire timestamps are unix-milliseconds (per spec).
public enum StoreDecoder {
    public static let shared: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            // Accept either millis integers or RFC3339 strings.
            if let ms = try? c.decode(Int64.self) {
                return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
            }
            if let d = try? c.decode(Double.self) {
                return Date(timeIntervalSince1970: d / 1000.0)
            }
            if let s = try? c.decode(String.self) {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: s) { return date }
                let iso2 = ISO8601DateFormatter()
                iso2.formatOptions = [.withInternetDateTime]
                if let date = iso2.date(from: s) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "expected unix-millis or ISO-8601 date"
            )
        }
        return d
    }()
}

/// Table names mirror the plue/Electric slice names. Keep these in ONE place
/// so renames in plue only touch a single constant here.
public enum StoreTable {
    public static let workflowRuns = "workflow_runs"
    public static let approvals = "approvals"
    public static let workspaces = "workspaces"
    public static let workspaceSessions = "workspace_sessions"
    public static let agentSessions = "agent_sessions"
    public static let agentMessages = "agent_messages"
    public static let agentParts = "agent_parts"
    public static let devtoolsSnapshots = "devtools_snapshots"
}

/// Write actions mirror the plue HTTP routes (ticket 0110/0111). Again, in
/// ONE place so rename churn stays surgical.
public enum StoreAction {
    public static let approveNode = "approvals.decide.approve"
    public static let denyNode = "approvals.decide.deny"
    public static let cancelRun = "runs.cancel"
    public static let rerunRun = "runs.rerun"
    public static let createWorkspace = "workspaces.create"
    public static let deleteWorkspace = "workspaces.delete"
    public static let suspendWorkspace = "workspaces.suspend"
    public static let resumeWorkspace = "workspaces.resume"
    public static let forkWorkspace = "workspaces.fork"
    public static let createWorkspaceSnapshot = "workspaces.snapshot.create"
    public static let deleteWorkspaceSnapshot = "workspaces.snapshot.delete"
    public static let sendAgentMessage = "agent.sessions.sendMessage"
}
