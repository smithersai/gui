import XCTest
@testable import SmithersGUI

final class DevToolsInputValidatorTests: XCTestCase {
    func testValidRunIdPasses() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(runId: "run-1776372721752"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(runId: "abc_XYZ-123"))
    }

    func testEmptyRunIdRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "")) { err in
            XCTAssertEqual(err as? DevToolsClientError, .invalidRunId(""))
        }
    }

    func testRunIdWithSpecialCharsRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "abc;rm -rf /"))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "a'b"))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(runId: "a/b"))
    }

    func testValidNodeIdPasses() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "s10:implement"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "node:review:0"))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(nodeId: "task_1-alt"))
    }

    func testNodeIdWithSpaceRejected() {
        XCTAssertThrowsError(try DevToolsInputValidator.validate(nodeId: "bad node id"))
    }

    func testIterationValidation() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(iteration: 0))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(iteration: 42))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(iteration: -1)) { err in
            XCTAssertEqual(err as? DevToolsClientError, .invalidIteration(-1))
        }
    }

    func testFrameNoValidation() throws {
        XCTAssertNoThrow(try DevToolsInputValidator.validate(frameNo: 0))
        XCTAssertNoThrow(try DevToolsInputValidator.validate(frameNo: 9999))
        XCTAssertThrowsError(try DevToolsInputValidator.validate(frameNo: -1))
    }
}

final class DevToolsSQLEscapeTests: XCTestCase {
    func testBasicQuote() {
        XCTAssertEqual(DevToolsSQL.quote("abc"), "'abc'")
    }

    func testEscapesApostrophes() {
        XCTAssertEqual(DevToolsSQL.quote("O'Brien"), "'O''Brien'")
        XCTAssertEqual(DevToolsSQL.quote("';DROP TABLE users--"), "''';DROP TABLE users--'")
    }
}

final class DevToolsTreeBuilderTests: XCTestCase {
    private func decodeXML(_ json: String) throws -> DevToolsFrameXMLNode {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(DevToolsFrameXMLNode.self, from: data)
    }

