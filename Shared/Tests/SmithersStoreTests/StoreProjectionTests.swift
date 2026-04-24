import Foundation
import XCTest
@testable import SmithersRuntime
@testable import SmithersStore

@MainActor
final class StoreProjectionTests: XCTestCase {
    func testRunsStoreSortsRowsByUpdatedAtAndFindsRun() {
        let session = FakeStoreRuntimeSession(cache: [
            StoreTable.workflowRuns: """
            [
              {"run_id":"old","status":"running","updated_at":1000},
              {"run_id":"new","status":"done","updated_at":3000},
              {"run_id":"mid","status":"queued","updated_at":2000}
            ]
            """,
        ])

        let store = RunsStore(session: session)

        XCTAssertEqual(store.rows.map(\.runId), ["new", "mid", "old"])
        XCTAssertEqual(store.row(for: "mid")?.status, "queued")
        XCTAssertNil(store.lastError)
    }

    func testApprovalsStoreSplitsPendingAndRecentDecisions() {
        let session = FakeStoreRuntimeSession(cache: [
            StoreTable.approvals: """
            [
              {"approval_id":"p1","run_id":"r","node_id":"n","status":"pending","created_at":1000},
              {"approval_id":"p2","run_id":"r","node_id":"n","status":"pending","created_at":3000},
              {"approval_id":"d1","run_id":"r","node_id":"n","status":"approved","created_at":1000,"decided_at":2000},
              {"approval_id":"d2","run_id":"r","node_id":"n","status":"denied","created_at":1000,"decided_at":4000}
            ]
            """,
        ])

        let store = ApprovalsStore(session: session)

        XCTAssertEqual(store.pending.map(\.approvalId), ["p2", "p1"])
        XCTAssertEqual(store.recentDecisions.map(\.approvalId), ["d2", "d1"])
        XCTAssertNil(store.lastError)
    }

    func testWorkspacesStoreLoadsSessionsAndFiltersByWorkspace() {
        let session = FakeStoreRuntimeSession(cache: [
            StoreTable.workspaces: """
            [
              {"workspace_id":"ws-old","name":"old","status":"active","updated_at":1000},
              {"workspace_id":"ws-new","name":"new","status":"active","updated_at":5000}
            ]
            """,
            StoreTable.workspaceSessions: """
            [
              {"session_id":"s1","workspace_id":"ws-new","kind":"terminal","status":"attached"},
              {"session_id":"s2","workspace_id":"ws-old","kind":"agent","status":"closed"},
              {"session_id":"s3","workspace_id":"ws-new","kind":"agent","status":"attached"}
            ]
            """,
        ])

        let store = WorkspacesStore(session: session)

        XCTAssertEqual(store.workspaces.map(\.workspaceId), ["ws-new", "ws-old"])
        XCTAssertEqual(store.sessions(forWorkspace: "ws-new").map(\.sessionId), ["s1", "s3"])
        XCTAssertNil(store.lastError)
    }

    func testAgentSessionsStoreBuildsOrderedTranscript() {
        let session = FakeStoreRuntimeSession(cache: [
            StoreTable.agentSessions: """
            [
              {"session_id":"agent-1","title":"Review","updated_at":1000}
            ]
            """,
            StoreTable.agentMessages: """
            [
              {"message_id":"m2","session_id":"agent-1","role":"assistant","sequence":2},
              {"message_id":"m1","session_id":"agent-1","role":"user","sequence":1},
              {"message_id":"other","session_id":"agent-2","role":"user","sequence":1}
            ]
            """,
            StoreTable.agentParts: """
            [
              {"part_id":"p2","message_id":"m1","session_id":"agent-1","ordinal":2,"kind":"text","content_text":"second"},
              {"part_id":"p1","message_id":"m1","session_id":"agent-1","ordinal":1,"kind":"text","content_text":"first"},
              {"part_id":"p3","message_id":"m2","session_id":"agent-1","ordinal":1,"kind":"text","content_text":"reply"},
              {"part_id":"other","message_id":"other","session_id":"agent-2","ordinal":1,"kind":"text","content_text":"ignored"}
            ]
            """,
        ])

        let store = AgentSessionsStore(session: session)
        let transcript = store.transcript(for: "agent-1")

        XCTAssertEqual(transcript.map(\.message.messageId), ["m1", "m2"])
        XCTAssertEqual(transcript[0].parts.map(\.partId), ["p1", "p2"])
        XCTAssertEqual(transcript[1].parts.map(\.contentText), ["reply"])
    }
}

private final class FakeStoreRuntimeSession: StoreRuntimeSession {
    struct Subscription: Equatable {
        let shape: String
        let paramsJSON: String
    }

    var cache: [String: String]
    private(set) var subscriptions: [Subscription] = []
    private(set) var pinned: [UInt64] = []
    private(set) var unpinned: [UInt64] = []
    private(set) var unsubscribed: [UInt64] = []
    private(set) var didWipeCache = false
    private var nextHandle: UInt64 = 1
    private var eventHandler: ((RuntimeEvent) -> Void)?

    init(cache: [String: String]) {
        self.cache = cache
    }

    func onEvent(_ handler: @escaping (RuntimeEvent) -> Void) {
        eventHandler = handler
    }

    func subscribe(shape: String, paramsJSON: String) throws -> UInt64 {
        subscriptions.append(Subscription(shape: shape, paramsJSON: paramsJSON))
        defer { nextHandle += 1 }
        return nextHandle
    }

    func unsubscribe(_ handle: UInt64) {
        unsubscribed.append(handle)
    }

    func pin(_ handle: UInt64) {
        pinned.append(handle)
    }

    func unpin(_ handle: UInt64) {
        unpinned.append(handle)
    }

    func cacheQuery(table: String, whereSQL: String?, limit: Int32, offset: Int32) throws -> String {
        _ = whereSQL
        _ = limit
        _ = offset
        return cache[table] ?? "[]"
    }

    func write(action: String, payloadJSON: String) throws -> UInt64 {
        _ = action
        _ = payloadJSON
        defer { nextHandle += 1 }
        return nextHandle
    }

    func wipeCache() throws {
        didWipeCache = true
    }

    func emit(_ event: RuntimeEvent) {
        eventHandler?(event)
    }
}
