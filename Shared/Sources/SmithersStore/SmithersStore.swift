// SmithersStore.swift — the root object for ticket 0124.
//
// Responsibilities:
//   1. Owns ONE `RuntimeSession` (0120) per signed-in user.
//   2. Vends entity-oriented observable sub-stores (runs, approvals,
//      workspaces, agent sessions/messages/parts, devtools snapshots).
//   3. Fans `RuntimeEvent`s out to whichever sub-store cares about the
//      shape-delta payload.
//   4. Implements the pessimistic-write dispatcher: writes go through
//      `smithers_core_write`, and the caller awaits a `writeAck` + the
//      resulting shape-delta before considering the UI state committed.
//   5. Plumbs sign-out cache-wipe through `SessionWipeHandler` from 0109.
//
// Platform neutrality: this file compiles on macOS + iOS; it has no
// AppKit / UIKit / CLI / local-FS dependencies beyond `Foundation`
// and the already-cross-platform `SmithersRuntime`.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

/// Surface the UI layer talks to. Concrete implementations:
///   - `SmithersStore` (production, wraps `RuntimeSession`)
///   - `InMemorySmithersStore` (tests)
public protocol SmithersStoreProtocol: AnyObject {
    var runs: RunsStore { get }
    var approvals: ApprovalsStore { get }
    var workspaces: WorkspacesStore { get }
    var agentSessions: AgentSessionsStore { get }
    var devtoolsSnapshots: DevToolsSnapshotsStore { get }

    /// Dispatch a mutation. Returns after the HTTP write completes AND the
    /// store has observed the shape echo (pessimistic-write rule).
    ///
    /// The returned payload is the `writeAck` body (if any); stores
    /// re-read from cache on the echo event — callers generally do not
    /// need to inspect the ack payload.
    func dispatch(action: String, payloadJSON: String, echoTable: String?) async throws -> String?

    /// Wipe the local cache and drop all subscriptions. Called from
    /// `SessionWipeHandler` on sign-out.
    func wipeForSignOut()
}

/// Production store. Owns the `RuntimeSession` lifecycle.
public final class SmithersStore: SmithersStoreProtocol, @unchecked Sendable {
    public let runs: RunsStore
    public let approvals: ApprovalsStore
    public let workspaces: WorkspacesStore
    public let agentSessions: AgentSessionsStore
    public let devtoolsSnapshots: DevToolsSnapshotsStore

    private let session: RuntimeSession
    private let eventQueue = DispatchQueue(label: "smithers.store.events", qos: .userInitiated)
    private let dispatchLock = NSLock()
    private var pendingEchoes: [UInt64: PendingEcho] = [:]

    /// Outbound notifications so hosts (AppKit banners, iOS toasts) can react.
    public let authExpired = NotificationCenter()
    public let reconnected = NotificationCenter()

    private struct PendingEcho {
        let table: String?
        let continuation: CheckedContinuation<String?, Error>
    }

    public init(session: RuntimeSession) {
        self.session = session
        self.runs = RunsStore(session: session)
        self.approvals = ApprovalsStore(session: session)
        self.workspaces = WorkspacesStore(session: session)
        self.agentSessions = AgentSessionsStore(session: session)
        self.devtoolsSnapshots = DevToolsSnapshotsStore(session: session)

        session.onEvent { [weak self] event in
            guard let self else { return }
            self.eventQueue.async { self.handle(event) }
        }

        // Initial subscriptions. Pin the ones the shell always needs.
        subscribeBaselineShapes()
    }

    // MARK: - Baseline subscriptions

    private func subscribeBaselineShapes() {
        do {
            let approvalsHandle = try session.subscribe(shape: StoreTable.approvals)
            session.pin(approvalsHandle)
            approvals.subscriptionHandle = approvalsHandle

            let runsHandle = try session.subscribe(shape: StoreTable.workflowRuns)
            runs.subscriptionHandle = runsHandle

            let wsHandle = try session.subscribe(shape: StoreTable.workspaces)
            session.pin(wsHandle)
            workspaces.subscriptionHandle = wsHandle

            let wsSessionsHandle = try session.subscribe(shape: StoreTable.workspaceSessions)
            workspaces.sessionsSubscriptionHandle = wsSessionsHandle
        } catch {
            // Fake-transport fallback: surface the error but keep the
            // store usable so the app does not crash on boot when 0120
            // returns errors from its placeholder connect path. TODO(0126):
            // promote this to an alertable failure once the real transport
            // lands.
            NSLog("[SmithersStore] baseline subscribe failed: \(error)")
        }
    }