    func testSimpleWorkflowConverts() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{"name":"main"},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"main"},"children":[]}
          ]}
        ]}
        """
        let xml = try decodeXML(json)
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [])
        XCTAssertEqual(tree.type, .workflow)
        XCTAssertEqual(tree.name, "main")
        XCTAssertEqual(tree.children.count, 1)
        XCTAssertEqual(tree.children[0].type, .sequence)
        XCTAssertEqual(tree.children[0].children.count, 1)
        XCTAssertEqual(tree.children[0].children[0].type, .task)
        XCTAssertEqual(tree.children[0].children[0].name, "main")
    }

    func testTaskIndexHoisted() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"s10:implement"},"children":[]}
        ]}
        """
        let xml = try decodeXML(json)
        let idx: [DevToolsTaskIndexEntry] = {
            let data = Data("""
            [{"nodeId":"s10:implement","ordinal":0,"iteration":0,"outputTableName":"implement"}]
            """.utf8)
            return (try? JSONDecoder().decode([DevToolsTaskIndexEntry].self, from: data)) ?? []
        }()
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: idx)
        let task = tree.children[0]
        XCTAssertNotNil(task.task)
        XCTAssertEqual(task.task?.nodeId, "s10:implement")
        XCTAssertEqual(task.task?.outputTableName, "implement")
    }

    func testAssignsUniqueIds() throws {
        let json = """
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
          {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}
        ]}
        """
        let xml = try decodeXML(json)
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [])
        var seen = Set<Int>()
        func walk(_ node: DevToolsNode) {
            seen.insert(node.id)
            for c in node.children { walk(c) }
        }
        walk(tree)
        XCTAssertEqual(seen.count, 3, "root + 2 tasks should each get a unique id")
    }

    // MARK: - Node-state population / rollup

    func testTaskNodeDefaultsToPendingWhenNoEntry() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"missing"},"children":[]}
        ]}
        """)
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: [:])
        XCTAssertEqual(extractState(from: tree.children[0]), .pending)
        XCTAssertNotEqual(
            extractState(from: tree.children[0]), .unknown,
            "Missing node-state entry must render as pending, not unknown"
        )
    }

    func testTaskNodeStatePopulatedFromDict() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"g74:implement"},"children":[]},
          {"kind":"element","tag":"smithers:task","props":{"id":"g74:review:0"},"children":[]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "g74:implement": .init(nodeId: "g74:implement", state: "finished", iteration: 0, lastAttempt: 1),
            "g74:review:0": .init(nodeId: "g74:review:0", state: "in-progress", iteration: 0, lastAttempt: 1),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        XCTAssertEqual(extractState(from: tree.children[0]), .finished)
        XCTAssertEqual(
            extractState(from: tree.children[1]), .running,
            "`in-progress` from DB should normalize to `running`"
        )
    }

    func testSkippedStateNormalizesToCancelled() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"s1"},"children":[]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "s1": .init(nodeId: "s1", state: "skipped", iteration: 0, lastAttempt: nil),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        XCTAssertEqual(extractState(from: tree.children[0]), .cancelled)
    }

    func testStructuralNodeRollsUpFailedOverRunning() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
            {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]},
            {"kind":"element","tag":"smithers:task","props":{"id":"c"},"children":[]}
          ]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "a": .init(nodeId: "a", state: "finished", iteration: 0, lastAttempt: 1),
            "b": .init(nodeId: "b", state: "in-progress", iteration: 0, lastAttempt: 1),
            "c": .init(nodeId: "c", state: "failed", iteration: 0, lastAttempt: 1),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        let sequence = tree.children[0]
        XCTAssertEqual(extractState(from: sequence), .failed)
        XCTAssertEqual(
            extractState(from: tree), .failed,
            "Workflow should also roll up to failed when any descendant failed"
        )
    }

    func testStructuralNodeRollsUpToFinishedWhenAllChildrenFinished() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
            {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}
          ]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "a": .init(nodeId: "a", state: "finished", iteration: 0, lastAttempt: 1),
            "b": .init(nodeId: "b", state: "finished", iteration: 0, lastAttempt: 1),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        XCTAssertEqual(extractState(from: tree.children[0]), .finished)
        XCTAssertEqual(extractState(from: tree), .finished)
    }

    func testRollupIgnoresCancelledWhenSiblingsFinished() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
          {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "a": .init(nodeId: "a", state: "finished", iteration: 0, lastAttempt: 1),
            "b": .init(nodeId: "b", state: "skipped", iteration: 0, lastAttempt: 1),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        XCTAssertEqual(extractState(from: tree), .finished)
    }

    func testStateMakeDictPrefersHighestIteration() {
        let rows: [[String: Any]] = [
            ["node_id": "g74:review:0", "state": "failed", "iteration": NSNumber(value: 0), "last_attempt": NSNumber(value: 1)],
            ["node_id": "g74:review:0", "state": "finished", "iteration": NSNumber(value: 1), "last_attempt": NSNumber(value: 2)],
            ["node_id": "g74:implement", "state": "running", "iteration": NSNumber(value: 0), "last_attempt": NSNumber(value: 1)],
        ]
        let dict = DevToolsNodeStateQuery.makeDict(fromRows: rows)
        XCTAssertEqual(dict.count, 2)
        XCTAssertEqual(dict["g74:review:0"]?.state, "finished")
        XCTAssertEqual(dict["g74:review:0"]?.iteration, 1)
        XCTAssertEqual(dict["g74:implement"]?.state, "running")
    }

    func testNormalizeDevToolsNodeStateCoversKnownAliases() {
        XCTAssertEqual(normalizeDevToolsNodeState("in-progress"), "running")
        XCTAssertEqual(normalizeDevToolsNodeState("in_progress"), "running")
        XCTAssertEqual(normalizeDevToolsNodeState("started"), "running")
        XCTAssertEqual(normalizeDevToolsNodeState("running"), "running")
        XCTAssertEqual(normalizeDevToolsNodeState("complete"), "finished")
        XCTAssertEqual(normalizeDevToolsNodeState("done"), "finished")
        XCTAssertEqual(normalizeDevToolsNodeState("error"), "failed")
        XCTAssertEqual(normalizeDevToolsNodeState("errored"), "failed")
        XCTAssertEqual(normalizeDevToolsNodeState("skipped"), "cancelled")
        XCTAssertEqual(normalizeDevToolsNodeState(""), "pending")
        XCTAssertEqual(normalizeDevToolsNodeState("blocked"), "blocked")
        XCTAssertEqual(normalizeDevToolsNodeState("waiting-approval"), "waitingApproval")
    }

    func testNodeStateQuerySelectsRunId() {
        let sql = DevToolsNodeStateQuery.query(runId: "run-1776372721752")
        XCTAssertTrue(sql.contains("_smithers_nodes"), "query must target _smithers_nodes table")
        XCTAssertTrue(sql.contains("'run-1776372721752'"), "query must include quoted run id")
        XCTAssertTrue(sql.contains("node_id"), "query must project node_id")
        XCTAssertTrue(sql.contains("state"), "query must project state")
    }

    func testExistingStatePropFromXMLIsPreservedOverNodeStateDict() throws {
        // A delta may have already written `state="running"` onto the XML prop.
        // In that case the transport-side dict should NOT overwrite it, because the
        // frame-level truth (what the scrubber is pointing at) wins over the latest
        // DB state when both are present.
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a","state":"running"},"children":[]}
        ]}
        """)
        let states: [String: DevToolsNodeStateEntry] = [
            "a": .init(nodeId: "a", state: "finished", iteration: 0, lastAttempt: 1),
        ]
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        XCTAssertEqual(extractState(from: tree.children[0]), .running)
    }
}

