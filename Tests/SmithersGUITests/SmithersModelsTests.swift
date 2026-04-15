import XCTest
@testable import SmithersGUI

final class SmithersModelsTests: XCTestCase {

    // MARK: - RunStatus

    func testRunStatusHas5Variants() {
        XCTAssertEqual(RunStatus.allCases.count, 5)
        let expected: Set<RunStatus> = [.running, .waitingApproval, .finished, .failed, .cancelled]
        XCTAssertEqual(Set(RunStatus.allCases), expected)
    }

    func testRunStatusRawValues() {
        XCTAssertEqual(RunStatus.running.rawValue, "running")
        XCTAssertEqual(RunStatus.waitingApproval.rawValue, "waiting-approval")
        XCTAssertEqual(RunStatus.finished.rawValue, "finished")
        XCTAssertEqual(RunStatus.failed.rawValue, "failed")
        XCTAssertEqual(RunStatus.cancelled.rawValue, "cancelled")
    }

    func testRunStatusLabels() {
        XCTAssertEqual(RunStatus.running.label, "RUNNING")
        XCTAssertEqual(RunStatus.waitingApproval.label, "APPROVAL")
        XCTAssertEqual(RunStatus.finished.label, "FINISHED")
        XCTAssertEqual(RunStatus.failed.label, "FAILED")
        XCTAssertEqual(RunStatus.cancelled.label, "CANCELLED")
    }

