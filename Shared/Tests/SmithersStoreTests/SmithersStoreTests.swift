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

    func testWriteActionNamesMatchRouteContract() {
        XCTAssertEqual(StoreAction.approveNode, "approvals.decide.approve")
        XCTAssertEqual(StoreAction.denyNode, "approvals.decide.deny")
        XCTAssertEqual(StoreAction.cancelRun, "runs.cancel")
        XCTAssertEqual(StoreAction.createWorkspace, "workspaces.create")
        XCTAssertEqual(StoreAction.sendAgentMessage, "agent.sessions.sendMessage")
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
