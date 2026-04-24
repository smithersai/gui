import Foundation

public enum ActionKind: String, CaseIterable, Sendable {
    case workspaceCreate = "workspace.create"
    case workspaceSuspend = "workspace.suspend"
    case workspaceResume = "workspace.resume"
    case workspaceDelete = "workspace.delete"
    case workspaceFork = "workspace.fork"
    case workspaceSnapshotCreate = "workspace_snapshot.create"
    case workspaceSnapshotDelete = "workspace_snapshot.delete"
    case workflowRunCancel = "workflow_run.cancel"
    case workflowRunRerun = "workflow_run.rerun"
    case workflowRunResume = "workflow_run.resume"
    case approvalDecide = "approval.decide"
    case agentSessionCreate = "agent_session.create"
    case agentSessionDelete = "agent_session.delete"
    case agentSessionAppendMessage = "agent_session.append_message"

    public var requiredPayloadKeys: Set<String> {
        switch self {
        case .workspaceCreate:
            return ["repo_owner", "repo_name", "name"]
        case .workspaceSuspend, .workspaceResume, .workspaceDelete, .workspaceFork:
            return ["repo_owner", "repo_name", "workspace_id"]
        case .workspaceSnapshotCreate:
            return ["repo_owner", "repo_name", "workspace_id", "name"]
        case .workspaceSnapshotDelete:
            return ["repo_owner", "repo_name", "snapshot_id"]
        case .workflowRunCancel, .workflowRunRerun, .workflowRunResume:
            return ["repo_owner", "repo_name", "run_id"]
        case .approvalDecide:
            return ["repo_owner", "repo_name", "approval_id", "decision"]
        case .agentSessionCreate:
            return ["repo_owner", "repo_name", "title"]
        case .agentSessionDelete:
            return ["repo_owner", "repo_name", "session_id"]
        case .agentSessionAppendMessage:
            return ["repo_owner", "repo_name", "session_id", "role", "parts"]
        }
    }
}

public struct ActionRepoRef: Sendable, Equatable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }
}

public enum ApprovalDecisionToken: String, Sendable {
    case approved
    case rejected
}

public enum ActionContractError: LocalizedError, Equatable, Sendable {
    case missingRepoContext
    case missingApprovalID(runID: String, nodeID: String, iteration: Int?)

    public var errorDescription: String? {
        switch self {
        case .missingRepoContext:
            return "missing repo_owner/repo_name for remote write"
        case .missingApprovalID(let runID, let nodeID, let iteration):
            if let iteration {
                return "missing approval_id for run \(runID) node \(nodeID) iteration \(iteration)"
            }
            return "missing approval_id for run \(runID) node \(nodeID)"
        }
    }
}

public struct AgentSessionPartPayload: Sendable, Codable, Equatable {
    public let type: String
    public let content: String

    public init(type: String, content: String) {
        self.type = type
        self.content = content
    }
}

public struct ActionRequest: Sendable, Equatable {
    public let kind: ActionKind
    public let payloadJSON: String

    public init(kind: ActionKind, payloadJSON: String) {
        self.kind = kind
        self.payloadJSON = payloadJSON
    }
}

