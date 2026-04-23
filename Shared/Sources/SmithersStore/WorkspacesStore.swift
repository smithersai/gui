// WorkspacesStore.swift — observable workspaces + workspace_sessions.
//
// Ticket 0124. Covers 0116 (workspaces) and 0117 (workspace_sessions)
// shape slices. Both are pinned because the sidebar uses them for the
// workspace switcher.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public final class WorkspacesStore: ObservableObject {
    @Published public private(set) var workspaces: [WorkspaceRow] = []
    @Published public private(set) var sessions: [WorkspaceSessionRow] = []
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var lastError: String? = nil

    internal var subscriptionHandle: UInt64 = 0
    internal var sessionsSubscriptionHandle: UInt64 = 0
    private let session: RuntimeSession

    public init(session: RuntimeSession) {
        self.session = session
        reloadFromCache()
    }

    public func reloadFromCache() {
        do {
            let wsJSON = try session.cacheQuery(
                table: StoreTable.workspaces,
                whereSQL: nil,
                limit: 500,
                offset: 0
            )
            let sJSON = try session.cacheQuery(
                table: StoreTable.workspaceSessions,
                whereSQL: nil,
                limit: 500,
                offset: 0
            )
            let wsRows = (wsJSON.data(using: .utf8))
                .flatMap { try? StoreDecoder.shared.decode([WorkspaceRow].self, from: $0) } ?? []
            let sRows = (sJSON.data(using: .utf8))
                .flatMap { try? StoreDecoder.shared.decode([WorkspaceSessionRow].self, from: $0) } ?? []
            dispatchMain { [weak self] in
                self?.workspaces = wsRows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                self?.sessions = sRows
                self?.lastRefreshedAt = Date()
                self?.lastError = nil
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    public func sessions(forWorkspace id: String) -> [WorkspaceSessionRow] {
        sessions.filter { $0.workspaceId == id }
    }

    internal func clear() {
        dispatchMain { [weak self] in
            self?.workspaces = []
            self?.sessions = []
            self?.lastRefreshedAt = nil
            self?.lastError = nil
        }
    }
}