// MARK: - Per-frame historical state reconstruction

/// Tests for the historical-scrubber fix. Uses `devToolsNodeStatesAtTimestamp` —
/// the same function the transport uses to compute per-node state at a specific
/// wall-clock timestamp from `_smithers_attempts` rows.
///
/// The canonical scenario is a sequence of three tasks that run in series:
/// - `a` runs t=100→200
/// - `b` runs t=200→400 (in flight at t=300)
/// - `c` runs t=400→500
///
/// Expected per-frame behaviour:
/// - t < 100   → nothing started, all nodes "pending" (absent from dict)
/// - t = 300   → a finished, b running, c pending
/// - t > 500   → all finished (equivalent to the old "final state" behaviour)
final class DevToolsPerFrameStateTests: XCTestCase {
    private func makeAttempts() -> [DevToolsAttemptEntry] {
        [
            DevToolsAttemptEntry(
                nodeId: "a", iteration: 0, attempt: 1,
                state: "finished",
                startedAtMs: 100, finishedAtMs: 200
            ),
            DevToolsAttemptEntry(
                nodeId: "b", iteration: 0, attempt: 1,
                state: "finished",
                startedAtMs: 200, finishedAtMs: 400
            ),
            DevToolsAttemptEntry(
                nodeId: "c", iteration: 0, attempt: 1,
                state: "finished",
                startedAtMs: 400, finishedAtMs: 500
            ),
        ]
    }

