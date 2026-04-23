// RunsStore.swift — observable workflow_runs projection.
//
// Ticket 0124. Reads from `smithers_core_cache_query("workflow_runs")`
// on every `.shapeDelta` for that table. Views bind via the `@Published
// rows` array (via Combine) or to `snapshot()` on platforms without
// ObservableObject — the wrapper class stays platform-neutral.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public final class RunsStore: ObservableObject {
    /// Current cached rows, most-recent first.
    @Published public private(set) var rows: [WorkflowRunRow] = []
    /// Non-nil after the first successful cache read. `nil` means "still
    /// connecting / still subscribing / fake transport not yet live".
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var lastError: String? = nil

    internal var subscriptionHandle: UInt64 = 0
    private let session: RuntimeSession

    public init(session: RuntimeSession) {
        self.session = session
        reloadFromCache()
    }

    /// Pin/unpin a specific run so its data stays hot in the cache.
    public func pinRun(_ runId: String) throws -> UInt64 {
        let h = try session.subscribe(
            shape: StoreTable.workflowRuns,
            paramsJSON: #"{"where":"run_id = '\#(runId)'"}"#
        )
        session.pin(h)
        return h
    }

    public func unpin(_ handle: UInt64) {
        session.unpin(handle)
        session.unsubscribe(handle)
    }

    public func row(for runId: String) -> WorkflowRunRow? {
        rows.first(where: { $0.runId == runId })
    }

    /// Called by `SmithersStore` on `shapeDelta` for `workflow_runs`.
    public func reloadFromCache() {
        do {
            let json = try session.cacheQuery(
                table: StoreTable.workflowRuns,
                whereSQL: nil,
                limit: 500,
                offset: 0
            )
            guard let data = json.data(using: .utf8) else { return }
            let decoded = try StoreDecoder.shared.decode([WorkflowRunRow].self, from: data)
            // Hop to main for UI observers.
            dispatchMain { [weak self] in
                self?.rows = decoded.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                self?.lastRefreshedAt = Date()
                self?.lastError = nil
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    internal func clear() {
        dispatchMain { [weak self] in
            self?.rows = []
            self?.lastRefreshedAt = nil
            self?.lastError = nil
        }
    }
}

@inline(__always)
internal func dispatchMain(_ body: @escaping () -> Void) {
    if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
}
