// DevToolsSnapshotsStore.swift — observable devtools_snapshots.
//
// Ticket 0124. Per 0107, this is the generic devtools snapshot surface.
// Subscriptions must include repository_id + session_id filters to satisfy
// Electric auth scoping requirements.

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
    private var scopedHandles: [Scope: UInt64] = [:]

    public convenience init(session: RuntimeSession) {
        self.init(session: session as any StoreRuntimeSession)
    }

    internal init(session: any StoreRuntimeSession) {
        self.session = session
    }

    /// Lazily subscribe when a view opens a specific agent session.
    /// The underlying where-clause intentionally includes BOTH repository_id
    /// and session_id because plue's electric auth proxy rejects repo-less
    /// subscriptions.
    public func ensureSubscribed(repositoryId: String, sessionId: String) {
        let scope = Scope(repositoryId: repositoryId, sessionId: sessionId)
        guard scopedHandles[scope] == nil else { return }
        do {
            let h = try session.subscribe(
                shape: StoreTable.devtoolsSnapshots,
                paramsJSON: paramsJSON(for: scope)
            )
            session.pin(h)
            scopedHandles[scope] = h
            reloadFromCache()
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    public func ensureSubscribed(repositoryId: Int64, sessionId: String) {
        ensureSubscribed(repositoryId: String(repositoryId), sessionId: sessionId)
    }

    public func release(repositoryId: String, sessionId: String) {
        let scope = Scope(repositoryId: repositoryId, sessionId: sessionId)
        guard let h = scopedHandles.removeValue(forKey: scope) else { return }
        session.unpin(h)
        session.unsubscribe(h)
    }

    public func release(repositoryId: Int64, sessionId: String) {
        release(repositoryId: String(repositoryId), sessionId: sessionId)
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
                self?.rows = decoded.sorted {
                    let lhs = $0.timestamp ?? .distantPast
                    let rhs = $1.timestamp ?? .distantPast
                    if lhs != rhs { return lhs > rhs }
                    return $0.id > $1.id
                }
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    internal func clear() {
        for (_, h) in scopedHandles { session.unpin(h); session.unsubscribe(h) }
        scopedHandles.removeAll()
        dispatchMain { [weak self] in
            self?.rows = []
            self?.lastError = nil
        }
    }
}

private extension DevToolsSnapshotsStore {
    struct Scope: Hashable {
        let repositoryId: String
        let sessionId: String
    }

    func paramsJSON(for scope: Scope) throws -> String {
        let whereClause = buildWhereClause(repositoryId: scope.repositoryId, sessionId: scope.sessionId)
        let payload: [String: String] = ["where": whereClause]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "DevToolsSnapshotsStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to encode paramsJSON"])
        }
        return json
    }

    func buildWhereClause(repositoryId: String, sessionId: String) -> String {
        let repoTerm: String = {
            let trimmed = repositoryId.trimmingCharacters(in: .whitespacesAndNewlines)
            if Int64(trimmed) != nil {
                return trimmed
            }
            return "'" + escapeSQLLiteral(trimmed) + "'"
        }()
        let sessionTerm = "'" + escapeSQLLiteral(sessionId) + "'"
        return "repository_id IN (\(repoTerm)) AND session_id IN (\(sessionTerm))"
    }

    func escapeSQLLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
