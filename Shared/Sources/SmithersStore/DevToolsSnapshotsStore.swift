// DevToolsSnapshotsStore.swift — observable devtools_snapshots.
//
// Ticket 0124. Per 0107, snapshots are a devtools-only surface. Views like
// `RunInspectView` bind to this for the snapshot picker.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public final class DevToolsSnapshotsStore: ObservableObject {
    @Published public private(set) var rows: [DevToolsSnapshotRow] = []
    @Published public private(set) var lastError: String? = nil

    private let session: any StoreRuntimeSession
    private var perRunHandles: [String: UInt64] = [:]

    public convenience init(session: RuntimeSession) {
        self.init(session: session as any StoreRuntimeSession)
    }

    internal init(session: any StoreRuntimeSession) {
        self.session = session
    }

    /// Lazily subscribe when a view opens a specific run's inspect tab.
    public func ensureSubscribed(runId: String) {
        guard perRunHandles[runId] == nil else { return }
        do {
            let h = try session.subscribe(
                shape: StoreTable.devtoolsSnapshots,
                paramsJSON: #"{"where":"run_id = '\#(runId)'"}"#
            )
            session.pin(h)
            perRunHandles[runId] = h
            reloadFromCache()
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    public func release(runId: String) {
        guard let h = perRunHandles.removeValue(forKey: runId) else { return }
        session.unpin(h)
        session.unsubscribe(h)
    }

    public func reloadFromCache() {
        do {
            let json = try session.cacheQuery(
                table: StoreTable.devtoolsSnapshots,
                whereSQL: nil,
                limit: 500,
                offset: 0
            )
            guard let data = json.data(using: .utf8) else { return }
            let decoded = try StoreDecoder.shared.decode([DevToolsSnapshotRow].self, from: data)
            dispatchMain { [weak self] in
                self?.rows = decoded.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    internal func clear() {
        for (_, h) in perRunHandles { session.unpin(h); session.unsubscribe(h) }
        perRunHandles.removeAll()
        dispatchMain { [weak self] in
            self?.rows = []
            self?.lastError = nil
        }
    }
}