    func testRunStatusCodable() throws {
        let json = Data(#""waiting-approval""#.utf8)
        let decoded = try JSONDecoder().decode(RunStatus.self, from: json)
        XCTAssertEqual(decoded, .waitingApproval)

        let encoded = try JSONEncoder().encode(RunStatus.cancelled)
        let str = String(data: encoded, encoding: .utf8)
        XCTAssertEqual(str, #""cancelled""#)
    }

    // MARK: - RunSummary

    func testRunSummaryStartedAtMsConversion() {
        let json = """
        {"runId":"r1","status":"running","startedAtMs":1700000000000}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.id, "r1")
        XCTAssertNotNil(run.startedAt)
        XCTAssertEqual(run.startedAt!.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testRunSummaryStartedAtNilWhenMissing() {
        let json = """
        {"runId":"r2","status":"finished"}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertNil(run.startedAt)
        XCTAssertNil(run.finishedAt)
    }

    func testRunSummaryProgress() {
        let json = """
        {"runId":"r3","status":"running","summary":{"total":10,"finished":3,"failed":1}}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.totalNodes, 10)
        XCTAssertEqual(run.finishedNodes, 3)
        XCTAssertEqual(run.failedNodes, 1)
        XCTAssertEqual(run.progress, 0.3, accuracy: 0.001)
    }

    func testRunSummaryProgressZeroWhenNoSummary() {
        let json = """
        {"runId":"r4","status":"running"}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.totalNodes, 0)
        XCTAssertEqual(run.progress, 0)
    }

    func testRunSummaryProgressZeroWhenTotalZero() {
        let json = """
        {"runId":"r5","status":"running","summary":{"total":0,"finished":0,"failed":0}}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.progress, 0)
    }

    func testRunSummaryElapsedStringSeconds() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-45).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r6","status":"finished","startedAtMs":\(startMs),"finishedAtMs":\(endMs)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.hasSuffix("s"))
    }

    func testRunSummaryElapsedStringMinutes() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-125).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r7","status":"finished","startedAtMs":\(startMs),"finishedAtMs":\(endMs)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.contains("m"))
    }

    func testRunSummaryElapsedStringHours() {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-7200).timeIntervalSince1970 * 1000)
        let endMs = Int64(now.timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r8","status":"finished","startedAtMs":\(startMs),"finishedAtMs":\(endMs)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.contains("h"))
    }

    func testRunSummaryElapsedStringEmptyWhenNoStart() {
        let json = """
        {"runId":"r9","status":"running"}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testRunSummaryCodableRoundTrip() throws {
        let json = """
        {"runId":"rt1","workflowName":"test","workflowPath":"/a/b","status":"failed","startedAtMs":1700000000000,"finishedAtMs":1700000060000,"summary":{"total":5,"finished":4,"failed":1},"errorJson":"{\\"msg\\":\\"oops\\"}"}
        """.data(using: .utf8)!
        let run = try JSONDecoder().decode(RunSummary.self, from: json)
        let reEncoded = try JSONEncoder().encode(run)
        let run2 = try JSONDecoder().decode(RunSummary.self, from: reEncoded)
        XCTAssertEqual(run.runId, run2.runId)
        XCTAssertEqual(run.status, run2.status)
        XCTAssertEqual(run.workflowName, run2.workflowName)
        XCTAssertEqual(run.errorJson, run2.errorJson)
    }

    // MARK: - RunTask

    func testRunTaskDecoding() throws {
        let json = """
        {"nodeId":"n1","label":"Step 1","iteration":2,"state":"running","lastAttempt":1,"updatedAtMs":1700000000000}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(RunTask.self, from: json)
        XCTAssertEqual(task.id, "n1-2")
        XCTAssertEqual(task.label, "Step 1")
        XCTAssertEqual(task.iteration, 2)
        XCTAssertEqual(task.state, "running")
    }

    // MARK: - RunInspection

    func testRunInspectionDecoding() throws {
        let json = """
        {"run":{"runId":"r1","status":"running"},"tasks":[{"nodeId":"n1","state":"pending"}]}
        """.data(using: .utf8)!
        let inspection = try JSONDecoder().decode(RunInspection.self, from: json)
        XCTAssertEqual(inspection.run.runId, "r1")
        XCTAssertEqual(inspection.tasks.count, 1)
    }

    // MARK: - SmithersAgent

    func testSmithersAgentDecodingDetected() throws {
        let json = """
        {"id":"codex","name":"Codex","command":"codex","binaryPath":"/usr/local/bin/codex","status":"api-key","hasAuth":false,"hasAPIKey":true,"usable":true,"roles":["coding","implement"],"version":null,"authExpired":null}
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(SmithersAgent.self, from: json)
        XCTAssertEqual(agent.id, "codex")
        XCTAssertEqual(agent.binaryPath, "/usr/local/bin/codex")
        XCTAssertEqual(agent.status, "api-key")
        XCTAssertTrue(agent.usable)
        XCTAssertEqual(agent.roles, ["coding", "implement"])
        XCTAssertTrue(agent.hasAPIKey)
        XCTAssertFalse(agent.hasAuth)
    }

    func testSmithersAgentDecodingUnavailable() throws {
        let json = """
        {"id":"forge","name":"Forge","command":"forge","binaryPath":"","status":"unavailable","hasAuth":false,"hasAPIKey":false,"usable":false,"roles":["coding"],"version":null,"authExpired":null}
        """.data(using: .utf8)!
        let agent = try JSONDecoder().decode(SmithersAgent.self, from: json)
        XCTAssertEqual(agent.status, "unavailable")
        XCTAssertFalse(agent.usable)
        XCTAssertEqual(agent.binaryPath, "")
    }

    // MARK: - WorkflowStatus

    func testWorkflowStatusHas4Variants() {
        let cases: [WorkflowStatus] = [.draft, .active, .hot, .archived]
        XCTAssertEqual(cases.count, 4)
    }

    func testWorkflowStatusRawValues() {
        XCTAssertEqual(WorkflowStatus.draft.rawValue, "draft")
        XCTAssertEqual(WorkflowStatus.active.rawValue, "active")
        XCTAssertEqual(WorkflowStatus.hot.rawValue, "hot")
        XCTAssertEqual(WorkflowStatus.archived.rawValue, "archived")
    }

    func testWorkflowStatusCodable() throws {
        let json = Data(#""hot""#.utf8)
        let decoded = try JSONDecoder().decode(WorkflowStatus.self, from: json)
        XCTAssertEqual(decoded, .hot)
    }

    // MARK: - Workflow

    func testWorkflowDecoding() throws {
        let json = """
        {"id":"w1","name":"Deploy","workspaceId":"ws1","relativePath":"deploy.yaml","status":"active","updatedAt":"2024-01-01"}
        """.data(using: .utf8)!
        let wf = try JSONDecoder().decode(Workflow.self, from: json)
        XCTAssertEqual(wf.id, "w1")
        XCTAssertEqual(wf.name, "Deploy")
        XCTAssertEqual(wf.status, .active)
    }

    func testWorkflowDecodingMinimal() throws {
        let json = """
        {"id":"w2","name":"Test"}
        """.data(using: .utf8)!
        let wf = try JSONDecoder().decode(Workflow.self, from: json)
        XCTAssertNil(wf.workspaceId)
        XCTAssertNil(wf.status)
    }

    // MARK: - WorkflowLaunchField

    func testWorkflowLaunchFieldDefaultValueCodingKey() throws {
        let json = """
        {"name":"Env","key":"env","type":"string","default":"prod"}
        """.data(using: .utf8)!
        let field = try JSONDecoder().decode(WorkflowLaunchField.self, from: json)
        XCTAssertEqual(field.defaultValue, "prod")
        XCTAssertEqual(field.name, "Env")
    }

    // MARK: - Approval

    func testApprovalRequestedDateConversion() throws {
        let json = """
        {"id":"a1","runId":"r1","nodeId":"n1","status":"pending","requestedAt":1700000000000}
        """.data(using: .utf8)!
        let approval = try JSONDecoder().decode(Approval.self, from: json)
        XCTAssertEqual(approval.requestedDate.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testApprovalWaitTimeSeconds() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000) - 30000 // 30s ago
        let json = """
        {"id":"a2","runId":"r1","nodeId":"n1","status":"pending","requestedAt":\(nowMs)}
        """.data(using: .utf8)!
        let approval = try JSONDecoder().decode(Approval.self, from: json)
        XCTAssertTrue(approval.waitTime.hasSuffix("s"))
    }

    func testApprovalWaitTimeMinutes() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000) - 120000 // 2min ago
        let json = """
        {"id":"a3","runId":"r1","nodeId":"n1","status":"pending","requestedAt":\(nowMs)}
        """.data(using: .utf8)!
        let approval = try JSONDecoder().decode(Approval.self, from: json)
        XCTAssertTrue(approval.waitTime.contains("m"))
    }

    func testApprovalWaitTimeHours() throws {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000) - 7200000 // 2hr ago
        let json = """
        {"id":"a4","runId":"r1","nodeId":"n1","status":"pending","requestedAt":\(nowMs)}
        """.data(using: .utf8)!
        let approval = try JSONDecoder().decode(Approval.self, from: json)
        XCTAssertTrue(approval.waitTime.contains("h"))
    }

