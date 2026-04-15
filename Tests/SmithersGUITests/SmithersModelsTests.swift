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
        XCTAssertEqual(run.completedNodes, 4)
        XCTAssertEqual(run.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(run.finishedProgress, 0.3, accuracy: 0.001)
        XCTAssertEqual(run.failedProgress, 0.1, accuracy: 0.001)
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

    func testRunTaskDecodingCLIShapeParsesIterationAndState() throws {
        let json = """
        {
          "id": "review-gate:0",
          "label": "Review Gate",
          "state": "in-progress",
          "attempt": "3",
          "updatedAt": "2026-04-15T01:05:45Z"
        }
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(RunTask.self, from: json)
        XCTAssertEqual(task.nodeId, "review-gate")
        XCTAssertEqual(task.iteration, 0)
        XCTAssertEqual(task.state, "running")
        XCTAssertEqual(task.lastAttempt, 3)
        XCTAssertEqual(task.updatedAtMs, 1_776_215_145_000)
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

    func testRunInspectionDecodesRealCLIInspectShape() throws {
        let json = """
        {
          "run": {
            "id": "92e861d1-d3e7-4926-a087-91f9a9c1598c",
            "workflow": "ticket-kanban",
            "status": "running",
            "started": "2026-04-15T01:05:15.093Z",
            "elapsed": "3h 42m"
          },
          "steps": [
            {
              "id": "0001-port-agents-view:implement",
              "state": "finished",
              "attempt": 1,
              "label": "0001-port-agents-view:implement"
            },
            {
              "id": "0001-port-agents-view:review:0",
              "state": "in-progress",
              "attempt": 1,
              "label": "0001-port-agents-view:review:0"
            },
            {
              "id": "release-gate",
              "state": "waitingApproval",
              "attempt": 0,
              "label": "Release gate"
            }
          ],
          "cta": {
            "description": "Suggested commands:",
            "commands": [
              {
                "command": "smithers logs 92e861d1-d3e7-4926-a087-91f9a9c1598c",
                "description": "Tail run logs"
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let inspection = try JSONDecoder().decode(RunInspection.self, from: json)

        XCTAssertEqual(inspection.run.runId, "92e861d1-d3e7-4926-a087-91f9a9c1598c")
        XCTAssertEqual(inspection.run.workflowName, "ticket-kanban")
        XCTAssertEqual(inspection.run.status, .running)
        XCTAssertEqual(inspection.run.startedAtMs, 1_776_215_115_093)
        XCTAssertEqual(inspection.run.summary?["total"], 3)
        XCTAssertEqual(inspection.run.summary?["finished"], 1)
        XCTAssertEqual(inspection.run.summary?["running"], 1)
        XCTAssertEqual(inspection.run.summary?["waiting-approval"], 1)

        XCTAssertEqual(inspection.tasks.count, 3)
        XCTAssertEqual(inspection.tasks[1].nodeId, "0001-port-agents-view:review")
        XCTAssertEqual(inspection.tasks[1].iteration, 0)
        XCTAssertEqual(inspection.tasks[1].state, "running")
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

    func testWorkflowDecodingFromEntryFileUsesFilePath() throws {
        let json = """
        {"id":"w3","displayName":"Deploy","entryFile":".smithers/workflows/deploy.tsx"}
        """.data(using: .utf8)!
        let wf = try JSONDecoder().decode(Workflow.self, from: json)
        XCTAssertEqual(wf.name, "Deploy")
        XCTAssertEqual(wf.filePath, ".smithers/workflows/deploy.tsx")
    }

    func testWorkflowDecodingFromPathAliasUsesFilePath() throws {
        let json = """
        {"id":"w4","name":"Release","path":"workflows/release.tsx","workspace_id":"ws-9","updated_at":"2026-04-15T00:00:00Z"}
        """.data(using: .utf8)!
        let wf = try JSONDecoder().decode(Workflow.self, from: json)
        XCTAssertEqual(wf.workspaceId, "ws-9")
        XCTAssertEqual(wf.updatedAt, "2026-04-15T00:00:00Z")
        XCTAssertEqual(wf.filePath, "workflows/release.tsx")
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

    func testWorkflowLaunchFieldDecodesNonStringDefaults() throws {
        let json = """
        [
          {"name":"Replicas","key":"replicas","type":"number","default":3},
          {"name":"Dry Run","key":"dry_run","type":"boolean","default":true},
          {"name":"Config","key":"config","type":"object","default":{"enabled":true,"tier":"canary"}}
        ]
        """.data(using: .utf8)!

        let fields = try JSONDecoder().decode([WorkflowLaunchField].self, from: json)

        XCTAssertEqual(fields[0].defaultValue, "3")
        XCTAssertEqual(fields[1].defaultValue, "true")
        XCTAssertEqual(fields[2].defaultValue, #"{"enabled":true,"tier":"canary"}"#)
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

    func testApprovalDecisionDecodingSupportsDecisionAndDecidedAliases() throws {
        let json = """
        {"id":"d2","run_id":"r2","node_id":"n2","decision":"approved","decided_at":1700000001000,"decided_by":"ops","requested_at":1700000000000,"workflow_path":".smithers/workflows/release.yml","gate":"Release Gate","payload":"{\\"environment\\":\\"prod\\"}","transport_source":"sqlite"}
        """.data(using: .utf8)!
        let decision = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(decision.action, "approved")
        XCTAssertEqual(decision.resolvedAt, 1700000001000)
        XCTAssertEqual(decision.resolvedBy, "ops")
        XCTAssertEqual(decision.requestedAt, 1700000000000)
        XCTAssertEqual(decision.workflowPath, ".smithers/workflows/release.yml")
        XCTAssertEqual(decision.gate, "Release Gate")
        XCTAssertEqual(decision.source, "sqlite")
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

    func testPromptInputDefaultValueAltCodingKey() throws {
        let json = """
        {"name":"goal","type":"string","defaultValue":"ship"}
        """.data(using: .utf8)!
        let input = try JSONDecoder().decode(PromptInput.self, from: json)
        XCTAssertEqual(input.defaultValue, "ship")
        XCTAssertEqual(input.id, "goal")
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

    func testScoreRowScorerDisplayNameTrimsAndFallsBack() throws {
        let named = ScoreRow(id: "s1", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: "sid", scorerName: " accuracy ", source: nil, score: 0.9, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0)
        let idFallback = ScoreRow(id: "s2", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: " scorer-id ", scorerName: " ", source: nil, score: 0.9, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0)
        let unknown = ScoreRow(id: "s3", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: nil, scorerName: nil, source: nil, score: 0.9, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0)

        XCTAssertEqual(named.scorerDisplayName, "accuracy")
        XCTAssertEqual(idFallback.scorerDisplayName, "scorer-id")
        XCTAssertEqual(unknown.scorerDisplayName, "Unknown")
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

    func testAggregateScoreAggregatesPerScorerName() throws {
        let scores = [
            ScoreRow(id: "s1", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: "quality-v1", scorerName: "Quality", source: nil, score: 0.8, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0),
            ScoreRow(id: "s2", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: "quality-v2", scorerName: "Quality", source: nil, score: 1.0, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0),
            ScoreRow(id: "s3", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: "lint", scorerName: "Lint", source: nil, score: 0.5, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0),
            ScoreRow(id: "s4", runId: nil, nodeId: nil, iteration: nil, attempt: nil, scorerId: "lint", scorerName: "Lint", source: nil, score: 0.7, reason: nil, metaJson: nil, latencyMs: nil, scoredAtMs: 0),
        ]

        let aggregates = AggregateScore.aggregate(scores)

        XCTAssertEqual(aggregates.map(\.scorerName), ["Lint", "Quality"])

        let lint = try XCTUnwrap(aggregates.first { $0.scorerName == "Lint" })
        XCTAssertEqual(lint.count, 2)
        XCTAssertEqual(lint.mean, 0.6, accuracy: 0.0001)
        XCTAssertEqual(lint.min, 0.5, accuracy: 0.0001)
        XCTAssertEqual(lint.max, 0.7, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(lint.p50), 0.6, accuracy: 0.0001)

        let quality = try XCTUnwrap(aggregates.first { $0.scorerName == "Quality" })
        XCTAssertEqual(quality.count, 2)
        XCTAssertEqual(quality.mean, 0.9, accuracy: 0.0001)
        XCTAssertEqual(quality.min, 0.8, accuracy: 0.0001)
        XCTAssertEqual(quality.max, 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(quality.p50), 0.9, accuracy: 0.0001)
    }

    // MARK: - Metrics

    func testMetricsFilterDefaultsToNilValues() {
        let filter = MetricsFilter()
        XCTAssertNil(filter.workflowPath)
        XCTAssertNil(filter.runId)
        XCTAssertNil(filter.nodeId)
        XCTAssertNil(filter.startMs)
        XCTAssertNil(filter.endMs)
        XCTAssertNil(filter.groupBy)
    }

    func testTokenMetricsDecodesSnakeCaseAndComputesTotalFallback() throws {
        let json = """
        {"total_input_tokens":2000,"total_output_tokens":500,"cache_read_tokens":250,"cache_write_tokens":10}
        """.data(using: .utf8)!
        let metrics = try JSONDecoder().decode(TokenMetrics.self, from: json)
        XCTAssertEqual(metrics.totalInputTokens, 2000)
        XCTAssertEqual(metrics.totalOutputTokens, 500)
        XCTAssertEqual(metrics.totalTokens, 2500)
        XCTAssertEqual(metrics.cacheReadTokens, 250)
        XCTAssertEqual(metrics.cacheWriteTokens, 10)
        XCTAssertEqual(metrics.cacheHitRate ?? 0, 0.1, accuracy: 0.0001)
    }

    func testLatencyMetricsDecodingWithByPeriod() throws {
        let json = """
        {"count":3,"meanMs":120.5,"minMs":10,"maxMs":300,"p50Ms":90,"p95Ms":280,"byPeriod":[{"label":"2026-04-15","count":3,"meanMs":120.5,"p50Ms":90,"p95Ms":280}]}
        """.data(using: .utf8)!
        let metrics = try JSONDecoder().decode(LatencyMetrics.self, from: json)
        XCTAssertEqual(metrics.count, 3)
        XCTAssertEqual(metrics.meanMs, 120.5, accuracy: 0.001)
        XCTAssertEqual(metrics.byPeriod.count, 1)
        XCTAssertEqual(metrics.byPeriod.first?.label, "2026-04-15")
    }

    func testCostReportDecodingWithByPeriod() throws {
        let json = """
        {"totalCostUsd":0.5,"inputCostUsd":0.2,"outputCostUsd":0.3,"runCount":4,"byPeriod":[{"label":"2026-04-15","totalCostUsd":0.3,"inputCostUsd":0.1,"outputCostUsd":0.2,"runCount":2}]}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(CostReport.self, from: json)
        XCTAssertEqual(report.totalCostUSD, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.runCount, 4)
        XCTAssertEqual(report.byPeriod.count, 1)
        XCTAssertEqual(report.byPeriod.first?.runCount, 2)
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

    func testMemoryFactSnakeCaseDecoding() throws {
        let json = """
        {"namespace":"workflow:implement","key":"k","value_json":"{\\"ok\\":true}","schema_sig":"sig","created_at_ms":1000,"updated_at_ms":2000,"ttl_ms":3000}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json)
        XCTAssertEqual(fact.namespace, "workflow:implement")
        XCTAssertEqual(fact.key, "k")
        XCTAssertEqual(fact.valueJson, #"{"ok":true}"#)
        XCTAssertEqual(fact.schemaSig, "sig")
        XCTAssertEqual(fact.createdAtMs, 1000)
        XCTAssertEqual(fact.updatedAtMs, 2000)
        XCTAssertEqual(fact.ttlMs, 3000)
    }

    func testMemoryFactDecodingSupportsStringTimestamps() throws {
        let json = """
        {"namespace":"ns","key":"k","valueJson":"{}","createdAtMs":"1000","updatedAtMs":"2000","ttlMs":"3000"}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json)
        XCTAssertEqual(fact.createdAtMs, 1000)
        XCTAssertEqual(fact.updatedAtMs, 2000)
        XCTAssertEqual(fact.ttlMs, 3000)
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

    func testTimelineDecodesRealCLIShapeIntoSnapshots() throws {
        let json = """
        {
          "runId": "run-123",
          "branch": null,
          "frames": [
            {
              "frameNo": 7,
              "createdAtMs": 1700000000000,
              "contentHash": "abcdef123456",
              "forks": [
                {
                  "runId": "child-1",
                  "branchLabel": "try-fix",
                  "forkDescription": "Replay from run-123:7"
                }
              ]
            }
          ],
          "children": []
        }
        """.data(using: .utf8)!
        let timeline = try JSONDecoder().decode(Timeline.self, from: json)
        let snapshots = timeline.snapshots(workflowPath: ".smithers/workflows/demo.tsx")

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].id, "run-123:7")
        XCTAssertEqual(snapshots[0].frameNo, 7)
        XCTAssertEqual(snapshots[0].contentHash, "abcdef123456")
        XCTAssertEqual(snapshots[0].forks?.first?.runId, "child-1")
        XCTAssertEqual(snapshots[0].workflowPath, ".smithers/workflows/demo.tsx")
    }

    // MARK: - SnapshotDiff

    func testSnapshotDiffDecoding() throws {
        let json = """
        {"fromId":"a","toId":"b","changes":["file1.txt","file2.txt"]}
        """.data(using: .utf8)!
        let diff = try JSONDecoder().decode(SnapshotDiff.self, from: json)
        XCTAssertEqual(diff.changes?.count, 2)
    }

    func testSnapshotDiffDecodesRealCLIShape() throws {
        let json = """
        {
          "nodesAdded": ["node-a::0"],
          "nodesRemoved": ["node-b::0"],
          "nodesChanged": [
            {
              "nodeId": "node-c::0",
              "from": {
                "nodeId": "node-c",
                "iteration": 0,
                "state": "running",
                "lastAttempt": 1,
                "outputTable": "outputs",
                "label": "Node C"
              },
              "to": {
                "nodeId": "node-c",
                "iteration": 0,
                "state": "finished",
                "lastAttempt": 2,
                "outputTable": "outputs",
                "label": "Node C"
              }
            }
          ],
          "outputsAdded": ["summary"],
          "outputsRemoved": [],
          "outputsChanged": [
            {
              "key": "result",
              "from": {"ok": false},
              "to": {"ok": true, "files": ["A.swift"]}
            }
          ],
          "ralphChanged": [
            {
              "ralphId": "loop",
              "from": {"ralphId": "loop", "iteration": 1, "done": false},
              "to": {"ralphId": "loop", "iteration": 2, "done": true}
            }
          ],
          "inputChanged": true,
          "vcsPointerChanged": false
        }
        """.data(using: .utf8)!
        let diff = try JSONDecoder().decode(SnapshotDiff.self, from: json)

        XCTAssertEqual(diff.nodesAdded, ["node-a::0"])
        XCTAssertEqual(diff.nodesRemoved, ["node-b::0"])
        XCTAssertEqual(diff.nodesChanged.first?.to.state, "finished")
        XCTAssertEqual(diff.outputsAdded, ["summary"])
        XCTAssertEqual(diff.outputsChanged.first?.to, .object(["ok": .bool(true), "files": .array([.string("A.swift")])]))
        XCTAssertEqual(diff.ralphChanged.first?.to.done, true)
        XCTAssertTrue(diff.inputChanged)
        XCTAssertFalse(diff.vcsPointerChanged)
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

    func testLandingJJHubDecoding() throws {
        let json = """
        {"number":42,"title":"Add feature","body":"desc","state":"open","target_bookmark":"main","author":{"id":7,"login":"dev"},"created_at":"2026-02-19T00:00:00Z"}
        """.data(using: .utf8)!
        let landing = try JSONDecoder().decode(Landing.self, from: json)
        XCTAssertEqual(landing.id, "landing-42")
        XCTAssertEqual(landing.description, "desc")
        XCTAssertEqual(landing.targetBranch, "main")
        XCTAssertEqual(landing.author, "dev")
        XCTAssertEqual(landing.createdAt, "2026-02-19T00:00:00Z")
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

    func testIssueDecodingFromJJHubCLIShape() throws {
        let json = """
        {"id":42,"number":10,"title":"Bug","body":"details","state":"open","labels":[{"id":1,"name":"bug","color":"ff0000"}],"assignees":[{"id":7,"login":"dev1"}],"comment_count":3}
        """.data(using: .utf8)!
        let issue = try JSONDecoder().decode(SmithersIssue.self, from: json)
        XCTAssertEqual(issue.id, "42")
        XCTAssertEqual(issue.labels, ["bug"])
        XCTAssertEqual(issue.assignees, ["dev1"])
        XCTAssertEqual(issue.commentCount, 3)
    }

    func testIssueDecodingSupportsDescriptionStatusAndCommentsFallbacks() throws {
        let json = """
        {"id":"i2","number":"11","title":"Bug","description":"details","status":"open","labels":[{"name":"bug"}],"assignees":[{"login":"dev2"}],"comments":"4"}
        """.data(using: .utf8)!
        let issue = try JSONDecoder().decode(SmithersIssue.self, from: json)
        XCTAssertEqual(issue.number, 11)
        XCTAssertEqual(issue.body, "details")
        XCTAssertEqual(issue.state, "open")
        XCTAssertEqual(issue.labels, ["bug"])
        XCTAssertEqual(issue.assignees, ["dev2"])
        XCTAssertEqual(issue.commentCount, 4)
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
        for status in ["active", "running", "suspended", "stopped"] {
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

    func testWorkspaceDecodesJJHubSnakeCaseDates() throws {
        let json = """
        {"id":"ws1","name":"Dev","status":"running","created_at":"2026-03-07T00:00:00Z","updated_at":"2026-03-07T01:00:00Z"}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertEqual(ws.status, "running")
        XCTAssertEqual(ws.createdAt, "2026-03-07T00:00:00Z")
    }

    func testWorkspaceDecodesNumericIDDisplayNameAndState() throws {
        let json = """
        {"id":42,"displayName":" Primary ","state":"running","created_at":"2026-03-07T00:00:00Z"}
        """.data(using: .utf8)!
        let ws = try JSONDecoder().decode(Workspace.self, from: json)
        XCTAssertEqual(ws.id, "42")
        XCTAssertEqual(ws.name, "Primary")
        XCTAssertEqual(ws.status, "running")
        XCTAssertEqual(ws.createdAt, "2026-03-07T00:00:00Z")
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

    func testWorkspaceSnapshotDecodesJJHubSnakeCaseFields() throws {
        let json = """
        {"id":"wss1","workspace_id":"ws1","name":"backup","freestyle_snapshot_id":"fs1","created_at":"2026-03-07T00:00:00Z","updated_at":"2026-03-07T01:00:00Z"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertEqual(snap.workspaceId, "ws1")
        XCTAssertEqual(snap.createdAt, "2026-03-07T00:00:00Z")
    }

    func testWorkspaceSnapshotDecodesNumericIDs() throws {
        let json = """
        {"id":9,"workspace_id":42,"name":" Nightly ","created_at":"2026-03-07T00:00:00Z"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertEqual(snap.id, "9")
        XCTAssertEqual(snap.workspaceId, "42")
        XCTAssertEqual(snap.name, "Nightly")
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

    func testChatBlockDecodingWithItemIdUsesLifecycleId() throws {
        let json = """
        {"item_id":"cmd-1","role":"tool","content":"running"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertNil(block.id)
        XCTAssertEqual(block.itemId, "cmd-1")
        XCTAssertEqual(block.lifecycleId, "cmd-1")
        XCTAssertEqual(block.stableId, "cmd-1")
    }

    func testChatBlockLifecycleIdPrefersItemIdWhenBothPresent() throws {
        let json = """
        {"id":"evt-123","item_id":"cmd-1","role":"tool","content":"running"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertEqual(block.id, "evt-123")
        XCTAssertEqual(block.itemId, "cmd-1")
        XCTAssertEqual(block.lifecycleId, "cmd-1")
        XCTAssertEqual(block.stableId, "cmd-1")
    }

    func testChatBlockDecodingWithoutId() throws {
        let json = """
        {"role":"user","content":"Hi"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertNil(block.id)
        XCTAssertFalse(block.stableId.isEmpty)
        XCTAssertTrue(block.stableId.hasPrefix("chatblock-"))
    }

    func testChatBlockInitializer() {
        let block = ChatBlock(id: nil, role: "system", content: "prompt")
        XCTAssertNil(block.id)
        XCTAssertEqual(block.role, "system")
        XCTAssertFalse(block.stableId.isEmpty)
        XCTAssertTrue(block.stableId.hasPrefix("chatblock-"))
    }

    func testChatBlockStableIdDeterministicForSameContent() throws {
        let json = """
        {"role":"user","content":"Hi"}
        """.data(using: .utf8)!
        let b1 = try JSONDecoder().decode(ChatBlock.self, from: json)
        let b2 = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertEqual(b1.stableId, b2.stableId)
    }

    func testChatBlockStableIdChangesWithContent() throws {
        let b1 = ChatBlock(id: nil, role: "user", content: "Hi")
        let b2 = ChatBlock(id: nil, role: "user", content: "Hello")
        XCTAssertNotEqual(b1.stableId, b2.stableId)
    }

    func testChatBlockStableIdUsesArrayIndexForDuplicateContent() throws {
        let json = """
        [{"role":"user","content":"Hi"},{"role":"user","content":"Hi"}]
        """.data(using: .utf8)!
        let firstDecode = try JSONDecoder().decode([ChatBlock].self, from: json)
        let secondDecode = try JSONDecoder().decode([ChatBlock].self, from: json)

        XCTAssertNotEqual(firstDecode[0].stableId, firstDecode[1].stableId)
        XCTAssertEqual(firstDecode.map(\.stableId), secondDecode.map(\.stableId))
    }

    func testChatBlockStableIdFallsBackForEmptyId() throws {
        let json = """
        {"id":"","role":"assistant","content":"Hello"}
        """.data(using: .utf8)!
        let block = try JSONDecoder().decode(ChatBlock.self, from: json)
        XCTAssertEqual(block.id, "")
        XCTAssertTrue(block.stableId.hasPrefix("chatblock-"))
    }

    func testChatBlockStableIdPreservedWhenMergingAnonymousAssistantStream() {
        let existing = ChatBlock(
            id: nil,
            runId: "run-1",
            nodeId: "node-1",
            attempt: 0,
            role: "assistant",
            content: "Hello",
            timestampMs: 100
        )
        let incoming = ChatBlock(
            id: nil,
            runId: "run-1",
            nodeId: "node-1",
            attempt: 0,
            role: "assistant",
            content: "Hello world",
            timestampMs: 101
        )

        let merged = existing.mergingAssistantStream(with: incoming)
        XCTAssertEqual(merged.stableId, existing.stableId)
        XCTAssertEqual(merged.content, "Hello world")
    }

    func testChatBlockMergedStreamingContentAppendsTimestampedDelta() {
        let merged = ChatBlock.mergedStreamingContent(
            existing: "Hello ",
            incoming: "world",
            existingTimestampMs: 100,
            incomingTimestampMs: 101
        )
        XCTAssertEqual(merged, "Hello world")
    }

    func testChatBlockMergedStreamingContentDeduplicatesOverlap() {
        let merged = ChatBlock.mergedStreamingContent(existing: "Hello wor", incoming: "world")
        XCTAssertEqual(merged, "Hello world")
    }

    func testChatBlockMergedStreamingContentIgnoresRetransmittedChunk() {
        let merged = ChatBlock.mergedStreamingContent(existing: "Hello world", incoming: "world")
        XCTAssertEqual(merged, "Hello world")
    }

    func testChatBlockMergedStreamingContentHandlesOutOfOrderCumulativeChunk() {
        let merged = ChatBlock.mergedStreamingContent(existing: "world", incoming: "Hello world")
        XCTAssertEqual(merged, "Hello world")
    }

    func testDeduplicatedChatBlocksMergesAssistantLifecycleDeltas() {
        let blocks = [
            ChatBlock(id: "stream-1", role: "assistant", content: "Hello wor"),
            ChatBlock(id: "stream-1", role: "assistant", content: "world"),
        ]

        let deduped = deduplicatedChatBlocks(blocks)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].content, "Hello world")
    }

    func testDeduplicatedChatBlocksReplacesNonAssistantLifecycleBlocks() {
        let blocks = [
            ChatBlock(id: "tool-1", role: "tool", content: "running"),
            ChatBlock(id: "tool-1", role: "tool", content: "complete"),
        ]

        let deduped = deduplicatedChatBlocks(blocks)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].content, "complete")
    }

    func testDeduplicatedChatBlocksUsesItemIdAcrossChangingEventIds() {
        let blocks = [
            ChatBlock(id: "evt-1", itemId: "cmd-1", role: "tool", content: "running"),
            ChatBlock(id: "evt-2", itemId: "cmd-1", role: "tool", content: "progress"),
            ChatBlock(id: "evt-3", itemId: "cmd-1", role: "tool", content: "complete"),
        ]

        let deduped = deduplicatedChatBlocks(blocks)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].lifecycleId, "cmd-1")
        XCTAssertEqual(deduped[0].content, "complete")
    }

    // MARK: - CronSchedule

    func testCronScheduleWithToggle() throws {
        let json = """
        {"id":"c1","pattern":"0 * * * *","workflowPath":"/deploy","enabled":true,"lastRunAtMs":1700000000000}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        XCTAssertTrue(cron.enabled)
        XCTAssertEqual(cron.pattern, "0 * * * *")
        XCTAssertEqual(cron.lastRunAtMs, 1_700_000_000_000)
        XCTAssertNotNil(cron.lastRunAt)
    }

    func testCronScheduleDisabled() throws {
        let json = """
        {"cronId":"c2","pattern":"*/5 * * * *","workflowPath":"/test","enabled":false,"errorJson":"{\\"message\\":\\"oops\\"}"}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        XCTAssertEqual(cron.id, "c2")
        XCTAssertFalse(cron.enabled)
        XCTAssertEqual(cron.errorJson, "{\"message\":\"oops\"}")
    }

    func testCronScheduleCodableRoundTrip() throws {
        let json = """
        {"id":"c3","pattern":"0 0 * * *","workflowPath":"/nightly","enabled":true,"nextRunAtMs":1700003600000}
        """.data(using: .utf8)!
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        let reEncoded = try JSONEncoder().encode(cron)
        let cron2 = try JSONDecoder().decode(CronSchedule.self, from: reEncoded)
        XCTAssertEqual(cron.id, cron2.id)
        XCTAssertEqual(cron.enabled, cron2.enabled)
        XCTAssertEqual(cron.pattern, cron2.pattern)
        XCTAssertEqual(cron.nextRunAtMs, cron2.nextRunAtMs)
    }

    func testCronScheduleGeneratesFallbackIdWhenIdMissing() throws {
        let json = """
        {"pattern":"15 * * * *","workflowPath":"/hourly","enabled":true}
        """.data(using: .utf8)!
        let cron1 = try JSONDecoder().decode(CronSchedule.self, from: json)
        let cron2 = try JSONDecoder().decode(CronSchedule.self, from: json)

        XCTAssertFalse(cron1.id.isEmpty)
        XCTAssertTrue(cron1.id.hasPrefix("cron-"))
        XCTAssertEqual(cron1.id, cron2.id)
        XCTAssertEqual(cron1.pattern, "15 * * * *")
        XCTAssertEqual(cron1.workflowPath, "/hourly")
    }

    func testCronScheduleFallbackIdChangesWithScheduleIdentity() throws {
        let first = """
        {"pattern":"15 * * * *","workflowPath":"/hourly","enabled":true}
        """.data(using: .utf8)!
        let second = """
        {"pattern":"15 * * * *","workflowPath":"/different","enabled":true}
        """.data(using: .utf8)!

        let cron1 = try JSONDecoder().decode(CronSchedule.self, from: first)
        let cron2 = try JSONDecoder().decode(CronSchedule.self, from: second)

        XCTAssertNotEqual(cron1.id, cron2.id)
    }

    func testCronScheduleThrowsWhenResolvedIdIsEmpty() throws {
        let json = """
        {"id":"","cronId":"","pattern":" ","workflowPath":"","enabled":true}
        """.data(using: .utf8)!

        XCTAssertThrowsError(try JSONDecoder().decode(CronSchedule.self, from: json)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("Expected dataCorrupted error, got \(error)")
            }
            XCTAssertEqual(context.debugDescription, "CronSchedule id resolved to an empty string")
        }
    }

    func testCronScheduleDecodesSnakeCaseTransportShape() throws {
        let json = """
        {"cron_id":"c4","cronPattern":"*/10 * * * *","workflow_path":".smithers/workflows/debug.tsx","isEnabled":"1","created_at_ms":"1776218840798","last_run_at_ms":null,"next_run_at_ms":"1776219440798","error_json":"{\\"message\\":\\"boom\\"}"}
        """.data(using: .utf8)!

        let cron = try JSONDecoder().decode(CronSchedule.self, from: json)
        XCTAssertEqual(cron.id, "c4")
        XCTAssertEqual(cron.pattern, "*/10 * * * *")
        XCTAssertEqual(cron.workflowPath, ".smithers/workflows/debug.tsx")
        XCTAssertTrue(cron.enabled)
        XCTAssertEqual(cron.createdAtMs, 1_776_218_840_798)
        XCTAssertEqual(cron.nextRunAtMs, 1_776_219_440_798)
        XCTAssertEqual(cron.errorJson, "{\"message\":\"boom\"}")
    }

    func testCronResponseDecodesNestedDataCrons() throws {
        let json = """
        {"data":{"crons":[{"cronId":"c5","pattern":"0 * * * *","workflowPath":"hourly.ts","enabled":true}]}}
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(CronResponse.self, from: json)
        XCTAssertEqual(response.crons.count, 1)
        XCTAssertEqual(response.crons[0].id, "c5")
        XCTAssertEqual(response.crons[0].workflowPath, "hourly.ts")
        XCTAssertTrue(response.crons[0].enabled)
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

    func testWorkflowDAGLegacyDecoding() throws {
        let json = """
        {"entryTask":"start","fields":[{"name":"Env","key":"env","type":"string","default":"staging"}]}
        """.data(using: .utf8)!
        let dag = try JSONDecoder().decode(WorkflowDAG.self, from: json)
        XCTAssertEqual(dag.entryTask, "start")
        XCTAssertEqual(dag.fields?.first?.defaultValue, "staging")
        XCTAssertTrue(dag.tasks.isEmpty)
    }

    func testWorkflowDAGDecodesSmithersGraphJSON() throws {
        let json = """
        {
          "runId": "graph",
          "frameNo": 0,
          "xml": {
            "kind": "element",
            "tag": "smithers:workflow",
            "props": { "name": "implement" },
            "children": [
              {
                "kind": "element",
                "tag": "smithers:sequence",
                "props": {},
                "children": [
                  { "kind": "element", "tag": "smithers:task", "props": { "id": "research" }, "children": [] },
                  { "kind": "element", "tag": "smithers:task", "props": { "id": "plan" }, "children": [] },
                  {
                    "kind": "element",
                    "tag": "smithers:parallel",
                    "props": {},
                    "children": [
                      { "kind": "element", "tag": "smithers:task", "props": { "id": "review:0" }, "children": [] },
                      { "kind": "element", "tag": "smithers:task", "props": { "id": "review:1" }, "children": [] }
                    ]
                  }
                ]
              }
            ]
          },
          "tasks": [
            { "nodeId": "research", "ordinal": 0, "iteration": 0, "outputTableName": "research", "needsApproval": false, "timeoutMs": null, "heartbeatTimeoutMs": 60000, "continueOnFail": false },
            { "nodeId": "plan", "ordinal": 1, "iteration": 0, "outputTableName": "plan", "needsApproval": false, "timeoutMs": null, "heartbeatTimeoutMs": 60000, "continueOnFail": false },
            { "nodeId": "review:0", "ordinal": 2, "iteration": 0, "outputTableName": "review", "needsApproval": false, "timeoutMs": 1800000, "heartbeatTimeoutMs": 600000, "continueOnFail": true, "parallelGroupId": "parallel:0.2" },
            { "nodeId": "review:1", "ordinal": 3, "iteration": 0, "outputTableName": "review", "needsApproval": false, "timeoutMs": 1800000, "heartbeatTimeoutMs": 600000, "continueOnFail": true, "parallelGroupId": "parallel:0.2" }
          ]
        }
        """.data(using: .utf8)!

        let dag = try JSONDecoder().decode(WorkflowDAG.self, from: json)

        XCTAssertEqual(dag.runId, "graph")
        XCTAssertEqual(dag.frameNo, 0)
        XCTAssertEqual(dag.entryTask, "research")
        XCTAssertEqual(dag.nodes.map(\.nodeId), ["research", "plan", "review:0", "review:1"])
        XCTAssertEqual(
            dag.edges,
            [
                WorkflowDAGEdge(from: "research", to: "plan"),
                WorkflowDAGEdge(from: "plan", to: "review:0"),
                WorkflowDAGEdge(from: "plan", to: "review:1"),
            ]
        )
        XCTAssertNil(dag.fields)
    }
}
