import XCTest
@testable import SmithersGUI

// MARK: - Approval Tests

final class ApprovalTests: XCTestCase {

    private func makeApproval(
        status: String = "pending",
        requestedAt: Int64 = 1700000000000,
        source: String? = nil
    ) -> Approval {
        Approval(
            id: "a1",
            runId: "r1",
            nodeId: "n1",
            status: status,
            requestedAt: requestedAt,
            source: source
        )
    }

    func testIsPendingTrue() {
        XCTAssertTrue(makeApproval(status: "pending").isPending)
    }

    func testIsPendingFalseForApproved() {
        XCTAssertFalse(makeApproval(status: "approved").isPending)
    }

    func testIsPendingFalseForDenied() {
        XCTAssertFalse(makeApproval(status: "denied").isPending)
    }

    func testIsPendingTrimsWhitespace() {
        XCTAssertTrue(makeApproval(status: "  pending  ").isPending)
    }

    func testIsPendingCaseInsensitive() {
        XCTAssertTrue(makeApproval(status: "Pending").isPending)
        XCTAssertTrue(makeApproval(status: "PENDING").isPending)
    }

    func testRequestedDate() {
        let a = makeApproval(requestedAt: 1700000000000)
        XCTAssertEqual(a.requestedDate.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testIsSyntheticFallbackTrue() {
        XCTAssertTrue(makeApproval(source: "synthetic").isSyntheticFallback)
    }

    func testIsSyntheticFallbackFalse() {
        XCTAssertFalse(makeApproval(source: "http").isSyntheticFallback)
    }

    func testIsSyntheticFallbackNil() {
        XCTAssertFalse(makeApproval(source: nil).isSyntheticFallback)
    }

    func testIsSyntheticFallbackCaseInsensitive() {
        XCTAssertTrue(makeApproval(source: "  Synthetic  ").isSyntheticFallback)
    }

    func testFilterPendingApprovals() {
        let approvals = [
            makeApproval(status: "pending"),
            makeApproval(status: "approved"),
            makeApproval(status: "pending"),
            makeApproval(status: "denied"),
        ]
        XCTAssertEqual(approvals.filterPendingApprovals().count, 2)
    }

    func testApprovalCodable() throws {
        let json = """
        {"id":"a1","runId":"r1","nodeId":"n1","status":"pending","requestedAt":1700000000000}
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Approval.self, from: json)
        XCTAssertEqual(a.id, "a1")
        XCTAssertEqual(a.status, "pending")
    }

    func testWaitTimeReturnsNonEmpty() {
        let a = makeApproval(requestedAt: Int64(Date().timeIntervalSince1970 * 1000) - 5000)
        XCTAssertFalse(a.waitTime.isEmpty)
    }
}

// MARK: - ApprovalDecision Tests

final class ApprovalDecisionTests: XCTestCase {

    func testDecisionDecodesFromCamelCaseKeys() throws {
        let json = """
        {"id":"d1","runId":"r1","nodeId":"n1","action":"approved"}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(d.action, "approved")
    }

    func testDecisionDecodesFromSnakeCaseKeys() throws {
        let json = """
        {"id":"d2","run_id":"r2","node_id":"n2","decision":"denied"}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(d.runId, "r2")
        XCTAssertEqual(d.nodeId, "n2")
        XCTAssertEqual(d.action, "denied")
    }

    func testDecisionDefaultsToApproved() throws {
        let json = """
        {"id":"d3","runId":"r3","nodeId":"n3"}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(d.action, "approved")
    }

    func testDecisionResolvedAtFromMultipleKeys() throws {
        let json = """
        {"id":"d4","runId":"r4","nodeId":"n4","action":"approved","decided_at":1700000000000}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(d.resolvedAt, 1700000000000)
    }

    func testDecisionSourceFromTransportSource() throws {
        let json = """
        {"id":"d5","runId":"r5","nodeId":"n5","action":"approved","transport_source":"http"}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ApprovalDecision.self, from: json)
        XCTAssertEqual(d.source, "http")
    }

    func testDecisionEncodeDecode() throws {
        let original = ApprovalDecision(id: "d6", runId: "r6", nodeId: "n6", action: "denied", note: "bad")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ApprovalDecision.self, from: data)
        XCTAssertEqual(decoded.id, "d6")
        XCTAssertEqual(decoded.action, "denied")
        XCTAssertEqual(decoded.note, "bad")
    }
}

