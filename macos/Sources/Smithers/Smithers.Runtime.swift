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
// `SmithersStore.dispatch(action:, payloadJSON:, echoTable:)`. The view
// `await`s the dispatch; the store only returns after the HTTP write AND
// the matching shape-delta have been observed.

import Foundation
#if SWIFT_PACKAGE
import SmithersRuntime
import SmithersStore
#endif

/// Hook the SwiftUI app installs at sign-in time. `SmithersClient` holds a
/// weak reference; view calls prefer the remote path when this is present
/// and `session` is alive.
@MainActor
final class SmithersRemoteProvider: ObservableObject {
    let lifecycle: SmithersSessionLifecycle
    var store: SmithersStore { lifecycle.store }

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

    // MARK: Writes — pessimistic.

    func approveNode(runId: String, nodeId: String, iteration: Int?, note: String?) async throws {
        let payload = jsonEncode([
            "run_id": runId,
            "node_id": nodeId,
            "iteration": iteration as Any,
            "note": note as Any,
        ])
        _ = try await store.dispatch(action: StoreAction.approveNode, payloadJSON: payload, echoTable: StoreTable.approvals)
    }

    func denyNode(runId: String, nodeId: String, iteration: Int?, reason: String?) async throws {
        let payload = jsonEncode([
            "run_id": runId,
            "node_id": nodeId,
            "iteration": iteration as Any,
            "reason": reason as Any,
        ])
        _ = try await store.dispatch(action: StoreAction.denyNode, payloadJSON: payload, echoTable: StoreTable.approvals)
    }

    func cancelRun(_ runId: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.cancelRun,
            payloadJSON: jsonEncode(["run_id": runId]),
            echoTable: StoreTable.workflowRuns
        )
    }

    func rerunRun(_ runId: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.rerunRun,
            payloadJSON: jsonEncode(["run_id": runId]),
            echoTable: StoreTable.workflowRuns
        )
    }

    func createWorkspace(name: String, snapshotId: String?) async throws {
        let payload = jsonEncode(["name": name, "snapshot_id": snapshotId as Any])
        _ = try await store.dispatch(action: StoreAction.createWorkspace, payloadJSON: payload, echoTable: StoreTable.workspaces)
    }

    func deleteWorkspace(_ id: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.deleteWorkspace,
            payloadJSON: jsonEncode(["workspace_id": id]),
            echoTable: StoreTable.workspaces
        )
    }

    func suspendWorkspace(_ id: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.suspendWorkspace,
            payloadJSON: jsonEncode(["workspace_id": id]),
            echoTable: StoreTable.workspaces
        )
    }

    func resumeWorkspace(_ id: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.resumeWorkspace,
            payloadJSON: jsonEncode(["workspace_id": id]),
            echoTable: StoreTable.workspaces
        )
    }

    func forkWorkspace(_ id: String, name: String?) async throws {
        _ = try await store.dispatch(
            action: StoreAction.forkWorkspace,
            payloadJSON: jsonEncode(["workspace_id": id, "name": name as Any]),
            echoTable: StoreTable.workspaces
        )
    }

    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.createWorkspaceSnapshot,
            payloadJSON: jsonEncode(["workspace_id": workspaceId, "name": name]),
            echoTable: nil
        )
    }

    func deleteWorkspaceSnapshot(_ id: String) async throws {
        _ = try await store.dispatch(
            action: StoreAction.deleteWorkspaceSnapshot,
            payloadJSON: jsonEncode(["snapshot_id": id]),
            echoTable: nil
        )
    }

    // MARK: Sign-out

    func wipe() {
        lifecycle.wipeForSignOut()
    }
}

// MARK: - JSON helpers

private func jsonEncode(_ dict: [String: Any]) -> String {
    // Convert `nil`-bearing Any values — JSONSerialization refuses to
    // encode Swift `Optional<Any>.none`; normalise to NSNull.
    var  normalised: [String: Any] = [:]
    for (k, v) in dict {
        if case Optional<Any>.none = v { normalised[k] = NSNull(); continue }
        normalised[k] = v
    }
    guard let data = try? JSONSerialization.data(withJSONObject: normalised, options: []) else {
        return "{}"
    }
    return String(decoding: data, as: UTF8.self)
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
