// SmithersStoreTests — structural tests for the 0124 store layer.
//
// These tests DO NOT require a live plue stack. They verify:
//   - Entity decoding from the JSON shapes the runtime cache emits.
//   - Store table/action name constants stay in sync with the production slices.
//
// End-to-end shape subscription + pessimistic-write tests are guarded
// behind `POC_ELECTRIC_STACK=1` because 0120's transport is still fake.

import XCTest
@testable import SmithersStore
@testable import SmithersRuntime

final class StoreEntitiesTests: XCTestCase {
    func testWorkflowRunDecodesFromWireShape() throws {
        let json = Data(#"""
        [
          {
            "run_id": "run_abc",
            "engine_id": "eng_1",
            "workspace_id": "ws_1",
            "workflow_slug": "deploy",
            "status": "running",
            "created_at": 1714000000000,
            "updated_at": 1714000005000,
            "started_at": 1714000001000,
            "finished_at": null,
            "summary": "deploy prod"
          }
        ]
        """#.utf8)
        let rows = try StoreDecoder.shared.decode([WorkflowRunRow].self, from: json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].runId, "run_abc")
        XCTAssertEqual(rows[0].status, "running")
        XCTAssertEqual(rows[0].workflowSlug, "deploy")
        XCTAssertNotNil(rows[0].updatedAt)
    }

    func testApprovalDecodesFromWireShape() throws {
        let json = Data(#"""
        [
          { "approval_id": "ap_1", "run_id": "run_abc", "node_id": "n1", "iteration": 2, "status": "pending", "created_at": 1714000000000 }
        ]
        """#.utf8)
        let rows = try StoreDecoder.shared.decode([ApprovalShapeRow].self, from: json)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].status, "pending")
        XCTAssertEqual(rows[0].iteration, 2)
    }

    func testWorkspaceDecodesFromWireShape() throws {
        let json = Data(#"""
        [ { "workspace_id": "ws_1", "name": "prod", "status": "active", "engine_id": "e", "created_at": 0, "updated_at": 1 } ]
        """#.utf8)
        let rows = try StoreDecoder.shared.decode([WorkspaceRow].self, from: json)
        XCTAssertEqual(rows[0].name, "prod")
    }

    func testAgentPartDecodesFromWireShape() throws {
        let json = Data(#"""
        [ { "part_id": "p_1", "message_id": "m_1", "session_id": "s_1", "ordinal": 0, "kind": "text", "content_text": "hi", "content_json": null } ]
        """#.utf8)
        let rows = try StoreDecoder.shared.decode([AgentPartRow].self, from: json)
        XCTAssertEqual(rows[0].contentText, "hi")
    }

    func testTableNamesMatchShapeSliceContract() {
        XCTAssertEqual(StoreTable.workflowRuns, "workflow_runs")
        XCTAssertEqual(StoreTable.approvals, "approvals")
        XCTAssertEqual(StoreTable.workspaces, "workspaces")
        XCTAssertEqual(StoreTable.workspaceSessions, "workspace_sessions")
        XCTAssertEqual(StoreTable.agentSessions, "agent_sessions")
        XCTAssertEqual(StoreTable.agentMessages, "agent_messages")
        XCTAssertEqual(StoreTable.agentParts, "agent_parts")
        XCTAssertEqual(StoreTable.devtoolsSnapshots, "devtools_snapshots")
    }

    func testWorkspaceDecodesRepoContextWhenPresent() throws {
        let json = Data(#"""
        [ { "workspace_id": "ws_2", "repo_owner": "acme", "repo_name": "widgets", "name": "prod", "status": "active", "engine_id": "e", "created_at": 0, "updated_at": 1 } ]
        """#.utf8)
        let rows = try StoreDecoder.shared.decode([WorkspaceRow].self, from: json)
        XCTAssertEqual(rows[0].repoOwner, "acme")
        XCTAssertEqual(rows[0].repoName, "widgets")
    }
}

final class ActionKindContractTests: XCTestCase {
    private let repo = ActionRepoRef(owner: "acme", name: "widgets")

    func testWorkspaceCreateRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceCreate(repo: repo, name: "scratch", snapshotID: nil),
            kind: .workspaceCreate
        )
    }

    func testWorkspaceSuspendRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceSuspend(repo: repo, workspaceID: "ws_1"),
            kind: .workspaceSuspend
        )
    }

    func testWorkspaceResumeRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceResume(repo: repo, workspaceID: "ws_1"),
            kind: .workspaceResume
        )
    }

    func testWorkspaceDeleteRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceDelete(repo: repo, workspaceID: "ws_1"),
            kind: .workspaceDelete
        )
    }

    func testWorkspaceForkRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceFork(repo: repo, workspaceID: "ws_1", name: "forked"),
            kind: .workspaceFork
        )
    }

    func testWorkspaceSnapshotCreateRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceSnapshotCreate(repo: repo, workspaceID: "ws_1", name: "before-merge"),
            kind: .workspaceSnapshotCreate
        )
    }

    func testWorkspaceSnapshotDeleteRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workspaceSnapshotDelete(repo: repo, snapshotID: "snap_1"),
            kind: .workspaceSnapshotDelete
        )
    }

    func testWorkflowRunCancelRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workflowRunCancel(repo: repo, runID: "run_1"),
            kind: .workflowRunCancel
        )
    }

    func testWorkflowRunRerunRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workflowRunRerun(repo: repo, runID: "run_1"),
            kind: .workflowRunRerun
        )
    }

    func testWorkflowRunResumeRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.workflowRunResume(repo: repo, runID: "run_1"),
            kind: .workflowRunResume
        )
    }

    func testApprovalDecideRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.approvalDecide(
                repo: repo,
                approvalID: "appr_1",
                runID: "run_1",
                nodeID: "gate.wait",
                iteration: 2,
                decision: .approved
            ),
            kind: .approvalDecide
        )
    }

    func testAgentSessionCreateRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.agentSessionCreate(repo: repo, title: "triage"),
            kind: .agentSessionCreate
        )
    }

    func testAgentSessionDeleteRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.agentSessionDelete(repo: repo, sessionID: "sess_1"),
            kind: .agentSessionDelete
        )
    }

    func testAgentSessionAppendMessageRequestIncludesRequiredKeys() throws {
        try assertRequest(
            ActionRequestFactory.agentSessionAppendMessage(
                repo: repo,
                sessionID: "sess_1",
                role: "user",
                parts: [.init(type: "text", content: "hello")]
            ),
            kind: .agentSessionAppendMessage
        )
    }

    private func assertRequest(
        _ request: ActionRequest,
        kind: ActionKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(request.kind, kind, file: file, line: line)
        XCTAssertEqual(request.kind.rawValue, expectedRawValue(for: kind), file: file, line: line)

        let data = try XCTUnwrap(request.payloadJSON.data(using: .utf8), file: file, line: line)
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        let object = try XCTUnwrap(raw as? [String: Any], file: file, line: line)

        for key in kind.requiredPayloadKeys {
            XCTAssertTrue(object.keys.contains(key), "missing key \(key) in \(request.payloadJSON)", file: file, line: line)
        }
    }

    private func expectedRawValue(for kind: ActionKind) -> String {
        switch kind {
        case .workspaceCreate: return "workspace.create"
        case .workspaceSuspend: return "workspace.suspend"
        case .workspaceResume: return "workspace.resume"
        case .workspaceDelete: return "workspace.delete"
        case .workspaceFork: return "workspace.fork"
        case .workspaceSnapshotCreate: return "workspace_snapshot.create"
        case .workspaceSnapshotDelete: return "workspace_snapshot.delete"
        case .workflowRunCancel: return "workflow_run.cancel"
        case .workflowRunRerun: return "workflow_run.rerun"
        case .workflowRunResume: return "workflow_run.resume"
        case .approvalDecide: return "approval.decide"
        case .agentSessionCreate: return "agent_session.create"
        case .agentSessionDelete: return "agent_session.delete"
        case .agentSessionAppendMessage: return "agent_session.append_message"
        }
    }
}

final class EndToEndStoreTests: XCTestCase {
    func testLiveStackRequiresFlag() throws {
        // Without `POC_ELECTRIC_STACK=1` we skip the E2E round-trip; 0120
        // ships a fake transport today. This placeholder documents where
        // the real assertions land once the live stack is reachable.
        guard ProcessInfo.processInfo.environment["POC_ELECTRIC_STACK"] == "1" else {
            throw XCTSkip("POC_ELECTRIC_STACK not set; live store E2E deferred to 0126")
        }
        // TODO(0126): bootstrap a real RuntimeSession, subscribe, dispatch
        // a write, assert the echo populates the published `rows` array.
    }
}

private final class FakeStoreRuntimeSession: StoreRuntimeSession, @unchecked Sendable {
    private let lock = NSLock()
    private var eventHandler: ((RuntimeEvent) -> Void)?
    private var nextSubscription: UInt64 = 1
    private var nextFuture: UInt64 = 1
    private var queuedFutures: [UInt64]
    private var cacheJSON: [String: String]
    private var cacheQueryCounts: [String: Int] = [:]
    private var writeCalls: [(action: String, payloadJSON: String)] = []

    init(queuedFutures: [UInt64] = [], cacheJSON: [String: String] = [:]) {
        self.queuedFutures = queuedFutures
        self.cacheJSON = cacheJSON
    }

    func onEvent(_ handler: @escaping (RuntimeEvent) -> Void) {
        lock.lock()
        eventHandler = handler
        lock.unlock()
    }

    func subscribe(shape: String, paramsJSON: String) throws -> UInt64 {
        _ = shape
        _ = paramsJSON
        lock.lock()
        defer { lock.unlock() }
        let id = nextSubscription
        nextSubscription += 1
        return id
    }

    func unsubscribe(_ handle: UInt64) {
        _ = handle
    }

    func pin(_ handle: UInt64) {
        _ = handle
    }

    func unpin(_ handle: UInt64) {
        _ = handle
    }

    func cacheQuery(table: String, whereSQL: String?, limit: Int32, offset: Int32) throws -> String {
        _ = whereSQL
        _ = limit
        _ = offset
        lock.lock()
        defer { lock.unlock() }
        cacheQueryCounts[table, default: 0] += 1
        return cacheJSON[table] ?? "[]"
    }

    func write(action: String, payloadJSON: String) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        writeCalls.append((action: action, payloadJSON: payloadJSON))
        if !queuedFutures.isEmpty {
            return queuedFutures.removeFirst()
        }
        let future = nextFuture
        nextFuture += 1
        return future
    }

    func wipeCache() throws {}

    func emit(_ event: RuntimeEvent) {
        let handler: ((RuntimeEvent) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return eventHandler
        }()
        handler?(event)
    }

    func cacheQueryCount(for table: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cacheQueryCounts[table, default: 0]
    }

    func writeCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return writeCalls.count
    }
}

private actor DispatchProbe {
    private var result: Result<String?, Error>?

    func record(_ result: Result<String?, Error>) {
        self.result = result
    }

    func snapshot() -> Result<String?, Error>? {
        result
    }
}

private func spawnDispatch(
    store: SmithersStore,
    request: ActionRequest,
    echoTable: String?
) -> DispatchProbe {
    let probe = DispatchProbe()
    Task {
        do {
            let payload = try await store.dispatch(request, echoTable: echoTable)
            await probe.record(.success(payload))
        } catch {
            await probe.record(.failure(error))
        }
    }
    return probe
}

private func workflowRunRequest(kind: ActionKind, runID: String) -> ActionRequest {
    ActionRequest(
        kind: kind,
        payloadJSON: #"{"repo_owner":"acme","repo_name":"repo","run_id":"\#(runID)"}"#
    )
}

private func workspaceSnapshotDeleteRequest(snapshotID: String) -> ActionRequest {
    ActionRequest(
        kind: .workspaceSnapshotDelete,
        payloadJSON: #"{"repo_owner":"acme","repo_name":"repo","snapshot_id":"\#(snapshotID)"}"#
    )
}

private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1.0,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @escaping @Sendable () async -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail(description, file: file, line: line)
}

private func assertSuccessPayload(
    _ probe: DispatchProbe,
    equals expected: String?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    guard let result = await probe.snapshot() else {
        return XCTFail("expected dispatch result", file: file, line: line)
    }
    switch result {
    case .success(let payload):
        XCTAssertEqual(payload, expected, file: file, line: line)
    case .failure(let error):
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

@MainActor
final class SmithersStoreRuntimeEventTests: XCTestCase {
    func testShapeDeltaWithoutFutureReloadsStoreAndLeavesPendingWriteWaiting() async {
        let session = FakeStoreRuntimeSession(queuedFutures: [101])
        let store = SmithersStore(session: session)
        let baselineReloads = session.cacheQueryCount(for: StoreTable.workflowRuns)
        let probe = spawnDispatch(
            store: store,
            request: workflowRunRequest(kind: .workflowRunCancel, runID: "run-1"),
            echoTable: StoreTable.workflowRuns
        )

        await waitUntil("dispatch was not issued") {
            session.writeCallCount() == 1
        }

        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-1","op":"upsert"}"#))

        await waitUntil("workflow_runs store did not reload on table delta") {
            session.cacheQueryCount(for: StoreTable.workflowRuns) == baselineReloads + 1
        }
        let pendingAfterTableOnlyDelta = await probe.snapshot()
        XCTAssertNil(pendingAfterTableOnlyDelta, "table-only delta must not resolve a pending future")

        let ackPayload = #"{"future_id":101,"ok":true,"status":200,"body":"ack-101"}"#
        session.emit(.writeAck(ackPayload))
        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-1","op":"upsert","future_id":101}"#))

        await waitUntil("pending write did not resolve after matching future echo") {
            await probe.snapshot() != nil
        }
        await assertSuccessPayload(probe, equals: ackPayload)
    }

    func testShapeDeltaWithFutureIDResumesOnlyMatchingPendingWrite() async {
        let session = FakeStoreRuntimeSession(queuedFutures: [201, 202])
        let store = SmithersStore(session: session)
        let firstProbe = spawnDispatch(
            store: store,
            request: workflowRunRequest(kind: .workflowRunCancel, runID: "run-a"),
            echoTable: StoreTable.workflowRuns
        )
        let secondProbe = spawnDispatch(
            store: store,
            request: workflowRunRequest(kind: .workflowRunRerun, runID: "run-b"),
            echoTable: StoreTable.workflowRuns
        )

        await waitUntil("dispatches were not issued") {
            session.writeCallCount() == 2
        }

        let firstAck = #"{"future_id":201,"ok":true,"status":200,"body":"ack-201"}"#
        let secondAck = #"{"future_id":202,"ok":true,"status":200,"body":"ack-202"}"#
        session.emit(.writeAck(firstAck))
        session.emit(.writeAck(secondAck))

        let firstBeforeEcho = await firstProbe.snapshot()
        let secondBeforeEcho = await secondProbe.snapshot()
        XCTAssertNil(firstBeforeEcho)
        XCTAssertNil(secondBeforeEcho)

        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-b","op":"upsert","future_id":202}"#))

        await waitUntil("matching future did not resolve") {
            await secondProbe.snapshot() != nil
        }
        let firstAfterSecondEcho = await firstProbe.snapshot()
        XCTAssertNil(firstAfterSecondEcho, "non-matching futures must remain pending")
        await assertSuccessPayload(secondProbe, equals: secondAck)

        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-a","op":"upsert","future_id":201}"#))
        await waitUntil("first future did not resolve after its echo") {
            await firstProbe.snapshot() != nil
        }
        await assertSuccessPayload(firstProbe, equals: firstAck)
    }

    func testWriteAckWithFutureIDAndNoShapeResumesAckOnlyWrite() async {
        let session = FakeStoreRuntimeSession(queuedFutures: [301])
        let store = SmithersStore(session: session)
        let probe = spawnDispatch(
            store: store,
            request: workspaceSnapshotDeleteRequest(snapshotID: "snap-1"),
            echoTable: nil
        )

        await waitUntil("ack-only dispatch was not issued") {
            session.writeCallCount() == 1
        }

        let ackPayload = #"{"future_id":301,"ok":true,"status":200,"body":"ack-301"}"#
        session.emit(.writeAck(ackPayload))

        await waitUntil("ack-only write did not resolve on write-ack") {
            await probe.snapshot() != nil
        }
        await assertSuccessPayload(probe, equals: ackPayload)
    }

    func testConcurrentWritesToSameEntityResolveByFutureIDNotTable() async {
        let session = FakeStoreRuntimeSession(queuedFutures: [401, 402])
        let store = SmithersStore(session: session)
        let firstProbe = spawnDispatch(
            store: store,
            request: workflowRunRequest(kind: .workflowRunCancel, runID: "run-1"),
            echoTable: StoreTable.workflowRuns
        )
        let secondProbe = spawnDispatch(
            store: store,
            request: workflowRunRequest(kind: .workflowRunRerun, runID: "run-1"),
            echoTable: StoreTable.workflowRuns
        )

        await waitUntil("concurrent dispatches were not issued") {
            session.writeCallCount() == 2
        }

        let firstAck = #"{"future_id":401,"ok":true,"status":200,"body":"ack-401"}"#
        let secondAck = #"{"future_id":402,"ok":true,"status":200,"body":"ack-402"}"#
        session.emit(.writeAck(secondAck))
        session.emit(.writeAck(firstAck))

        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-1","op":"upsert","future_id":402}"#))

        await waitUntil("second future did not resolve on its own echo") {
            await secondProbe.snapshot() != nil
        }
        let firstAfterWrongEcho = await firstProbe.snapshot()
        XCTAssertNil(firstAfterWrongEcho, "first future must not resolve on second future's echo")
        await assertSuccessPayload(secondProbe, equals: secondAck)

        session.emit(.shapeDelta(#"{"shape":"workflow_runs","pk":"run-1","op":"upsert","future_id":401}"#))
        await waitUntil("first future did not resolve on its echo") {
            await firstProbe.snapshot() != nil
        }
        await assertSuccessPayload(firstProbe, equals: firstAck)
    }
}