// MARK: - WorkflowDAG Tests

final class WorkflowDAGTests: XCTestCase {

    func testEmptyDAG() {
        let dag = WorkflowDAG()
        XCTAssertTrue(dag.isEmpty)
        XCTAssertTrue(dag.nodes.isEmpty)
        XCTAssertTrue(dag.edges.isEmpty)
    }

    func testNonEmptyDAGWithTasks() {
        let dag = WorkflowDAG(tasks: [
            WorkflowDAGTask(nodeId: "a", ordinal: 1),
            WorkflowDAGTask(nodeId: "b", ordinal: 2),
        ])
        XCTAssertFalse(dag.isEmpty)
        XCTAssertEqual(dag.nodes.count, 2)
        XCTAssertEqual(dag.nodes[0].nodeId, "a")
    }

    func testNodesSortedByOrdinal() {
        let dag = WorkflowDAG(tasks: [
            WorkflowDAGTask(nodeId: "b", ordinal: 3),
            WorkflowDAGTask(nodeId: "a", ordinal: 1),
            WorkflowDAGTask(nodeId: "c", ordinal: 2),
        ])
        XCTAssertEqual(dag.nodes.map(\.nodeId), ["a", "c", "b"])
    }

    func testNodesSortedByNameWhenOrdinalEqual() {
        let dag = WorkflowDAG(tasks: [
            WorkflowDAGTask(nodeId: "b"),
            WorkflowDAGTask(nodeId: "a"),
        ])
        XCTAssertEqual(dag.nodes.map(\.nodeId), ["a", "b"])
    }

    func testSequentialEdgesWithoutXML() {
        let dag = WorkflowDAG(tasks: [
            WorkflowDAGTask(nodeId: "a", ordinal: 1),
            WorkflowDAGTask(nodeId: "b", ordinal: 2),
            WorkflowDAGTask(nodeId: "c", ordinal: 3),
        ])
        let edges = dag.edges
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges[0].from, "a")
        XCTAssertEqual(edges[0].to, "b")
        XCTAssertEqual(edges[1].from, "b")
        XCTAssertEqual(edges[1].to, "c")
    }

    func testSingleTaskNoEdges() {
        let dag = WorkflowDAG(tasks: [WorkflowDAGTask(nodeId: "solo")])
        XCTAssertTrue(dag.edges.isEmpty)
    }

    func testResolvedEntryTaskID() {
        let dag = WorkflowDAG(entryTaskID: "eid")
        XCTAssertEqual(dag.resolvedEntryTaskID, "eid")
    }

    func testResolvedEntryTaskIDFallsBackToEntryTask() {
        let dag = WorkflowDAG(entryTask: "et", fields: nil)
        XCTAssertEqual(dag.resolvedEntryTaskID, "et")
    }

    func testLaunchFieldsEmpty() {
        let dag = WorkflowDAG()
        XCTAssertTrue(dag.launchFields.isEmpty)
    }

    func testLaunchFieldsPresent() {
        let dag = WorkflowDAG(fields: [
            WorkflowLaunchField(name: "input", key: "k", type: "string", defaultValue: nil)
        ])
        XCTAssertEqual(dag.launchFields.count, 1)
    }

    func testIsFallbackMode() {
        let dag = WorkflowDAG(mode: "fallback")
        XCTAssertTrue(dag.isFallbackMode)
    }

    func testIsNotFallbackMode() {
        let dag = WorkflowDAG(mode: "normal")
        XCTAssertFalse(dag.isFallbackMode)
    }

    func testIsFallbackModeCaseInsensitive() {
        let dag = WorkflowDAG(mode: " Fallback ")
        XCTAssertTrue(dag.isFallbackMode)
    }

    func testEdgeId() {
        let edge = WorkflowDAGEdge(from: "a", to: "b")
        XCTAssertEqual(edge.id, "a->b")
    }

    func testEdgeEquality() {
        let a = WorkflowDAGEdge(from: "x", to: "y")
        let b = WorkflowDAGEdge(from: "x", to: "y")
        XCTAssertEqual(a, b)
    }
}