    func testApprovalCodableRoundTrip() throws {
        let json = """
        {"id":"a5","runId":"r1","nodeId":"n1","gate":"deploy-gate","status":"approved","payload":"{}","requestedAt":1700000000000,"resolvedAt":1700000060000,"resolvedBy":"admin"}
        """.data(using: .utf8)!
        let approval = try JSONDecoder().decode(Approval.self, from: json)
        let reEncoded = try JSONEncoder().encode(approval)
        let approval2 = try JSONDecoder().decode(Approval.self, from: reEncoded)
        XCTAssertEqual(approval.id, approval2.id)
        XCTAssertEqual(approval.gate, approval2.gate)
        XCTAssertEqual(approval.resolvedBy, approval2.resolvedBy)
    }

    // MARK: - ApprovalDecision

    func testApprovalDecisionDecoding() throws {
        let json = """
        {"id":"d1","runId":"r1","nodeId":"n1","action":"denied","note":"not ready","reason":"missing tests","resolvedAt":1700000000000,"resolvedBy":"reviewer"}
        """.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(decision.action, "denied")
        XCTAssertEqual(decision.note, "not ready")
        XCTAssertEqual(decision.reason, "missing tests")
    }

    // MARK: - SmithersPrompt & PromptInput

    func testPromptInputDefaultValueCodingKey() throws {
        let json = """
        {"name":"model","type":"string","default":"gpt-4"}
        """.data(using: .utf8)!
        let input = try JSONDecoder().decode(PromptInput.self, from: json)
        XCTAssertEqual(input.defaultValue, "gpt-4")
        XCTAssertEqual(input.id, "model")
    }

    func testSmithersPromptDecoding() throws {
        let json = """
        {"id":"p1","entryFile":"main.py","source":"repo","inputs":[{"name":"temp","type":"number","default":"0.7"}]}
        """.data(using: .utf8)!
        let prompt = try JSONDecoder().decode(SmithersPrompt.self, from: json)
        XCTAssertEqual(prompt.inputs?.count, 1)
        XCTAssertEqual(prompt.inputs?.first?.defaultValue, "0.7")
    }

    // MARK: - ScoreRow

