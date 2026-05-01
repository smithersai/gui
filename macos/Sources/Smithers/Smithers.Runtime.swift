// Smithers.Runtime.swift — ticket 0124 facade.
//
// Hooks the production 0120 runtime + 0124 shared store into the existing
// `SmithersClient`. This is intentionally NOT a rewrite of
// `Smithers.Client.swift`: the view layer still calls `smithers.listRuns()`,
// `smithers.listPendingApprovals()`, etc. We inject a `RemoteProvider` that
// short-circuits those calls to cached reads from `SmithersStore` whenever
// remote mode is active. CLI fallbacks are only used when the user is
// signed out / no engine is configured.
//
// Pessimistic writes: all mutating verbs route through
// `SmithersStore.dispatch(_:echoTable:)`. The view
// `await`s the dispatch; the store only returns after the HTTP write AND
// the matching shape-delta have been observed.

import Foundation
#if canImport(SmithersRuntime)
import SmithersRuntime
#endif
#if canImport(SmithersStore)
import SmithersStore
#endif

/// Hook the SwiftUI app installs at sign-in time. `SmithersClient` holds a
/// weak reference; view calls prefer the remote path when this is present
/// and `session` is alive.
@MainActor
final class SmithersRemoteProvider: ObservableObject {
    let lifecycle: SmithersSessionLifecycle
    var store: SmithersStore { lifecycle.store }
    private static let repoOwnerEnvKeys = ["SMITHERS_REMOTE_REPO_OWNER", "PLUE_E2E_REPO_OWNER"]
    private static let repoNameEnvKeys = ["SMITHERS_REMOTE_REPO_NAME", "PLUE_E2E_REPO_NAME"]

    init (lifecycle: SmithersSessionLifecycle) {
        self.lifecycle = lifecycle
    }

    // MARK: Reads — map Electric shape rows into the view-layer DTOs.

    func listRuns() -> [RunSummary] {
        store.runs.rows.map { RunSummary(from: $0) }
    }

    func runInspection(for runId: String) -> RunInspection? {
        // 0124 does not reshape the inspect surface itself; RunInspectView
        // still needs the full tree. The store only carries the row; the
        // inspect detail is fetched lazily via an HTTP read — the runtime
        // will expose a dedicated FFI for this in 0126. For now this
        // returns nil so callers fall back to the existing path.
        //
        // TODO(0126): replace once `smithers_core_read("runs.inspect", …)`
        // lands (it is pending behind the fake transport boundary).
        _ = runId
        return nil
    }

    func listPendingApprovals() -> [Approval] {
        store.approvals.pending.map { Approval(from: $0) }
    }

    func listRecentDecisions() -> [ApprovalDecision] {
        store.approvals.recentDecisions.map { ApprovalDecision(from: $0) }
    }

    func listWorkspaces() -> [Workspace] {
        store.workspaces.workspaces.map { Workspace(from: $0) }
    }

    func listWorkspaceSnapshots() -> [WorkspaceSnapshot] {
        // TODO(0126): workspace snapshots aren't in the 0116/0117 slices yet;
        // this returns the last-known cache once the shape lands.
        []
    }