// MARK: - WorkflowDAGTask Tests

final class WorkflowDAGTaskTests: XCTestCase {

    func testTaskIdIsNodeId() {
        let task = WorkflowDAGTask(nodeId: "node1")
        XCTAssertEqual(task.id, "node1:0")
    }

    func testTaskIdIncludesIteration() {
        let task = WorkflowDAGTask(nodeId: "node1", iteration: 3)
        XCTAssertEqual(task.id, "node1:3")
    }

    func testLossyIntDecoding() throws {
        let json = """
        {"nodeId":"n1","ordinal":"5","retries":"3","timeoutMs":"10000"}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WorkflowDAGTask.self, from: json)
        XCTAssertEqual(task.ordinal, 5)
        XCTAssertEqual(task.retries, 3)
        XCTAssertEqual(task.timeoutMs, 10000)
    }

    func testLossyBoolDecoding() throws {
        let json = """
        {"nodeId":"n1","needsApproval":"true","continueOnFail":"false"}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WorkflowDAGTask.self, from: json)
        XCTAssertEqual(task.needsApproval, true)
        XCTAssertEqual(task.continueOnFail, false)
    }

    func testLossyBoolYesNo() throws {
        let json = """
        {"nodeId":"n1","needsApproval":"yes","continueOnFail":"no"}
        """.data(using: .utf8)!
        let task = try JSONDecoder().decode(WorkflowDAGTask.self, from: json)
        XCTAssertEqual(task.needsApproval, true)
        XCTAssertEqual(task.continueOnFail, false)
    }
}

// MARK: - WorkflowLaunchField Tests

final class WorkflowLaunchFieldTests: XCTestCase {

    func testDecodesLabelAsName() throws {
        let json = """
        {"key":"k1","label":"My Label"}
        """.data(using: .utf8)!
        let field = try JSONDecoder().decode(WorkflowLaunchField.self, from: json)
        XCTAssertEqual(field.name, "My Label")
    }

    func testNameTakesPrecedenceOverLabel() throws {
        let json = """
        {"key":"k1","name":"Name","label":"Label"}
        """.data(using: .utf8)!
        let field = try JSONDecoder().decode(WorkflowLaunchField.self, from: json)
        XCTAssertEqual(field.name, "Name")
    }

    func testFallsBackToKeyForName() throws {
        let json = """
        {"key":"myKey"}
        """.data(using: .utf8)!
        let field = try JSONDecoder().decode(WorkflowLaunchField.self, from: json)
        XCTAssertEqual(field.name, "myKey")
    }

    func testEncodeDecode() throws {
        let field = WorkflowLaunchField(name: "N", key: "K", type: "string", defaultValue: "hello")
        let data = try JSONEncoder().encode(field)
        let decoded = try JSONDecoder().decode(WorkflowLaunchField.self, from: data)
        XCTAssertEqual(decoded.name, "N")
        XCTAssertEqual(decoded.key, "K")
        XCTAssertEqual(decoded.type, "string")
        XCTAssertEqual(decoded.defaultValue, "hello")
    }
}

// MARK: - ScoreRow Tests

final class ScoreRowTests: XCTestCase {