    // MARK: - Event dispatch

    private func handle(_ event: RuntimeEvent) {
        switch event {
        case .stateChanged(let payload):
            NSLog("[SmithersStore] state: \(payload ?? "?")")
        case .authExpired:
            authExpired.post(name: .smithersAuthExpired, object: self)
        case .reconnect:
            reconnected.post(name: .smithersReconnected, object: self)
            // After reconnect each store refreshes from cache — the cache
            // is still authoritative for "last-known" rendering.
            runs.reloadFromCache()
            approvals.reloadFromCache()
            workspaces.reloadFromCache()
            agentSessions.reloadFromCache()
            devtoolsSnapshots.reloadFromCache()
        case .shapeDelta(let payload):
            routeShapeDelta(payload)
        case .writeAck(let payload):
            completeWrite(payload)
        case .ptyData, .ptyClosed:
            // Terminal work in 0123 owns the PTY path. We pass through.
            break
        }
    }

    private func routeShapeDelta(_ payload: String?) {
        guard let payload = payload, let data = payload.data(using: .utf8) else { return }
        // Payload shape: `{"table":"workflow_runs","changes":N,...}`. We only
        // need the table name to decide which sub-store reloads.
        guard
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let obj = raw as? [String: Any],
            let table = obj["table"] as? String
        else { return }

        switch table {
        case StoreTable.workflowRuns: runs.reloadFromCache()
        case StoreTable.approvals: approvals.reloadFromCache()
        case StoreTable.workspaces, StoreTable.workspaceSessions: workspaces.reloadFromCache()
        case StoreTable.agentSessions, StoreTable.agentMessages, StoreTable.agentParts: agentSessions.reloadFromCache()
        case StoreTable.devtoolsSnapshots: devtoolsSnapshots.reloadFromCache()
        default: break
        }

        // Any writer awaiting this table's echo can resume.
        dispatchLock.lock()
        let resumed = pendingEchoes.filter { $0.value.table == table || $0.value.table == nil }
        for (fid, _) in resumed { pendingEchoes.removeValue(forKey: fid) }
        dispatchLock.unlock()
        for (_, pending) in resumed {
            pending.continuation.resume(returning: nil)
        }
    }

    private func completeWrite(_ payload: String?) {
        // `payload` is expected to be `{"future_id":N,"ok":true,...}`. We
        // resume the awaiting continuation ONLY after we've also seen the
        // shape-delta for the write's target table (pessimistic rule). If
        // the ack arrives first, store the payload on the pending record
        // so the delta-side can forward it.
        guard
            let payload = payload,
            let data = payload.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let obj = raw as? [String: Any],
            let fid = (obj["future_id"] as? UInt64) ?? (obj["future_id"] as? Int).map(UInt64.init)
        else { return }

        dispatchLock.lock()
        let pending = pendingEchoes[fid]
        // If echoTable is nil the caller opted out of the pessimistic wait
        // and we resume immediately on ack.
        if let pending = pending, pending.table == nil {
            pendingEchoes.removeValue(forKey: fid)
            dispatchLock.unlock()
            pending.continuation.resume(returning: payload)
            return
        }
        dispatchLock.unlock()
    }

    // MARK: - Pessimistic write

    public func dispatch(action: String, payloadJSON: String, echoTable: String?) async throws -> String? {
        let fid = try session.write(action: action, payloadJSON: payloadJSON)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            dispatchLock.lock()
            pendingEchoes[fid] = PendingEcho(table: echoTable, continuation: cont)
            dispatchLock.unlock()
        }
    }

    // MARK: - Sign-out

    public func wipeForSignOut() {
        do { try session.wipeCache() } catch {
            NSLog("[SmithersStore] cache wipe failed: \(error)")
        }
        runs.clear()
        approvals.clear()
        workspaces.clear()
        agentSessions.clear()
        devtoolsSnapshots.clear()
    }
}

public extension Notification.Name {
    static let smithersAuthExpired = Notification.Name("SmithersStore.authExpired")
    static let smithersReconnected = Notification.Name("SmithersStore.reconnected")
}