public enum ActionRequestFactory {
    public static func workspaceCreate(
        repo: ActionRepoRef,
        name: String,
        snapshotID: String?
    ) -> ActionRequest {
        make(
            kind: .workspaceCreate,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("name", name),
                ("snapshot_id", snapshotID),
            ]
        )
    }

    public static func workspaceSuspend(
        repo: ActionRepoRef,
        workspaceID: String
    ) -> ActionRequest {
        workspaceMutation(kind: .workspaceSuspend, repo: repo, workspaceID: workspaceID)
    }

    public static func workspaceResume(
        repo: ActionRepoRef,
        workspaceID: String
    ) -> ActionRequest {
        workspaceMutation(kind: .workspaceResume, repo: repo, workspaceID: workspaceID)
    }

    public static func workspaceDelete(
        repo: ActionRepoRef,
        workspaceID: String
    ) -> ActionRequest {
        workspaceMutation(kind: .workspaceDelete, repo: repo, workspaceID: workspaceID)
    }

    public static func workspaceFork(
        repo: ActionRepoRef,
        workspaceID: String,
        name: String?
    ) -> ActionRequest {
        make(
            kind: .workspaceFork,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("workspace_id", workspaceID),
                ("name", name),
            ]
        )
    }

    public static func workspaceSnapshotCreate(
        repo: ActionRepoRef,
        workspaceID: String,
        name: String
    ) -> ActionRequest {
        make(
            kind: .workspaceSnapshotCreate,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("workspace_id", workspaceID),
                ("name", name),
            ]
        )
    }

    public static func workspaceSnapshotDelete(
        repo: ActionRepoRef,
        snapshotID: String
    ) -> ActionRequest {
        make(
            kind: .workspaceSnapshotDelete,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("snapshot_id", snapshotID),
            ]
        )
    }

    public static func workflowRunCancel(
        repo: ActionRepoRef,
        runID: String
    ) -> ActionRequest {
        workflowRunMutation(kind: .workflowRunCancel, repo: repo, runID: runID)
    }

    public static func workflowRunRerun(
        repo: ActionRepoRef,
        runID: String
    ) -> ActionRequest {
        workflowRunMutation(kind: .workflowRunRerun, repo: repo, runID: runID)
    }

    public static func workflowRunResume(
        repo: ActionRepoRef,
        runID: String
    ) -> ActionRequest {
        workflowRunMutation(kind: .workflowRunResume, repo: repo, runID: runID)
    }

    public static func approvalDecide(
        repo: ActionRepoRef,
        approvalID: String,
        runID: String,
        nodeID: String,
        iteration: Int?,
        decision: ApprovalDecisionToken,
        note: String? = nil,
        reason: String? = nil
    ) -> ActionRequest {
        make(
            kind: .approvalDecide,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("approval_id", approvalID),
                ("run_id", runID),
                ("node_id", nodeID),
                ("iteration", iteration),
                ("decision", decision.rawValue),
                ("note", note),
                ("reason", reason),
            ]
        )
    }

    public static func agentSessionCreate(
        repo: ActionRepoRef,
        title: String,
        workspaceID: String? = nil,
        runID: String? = nil
    ) -> ActionRequest {
        make(
            kind: .agentSessionCreate,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("title", title),
                ("workspace_id", workspaceID),
                ("run_id", runID),
            ]
        )
    }

    public static func agentSessionDelete(
        repo: ActionRepoRef,
        sessionID: String
    ) -> ActionRequest {
        make(
            kind: .agentSessionDelete,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("session_id", sessionID),
            ]
        )
    }

    public static func agentSessionAppendMessage(
        repo: ActionRepoRef,
        sessionID: String,
        role: String,
        parts: [AgentSessionPartPayload]
    ) -> ActionRequest {
        let encodedParts = parts.map { ["type": $0.type, "content": $0.content] }
        return make(
            kind: .agentSessionAppendMessage,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("session_id", sessionID),
                ("role", role),
                ("parts", encodedParts),
            ]
        )
    }

    private static func workspaceMutation(
        kind: ActionKind,
        repo: ActionRepoRef,
        workspaceID: String
    ) -> ActionRequest {
        make(
            kind: kind,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("workspace_id", workspaceID),
            ]
        )
    }

    private static func workflowRunMutation(
        kind: ActionKind,
        repo: ActionRepoRef,
        runID: String
    ) -> ActionRequest {
        make(
            kind: kind,
            fields: [
                ("repo_owner", repo.owner),
                ("repo_name", repo.name),
                ("run_id", runID),
            ]
        )
    }

    private static func make(
        kind: ActionKind,
        fields: [(String, Any?)]
    ) -> ActionRequest {
        var jsonObject: [String: Any] = [:]
        jsonObject.reserveCapacity(fields.count)
        for (key, value) in fields {
            jsonObject[key] = value ?? NSNull()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]) else {
            return ActionRequest(kind: kind, payloadJSON: "{}")
        }
        return ActionRequest(kind: kind, payloadJSON: String(decoding: data, as: UTF8.self))
    }
}