    func testScoredAt() {
        let json = """
        {"id":"s1","score":0.95,"scoredAtMs":1700000000000}
        """.data(using: .utf8)!
        let row = try! JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(row.scoredAt.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
    }

    func testScorerDisplayNameFromName() {
        let json = """
        {"id":"s1","score":0.5,"scoredAtMs":1000,"scorerName":"MyScorer"}
        """.data(using: .utf8)!
        let row = try! JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(row.scorerDisplayName, "MyScorer")
    }

    func testScorerDisplayNameFallsToId() {
        let json = """
        {"id":"s1","score":0.5,"scoredAtMs":1000,"scorerId":"sid1"}
        """.data(using: .utf8)!
        let row = try! JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(row.scorerDisplayName, "sid1")
    }

    func testScorerDisplayNameUnknown() {
        let json = """
        {"id":"s1","score":0.5,"scoredAtMs":1000}
        """.data(using: .utf8)!
        let row = try! JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(row.scorerDisplayName, "Unknown")
    }

    func testScorerDisplayNameSkipsBlank() {
        let json = """
        {"id":"s1","score":0.5,"scoredAtMs":1000,"scorerName":"  ","scorerId":"real"}
        """.data(using: .utf8)!
        let row = try! JSONDecoder().decode(ScoreRow.self, from: json)
        XCTAssertEqual(row.scorerDisplayName, "real")
    }
}

// MARK: - AggregateScore Tests

final class AggregateScoreTests: XCTestCase {

    private func makeScore(scorer: String, score: Double) -> ScoreRow {
        let json = """
        {"id":"\(UUID().uuidString)","score":\(score),"scoredAtMs":1000,"scorerName":"\(scorer)"}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(ScoreRow.self, from: json)
    }

    func testAggregateEmpty() {
        XCTAssertTrue(AggregateScore.aggregate([]).isEmpty)
    }

    func testAggregateSingleScorer() {
        let scores = [makeScore(scorer: "A", score: 0.8), makeScore(scorer: "A", score: 0.6)]
        let aggs = AggregateScore.aggregate(scores)
        XCTAssertEqual(aggs.count, 1)
        XCTAssertEqual(aggs[0].count, 2)
        XCTAssertEqual(aggs[0].mean, 0.7, accuracy: 0.001)
        XCTAssertEqual(aggs[0].min, 0.6, accuracy: 0.001)
        XCTAssertEqual(aggs[0].max, 0.8, accuracy: 0.001)
    }

    func testAggregateMultipleScorers() {
        let scores = [
            makeScore(scorer: "B", score: 0.5),
            makeScore(scorer: "A", score: 0.9),
        ]
        let aggs = AggregateScore.aggregate(scores)
        XCTAssertEqual(aggs.count, 2)
        // Sorted by name
        XCTAssertEqual(aggs[0].scorerName, "A")
        XCTAssertEqual(aggs[1].scorerName, "B")
    }

    func testAggregateP50OddCount() {
        let scores = [makeScore(scorer: "A", score: 1), makeScore(scorer: "A", score: 2), makeScore(scorer: "A", score: 3)]
        let aggs = AggregateScore.aggregate(scores)
        XCTAssertEqual(aggs[0].p50!, 2.0, accuracy: 0.001)
    }

    func testAggregateP50EvenCount() {
        let scores = [makeScore(scorer: "A", score: 1), makeScore(scorer: "A", score: 3)]
        let aggs = AggregateScore.aggregate(scores)
        XCTAssertEqual(aggs[0].p50!, 2.0, accuracy: 0.001)
    }
}

// MARK: - TokenMetrics Tests

final class TokenMetricsTests: XCTestCase {

    func testCacheHitRateNilWhenZeroTokens() {
        let m = TokenMetrics()
        XCTAssertNil(m.cacheHitRate)
    }

    func testCacheHitRateCalculation() {
        let m = TokenMetrics(totalTokens: 100, cacheReadTokens: 25)
        XCTAssertEqual(m.cacheHitRate!, 0.25, accuracy: 0.001)
    }

    func testTokenMetricsDecodesSnakeCase() throws {
        let json = """
        {"total_input_tokens":100,"total_output_tokens":50,"total_tokens":150,"cache_read_tokens":20,"cache_write_tokens":10}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(TokenMetrics.self, from: json)
        XCTAssertEqual(m.totalInputTokens, 100)
        XCTAssertEqual(m.totalOutputTokens, 50)
        XCTAssertEqual(m.totalTokens, 150)
        XCTAssertEqual(m.cacheReadTokens, 20)
        XCTAssertEqual(m.cacheWriteTokens, 10)
    }