    /// Resolve repo owner/name for remote writes without consulting local CLI
    /// state. Prefers workspace rows from the runtime store, then falls back to
    /// explicit environment overrides used by the macOS E2E harness.
    func preferredActionRepoRef(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ActionRepoRef? {
        Self.resolveActionRepoRef(
            workspaceRows: store.workspaces.workspaces,
            environment: environment
        )
    }

    static func resolveActionRepoRef(
        workspaceRows: [WorkspaceRow],
        environment: [String: String]
    ) -> ActionRepoRef? {
        if let repo = workspaceRows.lazy.compactMap(\.actionRepoRef).first {
            return repo
        }
        let owner = firstEnvironmentValue(in: environment, keys: repoOwnerEnvKeys)
        let name = firstEnvironmentValue(in: environment, keys: repoNameEnvKeys)
        guard let owner, let name else { return nil }
        return ActionRepoRef(owner: owner, name: name)
    }

    private static func firstEnvironmentValue(
        in environment: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                return raw
            }
        }
        return nil
    }

    // MARK: Writes — pessimistic.

    func approveNode(
        repo: ActionRepoRef,
        approvalID: String?,
        runId: String,
        nodeId: String,
        iteration: Int?,
        note: String?
    ) async throws {
        let resolvedApprovalID = try approvalID ?? resolveApprovalID(runId: runId, nodeId: nodeId, iteration: iteration)
        _ = try await store.dispatch(
            ActionRequestFactory.approvalDecide(
                repo: repo,
                approvalID: resolvedApprovalID,
                runID: runId,
                nodeID: nodeId,
                iteration: iteration,
                decision: .approved,
                note: note
            ),
            echoTable: StoreTable.approvals
        )
    }

    func denyNode(
        repo: ActionRepoRef,
        approvalID: String?,
        runId: String,
        nodeId: String,
        iteration: Int?,
        reason: String?
    ) async throws {
        let resolvedApprovalID = try approvalID ?? resolveApprovalID(runId: runId, nodeId: nodeId, iteration: iteration)
        _ = try await store.dispatch(
            ActionRequestFactory.approvalDecide(
                repo: repo,
                approvalID: resolvedApprovalID,
                runID: runId,
                nodeID: nodeId,
                iteration: iteration,
                decision: .rejected,
                reason: reason
            ),
            echoTable: StoreTable.approvals
        )
    }

    func cancelRun(_ runId: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workflowRunCancel(repo: repo, runID: runId),
            echoTable: StoreTable.workflowRuns
        )
    }

    func rerunRun(_ runId: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workflowRunRerun(repo: repo, runID: runId),
            echoTable: StoreTable.workflowRuns
        )
    }

    func createWorkspace(repo: ActionRepoRef, name: String, snapshotId: String?) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceCreate(repo: repo, name: name, snapshotID: snapshotId),
            echoTable: StoreTable.workspaces
        )
    }

    func deleteWorkspace(_ id: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceDelete(repo: repo, workspaceID: id),
            echoTable: StoreTable.workspaces
        )
    }

    func suspendWorkspace(_ id: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceSuspend(repo: repo, workspaceID: id),
            echoTable: StoreTable.workspaces
        )
    }

    func resumeWorkspace(_ id: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceResume(repo: repo, workspaceID: id),
            echoTable: StoreTable.workspaces
        )
    }

    func forkWorkspace(_ id: String, repo: ActionRepoRef, name: String?) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceFork(repo: repo, workspaceID: id, name: name),
            echoTable: StoreTable.workspaces
        )
    }

    func createWorkspaceSnapshot(repo: ActionRepoRef, workspaceId: String, name: String) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceSnapshotCreate(repo: repo, workspaceID: workspaceId, name: name),
            echoTable: nil
        )
    }

    func deleteWorkspaceSnapshot(_ id: String, repo: ActionRepoRef) async throws {
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceSnapshotDelete(repo: repo, snapshotID: id),
            echoTable: nil
        )
    }

    // MARK: Sign-out

    func wipe() {
        lifecycle.wipeForSignOut()
    }
    private func resolveApprovalID(runId: String, nodeId: String, iteration: Int?) throws -> String {
        if let match = store.approvals.pending.first(where: {
            $0.runId == runId && $0.nodeId == nodeId && $0.iteration == iteration
        }) {
            return match.approvalId
        }
        throw ActionContractError.missingApprovalID(runID: runId, nodeID: nodeId, iteration: iteration)
    }
}

// MARK: - DTO adapters

extension RunSummary {
    /// Map an Electric row into the UI-facing DTO. Fields missing from the
    /// shape are populated with zero-values; the view layer treats those
    /// cells as "unknown" and renders placeholders.
    init (from row: WorkflowRunRow) {
        self.init(
            runId: row.runId,
            workflowName: row.workflowSlug,
            workflowPath: nil,
            status: RunStatus.normalized(row.status),
            startedAtMs: row.startedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            finishedAtMs: row.finishedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            summary: nil,
            errorJson: nil
        )
    }
}

extension Approval {
    init (from row: ApprovalShapeRow) {
        self.init(
            id: row.approvalId,
            runId: row.runId,
            nodeId: row.nodeId,
            iteration: row.iteration,
            workflowPath: nil,
            gate: nil,
            status: row.status,
            payload: nil,
            requestedAt: row.createdAt.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0,
            resolvedAt: row.decidedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            resolvedBy: row.decidedBy,
            source: "electric"
        )
    }
}

extension ApprovalDecision {
    init (from row: ApprovalShapeRow) {
        self.init(
            id: row.approvalId,
            runId: row.runId,
            nodeId: row.nodeId,
            iteration: row.iteration,
            action: row.status,
            note: nil,
            reason: row.reason,
            resolvedAt: row.decidedAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            resolvedBy: row.decidedBy,
            workflowPath: nil,
            gate: nil,
            payload: nil,
            requestedAt: row.createdAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            source: "electric"
        )
    }
}

private let iso8601Formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

extension Workspace {
    init (from row: WorkspaceRow) {
        self.init(
            id: row.workspaceId,
            name: row.name,
            status: row.status,
            createdAt: row.createdAt.map { iso8601Formatter.string(from: $0) }
        )
    }
}

private extension WorkspaceRow {
    var actionRepoRef: ActionRepoRef? {
        guard
            let owner = repoOwner?.trimmingCharacters(in: .whitespacesAndNewlines),
            !owner.isEmpty,
            let name = repoName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            return nil
        }
        return ActionRepoRef(owner: owner, name: name)
    }
}
