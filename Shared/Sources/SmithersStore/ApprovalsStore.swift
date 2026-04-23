// ApprovalsStore.swift — observable approvals projection.
//
// Ticket 0124. The approvals shape is PINNED because the shell always
// needs pending-approval counts for the header badge and the home tab.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public final class ApprovalsStore: ObservableObject {
    @Published public private(set) var pending: [ApprovalShapeRow] = []
    @Published public private(set) var recentDecisions: [ApprovalShapeRow] = []
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var lastError: String? = nil

    internal var subscriptionHandle: UInt64 = 0
    private let session: RuntimeSession

    public init(session: RuntimeSession) {
        self.session = session
        reloadFromCache()
    }

    public func reloadFromCache() {
        do {
            let json = try session.cacheQuery(
                table: StoreTable.approvals,
                whereSQL: nil,
                limit: 500,
                offset: 0
            )
            guard let data = json.data(using: .utf8) else { return }
            let decoded = try StoreDecoder.shared.decode([ApprovalShapeRow].self, from: data)
            let pendingRows = decoded
                .filter { $0.status.lowercased() == "pending" }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            let decided = decoded
                .filter { $0.status.lowercased() != "pending" }
                .sorted { ($0.decidedAt ?? .distantPast) > ($1.decidedAt ?? .distantPast) }
                .prefix(50)
            dispatchMain { [weak self] in
                self?.pending = pendingRows
                self?.recentDecisions = Array(decided)
                self?.lastRefreshedAt = Date()
                self?.lastError = nil
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    internal func clear() {
        dispatchMain { [weak self] in
            self?.pending = []
            self?.recentDecisions = []
            self?.lastRefreshedAt = nil
            self?.lastError = nil
        }
    }
}