    func testTokenMetricsTotalTokensFallbackToSum() throws {
        let json = """
        {"totalInputTokens":60,"totalOutputTokens":40}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(TokenMetrics.self, from: json)
        XCTAssertEqual(m.totalTokens, 100)
    }
}

// MARK: - CostReport Tests

final class CostReportTests: XCTestCase {

    func testCostReportDecodesSnakeCase() throws {
        let json = """
        {"total_cost_usd":1.5,"input_cost_usd":0.5,"output_cost_usd":1.0,"run_count":10}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(CostReport.self, from: json)
        XCTAssertEqual(r.totalCostUSD, 1.5, accuracy: 0.001)
        XCTAssertEqual(r.runCount, 10)
    }

    func testCostReportDecodesCamelCase() throws {
        let json = """
        {"totalCostUsd":2.0,"inputCostUsd":0.8,"outputCostUsd":1.2,"runCount":5}
        """.data(using: .utf8)!
        let r = try JSONDecoder().decode(CostReport.self, from: json)
        XCTAssertEqual(r.totalCostUSD, 2.0, accuracy: 0.001)
        XCTAssertEqual(r.runCount, 5)
    }
}

// MARK: - LatencyMetrics Tests

final class LatencyMetricsTests: XCTestCase {

    func testLatencyMetricsDefaults() {
        let m = LatencyMetrics()
        XCTAssertEqual(m.count, 0)
        XCTAssertEqual(m.meanMs, 0)
    }

