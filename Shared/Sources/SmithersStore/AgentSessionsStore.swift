// AgentSessionsStore.swift — agent_sessions + agent_messages + agent_parts.
//
// Ticket 0124. Combines the three chat shape slices (0114/0115/0118) into a
// single consumer surface. Views typically want "give me all messages +
// parts for this session"; we keep flat published arrays and provide a
// transcript assembler that walks them in order.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

public struct AgentTranscriptMessage: Sendable, Identifiable, Equatable {
    public let message: AgentMessageRow
    public let parts: [AgentPartRow]
    public var id: String { message.messageId }
}

public final class AgentSessionsStore: ObservableObject {
    @Published public private(set) var sessions: [AgentSessionRow] = []
    @Published public private(set) var messages: [AgentMessageRow] = []
    @Published public private(set) var parts: [AgentPartRow] = []
    @Published public private(set) var lastRefreshedAt: Date? = nil
    @Published public private(set) var lastError: String? = nil

    internal var sessionsHandle: UInt64 = 0
    internal var messagesHandle: UInt64 = 0
    internal var partsHandle: UInt64 = 0
    private let session: any StoreRuntimeSession

    public convenience init(session: RuntimeSession) {
        self.init(session: session as any StoreRuntimeSession)
    }

    internal init(session: any StoreRuntimeSession) {
        self.session = session
        // Subscribe unconditionally — the shell surfaces use agent sessions
        // from the home tab onwards, and these tables are small per-user.
        do {
            sessionsHandle = try session.subscribe(shape: StoreTable.agentSessions)
            messagesHandle = try session.subscribe(shape: StoreTable.agentMessages)
            partsHandle = try session.subscribe(shape: StoreTable.agentParts)
        } catch {
            NSLog("[AgentSessionsStore] subscribe failed: \(error)")
        }
        reloadFromCache()
    }

    public func reloadFromCache() {
        do {
            let sJSON = try session.cacheQuery(table: StoreTable.agentSessions, whereSQL: nil, limit: 500, offset: 0)
            let mJSON = try session.cacheQuery(table: StoreTable.agentMessages, whereSQL: nil, limit: 2000, offset: 0)
            let pJSON = try session.cacheQuery(table: StoreTable.agentParts, whereSQL: nil, limit: 4000, offset: 0)
            let sRows = (sJSON.data(using: .utf8))
                .flatMap { try? StoreDecoder.shared.decode([AgentSessionRow].self, from: $0) } ?? []
            let mRows = (mJSON.data(using: .utf8))
                .flatMap { try? StoreDecoder.shared.decode([AgentMessageRow].self, from: $0) } ?? []
            let pRows = (pJSON.data(using: .utf8))
                .flatMap { try? StoreDecoder.shared.decode([AgentPartRow].self, from: $0) } ?? []
            dispatchMain { [weak self] in
                self?.sessions = sRows.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
                self?.messages = mRows
                self?.parts = pRows
                self?.lastRefreshedAt = Date()
                self?.lastError = nil
            }
        } catch {
            dispatchMain { [weak self] in self?.lastError = "\(error)" }
        }
    }

    public func transcript(for sessionId: String) -> [AgentTranscriptMessage] {
        let messagesInSession = messages
            .filter { $0.sessionId == sessionId }
            .sorted { $0.sequence < $1.sequence }
        let partsBySession = Dictionary(grouping: parts.filter { $0.sessionId == sessionId }, by: \.messageId)
        return messagesInSession.map { msg in
            let ps = (partsBySession[msg.messageId] ?? []).sorted { $0.ordinal < $1.ordinal }
            return AgentTranscriptMessage(message: msg, parts: ps)
        }
    }

    internal func clear() {
        dispatchMain { [weak self] in
            self?.sessions = []
            self?.messages = []
            self?.parts = []
            self?.lastRefreshedAt = nil
            self?.lastError = nil
        }
    }
}