    func testFrameBeforeAnyNodeStartsYieldsEmptyDict() {
        let attempts = makeAttempts()
        // Use a timestamp earlier than the earliest attempt's started_at_ms.
        let result = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 50)
        XCTAssertTrue(
            result.isEmpty,
            "No attempts started before the frame → caller treats all nodes as pending"
        )
    }

    func testFrameBeforeAnyNodeStartsTreeMarksAllPending() throws {
        // End-to-end: wire the empty state dict through DevToolsTreeBuilder and
        // assert the task row renders as `.pending`, matching the UX contract.
        let attempts = makeAttempts()
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 50)

        let xml = try JSONDecoder().decode(
            DevToolsFrameXMLNode.self,
            from: Data("""
            {"kind":"element","tag":"smithers:workflow","props":{},"children":[
              {"kind":"element","tag":"smithers:sequence","props":{},"children":[
                {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
                {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]},
                {"kind":"element","tag":"smithers:task","props":{"id":"c"},"children":[]}
              ]}
            ]}
            """.utf8)
        )
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        let seq = tree.children[0]
        XCTAssertEqual(extractState(from: seq.children[0]), .pending)
        XCTAssertEqual(extractState(from: seq.children[1]), .pending)
        XCTAssertEqual(extractState(from: seq.children[2]), .pending)
        XCTAssertEqual(extractState(from: seq), .pending, "parent rolls up to pending")
    }

    func testFrameDuringExecutionMarksMiddleNodeRunning() {
        // t=300: a finished (200 < 300), b running (200 < 300 < 400), c pending.
        let attempts = makeAttempts()
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 300)

        XCTAssertEqual(states["a"]?.state, "finished", "a completed by t=200 which is ≤ t=300")
        XCTAssertEqual(
            states["b"]?.state, "running",
            "b started at t=200 and hadn't finished by t=300 → running"
        )
        XCTAssertNil(states["c"], "c hadn't started by t=300 → absent (caller treats as pending)")
    }

    func testFrameDuringExecutionTreeMarksMiddleNodeRunning() throws {
        // Same scenario end-to-end through the tree builder.
        let attempts = makeAttempts()
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 300)
        let xml = try JSONDecoder().decode(
            DevToolsFrameXMLNode.self,
            from: Data("""
            {"kind":"element","tag":"smithers:workflow","props":{},"children":[
              {"kind":"element","tag":"smithers:sequence","props":{},"children":[
                {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},
                {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]},
                {"kind":"element","tag":"smithers:task","props":{"id":"c"},"children":[]}
              ]}
            ]}
            """.utf8)
        )
        let tree = DevToolsTreeBuilder.build(xml: xml, taskIndex: [], nodeStates: states)
        let seq = tree.children[0]
        XCTAssertEqual(extractState(from: seq.children[0]), .finished)
        XCTAssertEqual(extractState(from: seq.children[1]), .running)
        XCTAssertEqual(extractState(from: seq.children[2]), .pending)
        // Running beats pending / finished in the rollup precedence.
        XCTAssertEqual(extractState(from: seq), .running)
    }

    func testFrameAfterAllCompletedMatchesFinalState() {
        // After t=500, every attempt has finished and finished ≤ frame. This is the
        // "equivalent to current behaviour" case — the scrubber at the last frame
        // should reflect the terminal state.
        let attempts = makeAttempts()
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 1_000)

        XCTAssertEqual(states["a"]?.state, "finished")
        XCTAssertEqual(states["b"]?.state, "finished")
        XCTAssertEqual(states["c"]?.state, "finished")
    }

    func testInFlightAttemptWithNullFinishedIsRunning() {
        // Simulate a crash: an attempt started but never wrote finished_at_ms.
        // At any timestamp ≥ startedAt the node should be running until another
        // later attempt supersedes it.
        let attempts = [
            DevToolsAttemptEntry(
                nodeId: "x", iteration: 0, attempt: 1,
                state: "running",
                startedAtMs: 100, finishedAtMs: nil
            )
        ]
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 500)
        XCTAssertEqual(states["x"]?.state, "running")
    }

    func testLaterAttemptSupersedesEarlier() {
        // Retry: first attempt failed, second finished. At a frame after both we
        // want the latest attempt's terminal state, mirroring `_smithers_nodes`.
        let attempts = [
            DevToolsAttemptEntry(
                nodeId: "r", iteration: 0, attempt: 1,
                state: "failed",
                startedAtMs: 100, finishedAtMs: 200
            ),
            DevToolsAttemptEntry(
                nodeId: "r", iteration: 0, attempt: 2,
                state: "finished",
                startedAtMs: 300, finishedAtMs: 400
            ),
        ]
        let states = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 500)
        XCTAssertEqual(states["r"]?.state, "finished")
        XCTAssertEqual(states["r"]?.lastAttempt, 2)

        // But at t=250 (between attempts) the latest started attempt is #1, which
        // had already failed by then.
        let midStates = devToolsNodeStatesAtTimestamp(attempts: attempts, frameTimestampMs: 250)
        XCTAssertEqual(midStates["r"]?.state, "failed")
        XCTAssertEqual(midStates["r"]?.lastAttempt, 1)
    }

    func testAttemptQueryShapeIncludesRequiredColumns() {
        let sql = DevToolsAttemptQuery.query(runId: "run-1776372721752")
        XCTAssertTrue(sql.contains("_smithers_attempts"), "query must target _smithers_attempts")
        XCTAssertTrue(sql.contains("'run-1776372721752'"), "query must include quoted run id")
        XCTAssertTrue(sql.contains("node_id"))
        XCTAssertTrue(sql.contains("started_at_ms"))
        XCTAssertTrue(sql.contains("finished_at_ms"))
        XCTAssertTrue(sql.contains("state"))
    }

    func testAttemptQueryMakeEntriesParsesRows() {
        let rows: [[String: Any]] = [
            [
                "node_id": "a",
                "iteration": NSNumber(value: 0),
                "attempt": NSNumber(value: 1),
                "state": "finished",
                "started_at_ms": NSNumber(value: 100),
                "finished_at_ms": NSNumber(value: 200),
            ],
            [
                "node_id": "b",
                "iteration": NSNumber(value: 0),
                "attempt": NSNumber(value: 1),
                "state": "running",
                "started_at_ms": NSNumber(value: 200),
                "finished_at_ms": NSNull(),
            ],
        ]
        let entries = DevToolsAttemptQuery.makeEntries(fromRows: rows)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].nodeId, "a")
        XCTAssertEqual(entries[0].startedAtMs, 100)
        XCTAssertEqual(entries[0].finishedAtMs, 200)
        XCTAssertEqual(entries[1].nodeId, "b")
        XCTAssertNil(entries[1].finishedAtMs, "NSNull should decode to nil finished_at_ms")
    }
}

