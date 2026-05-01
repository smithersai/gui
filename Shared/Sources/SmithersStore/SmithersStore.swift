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
    func dispatch(_ request: ActionRequest, echoTable: String?) async throws -> String?

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

    private let session: any StoreRuntimeSession
    private let eventQueue = DispatchQueue(label: "smithers.store.events", qos: .userInitiated)
    private let dispatchLock = NSLock()
    private var pendingEchoes: [UInt64: PendingEcho] = [:]

    /// Outbound notifications so hosts (AppKit banners, iOS toasts) can react.
    public let authExpired = NotificationCenter()
    public let reconnected = NotificationCenter()

    private struct PendingEcho {
        let table: String?
        let continuation: CheckedContinuation<String?, Error>
        var ackPayload: String?
        var didAck: Bool = false
        var didSeeShapeEcho: Bool = false
    }

    public convenience init(session: RuntimeSession) {
        self.init(session: session as any StoreRuntimeSession)
    }

    internal init(session: any StoreRuntimeSession) {
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
        // Payload shape: `{"shape":"workflow_runs","pk":"...","op":"...","future_id":N?}`.
        guard
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let obj = raw as? [String: Any],
            let shape = obj["shape"] as? String
        else { return }
        let futureID = uint64Value(obj["future_id"])

        switch shape {
        case StoreTable.workflowRuns: runs.reloadFromCache()
        case StoreTable.approvals: approvals.reloadFromCache()
        case StoreTable.workspaces, StoreTable.workspaceSessions: workspaces.reloadFromCache()
        case StoreTable.agentSessions, StoreTable.agentMessages, StoreTable.agentParts: agentSessions.reloadFromCache()
        case StoreTable.devtoolsSnapshots: devtoolsSnapshots.reloadFromCache()
        default: break
        }

        guard let futureID else { return }

        dispatchLock.lock()
        guard var pending = pendingEchoes[futureID] else {
            dispatchLock.unlock()
            return
        }
        guard pending.table == shape else {
            dispatchLock.unlock()
            return
        }

        pending.didSeeShapeEcho = true
        if pending.didAck {
            pendingEchoes.removeValue(forKey: futureID)
            dispatchLock.unlock()
            pending.continuation.resume(returning: pending.ackPayload)
            return
        }

        pendingEchoes[futureID] = pending
        dispatchLock.unlock()
    }

    private func completeWrite(_ payload: String?) {
        // `payload` is expected to be `{"future_id":N,"ok":true,...}`.
        guard
            let payload = payload,
            let data = payload.data(using: .utf8),
            let raw = try? JSONSerialization.jsonObject(with: data, options: []),
            let obj = raw as? [String: Any],
            let fid = uint64Value(obj["future_id"])
        else { return }
        let ok = boolValue(obj["ok"]) ?? false

        dispatchLock.lock()
        guard var pending = pendingEchoes[fid] else {
            dispatchLock.unlock()
            return
        }

        pending.ackPayload = payload
        pending.didAck = true
        if pending.table == nil || !ok || pending.didSeeShapeEcho {
            pendingEchoes.removeValue(forKey: fid)
            dispatchLock.unlock()
            pending.continuation.resume(returning: payload)
            return
        }

        pendingEchoes[fid] = pending
        dispatchLock.unlock()
    }

    // MARK: - Pessimistic write

    public func dispatch(_ request: ActionRequest, echoTable: String?) async throws -> String? {
        let fid = try session.write(action: request.kind.rawValue, payloadJSON: request.payloadJSON)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
            dispatchLock.lock()
            pendingEchoes[fid] = PendingEcho(table: echoTable, continuation: cont)
            dispatchLock.unlock()
        }
    }

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

private func uint64Value(_ raw: Any?) -> UInt64? {
    switch raw {
    case let value as UInt64:
        return value
    case let value as Int:
        return value >= 0 ? UInt64(value) : nil
    case let value as NSNumber:
        let intValue = value.int64Value
        return intValue >= 0 ? UInt64(intValue) : nil
    case let value as String:
        return UInt64(value)
    default:
        return nil
    }
}

private func boolValue(_ raw: Any?) -> Bool? {
    switch raw {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    default:
        return nil
    }
}

public extension Notification.Name {
    static let smithersAuthExpired = Notification.Name("SmithersStore.authExpired")
    static let smithersReconnected = Notification.Name("SmithersStore.reconnected")
}