    func testScoreRowSourceField() throws {
        let json = """
        {"id":"s1","runId":"r1","nodeId":"n1","iteration":1,"attempt":1,"scorerId":"sc1","scorerName":"accuracy","source":"live","score":0.95,"reason":"good","latencyMs":150,"scoredAtMs":1700000000000}
        """.data(using: .utf8)!
        let score = try JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(score.source, "live")
        XCTAssertEqual(score.score, 0.95)
        XCTAssertEqual(score.scoredAt.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testScoreRowBatchSource() throws {
        let json = """
        {"id":"s2","score":0.5,"source":"batch","scoredAtMs":1700000000000}
        """.data(using: .utf8)!
        let score = try JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(score.source, "batch")
        XCTAssertNil(score.runId)
    }

    // MARK: - AggregateScore

    func testAggregateScoreDecoding() throws {
        let json = """
        {"scorerName":"accuracy","count":100,"mean":0.85,"min":0.1,"max":1.0,"p50":0.87}
        """.data(using: .utf8)!
        let agg = try JSONDecoder().decode(AggregateScore.self, from: json)
        XCTAssertEqual(agg.id, "accuracy")
        XCTAssertEqual(agg.count, 100)
        XCTAssertEqual(agg.p50, 0.87)
    }

    func testAggregateScoreP50Optional() throws {
        let json = """
        {"scorerName":"latency","count":10,"mean":200.0,"min":50.0,"max":500.0}
        """.data(using: .utf8)!
        let agg = try JSONDecoder().decode(AggregateScore.self, from: json)
        XCTAssertNil(agg.p50)
    }

    // MARK: - MemoryFact

    func testMemoryFactSchemaSig() throws {
        let json = """
        {"namespace":"ns","key":"k1","valueJson":"{}","schemaSig":"abc123","createdAtMs":1700000000000,"updatedAtMs":1700000060000,"ttlMs":3600000}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json)
        XCTAssertEqual(fact.schemaSig, "abc123")
        XCTAssertEqual(fact.id, "ns:k1")
        XCTAssertEqual(fact.createdAt.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
        XCTAssertEqual(fact.updatedAt.timeIntervalSince1970, 1700000060.0, accuracy: 0.001)
        XCTAssertEqual(fact.ttlMs, 3600000)
    }

    func testMemoryFactSchemaSigNil() throws {
        let json = """
        {"namespace":"ns","key":"k2","valueJson":"null","createdAtMs":0,"updatedAtMs":0}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json)
        XCTAssertNil(fact.schemaSig)
        XCTAssertNil(fact.ttlMs)
    }

    func testMemoryFactCodableRoundTrip() throws {
        let json = """
        {"namespace":"test","key":"foo","valueJson":"{\\"a\\":1}","schemaSig":"sig","createdAtMs":1000,"updatedAtMs":2000,"ttlMs":5000}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json)
        let reEncoded = try JSONEncoder().encode(fact)
        let fact2 = try JSONDecoder().decode(MemoryFact.self, from: reEncoded)
        XCTAssertEqual(fact.namespace, fact2.namespace)
        XCTAssertEqual(fact.key, fact2.key)
        XCTAssertEqual(fact.schemaSig, fact2.schemaSig)
    }

    // MARK: - MemoryRecallResult

    func testMemoryRecallResultDecoding() throws {
        let json = """
        {"score":0.95,"content":"hello world","metadata":"extra"}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(MemoryRecallResult.self, from: json)
        XCTAssertEqual(result.score, 0.95)
        XCTAssertTrue(result.id.contains("hello world"))
    }

    // MARK: - Snapshot

    func testSnapshotKindAutoManualErrorFork() throws {
        for kind in ["auto", "manual", "error", "fork"] {
            let json = """
            {"id":"snap-\(kind)","runId":"r1","kind":"\(kind)","createdAtMs":1700000000000}
            """.data(using: .utf8)!
            let snap = try JSONDecoder().decode(Snapshot.self, from: json)
            XCTAssertEqual(snap.kind, kind)
        }
    }

    func testSnapshotCreatedAtConversion() throws {
        let json = """
        {"id":"s1","runId":"r1","createdAtMs":1700000000000}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        XCTAssertEqual(snap.createdAt.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testSnapshotOptionalFields() throws {
        let json = """
        {"id":"s2","runId":"r1","nodeId":"n1","label":"checkpoint","kind":"manual","parentId":"s1","createdAtMs":1000}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        XCTAssertEqual(snap.nodeId, "n1")
        XCTAssertEqual(snap.label, "checkpoint")
        XCTAssertEqual(snap.parentId, "s1")
    }

    // MARK: - SnapshotDiff

    func testSnapshotDiffDecoding() throws {
        let json = """
        {"fromId":"a","toId":"b","changes":["file1.txt","file2.txt"]}
        """.data(using: .utf8)!
        let diff = try JSONDecoder().decode(SnapshotDiff.self, from: json)
        XCTAssertEqual(diff.changes?.count, 2)
    }

    // MARK: - Ticket

    func testTicketDecoding() throws {
        let json = """
        {"id":"t1","content":"Fix bug","status":"open","createdAtMs":1700000000000,"updatedAtMs":1700000060000}
        """.data(using: .utf8)!
        let ticket = try JSONDecoder().decode(Ticket.self, from: json)
        XCTAssertEqual(ticket.id, "t1")
        XCTAssertNotNil(ticket.createdAt)
    }

    func testTicketCreatedAtNilWhenMissing() throws {
        let json = """
        {"id":"t2"}
        """.data(using: .utf8)!
        let ticket = try JSONDecoder().decode(Ticket.self, from: json)
        XCTAssertNil(ticket.createdAt)
    }

    // MARK: - Landing

    func testLandingReviewStatus3States() throws {
        for status in ["approved", "changes_requested", "pending"] {
            let json = """
            {"id":"l1","title":"PR","reviewStatus":"\(status)"}
            """.data(using: .utf8)!
            let landing = try JSONDecoder().decode(Landing.self, from: json)
            XCTAssertEqual(landing.reviewStatus, status)
        }
    }

    func testLandingFullDecoding() throws {
        let json = """
        {"id":"l2","number":42,"title":"Add feature","description":"desc","state":"ready","targetBranch":"main","author":"dev","createdAt":"2024-01-01","reviewStatus":"approved"}
        """.data(using: .utf8)!
        let landing = try JSONDecoder().decode(Landing.self, from: json)
        XCTAssertEqual(landing.number, 42)
        XCTAssertEqual(landing.state, "ready")
        XCTAssertEqual(landing.author, "dev")
    }

    func testLandingStates() throws {
        for state in ["draft", "ready", "landed"] {
            let json = """
            {"id":"l-\(state)","title":"T","state":"\(state)"}
            """.data(using: .utf8)!
            let landing = try JSONDecoder().decode(Landing.self, from: json)
            XCTAssertEqual(landing.state, state)
        }
    }

    // MARK: - SmithersIssue

    func testIssueDecoding() throws {
        let json = """
        {"id":"i1","number":10,"title":"Bug","body":"details","state":"open","labels":["bug","p1"],"assignees":["dev1"],"commentCount":3}
        """.data(using: .utf8)!
        let issue = try JSONDecoder().decode(SmithersIssue.self, from: json)
        XCTAssertEqual(issue.labels?.count, 2)
        XCTAssertEqual(issue.assignees?.first, "dev1")
        XCTAssertEqual(issue.commentCount, 3)
    }

    func testIssueStates() throws {
        for state in ["open", "closed"] {
            let json = """
            {"id":"i-\(state)","title":"T","state":"\(state)"}
            """.data(using: .utf8)!
            let issue = try JSONDecoder().decode(SmithersIssue.self, from: json)
            XCTAssertEqual(issue.state, state)
        }
    }

    // MARK: - Workspace

    func testWorkspaceStatusActiveSuspendedStopped() throws {
        for status in ["active", "suspended", "stopped"] {
            let json = """
            {"id":"ws-\(status)","name":"WS","status":"\(status)"}
            """.data(using: .utf8)!
            let ws = try JSONDecoder().decode(Workspace.self, from: json)
            XCTAssertEqual(ws.status, status)
        }
    }

    func testWorkspaceMinimal() throws {
        let json = """
        {"id":"ws1","name":"Dev"}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertNil(ws.status)
        XCTAssertNil(ws.createdAt)
    }

    // MARK: - WorkspaceSnapshot

    func testWorkspaceSnapshotDecoding() throws {
        let json = """
        {"id":"wss1","workspaceId":"ws1","name":"backup","createdAt":"2024-01-01"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertEqual(snap.workspaceId, "ws1")
        XCTAssertEqual(snap.name, "backup")
    }

    // MARK: - Changes / Status (JJHub)

    func testJJHubWorkflowDecoding() throws {
        let json = """
        {"id":42,"repository_id":7,"name":"Deploy","path":".jjhub/workflows/deploy.yaml","is_active":true,"created_at":"2026-04-10T00:00:00Z","updated_at":"2026-04-12T00:00:00Z"}
        """.data(using: .utf8)!
        let workflow = try JSONDecoder().decode(JJHubWorkflow.self, from: json)
        XCTAssertEqual(workflow.id, 42)
        XCTAssertEqual(workflow.repositoryID, 7)
        XCTAssertEqual(workflow.name, "Deploy")
        XCTAssertTrue(workflow.isActive)
    }

    func testJJHubWorkflowRunDecoding() throws {
        let json = """
        {"id":901,"workflow_definition_id":42,"status":"running","trigger_event":"manual","trigger_ref":"main","trigger_commit_sha":"abc123","started_at":"2026-04-12T00:00:00Z","completed_at":null,"session_id":"sess-1","steps":["build","deploy"]}
        """.data(using: .utf8)!
        let run = try JSONDecoder().decode(JJHubWorkflowRun.self, from: json)
        XCTAssertEqual(run.id, 901)
        XCTAssertEqual(run.workflowDefinitionID, 42)
        XCTAssertEqual(run.triggerRef, "main")
        XCTAssertEqual(run.steps?.count, 2)
    }

    func testJJHubRepoDecoding() throws {
        let json = """
        {"id":7,"name":"smithers","full_name":"acme/smithers","owner":"acme","default_bookmark":"main","is_public":true,"is_archived":false,"num_issues":4,"num_stars":99,"created_at":"2026-04-10T00:00:00Z","updated_at":"2026-04-12T00:00:00Z"}
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(JJHubRepo.self, from: json)
        XCTAssertEqual(repo.id, 7)
        XCTAssertEqual(repo.fullName, "acme/smithers")
        XCTAssertEqual(repo.defaultBookmark, "main")
        XCTAssertEqual(repo.numStars, 99)
    }

    func testJJHubChangeDecoding() throws {
        let json = """
        {"change_id":"abc12345","commit_id":"deadbeef","description":"Fix regression","author":{"name":"Will","email":"will@example.com"},"timestamp":"2026-04-14T00:00:00Z","is_empty":false,"is_working_copy":false,"bookmarks":["main","release"]}
        """.data(using: .utf8)!
        let change = try JSONDecoder().decode(JJHubChange.self, from: json)
        XCTAssertEqual(change.id, "abc12345")
        XCTAssertEqual(change.commitID, "deadbeef")
        XCTAssertEqual(change.author?.name, "Will")
        XCTAssertEqual(change.bookmarks?.count, 2)
    }

    func testJJHubBookmarkDecoding() throws {
        let json = """
        {"name":"main","target_change_id":"abc12345","target_commit_id":"deadbeef","is_tracking_remote":true}
        """.data(using: .utf8)!
        let bookmark = try JSONDecoder().decode(JJHubBookmark.self, from: json)
        XCTAssertEqual(bookmark.id, "main")
        XCTAssertEqual(bookmark.targetChangeID, "abc12345")
        XCTAssertEqual(bookmark.isTrackingRemote, true)
    }

    // MARK: - ChatBlock

    func testChatBlockDecodingWithId() throws {
        let json = """
        {"id":"cb1","role":"assistant","content":"Hello"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertEqual(block.id, "cb1")
        XCTAssertEqual(block.stableId, "cb1")
        XCTAssertEqual(block.role, "assistant")
    }

    func testChatBlockDecodingWithoutId() throws {
        let json = """
        {"role":"user","content":"Hi"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertNil(block.id)
        XCTAssertFalse(block.stableId.isEmpty)
    }

    func testChatBlockInitializer() {
        let block = ChatBlock(id: nil, role: "system", content: "prompt")
        XCTAssertNil(block.id)
        XCTAssertEqual(block.role, "system")
        XCTAssertFalse(block.stableId.isEmpty)
    }

    func testChatBlockStableIdUniquePerInstance() throws {
        let json = """
        {"role":"user","content":"Hi"}
        """.data(using: .utf8)!
        let b1 = try JSONDecoder().decode(ChatBlock.self, from: json)
        let b2 = try JSONDecoder().decode(ChatBlock.self, from: json)
        // Each should get a unique fallback UUID
        XCTAssertNotEqual(b1.stableId, b2.stableId)
    }

    // MARK: - CronSchedule

    func testCronScheduleWithToggle() throws {
        let json = """
        {"id":"c1","pattern":"0 * * * *","workflowPath":"/deploy","enabled":true}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        XCTAssertTrue(cron.enabled)
        XCTAssertEqual(cron.pattern, "0 * * * *")
    }

    func testCronScheduleDisabled() throws {
        let json = """
        {"id":"c2","pattern":"*/5 * * * *","workflowPath":"/test","enabled":false}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        XCTAssertFalse(cron.enabled)
    }

    func testCronScheduleCodableRoundTrip() throws {
        let json = """
        {"id":"c3","pattern":"0 0 * * *","workflowPath":"/nightly","enabled":true}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        let reEncoded = try JSONEncoder().encode(cron)
        let cron2 = try JSONDecoder().decode(CronSchedule.self, from: reEncoded)
        XCTAssertEqual(cron.id, cron2.id)
        XCTAssertEqual(cron.enabled, cron2.enabled)
        XCTAssertEqual(cron.pattern, cron2.pattern)
    }

    // MARK: - SQLResult

    func testSQLResultDecoding() throws {
        let json = """
        {"columns":["id","name"],"rows":[["1","Alice"],["2","Bob"]]}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(SQLResult.self, from: json)
        XCTAssertEqual(result.columns.count, 2)
        XCTAssertEqual(result.rows.count, 2)
    }

    func testSQLResultEmpty() throws {
        let json = "{}".data(using: .utf8)!
        let result = try JSONDecoder().decode(SQLResult.self, from: json)
        XCTAssertTrue(result.columns.isEmpty)
        XCTAssertTrue(result.rows.isEmpty)
    }

    // MARK: - SearchResult

    func testSearchResultDecoding() throws {
        let json = """
        {"id":"sr1","title":"Found","description":"match","snippet":"line 42","filePath":"/src/main.rs","lineNumber":42,"kind":"code"}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(SearchResult.self, from: json)
        XCTAssertEqual(result.kind, "code")
        XCTAssertEqual(result.lineNumber, 42)
    }

    func testSearchResultKinds() throws {
        for kind in ["repo", "issue", "code"] {
            let json = """
            {"id":"sr-\(kind)","title":"T","kind":"\(kind)"}
            """.data(using: .utf8)!
            let result = try JSONDecoder().decode(SearchResult.self, from: json)
            XCTAssertEqual(result.kind, kind)
        }
    }

    // MARK: - SSEEvent

    func testSSEEventTypeAndData() {
        let event = SSEEvent(event: "message", data: "{\"key\":\"value\"}")
        XCTAssertEqual(event.event, "message")
        XCTAssertEqual(event.data, "{\"key\":\"value\"}")
    }

    func testSSEEventNilType() {
        let event = SSEEvent(event: nil, data: "data")
        XCTAssertNil(event.event)
        XCTAssertEqual(event.data, "data")
    }

    // MARK: - APIEnvelope

    func testAPIEnvelopeSuccess() throws {
        let json = """
        {"ok":true,"data":{"id":"w1","name":"Test"},"error":null}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<Workspace>.self, from: json)
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data?.id, "w1")
        XCTAssertNil(envelope.error)
    }

    func testAPIEnvelopeError() throws {
        let json = """
        {"ok":false,"data":null,"error":"not found"}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<Workspace>.self, from: json)
        XCTAssertFalse(envelope.ok)
        XCTAssertNil(envelope.data)
        XCTAssertEqual(envelope.error, "not found")
    }

    func testAPIEnvelopeWithArray() throws {
        let json = """
        {"ok":true,"data":[{"id":"s1","title":"Result","kind":"code"}]}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<[SearchResult]>.self, from: json)
        XCTAssertTrue(envelope.ok)
        XCTAssertEqual(envelope.data?.count, 1)
    }

    func testAPIEnvelopeMissingDataField() throws {
        let json = """
        {"ok":true}
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(APIEnvelope<Workspace>.self, from: json)
        XCTAssertTrue(envelope.ok)
        XCTAssertNil(envelope.data)
    }

    // MARK: - WorkflowDAG

    func testWorkflowDAGDecoding() throws {
        let json = """
        {"entryTask":"start","fields":[{"name":"Env","key":"env","type":"string","default":"staging"}]}
        """.data(using: .utf8)!
        let dag = try JSONDecoder().decode(WorkflowDAG.self, from: json)
        XCTAssertEqual(dag.entryTask, "start")
        XCTAssertEqual(dag.fields?.first?.defaultValue, "staging")
    }
}