    func testLatencyMetricsDecodesSnakeCase() throws {
        let json = """
        {"count":10,"mean_ms":50.5,"min_ms":10.0,"max_ms":200.0,"p50_ms":45.0,"p95_ms":180.0}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(LatencyMetrics.self, from: json)
        XCTAssertEqual(m.count, 10)
        XCTAssertEqual(m.meanMs, 50.5, accuracy: 0.001)
        XCTAssertEqual(m.p95Ms, 180.0, accuracy: 0.001)
    }
}

// MARK: - CodexAuthState Additional Tests

final class CodexAuthStateAdditionalTests: XCTestCase {

    func testIsReadyWithAuthFile() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: true, hasAPIKey: false, authFilePath: "/tmp")
        XCTAssertTrue(s.isReady)
    }

    func testIsReadyWithAPIKey() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: false, hasAPIKey: true, authFilePath: "/tmp")
        XCTAssertTrue(s.isReady)
    }

    func testNotReadyWithNeither() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: false, hasAPIKey: false, authFilePath: "/tmp")
        XCTAssertFalse(s.isReady)
    }

    func testModeLabelBoth() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: true, hasAPIKey: true, authFilePath: "/tmp")
        XCTAssertEqual(s.modeLabel, "ChatGPT + API key")
    }

    func testModeLabelChatGPTOnly() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: true, hasAPIKey: false, authFilePath: "/tmp")
        XCTAssertEqual(s.modeLabel, "ChatGPT")
    }

    func testModeLabelAPIKeyOnly() {
        let s = CodexAuthState(hasCodexCLI: true, codexCLIPath: nil, hasAuthFile: false, hasAPIKey: true, authFilePath: "/tmp")
        XCTAssertEqual(s.modeLabel, "API key")
    }

    func testModeLabelNotConfigured() {
        let s = CodexAuthState(hasCodexCLI: false, codexCLIPath: nil, hasAuthFile: false, hasAPIKey: false, authFilePath: "/tmp")
        XCTAssertEqual(s.modeLabel, "Not configured")
    }
}

// MARK: - WorkflowStatus Tests

final class WorkflowStatusTests: XCTestCase {

    func testAllCases() {
        let json = [#""draft""#, #""active""#, #""hot""#, #""archived""#]
        for j in json {
            let decoded = try! JSONDecoder().decode(WorkflowStatus.self, from: Data(j.utf8))
            XCTAssertNotNil(decoded)
        }
    }
}

// MARK: - RunSummary Sorting Tests

final class RunSummarySortingTests: XCTestCase {

    private func run(id: String, startedAtMs: Int64?) -> RunSummary {
        let json: String
        if let ms = startedAtMs {
            json = """
            {"runId":"\(id)","status":"finished","startedAtMs":\(ms)}
            """
        } else {
            json = """
            {"runId":"\(id)","status":"finished"}
            """
        }
        return try! JSONDecoder().decode(RunSummary.self, from: Data(json.utf8))
    }

    func testSortedByStartedAtDescending() {
        let runs = [
            run(id: "old", startedAtMs: 1000),
            run(id: "new", startedAtMs: 3000),
            run(id: "mid", startedAtMs: 2000),
        ]
        let sorted = runs.sortedByStartedAtDescending()
        XCTAssertEqual(sorted.map(\.id), ["new", "mid", "old"])
    }

    func testNilStartedAtSortedLast() {
        let runs = [
            run(id: "nil1", startedAtMs: nil),
            run(id: "has", startedAtMs: 1000),
            run(id: "nil2", startedAtMs: nil),
        ]
        let sorted = runs.sortedByStartedAtDescending()
        XCTAssertEqual(sorted[0].id, "has")
    }

    func testStableSortForEqualTimestamps() {
        let runs = [
            run(id: "first", startedAtMs: 1000),
            run(id: "second", startedAtMs: 1000),
        ]
        let sorted = runs.sortedByStartedAtDescending()
        XCTAssertEqual(sorted[0].id, "first")
        XCTAssertEqual(sorted[1].id, "second")
    }
}

// MARK: - RunSummary ElapsedString Additional Tests

final class RunSummaryElapsedStringAdditionalTests: XCTestCase {

    func testElapsedStringEmpty() {
        let json = """
        {"runId":"r1","status":"running"}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testElapsedStringSeconds() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r1","status":"running","startedAtMs":\(now - 30000)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.hasSuffix("s"))
    }

    func testElapsedStringMinutes() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r1","status":"running","startedAtMs":\(now - 120_000)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.contains("m"))
    }

    func testElapsedStringHours() {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r1","status":"running","startedAtMs":\(now - 7_200_000)}
        """.data(using: .utf8)!
        let run = try! JSONDecoder().decode(RunSummary.self, from: json)
        XCTAssertTrue(run.elapsedString.contains("h"))
    }
}

// MARK: - PromptInput Tests

final class PromptInputTests: XCTestCase {

    func testDecodesDefaultValueKey() throws {
        let json = """
        {"name":"input1","type":"string","default":"hello"}
        """.data(using: .utf8)!
        let input = try JSONDecoder().decode(PromptInput.self, from: json)
        XCTAssertEqual(input.defaultValue, "hello")
    }

    func testDecodesDefaultValueAltKey() throws {
        let json = """
        {"name":"input1","defaultValue":"world"}
        """.data(using: .utf8)!
        let input = try JSONDecoder().decode(PromptInput.self, from: json)
        XCTAssertEqual(input.defaultValue, "world")
    }

    func testIdIsName() {
        let input = PromptInput(name: "myInput", type: nil, defaultValue: nil)
        XCTAssertEqual(input.id, "myInput")
    }
}

// MARK: - WorkflowDoctorIssue Tests

final class WorkflowDoctorIssueTests: XCTestCase {

    func testIdIsComposite() throws {
        let json = """
        {"severity":"error","check":"auth","message":"missing token"}
        """.data(using: .utf8)!
        let issue = try JSONDecoder().decode(WorkflowDoctorIssue.self, from: json)
        XCTAssertEqual(issue.id, "auth:error:missing token")
    }
}