final class DevToolsFrameApplierTests: XCTestCase {
    private func decodeXML(_ json: String) throws -> DevToolsFrameXMLNode {
        try JSONDecoder().decode(DevToolsFrameXMLNode.self, from: Data(json.utf8))
    }

    private func decodeDelta(_ json: String) throws -> DevToolsFrameDelta {
        try JSONDecoder().decode(DevToolsFrameDelta.self, from: Data(json.utf8))
    }

    func testEmptyDeltasLeaveTreeUnchanged() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.tag, "smithers:workflow")
        XCTAssertEqual(result.children.count, 0)
    }

    func testSetPropagatesText() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[
            {"kind":"text","text":"old"}
          ]}
        ]}
        """)
        // Deltas in real data target the text child's "text" prop via:
        //   ["children", 0, "children", 0, "text"]
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"set","path":["children",0,"children",0,"text"],"value":"new text"}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        let taskChild = result.children[0]
        let textChild = taskChild.children[0]
        XCTAssertEqual(textChild.text, "new text")
    }

    func testInsertAppendsChild() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[]}
        ]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"insert","path":["children",0,"children",0],
           "value":{"kind":"element","tag":"smithers:task","props":{"id":"new"},"children":[]}}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.children[0].children.count, 1)
        XCTAssertEqual(result.children[0].children[0].props["id"], "new")
    }

    func testRemoveDeletesChild() throws {
        let xml = try decodeXML("""
        {"kind":"element","tag":"smithers:workflow","props":{},"children":[
          {"kind":"element","tag":"smithers:sequence","props":{},"children":[
            {"kind":"element","tag":"smithers:task","props":{"id":"doomed"},"children":[]}
          ]}
        ]}
        """)
        let delta = try decodeDelta("""
        {"version":1,"ops":[
          {"op":"remove","path":["children",0,"children",0]}
        ]}
        """)
        let result = try DevToolsFrameApplier.apply(deltas: [delta], toKeyframe: xml)
        XCTAssertEqual(result.children[0].children.count, 0)
    }
}

/// Smoke-tests that require `/usr/bin/sqlite3` and a real smithers.db file.
/// These run only when the environment variable `SMITHERS_DEVTOOLS_TEST_DB` points
/// at a valid database path, to keep the suite hermetic by default.
@MainActor
final class DevToolsCLITransportIntegrationTests: XCTestCase {
    private var dbPath: String? {
        ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_TEST_DB"]
    }

    func testInvalidRunIdThrowsWithoutReachingDisk() async {
        let client = SmithersClient()
        do {
            _ = try await client.getDevToolsSnapshot(runId: "bad id", frameNo: nil)
            XCTFail("Expected invalidRunId")
        } catch let err as DevToolsClientError {
            XCTAssertEqual(err, .invalidRunId("bad id"))
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testSnapshotReturnsDataFromRealDB() async throws {
        guard let dbPath, FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Set SMITHERS_DEVTOOLS_TEST_DB to run this test.")
        }
        // Pick a runId known to exist in the DB.
        let runId = ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_TEST_RUN_ID"] ?? "run-1776372721752"

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: nil)
        XCTAssertEqual(snap.runId, runId)
        XCTAssertGreaterThan(snap.frameNo, 0)
        XCTAssertEqual(snap.root.type, .workflow)
        // Tree should have at least one child (workflow has a sequence inside).
        XCTAssertFalse(snap.root.children.isEmpty)
    }

    func testSnapshotAtFrameBeforeKeyframeReturnsRun() async throws {
        guard let dbPath, FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("Set SMITHERS_DEVTOOLS_TEST_DB to run this test.")
        }
        let runId = ProcessInfo.processInfo.environment["SMITHERS_DEVTOOLS_TEST_RUN_ID"] ?? "run-1776372721752"
        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        // Frame 1 is the first keyframe; this should return a snapshot.
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: 1)
        XCTAssertEqual(snap.frameNo, 1)
    }
}

/// End-to-end test that stands up a minimal `smithers.db` with `_smithers_frames` +
/// `_smithers_nodes` populated, then calls `getDevToolsSnapshot` and asserts the
/// resulting tree has real (non-unknown) states on task rows.
@MainActor
final class DevToolsSnapshotWithNodeStatesTests: XCTestCase {
    private func sqlite3Exists() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")
    }

    /// Creates a temp sqlite db with a single keyframe + two node-state rows.
    private func makeTempDB(runId: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smithers-devtools-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("smithers.db").path

        let keyframeXML = """
        {"kind":"element","tag":"smithers:workflow","props":{"name":"main"},"children":[\
        {"kind":"element","tag":"smithers:sequence","props":{},"children":[\
        {"kind":"element","tag":"smithers:task","props":{"id":"g74:implement"},"children":[]},\
        {"kind":"element","tag":"smithers:task","props":{"id":"g74:review:0"},"children":[]}\
        ]}]}
        """
        let escapedXML = keyframeXML.replacingOccurrences(of: "'", with: "''")
        let taskIndexJson = "[]"
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let setup = """
        CREATE TABLE _smithers_frames (
          run_id TEXT NOT NULL,
          frame_no INTEGER NOT NULL,
          encoding TEXT NOT NULL,
          xml_json TEXT NOT NULL,
          task_index_json TEXT,
          created_at_ms INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (run_id, frame_no)
        );
        CREATE TABLE _smithers_nodes (
          run_id TEXT NOT NULL,
          node_id TEXT NOT NULL,
          iteration INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL,
          last_attempt INTEGER,
          updated_at_ms INTEGER NOT NULL,
          output_table TEXT NOT NULL,
          label TEXT,
          PRIMARY KEY (run_id, node_id, iteration)
        );
        INSERT INTO _smithers_frames(run_id, frame_no, encoding, xml_json, task_index_json, created_at_ms) VALUES
          ('\(runId)', 1, 'keyframe', '\(escapedXML)', '\(taskIndexJson)', \(nowMs));
        INSERT INTO _smithers_nodes(run_id, node_id, iteration, state, last_attempt, updated_at_ms, output_table) VALUES
          ('\(runId)', 'g74:implement', 0, 'finished', 1, \(nowMs), 'implement'),
          ('\(runId)', 'g74:review:0', 0, 'in-progress', 1, \(nowMs), 'review');
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath]
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardError = errPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(setup.utf8))
        try inPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errText = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "TempDB", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errText,
            ])
        }

        return dbPath
    }

    func testSnapshotPopulatesStateFromNodesTable() async throws {
        guard sqlite3Exists() else {
            throw XCTSkip("/usr/bin/sqlite3 not available")
        }
        let runId = "run-devtools-nodestate-test"
        let dbPath = try makeTempDB(runId: runId)
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: nil)

        // Root: workflow → sequence → [task(implement), task(review:0)]
        XCTAssertEqual(snap.root.type, .workflow)
        let seq = snap.root.children[0]
        XCTAssertEqual(seq.type, .sequence)
        XCTAssertEqual(seq.children.count, 2)

        let implement = seq.children[0]
        let review = seq.children[1]

        XCTAssertEqual(
            extractState(from: implement), .finished,
            "`finished` from _smithers_nodes should map to .finished"
        )
        XCTAssertEqual(
            extractState(from: review), .running,
            "`in-progress` from _smithers_nodes should map to .running"
        )
        XCTAssertNotEqual(
            extractState(from: implement), .unknown,
            "Task row must never render as Unknown when the DB has a row for it"
        )

        // Sequence should roll up to `running` (failed > running > … > finished).
        XCTAssertEqual(extractState(from: seq), .running)
        XCTAssertEqual(extractState(from: snap.root), .running)
    }
}

/// End-to-end integration for the historical-scrubber fix. Builds a temp DB with
/// multiple frames and multiple `_smithers_attempts` rows spanning different
/// wall-clock timestamps, then asks `getDevToolsSnapshot` for specific historical
/// frames and asserts the per-node state reflects what was in flight *at that
/// frame's timestamp* rather than the terminal state.
@MainActor
final class DevToolsHistoricalScrubberIntegrationTests: XCTestCase {
    private func sqlite3Exists() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3")
    }

    /// Frames:
    ///   frame 1 at t=100 (keyframe, both tasks pending — before any attempt started)
    ///   frame 2 at t=250 (mid-execution: attempt-a finished, attempt-b running)
    ///   frame 3 at t=500 (both done)
    ///
    /// Attempts:
    ///   a:  started_at=150, finished_at=200 (finished)
    ///   b:  started_at=220, finished_at=450 (finished)
    private func makeHistoricalTempDB(runId: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smithers-historical-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("smithers.db").path

        let keyframeXML = """
        {"kind":"element","tag":"smithers:workflow","props":{"name":"main"},"children":[\
        {"kind":"element","tag":"smithers:sequence","props":{},"children":[\
        {"kind":"element","tag":"smithers:task","props":{"id":"a"},"children":[]},\
        {"kind":"element","tag":"smithers:task","props":{"id":"b"},"children":[]}\
        ]}]}
        """
        let escapedXML = keyframeXML.replacingOccurrences(of: "'", with: "''")

        let setup = """
        CREATE TABLE _smithers_frames (
          run_id TEXT NOT NULL,
          frame_no INTEGER NOT NULL,
          encoding TEXT NOT NULL,
          xml_json TEXT NOT NULL,
          task_index_json TEXT,
          created_at_ms INTEGER NOT NULL,
          PRIMARY KEY (run_id, frame_no)
        );
        CREATE TABLE _smithers_attempts (
          run_id TEXT NOT NULL,
          node_id TEXT NOT NULL,
          iteration INTEGER NOT NULL DEFAULT 0,
          attempt INTEGER NOT NULL,
          state TEXT NOT NULL,
          started_at_ms INTEGER NOT NULL,
          finished_at_ms INTEGER,
          PRIMARY KEY (run_id, node_id, iteration, attempt)
        );
        CREATE TABLE _smithers_nodes (
          run_id TEXT NOT NULL,
          node_id TEXT NOT NULL,
          iteration INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL,
          last_attempt INTEGER,
          updated_at_ms INTEGER NOT NULL,
          output_table TEXT NOT NULL,
          label TEXT,
          PRIMARY KEY (run_id, node_id, iteration)
        );
        INSERT INTO _smithers_frames(run_id, frame_no, encoding, xml_json, task_index_json, created_at_ms) VALUES
          ('\(runId)', 1, 'keyframe', '\(escapedXML)', '[]', 100),
          ('\(runId)', 2, 'keyframe', '\(escapedXML)', '[]', 250),
          ('\(runId)', 3, 'keyframe', '\(escapedXML)', '[]', 500);
        INSERT INTO _smithers_attempts(run_id, node_id, iteration, attempt, state, started_at_ms, finished_at_ms) VALUES
          ('\(runId)', 'a', 0, 1, 'finished', 150, 200),
          ('\(runId)', 'b', 0, 1, 'finished', 220, 450);
        INSERT INTO _smithers_nodes(run_id, node_id, iteration, state, last_attempt, updated_at_ms, output_table) VALUES
          ('\(runId)', 'a', 0, 'finished', 1, 500, 'implement'),
          ('\(runId)', 'b', 0, 'finished', 1, 500, 'review');
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath]
        let inPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardError = errPipe
        try process.run()
        inPipe.fileHandleForWriting.write(Data(setup.utf8))
        try inPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0,
            "temp DB setup failed: \(String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")"
        )
        return dbPath
    }

    func testSnapshotAtFrameBeforeAnyAttemptShowsPending() async throws {
        guard sqlite3Exists() else { throw XCTSkip("/usr/bin/sqlite3 not available") }
        let runId = "run-historical-before-test"
        let dbPath = try makeHistoricalTempDB(runId: runId)
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        // Frame 1 at t=100 — before either attempt started (a started at t=150).
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: 1)
        let seq = snap.root.children[0]
        XCTAssertEqual(extractState(from: seq.children[0]), .pending, "a hadn't started yet")
        XCTAssertEqual(extractState(from: seq.children[1]), .pending, "b hadn't started yet")
    }

    func testSnapshotAtMidExecutionFrameShowsMixedState() async throws {
        guard sqlite3Exists() else { throw XCTSkip("/usr/bin/sqlite3 not available") }
        let runId = "run-historical-mid-test"
        let dbPath = try makeHistoricalTempDB(runId: runId)
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        // Frame 2 at t=250. a finished at 200, b is running (started 220, finishes 450).
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: 2)
        let seq = snap.root.children[0]
        XCTAssertEqual(
            extractState(from: seq.children[0]), .finished,
            "a completed at t=200 which is ≤ frame ts=250"
        )
        XCTAssertEqual(
            extractState(from: seq.children[1]), .running,
            "b started at t=220 and hadn't finished by t=250 → running"
        )
        // Sequence should roll up to `running` (running beats finished).
        XCTAssertEqual(extractState(from: seq), .running)
    }

    func testSnapshotAtFinalFrameShowsAllFinished() async throws {
        guard sqlite3Exists() else { throw XCTSkip("/usr/bin/sqlite3 not available") }
        let runId = "run-historical-final-test"
        let dbPath = try makeHistoricalTempDB(runId: runId)
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        // Frame 3 at t=500, well after both finish times.
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: 3)
        let seq = snap.root.children[0]
        XCTAssertEqual(extractState(from: seq.children[0]), .finished)
        XCTAssertEqual(extractState(from: seq.children[1]), .finished)
        XCTAssertEqual(extractState(from: seq), .finished)
    }

    func testSnapshotInLiveModeUsesNodesTable() async throws {
        guard sqlite3Exists() else { throw XCTSkip("/usr/bin/sqlite3 not available") }
        let runId = "run-historical-live-test"
        let dbPath = try makeHistoricalTempDB(runId: runId)
        defer { try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent) }

        setenv("SMITHERS_DB_PATH", dbPath, 1)
        defer { unsetenv("SMITHERS_DB_PATH") }

        let client = SmithersClient(cwd: (dbPath as NSString).deletingLastPathComponent)
        // frameNo=nil → live mode — pull from _smithers_nodes (terminal state).
        let snap = try await client.getDevToolsSnapshot(runId: runId, frameNo: nil)
        let seq = snap.root.children[0]
        XCTAssertEqual(extractState(from: seq.children[0]), .finished)
        XCTAssertEqual(extractState(from: seq.children[1]), .finished)
    }
}
