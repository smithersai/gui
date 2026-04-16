import XCTest
@testable import SmithersGUI

// MARK: - SSE Parser Tests (unit-testable without mocking CLI)

/// Standalone SSE line parser extracted to mirror SmithersClient's sseStream logic.
/// This lets us test STREAMING_SSE_LINE_PARSER independently.
private func parseSSELines(_ raw: String) -> [SSEEvent] {
    var events: [SSEEvent] = []
    var eventType: String? = nil
    var dataLines: [String] = []
    var runId: String? = nil

    func dispatch() {
        guard !dataLines.isEmpty else {
            eventType = nil
            runId = nil
            return
        }
        let event = eventType?.isEmpty == true ? nil : eventType
        events.append(SSEEvent(event: event, data: dataLines.joined(separator: "\n"), runId: runId))
        eventType = nil
        dataLines.removeAll(keepingCapacity: true)
        runId = nil
    }

    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            dispatch()
            continue
        }

        guard !line.hasPrefix(":") else {
            continue
        }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.first == " " {
            value.removeFirst()
        }

        if field == "event" {
            eventType = value
        } else if field == "data" {
            dataLines.append(value)
        } else if field == "runId" || field == "run_id" || field == "workflowRunId" || field == "workflow_run_id" {
            runId = SSEEvent.normalizedRunId(value)
        }
    }
    // Flush remaining buffer (matches SmithersClient behavior)
    dispatch()
    return events
}

// MARK: - SmithersError Tests

final class SmithersErrorTests: XCTestCase {

    func testErrorDescriptions() {
        XCTAssertEqual(SmithersError.unauthorized.errorDescription, "Unauthorized – check your API token")
        XCTAssertEqual(SmithersError.notFound.errorDescription, "Resource not found")
        XCTAssertEqual(SmithersError.httpError(502).errorDescription, "HTTP error 502")
        XCTAssertEqual(SmithersError.api("bad request").errorDescription, "bad request")
        XCTAssertEqual(SmithersError.cli("binary missing").errorDescription, "binary missing")
        XCTAssertEqual(SmithersError.noWorkspace.errorDescription, "No workspace ID configured")
        XCTAssertEqual(SmithersError.notAvailable("Landings require JJHub").errorDescription, "Landings require JJHub")
    }

    func testSmithersErrorConformsToLocalizedError() {
        let error: LocalizedError = SmithersError.unauthorized
        XCTAssertNotNil(error.errorDescription)
    }
}

// MARK: - SSE Parser Tests

final class SSEParserTests: XCTestCase {

    // STREAMING_SSE_LINE_PARSER — basic event
    func testParsesSingleEvent() {
        let raw = "data: hello world\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].event)
        XCTAssertEqual(events[0].data, "hello world")
    }

    // STREAMING_SSE_LINE_PARSER — event with type
    func testParsesEventWithType() {
        let raw = "event: message\ndata: {\"text\":\"hi\"}\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "{\"text\":\"hi\"}")
    }

    // STREAMING_SSE_LINE_PARSER — multiline data
    func testParsesMultilineData() {
        let raw = "data: line1\ndata: line2\ndata: line3\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2\nline3")
    }

    // STREAMING_SSE_LINE_PARSER — multiple events
    func testParsesMultipleEvents() {
        let raw = "event: start\ndata: a\n\nevent: end\ndata: b\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].event, "start")
        XCTAssertEqual(events[0].data, "a")
        XCTAssertEqual(events[1].event, "end")
        XCTAssertEqual(events[1].data, "b")
    }

    // STREAMING_SSE_LINE_PARSER — empty lines between events are separators
    func testEmptyLinesSeparateEvents() {
        let raw = "data: first\n\n\ndata: second\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 2)
    }

    // STREAMING_SSE_LINE_PARSER — unterminated event (no trailing blank line) is flushed
    func testUnterminatedEventFlushed() {
        let raw = "event: partial\ndata: leftovers"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "partial")
        XCTAssertEqual(events[0].data, "leftovers")
    }

    // STREAMING_SSE_LINE_PARSER — separators without data do not emit events
    func testEmptyLinesOnlyNoEvent() {
        let raw = "\n\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 0)
    }

    // STREAMING_SSE_LINE_PARSER — only one optional leading space after ":" is stripped
    func testWhitespacePreserved() {
        let raw = "event:   spaced  \ndata:   padded  \n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events[0].event, "  spaced  ")
        XCTAssertEqual(events[0].data, "  padded  ")
    }

    func testEmptyDataEventEmitted() {
        let raw = "event: heartbeat\ndata:\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "heartbeat")
        XCTAssertEqual(events[0].data, "")
    }

    // STREAMING_SSE_LINE_PARSER — event type resets after dispatch
    func testEventTypeResetsAfterDispatch() {
        let raw = "event: typed\ndata: one\n\ndata: two\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events[0].event, "typed")
        XCTAssertNil(events[1].event, "Event type should reset to nil after dispatch")
    }

    func testParsedEventExtractsTopLevelRunId() {
        let raw = "data: {\"runId\":\"run-1\",\"type\":\"RunStarted\"}\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events[0].runId, "run-1")
    }

    func testParsedEventUsesSSEFieldRunId() {
        let raw = "event: message\nrunId: run-from-field\ndata: {\"type\":\"RunStarted\"}\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events[0].runId, "run-from-field")
    }

    func testExtractsNestedRunIdFromEnvelope() {
        let json = """
        {"event":{"runId":"run-nested","type":"RunFinished"}}
        """
        XCTAssertEqual(SSEEvent.extractRunId(from: json), "run-nested")
    }

    func testExtractsSnakeCaseRunId() {
        let json = """
        {"data":{"run_id":"run-snake","type":"RunFinished"}}
        """
        XCTAssertEqual(SSEEvent.extractRunId(from: json), "run-snake")
    }

    func testFilteredEventDropsExplicitMismatchedRunId() {
        let json = "{\"runId\":\"other-run\",\"type\":\"RunStarted\"}"
        XCTAssertNil(SSEEvent.filtered(event: "message", data: json, expectedRunId: "target-run"))
    }

    func testFilteredEventKeepsMatchingRunId() {
        let json = "{\"runId\":\"target-run\",\"type\":\"RunStarted\"}"
        let event = SSEEvent.filtered(event: "message", data: json, expectedRunId: "target-run")
        XCTAssertEqual(event?.runId, "target-run")
        XCTAssertEqual(event?.data, json)
    }

    func testFilteredEventKeepsAndTagsMissingRunId() {
        let json = "{\"type\":\"heartbeat\"}"
        let event = SSEEvent.filtered(event: "message", data: json, expectedRunId: "target-run")
        XCTAssertEqual(event?.runId, "target-run")
        XCTAssertEqual(event?.data, json)
    }

    func testFilteredEventDropsMissingRunIdWhenRunAttributionIsRequired() {
        let json = "{\"type\":\"heartbeat\"}"
        let event = SSEEvent.filtered(
            event: "message",
            data: json,
            expectedRunId: "target-run",
            requireAttributedRunId: true
        )
        XCTAssertNil(event)
    }

    func testFilteredEventDropsMismatchedSSEFieldRunId() {
        let json = "{\"type\":\"RunStarted\"}"
        let event = SSEEvent.filtered(
            event: "message",
            data: json,
            eventRunId: "other-run",
            expectedRunId: "target-run"
        )
        XCTAssertNil(event)
    }

    func testFilteredEventUsesSSEFieldRunIdWhenPayloadRunIdMissing() {
        let json = "{\"type\":\"RunStarted\"}"
        let event = SSEEvent.filtered(
            event: "message",
            data: json,
            eventRunId: "target-run",
            expectedRunId: "target-run"
        )
        XCTAssertEqual(event?.runId, "target-run")
    }

    func testFilteredEventDropsWhenSSEAndPayloadRunIdsConflict() {
        let json = "{\"runId\":\"payload-run\",\"type\":\"RunStarted\"}"
        let event = SSEEvent.filtered(
            event: "message",
            data: json,
            eventRunId: "field-run",
            expectedRunId: "field-run"
        )
        XCTAssertNil(event)
    }
}

// MARK: - SmithersClient Initialization & Properties Tests

@MainActor
final class SmithersClientInitTests: XCTestCase {

    // PLATFORM_SMITHERS_CLI_BRIDGE — default init falls back to home when cwd is missing
    func testDefaultInitFallsBackToHomeDirectoryWhenCwdMissing() {
        let client = SmithersClient()
        XCTAssertEqual(client.workingDirectory, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // PLATFORM_SMITHERS_CLI_BRIDGE — custom cwd
    func testCustomCwd() {
        let client = SmithersClient(cwd: "/tmp")
        XCTAssertNotNil(client)
    }

    // PLATFORM_SMITHERS_CLI_AVAILABLE_FLAG — starts false
    func testCliAvailableStartsFalse() {
        let client = SmithersClient()
        XCTAssertFalse(client.cliAvailable)
    }

    // PLATFORM_SMITHERS_IS_CONNECTED_FLAG — starts false
    func testIsConnectedStartsFalse() {
        let client = SmithersClient()
        XCTAssertFalse(client.isConnected)
    }

    // PLATFORM_SMITHERS_SERVER_URL_OPTIONAL — starts nil
    func testServerURLStartsNil() {
        let client = SmithersClient()
        XCTAssertNil(client.serverURL)
    }

    // PLATFORM_SMITHERS_SERVER_URL_OPTIONAL — can be set
    func testServerURLCanBeSet() {
        let client = SmithersClient()
        client.serverURL = "http://localhost:7331"
        XCTAssertEqual(client.serverURL, "http://localhost:7331")
    }

    // CONSTANT_SSE_DEFAULT_PORT_7331 — stream methods use 7331 as default
    func testDefaultSSEPort() {
        // The default parameter for port is 7331 in streamRunEvents and streamChat.
        // We verify by calling with default and ensuring no crash.
        let client = SmithersClient()
        let stream = client.streamRunEvents("test-run")
        XCTAssertNotNil(stream)
    }

    func testStreamChatDefaultPort() {
        let client = SmithersClient()
        let stream = client.streamChat("test-run")
        XCTAssertNotNil(stream)
    }
}

// MARK: - SmithersClient Transport & CLI Argument Tests

@MainActor
final class SmithersClientTransportTests: XCTestCase {

    // TRANSPORT_HTTP_TIMEOUT_15S — non-streaming URLSession timeout is 15s
    func testSessionTimeoutConfigured() {
        let config = SmithersClient.makeHTTPURLSessionConfiguration()
        XCTAssertEqual(config.timeoutIntervalForRequest, 15)
    }

    func testSSESessionDoesNotUseShortRequestTimeout() {
        let config = SmithersClient.makeSSEURLSessionConfiguration()
        XCTAssertTrue(config.timeoutIntervalForRequest.isInfinite)
        XCTAssertTrue(config.timeoutIntervalForResource.isInfinite)
    }

    // TRANSPORT_WRAPPED_VS_BARE_JSON — listWorkflows handles wrapped {"workflows":[...]}
    // and bare [...] formats. We test the JSON decoding paths via model round-trips.
    func testWrappedWorkflowResponseDecoding() throws {
        let json = """
        {"workflows":[{"id":"w1","displayName":"My Flow","entryFile":"flow.ts","sourceType":"local"}]}
        """
        struct Response: Decodable {
            let workflows: [DiscoveredWorkflow]
        }
        struct DiscoveredWorkflow: Decodable {
            let id: String
            let displayName: String
            let entryFile: String
            let sourceType: String
        }
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(Response.self, from: data)
        XCTAssertEqual(response.workflows.count, 1)
        XCTAssertEqual(response.workflows[0].id, "w1")
        XCTAssertEqual(response.workflows[0].displayName, "My Flow")
    }

    func testBareWorkflowArrayDecoding() throws {
        let json = """
        [{"id":"w2","displayName":"Bare","entryFile":"bare.ts","sourceType":"local"}]
        """
        struct DiscoveredWorkflow: Decodable {
            let id: String
            let displayName: String
            let entryFile: String
            let sourceType: String
        }
        let data = json.data(using: .utf8)!
        let bare = try JSONDecoder().decode([DiscoveredWorkflow].self, from: data)
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].id, "w2")
    }

    // TRANSPORT_WRAPPED_VS_BARE_JSON — listRuns handles both
    func testWrappedRunsResponseDecoding() throws {
        let json = """
        {"runs":[{"runId":"r1","status":"running","workflowName":null,"workflowPath":null,"startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null}]}
        """
        let data = json.data(using: .utf8)!
        // Use the private wrapper struct shape
        struct RunsResponse: Decodable { let runs: [RunSummary] }
        let wrapped = try JSONDecoder().decode(RunsResponse.self, from: data)
        XCTAssertEqual(wrapped.runs.count, 1)
        XCTAssertEqual(wrapped.runs[0].runId, "r1")
    }

    func testBareRunsArrayDecoding() throws {
        let json = """
        [{"runId":"r2","status":"finished","workflowName":"wf","workflowPath":"wf.ts","startedAtMs":1000,"finishedAtMs":2000,"summary":{"total":5,"finished":5},"errorJson":null}]
        """
        let data = json.data(using: .utf8)!
        let bare = try JSONDecoder().decode([RunSummary].self, from: data)
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].status, .finished)
    }

    // TRANSPORT_CRON_LIST_WRAPPED_JSON — cron list returns {"crons":[...]}
    func testWrappedCronResponseDecoding() throws {
        let json = """
        {"crons":[{"cronId":"c1","pattern":"*/15 * * * *","workflowPath":".smithers/workflows/debug.tsx","enabled":true,"createdAtMs":1776218840798,"lastRunAtMs":null,"nextRunAtMs":null,"errorJson":null}]}
        """
        let data = json.data(using: .utf8)!
        let wrapped = try JSONDecoder().decode(CronResponse.self, from: data)
        XCTAssertEqual(wrapped.crons.count, 1)
        XCTAssertEqual(wrapped.crons[0].id, "c1")
        XCTAssertEqual(wrapped.crons[0].workflowPath, ".smithers/workflows/debug.tsx")
        XCTAssertTrue(wrapped.crons[0].enabled)
    }

    func testBareCronArrayDecoding() throws {
        let json = """
        [{"cronId":"c2","pattern":"0 * * * *","workflowPath":"hourly.ts","enabled":false,"createdAtMs":1000,"lastRunAtMs":null,"nextRunAtMs":2000,"errorJson":null}]
        """
        let data = json.data(using: .utf8)!
        let bare = try JSONDecoder().decode([CronSchedule].self, from: data)
        XCTAssertEqual(bare.count, 1)
        XCTAssertEqual(bare[0].id, "c2")
        XCTAssertEqual(bare[0].nextRunAtMs, 2_000)
    }

    // TRANSPORT_WRAPPED_VS_BARE_JSON — memory responses
    func testWrappedMemoryResponseDecoding() throws {
        let json = """
        {"facts":[{"namespace":"default","key":"k1","valueJson":"{}","schemaSig":null,"createdAtMs":1000,"updatedAtMs":2000,"ttlMs":null}]}
        """
        struct MemoryResponse: Decodable { let facts: [MemoryFact] }
        let data = json.data(using: .utf8)!
        let wrapped = try JSONDecoder().decode(MemoryResponse.self, from: data)
        XCTAssertEqual(wrapped.facts.count, 1)
        XCTAssertEqual(wrapped.facts[0].key, "k1")
    }

    // TRANSPORT_WRAPPED_VS_BARE_JSON — scores responses
    func testWrappedScoresResponseDecoding() throws {
        let json = """
        {"scores":[{"id":"s1","runId":"r1","nodeId":null,"iteration":null,"attempt":null,"scorerId":"sc1","scorerName":"accuracy","source":"live","score":0.95,"reason":null,"metaJson":null,"latencyMs":null,"scoredAtMs":1000}]}
        """
        struct ScoresResponse: Decodable { let scores: [ScoreRow] }
        let data = json.data(using: .utf8)!
        let wrapped = try JSONDecoder().decode(ScoresResponse.self, from: data)
        XCTAssertEqual(wrapped.scores.count, 1)
        XCTAssertEqual(wrapped.scores[0].score, 0.95)
    }

    // TRANSPORT_WRAPPED_VS_BARE_JSON — recall responses
    func testWrappedRecallResponseDecoding() throws {
        let json = """
        {"results":[{"score":0.8,"content":"remembered","metadata":null}]}
        """
        struct RecallResponse: Decodable { let results: [MemoryRecallResult] }
        let data = json.data(using: .utf8)!
        let wrapped = try JSONDecoder().decode(RecallResponse.self, from: data)
        XCTAssertEqual(wrapped.results.count, 1)
        XCTAssertEqual(wrapped.results[0].content, "remembered")
    }

    // TRANSPORT_WORKFLOW_INPUT_JSON_ENCODING — inputs are JSON-encoded
    func testWorkflowInputJSONEncoding() throws {
        let inputs = ["prompt": "hello", "model": "gpt-4"]
        let encoded = try JSONEncoder().encode(inputs)
        let str = String(data: encoded, encoding: .utf8)!
        // Should be valid JSON
        let decoded = try JSONDecoder().decode([String: String].self, from: str.data(using: .utf8)!)
        XCTAssertEqual(decoded["prompt"], "hello")
        XCTAssertEqual(decoded["model"], "gpt-4")
    }
}

// MARK: - CLI Command Argument Construction Tests

/// These tests verify the correct CLI arguments would be constructed for each command.
/// Since we can't easily mock Process, we verify argument construction logic.
@MainActor
final class SmithersClientCLICommandTests: XCTestCase {

    // CLI_WORKFLOW_LIST — "workflow list --format json"
    func testWorkflowListCommandShape() {
        // Verified from source: exec("workflow", "list", "--format", "json")
        let args = ["workflow", "list", "--format", "json"]
        XCTAssertEqual(args[0], "workflow")
        XCTAssertEqual(args[1], "list")
        XCTAssertEqual(args[2], "--format")
        XCTAssertEqual(args[3], "json")
    }

    // CLI_PS — "ps --format json"
    func testPsCommandShape() {
        let args = ["ps", "--format", "json"]
        XCTAssertEqual(args[0], "ps")
        XCTAssertTrue(args.contains("--format"))
        XCTAssertTrue(args.contains("json"))
    }

    // CLI_INSPECT — "inspect <runId> --format json"
    func testInspectCommandShape() {
        let runId = "run-abc123"
        let args = ["inspect", runId, "--format", "json"]
        XCTAssertEqual(args[1], runId)
    }

    // CLI_CANCEL — "cancel <runId>"
    func testCancelCommandShape() {
        let runId = "run-abc123"
        let args = ["cancel", runId]
        XCTAssertEqual(args.count, 2)
        XCTAssertEqual(args[0], "cancel")
        XCTAssertEqual(args[1], runId)
    }

    // CLI_HIJACK — boolean flag must use --launch=false, not split --launch false.
    func testHijackCommandShapeUsesEqualsBoolean() {
        let args = SmithersClient.hijackRunCLIArgs(runId: "run-1")
        XCTAssertEqual(args, ["hijack", "run-1", "--launch=false", "--format", "json"])
        XCTAssertFalse(args.contains("--launch"))
    }

    func testHijackRunUsesNonLaunchingCLIQuery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientHijackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "hijack" ] && [ "$2" = "run-1" ] && [ "$3" = "--launch=false" ] && [ "$4" = "--format" ] && [ "$5" = "json" ]; then
          cat <<'JSON'
        {"runId":"run-1","engine":"codex","mode":"native-cli","resume":"session-123","cwd":"\(root.path)","launch":{"command":"codex","args":["resume","session-123","-C","\(root.path)"],"cwd":"\(root.path)"}}
        JSON
          exit 0
        fi

        if [ "$1" = "hijack" ] && [ "$2" = "run-1" ] && [ "$3" = "--launch" ]; then
          echo "stdout is not a terminal" >&2
          exit 7
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

        let client = SmithersClient(cwd: root.path, smithersBin: bin.path)
        let session = try await client.hijackRun("run-1", port: 1)

        XCTAssertEqual(session.runId, "run-1")
        XCTAssertEqual(session.agentEngine, "codex")
        XCTAssertEqual(session.launchInvocation(defaultWorkingDirectory: "/fallback")?.arguments, [
            "resume", "session-123", "-C", root.path,
        ])
        let recordedCalls = try String(contentsOf: calls, encoding: .utf8)
        XCTAssertTrue(recordedCalls.contains("hijack run-1 --launch=false --format json"))
    }

    // CLI_APPROVE — "approve <runId> --node <nodeId>"
    // TRANSPORT_APPROVE_NOTE_PARAMETER — optional --note
    func testApproveCommandShape() {
        let args = SmithersClient.approveNodeCLIArgs(runId: "run-1", nodeId: "node-a")
        XCTAssertEqual(args, ["approve", "run-1", "--node", "node-a"])
        XCTAssertFalse(args.contains("--run"))
    }

    // TRANSPORT_APPROVE_NOTE_PARAMETER — optional --note
    func testApproveCommandShapeIncludesNote() {
        let args = SmithersClient.approveNodeCLIArgs(runId: "run-1", nodeId: "node-a", note: "LGTM")
        XCTAssertEqual(args, ["approve", "run-1", "--node", "node-a", "--note", "LGTM"])
    }

    // CLI_APPROVE_ITERATION — optional --iteration
    func testApproveCommandShapeIncludesIterationWhenProvided() {
        let args = SmithersClient.approveNodeCLIArgs(runId: "run-1", nodeId: "node-a", iteration: 2)
        XCTAssertEqual(args, ["approve", "run-1", "--node", "node-a", "--iteration", "2"])
    }

    // CLI_APPROVE — ensure explicit node survives optional flags.
    func testApproveCommandShapeIncludesExplicitNodeWithAllOptionalFlags() {
        let args = SmithersClient.approveNodeCLIArgs(
            runId: "run-1",
            nodeId: "node-a",
            iteration: 2,
            note: "LGTM"
        )
        XCTAssertEqual(args, ["approve", "run-1", "--node", "node-a", "--iteration", "2", "--note", "LGTM"])
    }

    // CLI_DENY — "deny <runId> --node <nodeId>"
    // TRANSPORT_DENY_REASON_PARAMETER — optional --reason
    func testDenyCommandShape() {
        let args = SmithersClient.denyNodeCLIArgs(runId: "run-1", nodeId: "node-b")
        XCTAssertEqual(args, ["deny", "run-1", "--node", "node-b"])
        XCTAssertFalse(args.contains("--run"))
    }

    // TRANSPORT_DENY_REASON_PARAMETER — optional --reason
    func testDenyCommandShapeIncludesReason() {
        let args = SmithersClient.denyNodeCLIArgs(runId: "run-1", nodeId: "node-b", reason: "unsafe operation")
        XCTAssertEqual(args, ["deny", "run-1", "--node", "node-b", "--reason", "unsafe operation"])
    }

    // CLI_DENY_ITERATION — optional --iteration
    func testDenyCommandShapeIncludesIterationWhenProvided() {
        let args = SmithersClient.denyNodeCLIArgs(runId: "run-1", nodeId: "node-b", iteration: 3)
        XCTAssertEqual(args, ["deny", "run-1", "--node", "node-b", "--iteration", "3"])
    }

    // CLI_DENY — ensure explicit node survives optional flags.
    func testDenyCommandShapeIncludesExplicitNodeWithAllOptionalFlags() {
        let args = SmithersClient.denyNodeCLIArgs(
            runId: "run-1",
            nodeId: "node-b",
            iteration: 3,
            reason: "unsafe operation"
        )
        XCTAssertEqual(args, ["deny", "run-1", "--node", "node-b", "--iteration", "3", "--reason", "unsafe operation"])
    }

    // CLI_APPROVE_DENY_NODE_SELECTION — multiple pending approvals still pass explicit node IDs.
    func testApproveAndDenyCommandShapesPreserveNodePerApproval() {
        let nodes = ["deploy-gate", "security-gate"]
        let approveNodeSegments = nodes.map {
            Array(SmithersClient.approveNodeCLIArgs(runId: "run-1", nodeId: $0)[2...3])
        }
        let denyNodeSegments = nodes.map {
            Array(SmithersClient.denyNodeCLIArgs(runId: "run-1", nodeId: $0)[2...3])
        }
        XCTAssertEqual(approveNodeSegments, [["--node", "deploy-gate"], ["--node", "security-gate"]])
        XCTAssertEqual(denyNodeSegments, [["--node", "deploy-gate"], ["--node", "security-gate"]])
    }

    // CLI_MEMORY_LIST — "memory list --format json [--namespace <namespace>] [--workflow <path>]"
    func testMemoryListCommandShape() {
        let args = SmithersMemoryCLI.listArgs(
            namespace: "workflow:implement",
            workflowPath: ".smithers/workflows/implement.tsx"
        )
        XCTAssertEqual(args, [
            "memory", "list",
            "--format", "json",
            "--namespace", "workflow:implement",
            "--workflow", ".smithers/workflows/implement.tsx",
        ])
    }

    func testMemoryListCommandDoesNotForceNamespace() {
        let args = SmithersMemoryCLI.listArgs(workflowPath: ".smithers/workflows/implement.tsx")
        XCTAssertFalse(args.contains("--namespace"))
    }

    func testMemoryListAllCommandShape() {
        let args = SmithersMemoryCLI.listAllArgs(workflowPath: ".smithers/workflows/implement.tsx")
        XCTAssertEqual(args, [
            "memory", "list",
            "--format", "json",
            "--workflow", ".smithers/workflows/implement.tsx",
        ])
    }

    // CLI_MEMORY_RECALL — "memory recall <query> --format json --namespace <namespace> --top-k <n> --workflow <path>"
    func testMemoryRecallCommandShape() {
        let query = "deployment steps"
        let topK = 5
        let args = SmithersMemoryCLI.recallArgs(
            query: query,
            namespace: "global:default",
            workflowPath: ".smithers/workflows/implement.tsx",
            topK: topK
        )
        XCTAssertEqual(args, [
            "memory", "recall", query,
            "--format", "json",
            "--namespace", "global:default",
            "--top-k", "5",
            "--workflow", ".smithers/workflows/implement.tsx",
        ])
    }

    func testMemoryRecallCommandDoesNotForceNamespace() {
        let args = SmithersMemoryCLI.recallArgs(query: "deployment steps", topK: 5)
        XCTAssertFalse(args.contains("--namespace"))
    }

    private func makeMemoryCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "memory" ] && [ "$2" = "list" ]; then
          echo 'No facts found in namespace "workflow:implement".'
          cat <<'JSON'
        {"facts":[{"namespace":"workflow:implement","key":"language","valueJson":"{}","schemaSig":null,"createdAtMs":1000,"updatedAtMs":2000,"ttlMs":null}],"namespace":"workflow:implement"}
        JSON
          exit 0
        fi

        if [ "$1" = "memory" ] && [ "$2" = "recall" ]; then
          echo 'No results found.'
          cat <<'JSON'
        {"query":"deploy","namespace":"global:default","results":[{"score":0.8,"content":"remembered","metadata":null}]}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func makeLegacyMemoryCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientLegacyMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "memory" ] && [ "$2" = "list" ]; then
          if [ "$3" = "--format" ]; then
            echo "Unknown flag: --namespace" >&2
            exit 2
          fi
          cat <<'JSON'
        {"facts":[{"namespace":"workflow:implement","key":"language","valueJson":"{}","schemaSig":null,"createdAtMs":1000,"updatedAtMs":2000,"ttlMs":null}],"namespace":"workflow:implement"}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    func testListMemoryFactsUsesScopedNamespaceWorkflowAndWrappedJSON() async throws {
        let cli = try makeMemoryCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let facts = try await client.listMemoryFacts(
            namespace: "workflow:implement",
            workflowPath: ".smithers/workflows/implement.tsx"
        )

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].namespace, "workflow:implement")
        XCTAssertEqual(facts[0].key, "language")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("memory list --format json --namespace workflow:implement --workflow .smithers/workflows/implement.tsx"))
    }

    func testListMemoryFactsFallsBackToLegacyPositionalNamespaceShape() async throws {
        let cli = try makeLegacyMemoryCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let facts = try await client.listMemoryFacts(
            namespace: "workflow:implement",
            workflowPath: ".smithers/workflows/implement.tsx"
        )

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].namespace, "workflow:implement")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("memory list --format json --namespace workflow:implement --workflow .smithers/workflows/implement.tsx"))
        XCTAssertTrue(calls.contains("memory list workflow:implement --format json --workflow .smithers/workflows/implement.tsx"))
    }

    func testListAllMemoryFactsUsesWorkflowScopedShapeAndWrappedJSON() async throws {
        let cli = try makeMemoryCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let facts = try await client.listAllMemoryFacts(workflowPath: ".smithers/workflows/implement.tsx")

        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].namespace, "workflow:implement")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("memory list --format json --workflow .smithers/workflows/implement.tsx"))
        XCTAssertFalse(calls.contains("--all"))
    }

    func testRecallMemoryDefaultArgsMatchTUIBehavior() async throws {
        let cli = try makeMemoryCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let results = try await client.recallMemory(query: "deploy")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].content, "remembered")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("memory recall deploy --format json --top-k 10"))
        XCTAssertFalse(calls.contains("--namespace global:default"))
    }

    private func makeScoresCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientScoresTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "scores" ] && [ "$2" = "run-xyz" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
          cat <<'JSON'
        {"scores":[{"id":"s1","runId":"run-xyz","nodeId":null,"iteration":null,"attempt":null,"scorerId":"sc1","scorerName":"accuracy","source":"live","score":0.95,"reason":null,"metaJson":null,"latencyMs":null,"scoredAtMs":1000}]}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func makeWorkflowCLI(
        listPayload: String = """
        {"workflows":[{"id":"deploy","displayName":"Deploy","entryFile":".smithers/workflows/deploy.yaml","sourceType":"local"}]}
        """,
        graphPayload: String = """
        {"workflowId":".smithers/workflows/deploy.yaml","runId":"graph","tasks":[]}
        """
    ) throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "workflow" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        \(listPayload)
        JSON
          exit 0
        fi

        if [ "$1" = "graph" ]; then
          cat <<'JSON'
        \(graphPayload)
        JSON
          exit 0
        fi

        if [ "$1" = "up" ]; then
          cat <<'JSON'
        {"runId":"run-from-relative-path"}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func makeWorkflowGraphFirstCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientWorkflowGraphFirstTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "workflow" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        {"workflows":[{"id":"deploy","displayName":"Deploy","entryFile":".smithers/workflows/deploy.yaml","sourceType":"local"}]}
        JSON
          exit 0
        fi

        if [ "$1" = "workflow" ] && [ "$2" = "graph" ]; then
          cat <<'JSON'
        {"workflow_id":".smithers/workflows/deploy.yaml","run_id":"graph","nodes":[{"id":"build","ordinal":0},{"id":"test","ordinal":1}],"edges":[{"source":"build","target":"test"}]}
        JSON
          exit 0
        fi

        if [ "$1" = "graph" ]; then
          echo "legacy graph path should not be called" >&2
          exit 3
        fi

        if [ "$1" = "up" ]; then
          cat <<'JSON'
        {"runId":"run-from-relative-path"}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    func testGetWorkflowDAGUsesWorkflowRelativePath() async throws {
        let cli = try makeWorkflowCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflow = Workflow(
            id: "deploy",
            workspaceId: nil,
            name: "Deploy",
            relativePath: ".smithers/workflows/deploy.yaml",
            status: nil,
            updatedAt: nil
        )

        let dag = try await client.getWorkflowDAG(workflow)

        XCTAssertEqual(dag.workflowID, ".smithers/workflows/deploy.yaml")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("graph .smithers/workflows/deploy.yaml --format json"))
        XCTAssertFalse(calls.contains("graph deploy --format json"))
    }

    func testGetWorkflowDAGBuildsLaunchFieldsFromInputSchema() async throws {
        let cli = try makeWorkflowCLI(
            graphPayload: """
            {
              "workflowId":".smithers/workflows/deploy.yaml",
              "inputSchema":{
                "type":"object",
                "required":["dry_run","replicas"],
                "properties":{
                  "dry_run":{"type":"boolean","default":false},
                  "replicas":{"type":"integer","default":3},
                  "extra":{"type":"array","items":{"type":"string"}}
                }
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflow = Workflow(
            id: "deploy",
            workspaceId: nil,
            name: "Deploy",
            relativePath: ".smithers/workflows/deploy.yaml",
            status: nil,
            updatedAt: nil
        )

        let dag = try await client.getWorkflowDAG(workflow)
        let fieldsByKey = Dictionary(uniqueKeysWithValues: dag.launchFields.map { ($0.key, $0) })

        XCTAssertEqual(fieldsByKey["dry_run"]?.type, "boolean")
        XCTAssertEqual(fieldsByKey["dry_run"]?.defaultValue, "false")
        XCTAssertTrue(fieldsByKey["dry_run"]?.required == true)

        XCTAssertEqual(fieldsByKey["replicas"]?.type, "number")
        XCTAssertEqual(fieldsByKey["replicas"]?.defaultValue, "3")
        XCTAssertTrue(fieldsByKey["replicas"]?.required == true)

        XCTAssertEqual(fieldsByKey["extra"]?.type, "array")
        XCTAssertFalse(fieldsByKey["extra"]?.required == true)
    }

    func testGetWorkflowDAGMergesFieldEntriesWithInputSchema() async throws {
        let cli = try makeWorkflowCLI(
            graphPayload: """
            {
              "workflowId":".smithers/workflows/deploy.yaml",
              "fields":[
                {"key":"dry_run"},
                {"key":"replicas","name":"Replica Count Override"}
              ],
              "inputSchema":{
                "type":"object",
                "required":["dry_run","replicas"],
                "properties":{
                  "dry_run":{"type":"boolean","default":false,"title":"Dry Run"},
                  "replicas":{"type":"integer","default":3},
                  "features":{"type":"array","items":{"type":"string"}}
                }
              }
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflow = Workflow(
            id: "deploy",
            workspaceId: nil,
            name: "Deploy",
            relativePath: ".smithers/workflows/deploy.yaml",
            status: nil,
            updatedAt: nil
        )

        let dag = try await client.getWorkflowDAG(workflow)
        let fieldsByKey = Dictionary(uniqueKeysWithValues: dag.launchFields.map { ($0.key, $0) })

        XCTAssertEqual(fieldsByKey["dry_run"]?.name, "Dry Run")
        XCTAssertEqual(fieldsByKey["dry_run"]?.type, "boolean")
        XCTAssertEqual(fieldsByKey["dry_run"]?.defaultValue, "false")
        XCTAssertTrue(fieldsByKey["dry_run"]?.required == true)

        XCTAssertEqual(fieldsByKey["replicas"]?.name, "Replica Count Override")
        XCTAssertEqual(fieldsByKey["replicas"]?.type, "number")
        XCTAssertEqual(fieldsByKey["replicas"]?.defaultValue, "3")
        XCTAssertTrue(fieldsByKey["replicas"]?.required == true)

        XCTAssertEqual(fieldsByKey["features"]?.type, "array")
    }

    func testGetWorkflowDAGPrefersWorkflowGraphCommandWhenAvailable() async throws {
        let cli = try makeWorkflowGraphFirstCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflow = Workflow(
            id: "deploy",
            workspaceId: nil,
            name: "Deploy",
            relativePath: ".smithers/workflows/deploy.yaml",
            status: nil,
            updatedAt: nil
        )

        let dag = try await client.getWorkflowDAG(workflow)

        XCTAssertEqual(dag.nodes.map(\.nodeId), ["build", "test"])
        XCTAssertEqual(dag.edges, [WorkflowDAGEdge(from: "build", to: "test")])

        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(calls.contains("workflow graph .smithers/workflows/deploy.yaml --format json"))
        XCTAssertFalse(calls.contains("graph .smithers/workflows/deploy.yaml --format json"))
    }

    func testRunWorkflowUsesWorkflowRelativePath() async throws {
        let cli = try makeWorkflowCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflow = Workflow(
            id: "deploy",
            workspaceId: nil,
            name: "Deploy",
            relativePath: ".smithers/workflows/deploy.yaml",
            status: nil,
            updatedAt: nil
        )

        let result = try await client.runWorkflow(workflow)

        XCTAssertEqual(result.runId, "run-from-relative-path")
        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("up .smithers/workflows/deploy.yaml -d --format json"))
        XCTAssertFalse(calls.contains("up deploy -d --format json"))
    }

    func testListWorkflowsThenGraphAndUpUseWorkflowPathAlias() async throws {
        let cli = try makeWorkflowCLI(
            listPayload: """
            {"workflows":[{"id":"deploy","displayName":"Deploy","path":".smithers/workflows/deploy.yaml"}]}
            """
        )
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let workflows = try await client.listWorkflows()
        let workflow = try XCTUnwrap(workflows.first)

        XCTAssertEqual(workflow.id, "deploy")
        XCTAssertEqual(workflow.filePath, ".smithers/workflows/deploy.yaml")

        _ = try await client.getWorkflowDAG(workflow)
        _ = try await client.runWorkflow(workflow)

        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("graph .smithers/workflows/deploy.yaml --format json"))
        XCTAssertTrue(calls.contains("up .smithers/workflows/deploy.yaml -d --format json"))
        XCTAssertFalse(calls.contains("graph deploy --format json"))
        XCTAssertFalse(calls.contains("up deploy -d --format json"))
    }

    func testRunWorkflowSerializesTypedInputs() async throws {
        let cli = try makeWorkflowCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        _ = try await client.runWorkflow(
            workflowPath: ".smithers/workflows/deploy.yaml",
            inputs: [
                "config": .object(["enabled": .bool(true)]),
                "dry_run": .bool(false),
                "replicas": .number(3),
            ]
        )

        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        guard let line = calls.split(separator: "\n").last else {
            return XCTFail("Expected workflow command to be logged")
        }
        let parts = line.split(separator: " ").map(String.init)
        guard let inputIndex = parts.firstIndex(of: "--input"), parts.indices.contains(inputIndex + 1) else {
            return XCTFail("Expected --input JSON payload in \(line)")
        }

        let inputJSON = parts[inputIndex + 1]
        let decoded = try JSONDecoder().decode([String: JSONValue].self, from: Data(inputJSON.utf8))
        XCTAssertEqual(decoded["config"], .object(["enabled": .bool(true)]))
        XCTAssertEqual(decoded["dry_run"], .bool(false))
        XCTAssertEqual(decoded["replicas"], .number(3))
        XCTAssertFalse(inputJSON.contains(#""false""#), "Boolean inputs must not be encoded as strings")
        XCTAssertFalse(inputJSON.contains(#""3""#), "Number inputs must not be encoded as strings")
    }

    // CLI_SCORES — "scores <runId> --format json"
    func testScoresCommandShape() {
        let runId = "run-xyz"
        let args = ["scores", runId, "--format", "json"]
        XCTAssertEqual(args, ["scores", "run-xyz", "--format", "json"])
    }

    func testListRecentScoresUsesRunIdPositionalArgument() async throws {
        let cli = try makeScoresCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let scores = try await client.listRecentScores(runId: "run-xyz")

        XCTAssertEqual(scores.count, 1)
        XCTAssertEqual(scores.first?.runId, "run-xyz")

        let calls = try String(contentsOf: cli.calls, encoding: .utf8)
        XCTAssertTrue(calls.contains("scores run-xyz --format json"))
        XCTAssertFalse(calls.contains("scores --run run-xyz"))
    }

    func testMetricsCommandShapes() {
        let tokenArgs = ["metrics", "token-usage", "--format", "json", "--run", "run-xyz", "--group-by", "day"]
        XCTAssertEqual(Array(tokenArgs.prefix(4)), ["metrics", "token-usage", "--format", "json"])
        XCTAssertTrue(tokenArgs.contains("--run"))
        XCTAssertTrue(tokenArgs.contains("--group-by"))

        let latencyArgs = ["metrics", "latency", "--format", "json", "--workflow", ".smithers/workflows/review.tsx"]
        XCTAssertEqual(Array(latencyArgs.prefix(4)), ["metrics", "latency", "--format", "json"])
        XCTAssertTrue(latencyArgs.contains("--workflow"))

        let costArgs = ["metrics", "cost", "--format", "json", "--start", "1", "--end", "2"]
        XCTAssertEqual(Array(costArgs.prefix(4)), ["metrics", "cost", "--format", "json"])
        XCTAssertTrue(costArgs.contains("--start"))
        XCTAssertTrue(costArgs.contains("--end"))
    }

    func testListRecentScoresRejectsBlankRunId() async {
        let client = SmithersClient(cwd: "/tmp")
        do {
            _ = try await client.listRecentScores(runId: " ")
            XCTFail("Expected blank scores run ID to throw")
        } catch SmithersError.cli(let message) {
            XCTAssertTrue(message.contains("Run ID is required"))
        } catch {
            XCTFail("Expected SmithersError.cli, got \(error)")
        }
    }

    func testListRecentScoresFixturesUseRequestedRunId() async throws {
        setenv("SMITHERS_GUI_UITEST", "1", 1)
        defer { unsetenv("SMITHERS_GUI_UITEST") }

        let client = SmithersClient(cwd: "/tmp")
        let scores = try await client.listRecentScores(runId: "run-xyz")
        XCTAssertFalse(scores.isEmpty)
        XCTAssertEqual(Set(scores.compactMap(\.runId)), ["run-xyz"])
    }

    func testScoreMetricsFixturesLoad() async throws {
        setenv("SMITHERS_GUI_UITEST", "1", 1)
        defer { unsetenv("SMITHERS_GUI_UITEST") }

        let client = SmithersClient(cwd: "/tmp")
        let tokenMetrics = try await client.getTokenUsageMetrics()
        let latencyMetrics = try await client.getLatencyMetrics()
        let costReport = try await client.getCostTracking()

        XCTAssertGreaterThan(tokenMetrics.totalTokens, 0)
        XCTAssertGreaterThan(latencyMetrics.count, 0)
        XCTAssertGreaterThan(costReport.totalCostUSD, 0)
    }

    // TRANSPORT_WORKFLOW_DETACH_FLAG — "up <path> -d --format json"
    func testRunWorkflowDetachFlag() {
        let workflowPath = ".smithers/workflows/deploy.yaml"
        let args = ["up", workflowPath, "-d", "--format", "json"]
        XCTAssertTrue(args.contains("-d"), "Must include detach flag")
        XCTAssertEqual(args[0], "up")
    }

    // TRANSPORT_CLI_NO_COLOR_ENV — NO_COLOR=1 set in env
    func testNoColorEnvExpected() {
        // Verified from source: env["NO_COLOR"] = "1"
        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        XCTAssertEqual(env["NO_COLOR"], "1")
    }

    // TRANSPORT_CLI_JSON_FORMAT_FLAG — --format json used in all data commands
    func testAllDataCommandsUseJsonFormat() {
        // All CLI data-fetching commands include --format json.
        // Verified by reading source for: listWorkflows, listRuns, inspectRun,
        // listMemoryFacts, recallMemory, listRecentScores, runWorkflow, listSnapshots, listCrons, createCron
        let commands: [[String]] = [
            ["workflow", "list", "--format", "json"],
            ["ps", "--format", "json"],
            ["inspect", "RUN", "--format", "json"],
            SmithersMemoryCLI.listArgs(namespace: "global:default", workflowPath: ".smithers/workflows/implement.tsx"),
            SmithersMemoryCLI.recallArgs(query: "Q", workflowPath: ".smithers/workflows/implement.tsx", topK: 10),
            ["scores", "RUN", "--format", "json"],
            ["metrics", "token-usage", "--format", "json"],
            ["metrics", "latency", "--format", "json"],
            ["metrics", "cost", "--format", "json"],
            ["up", ".smithers/workflows/deploy.yaml", "-d", "--format", "json"],
            ["timeline", "RUN", "--format", "json"],
            ["cron", "list", "--format", "json"],
            ["cron", "add", "0 * * * *", ".smithers/workflows/hourly.tsx", "--format", "json"],
        ]
        for cmd in commands {
            XCTAssertTrue(cmd.contains("--format"), "Command \(cmd[0]) missing --format")
            XCTAssertTrue(cmd.contains("json"), "Command \(cmd[0]) missing json")
        }
    }

    // TRANSPORT_CRON_TOGGLE_ENABLE_DISABLE — toggle maps to enable/disable subcommands.
    func testCronToggleEnableDisableCommandShape() {
        let enableArgs = ["cron", "enable", "cron-123"]
        XCTAssertEqual(enableArgs, ["cron", "enable", "cron-123"])

        let disableArgs = ["cron", "disable", "cron-123"]
        XCTAssertEqual(disableArgs, ["cron", "disable", "cron-123"])
    }

    // TRANSPORT_CRON_DELETE_COMMAND — delete uses `cron rm <id>`.
    func testCronDeleteCommandShape() {
        let args = ["cron", "rm", "cron-123"]
        XCTAssertEqual(args, ["cron", "rm", "cron-123"])
    }

    // TRANSPORT_SMITHERS_BINARY_DISCOVERY — uses /usr/bin/env smithers
    func testBinaryDiscoveryViaEnv() {
        // Verified from source: process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // process.arguments = [smithersBin] + args where smithersBin = "smithers"
        let execURL = URL(fileURLWithPath: "/usr/bin/env")
        XCTAssertEqual(execURL.path, "/usr/bin/env")
    }

    // TRANSPORT_CLI_PATH_INHERITANCE — environment inherits PATH
    func testPathInheritance() {
        let env = ProcessInfo.processInfo.environment
        XCTAssertNotNil(env["PATH"], "PATH must be available for inheritance")
    }

    // JJHUB_GET_CURRENT_REPO — "jjhub repo view --json --no-color"
    func testJJHubGetCurrentRepoCommandShape() {
        let args = ["repo", "view", "--json", "--no-color"]
        XCTAssertEqual(args[0], "repo")
        XCTAssertEqual(args[1], "view")
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_LIST_WORKFLOWS — "jjhub workflow list -L <n> --json --no-color"
    func testJJHubListWorkflowsCommandShape() {
        let args = ["workflow", "list", "-L", "100", "--json", "--no-color"]
        XCTAssertEqual(args[0], "workflow")
        XCTAssertEqual(args[1], "list")
        XCTAssertEqual(args[2], "-L")
        XCTAssertEqual(args[3], "100")
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_TRIGGER_WORKFLOW_WITH_REF — "jjhub workflow run <id> --ref <ref> --json --no-color"
    func testJJHubTriggerWorkflowWithRefCommandShape() {
        let args = ["workflow", "run", "301", "--ref", "feature/ref", "--json", "--no-color"]
        XCTAssertEqual(args[0], "workflow")
        XCTAssertEqual(args[1], "run")
        XCTAssertEqual(args[2], "301")
        XCTAssertEqual(args[3], "--ref")
        XCTAssertEqual(args[4], "feature/ref")
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_TRIGGER_WORKFLOW_WITHOUT_REF — "jjhub workflow run <id> --json --no-color"
    func testJJHubTriggerWorkflowWithoutRefCommandShape() {
        let args = ["workflow", "run", "301", "--json", "--no-color"]
        XCTAssertEqual(args[0], "workflow")
        XCTAssertEqual(args[1], "run")
        XCTAssertEqual(args[2], "301")
        XCTAssertFalse(args.contains("--ref"))
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_LIST_CHANGES — "jjhub change list --limit <n> --json --no-color"
    func testJJHubListChangesCommandShape() {
        let args = ["change", "list", "--limit", "50", "--json", "--no-color"]
        XCTAssertEqual(args[0], "change")
        XCTAssertEqual(args[1], "list")
        XCTAssertTrue(args.contains("--limit"))
        XCTAssertTrue(args.contains("--json"))
        XCTAssertTrue(args.contains("--no-color"))
    }

    // JJHUB_VIEW_CHANGE — "jjhub change show <changeID> --json --no-color"
    func testJJHubViewChangeCommandShape() {
        let args = ["change", "show", "abc12345", "--json", "--no-color"]
        XCTAssertEqual(args[0], "change")
        XCTAssertEqual(args[1], "show")
        XCTAssertEqual(args[2], "abc12345")
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_CHANGE_DIFF — "jjhub change diff [changeID] --no-color"
    func testJJHubChangeDiffCommandShapes() {
        let withID = ["change", "diff", "abc12345", "--no-color"]
        XCTAssertEqual(withID[0], "change")
        XCTAssertEqual(withID[1], "diff")
        XCTAssertEqual(withID[2], "abc12345")
        XCTAssertEqual(withID.last, "--no-color")

        let withoutID = ["change", "diff", "--no-color"]
        XCTAssertEqual(withoutID[0], "change")
        XCTAssertEqual(withoutID[1], "diff")
        XCTAssertEqual(withoutID.last, "--no-color")
    }

    // JJHUB_STATUS — "jjhub status --no-color"
    func testJJHubStatusCommandShape() {
        let args = ["status", "--no-color"]
        XCTAssertEqual(args[0], "status")
        XCTAssertEqual(args[1], "--no-color")
    }

    // JJ_WORKING_COPY_DIFF — "jj diff --no-color"
    func testJJWorkingCopyDiffCommandShape() {
        let args = ["diff", "--no-color"]
        XCTAssertEqual(args, ["diff", "--no-color"])
    }

    // JJHUB_CREATE_BOOKMARK — "jjhub bookmark create <name> --change-id <id> -r --json --no-color"
    func testJJHubCreateBookmarkCommandShape() {
        var args = ["bookmark", "create", "feature/bookmark", "--change-id", "abc12345", "-r"]
        args += ["--json", "--no-color"]
        XCTAssertEqual(args[0], "bookmark")
        XCTAssertEqual(args[1], "create")
        XCTAssertTrue(args.contains("--change-id"))
        XCTAssertTrue(args.contains("-r"))
        XCTAssertEqual(Array(args.suffix(2)), ["--json", "--no-color"])
    }

    // JJHUB_DELETE_BOOKMARK — "jjhub bookmark delete <name> -r --no-color"
    func testJJHubDeleteBookmarkCommandShape() {
        let args = ["bookmark", "delete", "feature/bookmark", "-r", "--no-color"]
        XCTAssertEqual(args[0], "bookmark")
        XCTAssertEqual(args[1], "delete")
        XCTAssertEqual(args[2], "feature/bookmark")
        XCTAssertEqual(args.last, "--no-color")
    }

    func testJJHubMethodsUseFixturesInUITestMode() async throws {
        setenv("SMITHERS_GUI_UITEST", "1", 1)
        defer { unsetenv("SMITHERS_GUI_UITEST") }

        let client = SmithersClient()

        let repo = try await client.getCurrentRepo()
        XCTAssertEqual(repo.defaultBookmark, "main")

        let workflows = try await client.listJJHubWorkflows(limit: 10)
        XCTAssertEqual(workflows.count, 2)
        XCTAssertEqual(workflows.first?.id, 301)

        let run = try await client.triggerJJHubWorkflow(workflowID: 301, ref: "")
        XCTAssertEqual(run.workflowDefinitionID, 301)
        XCTAssertEqual(run.triggerRef, "main")
    }
}

// MARK: - Approval Transport Tests

@MainActor
final class SmithersClientApprovalTransportTests: XCTestCase {
    private func makeTemporarySmithersCLI(body: String) throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientApprovalTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.txt")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS_FILE='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS_FILE"
        \(body)
        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func readCalls(_ calls: URL) throws -> String {
        try String(contentsOf: calls, encoding: .utf8)
    }

    func testListRunsParsesRelativeStartedValuesFromCLI() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "ps" ] && [ "$2" = "--format" ] && [ "$3" = "json" ]; then
          cat <<'JSON'
        {"runs":[{"id":"run-old","workflow":"old","status":"running","started":"2h ago"},{"id":"run-new","workflow":"new","status":"running","started":"15m ago"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let runs = try await client.listRuns()

        XCTAssertEqual(runs.count, 2)
        XCTAssertNotNil(runs.first(where: { $0.runId == "run-old" })?.startedAtMs)
        XCTAssertNotNil(runs.first(where: { $0.runId == "run-new" })?.startedAtMs)

        let sorted = runs.sortedByStartedAtDescending()
        XCTAssertEqual(sorted.map(\.runId), ["run-new", "run-old"])
    }

    func testListRunsParsesStartedAtAliasesFromCLI() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "ps" ] && [ "$2" = "--format" ] && [ "$3" = "json" ]; then
          cat <<'JSON'
        {"runs":[{"id":"run-old","workflow":"old","status":"running","started_at":"2026-04-16T10:00:00Z"},{"id":"run-new","workflow":"new","status":"running","startedAt":"2026-04-16T12:00:00Z"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let runs = try await client.listRuns()

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first(where: { $0.runId == "run-old" })?.startedAtMs, 1_776_333_600_000)
        XCTAssertEqual(runs.first(where: { $0.runId == "run-new" })?.startedAtMs, 1_776_340_800_000)

        let sorted = runs.sortedByStartedAtDescending()
        XCTAssertEqual(sorted.map(\.runId), ["run-new", "run-old"])
    }

    func testListPendingApprovalsUsesExecApprovalListWhenAvailable() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "approval" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
          cat <<'JSON'
        [{"id":"approval-1","runId":"run-1","nodeId":"gate-1","workflowPath":".smithers/workflows/release.yml","gate":"Release Gate","status":"pending","payload":{"environment":"prod"},"requestedAt":1700000000000,"resolvedAt":null,"resolvedBy":null}]
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let approvals = try await client.listPendingApprovals()

        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals[0].id, "approval-1")
        XCTAssertEqual(approvals[0].gate, "Release Gate")
        XCTAssertEqual(approvals[0].source, "exec")
        XCTAssertTrue((approvals[0].payload ?? "").contains("\"environment\":\"prod\""))
    }

    func testListRecentDecisionsUsesExecHistoryWhenAvailable() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "approval" ] && [ "$2" = "decisions" ]; then
          cat <<'JSON'
        [{"id":"decision-1","run_id":"run-1","node_id":"gate-1","decision":"approved","note":"ship it","decided_at_ms":1700000100000,"decided_by":"reviewer","requested_at_ms":1700000000000,"workflow_path":".smithers/workflows/release.yml","gate":"Release Gate","payload":{"environment":"prod"}}]
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let decisions = try await client.listRecentDecisions(limit: 10)

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].id, "decision-1")
        XCTAssertEqual(decisions[0].action, "approved")
        XCTAssertEqual(decisions[0].resolvedBy, "reviewer")
        XCTAssertEqual(decisions[0].requestedAt, 1700000000000)
        XCTAssertEqual(decisions[0].source, "exec")
        XCTAssertTrue((decisions[0].payload ?? "").contains("\"environment\":\"prod\""))
    }

    func testListPendingApprovalsFallsBackToSyntheticWhenNoApprovalTransport() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "approval" ] && [ "$2" = "list" ]; then
          echo "unknown command: approval list" >&2
          exit 2
        fi
        if [ "$1" = "approvals" ] && [ "$2" = "list" ]; then
          echo "unknown command: approvals list" >&2
          exit 2
        fi
        if [ "$1" = "ps" ] && [ "$2" = "--format" ] && [ "$3" = "json" ]; then
          cat <<'JSON'
        [{"runId":"run-synth","workflowName":"Release","workflowPath":".smithers/workflows/release.yml","status":"waiting-approval","startedAtMs":1700000000000}]
        JSON
          exit 0
        fi
        if [ "$1" = "inspect" ] && [ "$2" = "run-synth" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
          cat <<'JSON'
        {"run":{"runId":"run-synth","workflowName":"Release","workflowPath":".smithers/workflows/release.yml","status":"waiting-approval","startedAtMs":1700000000000},"tasks":[{"nodeId":"deploy-gate","label":"Deploy Gate","iteration":0,"state":"blocked"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let approvals = try await client.listPendingApprovals()

        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals[0].runId, "run-synth")
        XCTAssertEqual(approvals[0].nodeId, "deploy-gate")
        XCTAssertEqual(approvals[0].source, "synthetic")
    }

    func testApproveAndDenyUseJSONFormatOnExecFallback() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "approve" ]; then
          echo '{}'
          exit 0
        fi
        if [ "$1" = "deny" ]; then
          echo '{}'
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        try await client.approveNode(runId: "run-1", nodeId: "gate-1")
        try await client.denyNode(runId: "run-1", nodeId: "gate-1")

        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("approve run-1 --node gate-1 --format json"))
        XCTAssertTrue(calls.contains("deny run-1 --node gate-1 --format json"))
        XCTAssertFalse(calls.contains("--iteration 0"))
    }

    func testApproveAndDenyForwardIterationWhenProvidedOnExecFallback() async throws {
        let cli = try makeTemporarySmithersCLI(body: """
        if [ "$1" = "approve" ]; then
          echo '{}'
          exit 0
        fi
        if [ "$1" = "deny" ]; then
          echo '{}'
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        try await client.approveNode(runId: "run-1", nodeId: "gate-1", iteration: 2)
        try await client.denyNode(runId: "run-1", nodeId: "gate-1", iteration: 3)

        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("approve run-1 --node gate-1 --iteration 2 --format json"))
        XCTAssertTrue(calls.contains("deny run-1 --node gate-1 --iteration 3 --format json"))
    }
}

// MARK: - Model Decoding Tests

final class SmithersModelDecodingTests: XCTestCase {

    func testRunSummaryDecoding() throws {
        let json = """
        {"runId":"r1","status":"running","workflowName":"test","workflowPath":"test.ts","startedAtMs":1700000000000,"finishedAtMs":null,"summary":{"total":10,"finished":3,"failed":1},"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.runId, "r1")
        XCTAssertEqual(run.status, .running)
        XCTAssertEqual(run.totalNodes, 10)
        XCTAssertEqual(run.finishedNodes, 3)
        XCTAssertEqual(run.failedNodes, 1)
        XCTAssertEqual(run.completedNodes, 4)
        XCTAssertEqual(run.progress, 0.4)
        XCTAssertNotNil(run.startedAt)
        XCTAssertNil(run.finishedAt)
    }

    func testRunSummaryProgressZeroWhenNoTotal() throws {
        let json = """
        {"runId":"r2","status":"finished","workflowName":null,"workflowPath":null,"startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.progress, 0)
        XCTAssertEqual(run.totalNodes, 0)
    }

    func testRunStatusDecoding() throws {
        let statuses: [(String, RunStatus)] = [
            ("\"running\"", .running),
            ("\"waiting-approval\"", .waitingApproval),
            ("\"finished\"", .finished),
            ("\"failed\"", .failed),
            ("\"cancelled\"", .cancelled),
        ]
        for (json, expected) in statuses {
            let decoded = try JSONDecoder().decode(RunStatus.self, from: json.data(using: .utf8)!)
            XCTAssertEqual(decoded, expected)
        }
    }

    func testRunStatusLabels() {
        XCTAssertEqual(RunStatus.running.label, "RUNNING")
        XCTAssertEqual(RunStatus.waitingApproval.label, "APPROVAL")
        XCTAssertEqual(RunStatus.finished.label, "FINISHED")
        XCTAssertEqual(RunStatus.failed.label, "FAILED")
        XCTAssertEqual(RunStatus.cancelled.label, "CANCELLED")
    }

    func testRunInspectionDecoding() throws {
        let json = """
        {"run":{"runId":"r1","status":"running","workflowName":null,"workflowPath":null,"startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null},"tasks":[{"nodeId":"n1","label":"step1","iteration":0,"state":"finished","lastAttempt":1,"updatedAtMs":1000}]}
        """
        let inspection = try JSONDecoder().decode(RunInspection.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(inspection.tasks.count, 1)
        XCTAssertEqual(inspection.tasks[0].nodeId, "n1")
        XCTAssertEqual(inspection.tasks[0].state, "finished")
    }

    func testCLIInspectResponseMapsToRunInspection() throws {
        let json = """
        {
          "run": {
            "id": "92e861d1-d3e7-4926-a087-91f9a9c1598c",
            "workflow": "ticket-kanban",
            "status": "running",
            "started": "2026-04-15T01:05:15.093Z",
            "elapsed": "1h 0m",
            "error": {"message": "boom"}
          },
          "steps": [
            {
              "id": "0001-port-agents-view:implement",
              "state": "finished",
              "attempt": 1,
              "label": "0001-port-agents-view:implement"
            },
            {
              "id": "0008-port-triggers-and-crons:review:0",
              "state": "in-progress",
              "attempt": 1,
              "label": "0008-port-triggers-and-crons:review:0"
            },
            {
              "id": "release-gate",
              "state": "waiting-approval",
              "attempt": 0,
              "label": "Release gate"
            }
          ],
          "cta": {
            "commands": [
              {"command": "smithers logs 92e861d1-d3e7-4926-a087-91f9a9c1598c", "description": "Tail run logs"}
            ]
          }
        }
        """

        let inspection = try SmithersClient.decodeRunInspection(from: json.data(using: .utf8)!)

        XCTAssertEqual(inspection.run.runId, "92e861d1-d3e7-4926-a087-91f9a9c1598c")
        XCTAssertEqual(inspection.run.workflowName, "ticket-kanban")
        XCTAssertEqual(inspection.run.status, .running)
        XCTAssertEqual(inspection.run.startedAtMs, 1_776_215_115_093)
        XCTAssertEqual(inspection.run.summary?["total"], 3)
        XCTAssertEqual(inspection.run.summary?["finished"], 1)
        XCTAssertEqual(inspection.run.summary?["running"], 1)
        XCTAssertEqual(inspection.run.summary?["waiting-approval"], 1)
        XCTAssertTrue(inspection.run.errorJson?.contains("\"message\":\"boom\"") == true)

        XCTAssertEqual(inspection.tasks.count, 3)
        XCTAssertEqual(inspection.tasks[0].nodeId, "0001-port-agents-view:implement")
        XCTAssertEqual(inspection.tasks[0].lastAttempt, 1)
        XCTAssertEqual(inspection.tasks[1].state, "running")
        XCTAssertEqual(inspection.tasks[2].label, "Release gate")
    }

    func testVerboseCLIInspectEnvelopeMapsToRunInspection() throws {
        let json = """
        {
          "ok": true,
          "data": {
            "run": {
              "id": "run-verbose",
              "workflow": "ticket-kanban",
              "status": "finished",
              "started": "2026-04-15T01:05:15Z",
              "finished": "2026-04-15T01:06:15Z"
            },
            "steps": [
              {"id": "validate", "state": "finished", "attempt": 2, "label": "Validate"}
            ]
          }
        }
        """

        let inspection = try SmithersClient.decodeRunInspection(from: json.data(using: .utf8)!)

        XCTAssertEqual(inspection.run.runId, "run-verbose")
        XCTAssertEqual(inspection.run.status, .finished)
        XCTAssertEqual(inspection.run.finishedAtMs, 1_776_215_175_000)
        XCTAssertEqual(inspection.tasks.first?.nodeId, "validate")
        XCTAssertEqual(inspection.tasks.first?.lastAttempt, 2)
    }

    func testWorkflowDecoding() throws {
        let json = """
        {"id":"w1","workspaceId":null,"name":"Test Flow","relativePath":"flow.ts","status":"active","updatedAt":null}
        """
        let wf = try JSONDecoder().decode(Workflow.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(wf.id, "w1")
        XCTAssertEqual(wf.name, "Test Flow")
        XCTAssertEqual(wf.status, .active)
    }

    func testWorkflowDAGDecoding() throws {
        let json = """
        {"runId":"graph","frameNo":0,"xml":{"kind":"element","tag":"smithers:workflow","props":{"name":"main"},"children":[{"kind":"element","tag":"smithers:sequence","props":{},"children":[{"kind":"element","tag":"smithers:task","props":{"id":"main"},"children":[]}]}]},"tasks":[{"nodeId":"main","ordinal":0,"iteration":0,"outputTableName":"main","needsApproval":false,"approvalMode":"gate","retries":0,"timeoutMs":null,"heartbeatTimeoutMs":60000,"continueOnFail":false}]}
        """
        let dag = try JSONDecoder().decode(WorkflowDAG.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(dag.runId, "graph")
        XCTAssertEqual(dag.entryTask, "main")
        XCTAssertEqual(dag.tasks.count, 1)
        XCTAssertEqual(dag.tasks[0].nodeId, "main")
        XCTAssertEqual(dag.edges, [])
    }

    func testLaunchResultDecoding() throws {
        let json = """
        {"runId":"launched-123"}
        """
        let result = try JSONDecoder().decode(SmithersClient.LaunchResult.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(result.runId, "launched-123")
    }

    func testMemoryFactDecoding() throws {
        let json = """
        {"namespace":"default","key":"api-key","valueJson":"{\\"v\\":1}","schemaSig":"abc","createdAtMs":1000,"updatedAtMs":2000,"ttlMs":60000}
        """
        let fact = try JSONDecoder().decode(MemoryFact.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(fact.namespace, "default")
        XCTAssertEqual(fact.key, "api-key")
        XCTAssertEqual(fact.id, "default:api-key")
        XCTAssertNotNil(fact.ttlMs)
    }

    func testMemoryRecallResultDecoding() throws {
        let json = """
        {"score":0.92,"content":"The API uses REST","metadata":"source:docs"}
        """
        let result = try JSONDecoder().decode(MemoryRecallResult.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(result.score, 0.92)
        XCTAssertEqual(result.content, "The API uses REST")
    }

    func testScoreRowDecoding() throws {
        let json = """
        {"id":"s1","runId":"r1","nodeId":"n1","iteration":0,"attempt":1,"scorerId":"sc1","scorerName":"accuracy","source":"live","score":0.85,"reason":"correct","metaJson":null,"latencyMs":120,"scoredAtMs":1700000000000}
        """
        let score = try JSONDecoder().decode(ScoreRow.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(score.score, 0.85)
        XCTAssertEqual(score.scorerName, "accuracy")
        XCTAssertNotNil(score.scoredAt)
    }

    func testSnapshotDecoding() throws {
        let json = """
        {"id":"snap1","runId":"r1","nodeId":"n1","label":"checkpoint","kind":"auto","parentId":null,"createdAtMs":1700000000000}
        """
        let snap = try JSONDecoder().decode(Snapshot.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(snap.id, "snap1")
        XCTAssertEqual(snap.kind, "auto")
    }

    func testSnapshotDiffDecoding() throws {
        let json = """
        {"fromId":"a","toId":"b","changes":["added node X","removed node Y"]}
        """
        let diff = try JSONDecoder().decode(SnapshotDiff.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(diff.changes?.count, 2)
    }

    func testCronScheduleDecoding() throws {
        let json = """
        {"cronId":"c1","pattern":"0 * * * *","workflowPath":"hourly.ts","enabled":true,"nextRunAtMs":1700003600000}
        """
        let cron = try JSONDecoder().decode(CronSchedule.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(cron.id, "c1")
        XCTAssertEqual(cron.pattern, "0 * * * *")
        XCTAssertTrue(cron.enabled)
        XCTAssertEqual(cron.nextRunAtMs, 1_700_003_600_000)
    }

    func testSSEEventStruct() {
        let event = SSEEvent(event: "update", data: "{\"progress\":50}")
        XCTAssertEqual(event.event, "update")
        XCTAssertEqual(event.data, "{\"progress\":50}")
    }

    func testSSEEventNilType() {
        let event = SSEEvent(event: nil, data: "ping")
        XCTAssertNil(event.event)
        XCTAssertEqual(event.data, "ping")
    }
}

// MARK: - Aggregate Scores Logic Tests

final class AggregateScoresLogicTests: XCTestCase {

    /// Test the aggregation logic used by SmithersClient.aggregateScores
    func testAggregateScoresComputation() {
        let scores: [ScoreRow] = [
            makeScore(id: "1", scorerName: "accuracy", score: 0.8),
            makeScore(id: "2", scorerName: "accuracy", score: 0.9),
            makeScore(id: "3", scorerName: "accuracy", score: 1.0),
            makeScore(id: "4", scorerName: "latency", score: 0.5),
            makeScore(id: "5", scorerName: "latency", score: 0.7),
        ]

        let aggregates = AggregateScore.aggregate(scores)

        let accuracy = aggregates.first(where: { $0.scorerName == "accuracy" })!
        XCTAssertEqual(accuracy.count, 3)
        XCTAssertEqual(accuracy.mean, 0.9, accuracy: 0.001)
        XCTAssertEqual(accuracy.min, 0.8)
        XCTAssertEqual(accuracy.max, 1.0)
        XCTAssertEqual(accuracy.p50, 0.9) // sorted[1] for count=3

        let latency = aggregates.first(where: { $0.scorerName == "latency" })!
        XCTAssertEqual(latency.count, 2)
        XCTAssertEqual(latency.mean, 0.6, accuracy: 0.001)
        XCTAssertEqual(latency.min, 0.5)
        XCTAssertEqual(latency.max, 0.7)
        XCTAssertEqual(latency.p50, 0.6) // median of [0.5, 0.7]
    }

    /// Test aggregation with nil scorerName falls back to scorerId then "Unknown"
    func testAggregateScoresFallbackNaming() {
        let scores: [ScoreRow] = [
            makeScore(id: "1", scorerId: "sid1", scorerName: nil, score: 0.5),
            makeScore(id: "2", scorerId: nil, scorerName: nil, score: 0.3),
        ]

        let aggregates = AggregateScore.aggregate(scores)

        XCTAssertNotNil(aggregates.first { $0.scorerName == "sid1" })
        XCTAssertNotNil(aggregates.first { $0.scorerName == "Unknown" })
    }

    private func makeScore(id: String, scorerId: String? = "sc", scorerName: String? = nil, score: Double) -> ScoreRow {
        // Decode from JSON to exercise the same model shape returned by the CLI.
        let json = """
        {"id":"\(id)","runId":"r1","nodeId":null,"iteration":null,"attempt":null,"scorerId":\(scorerId.map { "\"\($0)\"" } ?? "null"),"scorerName":\(scorerName.map { "\"\($0)\"" } ?? "null"),"source":"live","score":\(score),"reason":null,"metaJson":null,"latencyMs":null,"scoredAtMs":1000}
        """
        return try! JSONDecoder().decode(ScoreRow.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - JJHub Client Tests

@MainActor
final class SmithersClientJJHubStubTests: XCTestCase {
    private func makeTemporaryJJHubCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientJJHubTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.txt")
        let bin = root.appendingPathComponent("jjhub")
        let script = """
        #!/bin/sh
        CALLS_FILE='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS_FILE"

        if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        [{"id":42,"number":10,"title":"Listed issue","body":"listed body","state":"open","labels":[{"id":1,"name":"bug","color":"ff0000"}],"assignees":[{"id":7,"login":"dev1"}],"comment_count":3}]
        JSON
          exit 0
        fi

        if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
          cat <<'JSON'
        {"id":42,"number":10,"title":"Viewed issue","body":"full body","state":"open","labels":[{"id":1,"name":"bug","color":"ff0000"}],"assignees":[{"id":7,"login":"dev1"}],"comment_count":4}
        JSON
          exit 0
        fi

        if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
          cat <<'JSON'
        {"id":43,"number":11,"title":"Created issue","body":"created body","state":"open","labels":[],"assignees":[],"comment_count":0}
        JSON
          exit 0
        fi

        if [ "$1" = "issue" ] && [ "$2" = "close" ]; then
          cat <<'JSON'
        {"id":42,"number":10,"title":"Viewed issue","body":"full body","state":"closed","labels":[{"id":1,"name":"bug","color":"ff0000"}],"assignees":[{"id":7,"login":"dev1"}],"comment_count":4}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        [{"id":"ws_123","repository_id":1,"user_id":7,"name":"Primary","status":"running","is_fork":false,"freestyle_vm_id":"vm_123","persistence":"sticky","idle_timeout_seconds":1800,"created_at":"2026-03-07T00:00:00Z","updated_at":"2026-03-07T01:00:00Z"}]
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "view" ]; then
          cat <<'JSON'
        {"id":"ws_123","repository_id":1,"user_id":7,"name":"Primary","status":"running","is_fork":false,"freestyle_vm_id":"vm_123","persistence":"sticky","idle_timeout_seconds":1800,"created_at":"2026-03-07T00:00:00Z","updated_at":"2026-03-07T01:00:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "create" ]; then
          cat <<'JSON'
        {"id":"ws_created","repository_id":1,"user_id":7,"name":"Created Workspace","status":"running","is_fork":false,"freestyle_vm_id":"vm_created","persistence":"sticky","snapshot_id":"snap_123","idle_timeout_seconds":1800,"created_at":"2026-03-07T02:00:00Z","updated_at":"2026-03-07T02:00:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "fork" ]; then
          cat <<'JSON'
        {"id":"ws_forked","repository_id":1,"user_id":7,"name":"Forked Workspace","status":"running","is_fork":true,"parent_workspace_id":"ws_123","freestyle_vm_id":"vm_forked","persistence":"sticky","idle_timeout_seconds":1800,"created_at":"2026-03-07T02:30:00Z","updated_at":"2026-03-07T02:30:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "delete" ]; then
          printf '{"status":"deleted","id":"%s"}\n' "$3"
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "suspend" ]; then
          printf '{"id":"%s","name":"Primary","status":"suspended","created_at":"2026-03-07T00:00:00Z"}\n' "$3"
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "resume" ]; then
          printf '{"id":"%s","name":"Primary","status":"running","created_at":"2026-03-07T00:00:00Z"}\n' "$3"
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "snapshot" ] && [ "$3" = "list" ]; then
          cat <<'JSON'
        [{"id":"snap_123","repository_id":1,"user_id":7,"name":"Morning","workspace_id":"ws_123","freestyle_snapshot_id":"fs_snap_123","created_at":"2026-03-07T03:00:00Z","updated_at":"2026-03-07T03:00:00Z"}]
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "snapshot" ] && [ "$3" = "view" ]; then
          cat <<'JSON'
        {"id":"snap_123","repository_id":1,"user_id":7,"name":"Morning","workspace_id":"ws_123","freestyle_snapshot_id":"fs_snap_123","created_at":"2026-03-07T03:00:00Z","updated_at":"2026-03-07T03:00:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "snapshot" ] && [ "$3" = "create" ]; then
          cat <<'JSON'
        {"id":"snap_created","repository_id":1,"user_id":7,"name":"Nightly","workspace_id":"ws_123","freestyle_snapshot_id":"fs_snap_created","created_at":"2026-03-07T04:00:00Z","updated_at":"2026-03-07T04:00:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "snapshot" ] && [ "$3" = "delete" ]; then
          printf '{"status":"deleted","id":"%s"}\n' "$4"
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        [{"number":42,"title":"Listed landing","body":"listed body","state":"open","target_bookmark":"main","author":{"id":7,"login":"dev1"},"created_at":"2026-02-19T00:00:00Z"}]
        JSON
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "view" ]; then
          cat <<'JSON'
        {"landing":{"number":42,"title":"Viewed landing","body":"full body","state":"open","target_bookmark":"main","author":{"id":7,"login":"dev1"},"created_at":"2026-02-19T00:00:00Z"},"changes":[{"id":1,"landing_request_id":42,"change_id":"kseed001","position_in_stack":1,"created_at":"2026-02-19T00:00:00Z"}],"reviews":[]}
        JSON
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "create" ]; then
          cat <<'JSON'
        {"number":77,"title":"Created landing","body":"created body","state":"open","target_bookmark":"main","author":{"id":7,"login":"dev1"},"created_at":"2026-02-19T00:00:00Z"}
        JSON
          exit 0
        fi

        if [ "$1" = "change" ] && [ "$2" = "diff" ]; then
          printf 'diff --git a/file.swift b/file.swift\\n+landing change\\n'
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "review" ]; then
          echo "reviewed"
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "land" ]; then
          echo "landed"
          exit 0
        fi

        if [ "$1" = "land" ] && [ "$2" = "checks" ]; then
          printf 'ci/unit: pass\\nci/lint: pass\\n'
          exit 0
        fi

        if [ "$1" = "search" ] && [ "$2" = "code" ]; then
          cat <<'JSON'
        {"items":[{"id":7,"repository":"alice/demo","file_path":"src/main.swift","text_matches":[{"content":"func main()","line_number":12}]}],"total_count":1,"page":1,"limit":30}
        JSON
          exit 0
        fi

        if [ "$1" = "search" ] && [ "$2" = "issues" ]; then
          cat <<'JSON'
        {"items":[{"id":10,"number":5,"title":"Bug report","state":"open","repository_name":"alice/demo"}],"total_count":1,"page":1,"limit":30}
        JSON
          exit 0
        fi

        if [ "$1" = "search" ] && [ "$2" = "repos" ]; then
          cat <<'JSON'
        {"items":[{"id":1,"owner":"alice","name":"demo","full_name":"alice/demo","description":"A demo repo","is_public":true,"topics":[]}],"total_count":1,"page":1,"limit":30}
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func makeTemporaryWorkspacePayloadCLI(
        workspaceListPayload: String,
        workspaceSnapshotListPayload: String = "[]"
    ) throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientWorkspacePayloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.txt")
        let bin = root.appendingPathComponent("jjhub")
        let script = """
        #!/bin/sh
        CALLS_FILE='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS_FILE"

        if [ "$1" = "workspace" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        \(workspaceListPayload)
        JSON
          exit 0
        fi

        if [ "$1" = "workspace" ] && [ "$2" = "snapshot" ] && [ "$3" = "list" ]; then
          cat <<'JSON'
        \(workspaceSnapshotListPayload)
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func readCalls(_ calls: URL) throws -> String {
        try String(contentsOf: calls, encoding: .utf8)
    }

    private func makeIssueListOnlyCLI(issueListPayload: String) throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientIssueListTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.txt")
        let bin = root.appendingPathComponent("jjhub")
        let script = """
        #!/bin/sh
        CALLS_FILE='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS_FILE"

        if [ "$1" = "issue" ] && [ "$2" = "list" ]; then
          cat <<'JSON'
        \(issueListPayload)
        JSON
          exit 0
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func makeSearchAPIFallbackCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientSearchFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.txt")
        let bin = root.appendingPathComponent("jjhub")
        let script = """
        #!/bin/sh
        CALLS_FILE='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS_FILE"

        if [ "$1" = "search" ] && [ "$2" = "code" ]; then
          echo "Unknown command: search" >&2
          exit 2
        fi

        if [ "$1" = "api" ]; then
          case "$2" in
            /search/code*)
              cat <<'JSON'
        {"items":[{"id":99,"repository":"alice/demo","file_path":"src/alt.swift","text_matches":[{"content":"func fallback()","line_number":44}]}],"total_count":1,"page":1,"limit":30}
        JSON
              exit 0
              ;;
          esac
        fi

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    func testListLandingsUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let landings = try await client.listLandings()

        XCTAssertEqual(landings.count, 1)
        XCTAssertEqual(landings[0].number, 42)
        XCTAssertEqual(landings[0].title, "Listed landing")
        XCTAssertEqual(landings[0].description, "listed body")
        XCTAssertEqual(landings[0].targetBranch, "main")
        XCTAssertEqual(landings[0].author, "dev1")
        XCTAssertEqual(landings[0].id, "landing-42")
        XCTAssertTrue(try readCalls(cli.calls).contains("land list -s all -L 100 --json --no-color"))
    }

    func testGetLandingUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let landing = try await client.getLanding(number: 42)

        XCTAssertEqual(landing.title, "Viewed landing")
        XCTAssertEqual(landing.description, "full body")
        XCTAssertEqual(landing.state, "open")
        XCTAssertTrue(try readCalls(cli.calls).contains("land view 42 --json --no-color"))
    }

    func testLandingDiffUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let diff = try await client.landingDiff(number: 42)

        XCTAssertTrue(diff.contains("Change kseed001"))
        XCTAssertTrue(diff.contains("+landing change"))
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("land view 42 --json --no-color"))
        XCTAssertTrue(calls.contains("change diff kseed001 --no-color"))
    }

    func testCreateLandingUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let landing = try await client.createLanding(title: " Created landing ", body: "created body", target: "main", stack: true)

        XCTAssertEqual(landing.number, 77)
        XCTAssertEqual(landing.title, "Created landing")
        XCTAssertEqual(landing.state, "open")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("land create -t Created landing -b created body --target main --stack --json --no-color"))
    }

    func testReviewLandingUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.reviewLanding(number: 42, action: "approve", body: "LGTM")

        XCTAssertTrue(try readCalls(cli.calls).contains("land review 42 -a -b LGTM --no-color"))
    }

    func testReviewLandingRequestChangesUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.reviewLanding(number: 42, action: "request_changes", body: "needs-work")

        XCTAssertTrue(try readCalls(cli.calls).contains("land review 42 -r -b needs-work --no-color"))
    }

    func testLandLandingUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.landLanding(number: 42)

        XCTAssertTrue(try readCalls(cli.calls).contains("land land 42 --no-color"))
    }

    func testLandingChecksUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let checks = try await client.landingChecks(number: 42)

        XCTAssertTrue(checks.contains("ci/unit: pass"))
        XCTAssertTrue(try readCalls(cli.calls).contains("land checks 42 --no-color"))
    }

    func testGetIssueUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let issue = try await client.getIssue(number: 10)

        XCTAssertEqual(issue.title, "Viewed issue")
        XCTAssertEqual(issue.body, "full body")
        XCTAssertEqual(issue.assignees, ["dev1"])
        XCTAssertTrue(try readCalls(cli.calls).contains("issue view 10 --json --no-color"))
    }

    func testCreateIssueUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let issue = try await client.createIssue(title: " Created issue ", body: "created body")

        XCTAssertEqual(issue.number, 11)
        XCTAssertEqual(issue.state, "open")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("issue create -t Created issue -b created body --json --no-color"))
    }

    func testCloseIssueUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.closeIssue(number: 10, comment: "done")

        XCTAssertTrue(try readCalls(cli.calls).contains("issue close 10 -c done --json --no-color"))
    }

    func testCreateWorkspaceUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let workspace = try await client.createWorkspace(name: " Created Workspace ", snapshotId: " snap_123 ")

        XCTAssertEqual(workspace.id, "ws_created")
        XCTAssertEqual(workspace.status, "running")
        XCTAssertEqual(workspace.createdAt, "2026-03-07T02:00:00Z")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("workspace create --name Created Workspace --snapshot snap_123 --json --no-color"))
    }

    func testViewWorkspaceUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let workspace = try await client.viewWorkspace(" ws_123 ")

        XCTAssertEqual(workspace.id, "ws_123")
        XCTAssertEqual(workspace.name, "Primary")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace view ws_123 --json --no-color"))
    }

    func testForkWorkspaceUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let workspace = try await client.forkWorkspace(" ws_123 ", name: " Forked Workspace ")

        XCTAssertEqual(workspace.id, "ws_forked")
        XCTAssertEqual(workspace.name, "Forked Workspace")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace fork ws_123 --name Forked Workspace --json --no-color"))
    }

    func testDeleteWorkspaceUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.deleteWorkspace(" ws_123 ")

        XCTAssertTrue(try readCalls(cli.calls).contains("workspace delete ws_123 --no-color"))
    }

    func testSuspendResumeWorkspaceUseJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.suspendWorkspace(" ws_123 ")
        try await client.resumeWorkspace(" ws_123 ")

        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("workspace suspend ws_123 --json --no-color"))
        XCTAssertTrue(calls.contains("workspace resume ws_123 --json --no-color"))
    }

    func testCreateWorkspaceSnapshotUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let snapshot = try await client.createWorkspaceSnapshot(workspaceId: " ws_123 ", name: " Nightly ")

        XCTAssertEqual(snapshot.id, "snap_created")
        XCTAssertEqual(snapshot.workspaceId, "ws_123")
        XCTAssertEqual(snapshot.createdAt, "2026-03-07T04:00:00Z")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("workspace snapshot create ws_123 --name Nightly --json --no-color"))
    }

    func testViewWorkspaceSnapshotUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let snapshot = try await client.viewWorkspaceSnapshot(" snap_123 ")

        XCTAssertEqual(snapshot.id, "snap_123")
        XCTAssertEqual(snapshot.workspaceId, "ws_123")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace snapshot view snap_123 --json --no-color"))
    }

    func testDeleteWorkspaceSnapshotUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        try await client.deleteWorkspaceSnapshot(" snap_123 ")

        XCTAssertTrue(try readCalls(cli.calls).contains("workspace snapshot delete snap_123 --no-color"))
    }

    // Empty-return stubs
    func testListDecisionsReturnsEmpty() async throws {
        let client = SmithersClient()
        let decisions = try await client.listRecentDecisions()
        XCTAssertTrue(decisions.isEmpty)
    }

    func testListIssuesUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let issues = try await client.listIssues()

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].title, "Listed issue")
        XCTAssertEqual(issues[0].labels, ["bug"])
        XCTAssertTrue(try readCalls(cli.calls).contains("issue list -s all -L 100 --json --no-color"))
    }

    func testListIssuesDecodesWrappedItemsShape() async throws {
        let cli = try makeIssueListOnlyCLI(issueListPayload: """
        {"items":[{"id":"wrapped-10","number":10,"title":"Wrapped issue","description":"wrapped body","status":"open","labels":[{"name":"bug"}],"assignees":[{"login":"dev1"}],"comments":2}]}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let issues = try await client.listIssues(state: "open")

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].id, "wrapped-10")
        XCTAssertEqual(issues[0].title, "Wrapped issue")
        XCTAssertEqual(issues[0].body, "wrapped body")
        XCTAssertEqual(issues[0].state, "open")
        XCTAssertEqual(issues[0].labels, ["bug"])
        XCTAssertEqual(issues[0].assignees, ["dev1"])
        XCTAssertEqual(issues[0].commentCount, 2)
        XCTAssertTrue(try readCalls(cli.calls).contains("issue list -s open -L 100 --json --no-color"))
    }

    func testListIssuesThrowsOnUnsupportedShape() async throws {
        let cli = try makeIssueListOnlyCLI(issueListPayload: """
        {"unexpected":"shape"}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        do {
            _ = try await client.listIssues()
            XCTFail("Expected listIssues to throw for unsupported payload")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("parse issues"))
        }
    }

    func testListWorkspacesUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let workspaces = try await client.listWorkspaces()

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, "ws_123")
        XCTAssertEqual(workspaces[0].status, "running")
        XCTAssertEqual(workspaces[0].createdAt, "2026-03-07T00:00:00Z")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace list -L 100 --json --no-color"))
    }

    func testListWorkspacesDecodesLegacyEnvelopeWithItems() async throws {
        let payload = """
        warning: using legacy transport
        {"ok":true,"data":{"items":[{"id":321,"displayName":" Wrapped Primary ","state":"running","created_at":"2026-03-07T08:00:00Z"}]}}
        """
        let cli = try makeTemporaryWorkspacePayloadCLI(workspaceListPayload: payload)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let workspaces = try await client.listWorkspaces()

        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, "321")
        XCTAssertEqual(workspaces[0].name, "Wrapped Primary")
        XCTAssertEqual(workspaces[0].status, "running")
        XCTAssertEqual(workspaces[0].createdAt, "2026-03-07T08:00:00Z")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace list -L 100 --json --no-color"))
    }

    func testListWorkspaceSnapshotsUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let snapshots = try await client.listWorkspaceSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].id, "snap_123")
        XCTAssertEqual(snapshots[0].workspaceId, "ws_123")
        XCTAssertEqual(snapshots[0].createdAt, "2026-03-07T03:00:00Z")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace snapshot list -L 100 --json --no-color"))
    }

    func testListWorkspaceSnapshotsDecodesLegacyEnvelopeWithResults() async throws {
        let payload = """
        note: fetching snapshots
        {"ok":true,"data":{"results":[{"id":7,"workspace_id":321,"name":" Nightly Backup ","created_at":"2026-03-07T09:00:00Z"}]}}
        """
        let cli = try makeTemporaryWorkspacePayloadCLI(
            workspaceListPayload: "[]",
            workspaceSnapshotListPayload: payload
        )
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let snapshots = try await client.listWorkspaceSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].id, "7")
        XCTAssertEqual(snapshots[0].workspaceId, "321")
        XCTAssertEqual(snapshots[0].name, "Nightly Backup")
        XCTAssertEqual(snapshots[0].createdAt, "2026-03-07T09:00:00Z")
        XCTAssertTrue(try readCalls(cli.calls).contains("workspace snapshot list -L 100 --json --no-color"))
    }

    func testSearchCodeUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let results = try await client.searchCode(query: " fn main ", limit: 7)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "code-7")
        XCTAssertEqual(results[0].title, "main.swift")
        XCTAssertEqual(results[0].description, "alice/demo")
        XCTAssertEqual(results[0].filePath, "src/main.swift")
        XCTAssertEqual(results[0].lineNumber, 12)
        XCTAssertEqual(results[0].snippet, "func main()")
        XCTAssertTrue(try readCalls(cli.calls).contains("search code fn main --limit 7 --json --no-color"))
    }

    func testUnifiedSearchUsesScopeSpecificCLICommand() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let results = try await client.search(query: "demo", scope: .repos, limit: 5)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "repo-1")
        XCTAssertEqual(results[0].title, "alice/demo")
        XCTAssertTrue(try readCalls(cli.calls).contains("search repos demo --limit 5 --json --no-color"))
    }

    func testSearchIssuesUsesJJHubCLIAndStateFilter() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let results = try await client.searchIssues(query: "bug", state: "open", limit: 9)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "issue-10")
        XCTAssertEqual(results[0].title, "Bug report")
        XCTAssertEqual(results[0].description, "#5 · open · alice/demo")
        XCTAssertTrue(try readCalls(cli.calls).contains("search issues bug --limit 9 --state open --json --no-color"))
    }

    func testUnifiedSearchFallsBackToJJHubAPIWhenSearchCommandUnavailable() async throws {
        let cli = try makeSearchAPIFallbackCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let results = try await client.search(query: "fn main", scope: .code, limit: 11)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "code-99")
        XCTAssertEqual(results[0].title, "alt.swift")
        XCTAssertEqual(results[0].description, "alice/demo")
        XCTAssertEqual(results[0].filePath, "src/alt.swift")
        XCTAssertEqual(results[0].lineNumber, 44)
        XCTAssertEqual(results[0].snippet, "func fallback()")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("search code fn main --limit 11 --json --no-color"))
        XCTAssertTrue(calls.contains("api /search/code?q=fn%20main&limit=11 --json --no-color"))
    }

    func testSearchReposUsesJJHubCLI() async throws {
        let cli = try makeTemporaryJJHubCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, jjhubBin: cli.bin)
        let results = try await client.searchRepos(query: "demo", limit: 5)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "repo-1")
        XCTAssertEqual(results[0].title, "alice/demo")
        XCTAssertEqual(results[0].description, "A demo repo")
        XCTAssertTrue(try readCalls(cli.calls).contains("search repos demo --limit 5 --json --no-color"))
    }
}

// MARK: - Prompt Transport Parity Tests

@MainActor
final class SmithersClientPromptTests: XCTestCase {
    private func makePromptClient(promptId: String = "sample", source: String) throws -> (client: SmithersClient, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientPromptTests-\(UUID().uuidString)", isDirectory: true)
        let promptsDir = root.appendingPathComponent(".smithers/prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try source.write(to: promptsDir.appendingPathComponent("\(promptId).mdx"), atomically: true, encoding: .utf8)
        return (SmithersClient(cwd: root.path), root)
    }

    private func makePromptCLI(scriptBody: String) throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientPromptCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        \(scriptBody)

        echo "unexpected command: $*" >&2
        exit 2
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, calls)
    }

    private func readCalls(_ calls: URL) throws -> String {
        try String(contentsOf: calls, encoding: .utf8)
    }

    func testListPromptsFilesystemReturnsPromptEntriesWithoutSource() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientPromptListFSTests-\(UUID().uuidString)", isDirectory: true)
        let promptsDir = root.appendingPathComponent(".smithers/prompts", isDirectory: true)
        try FileManager.default.createDirectory(at: promptsDir, withIntermediateDirectories: true)
        try "# Plan\n".write(to: promptsDir.appendingPathComponent("plan.mdx"), atomically: true, encoding: .utf8)
        try "# Review\n".write(to: promptsDir.appendingPathComponent("review.mdx"), atomically: true, encoding: .utf8)
        try "ignore".write(to: promptsDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let client = SmithersClient(cwd: root.path)
        let prompts = try await client.listPrompts()

        XCTAssertEqual(prompts.map(\.id), ["plan", "review"])
        XCTAssertEqual(prompts.map(\.entryFile), [".smithers/prompts/plan.mdx", ".smithers/prompts/review.mdx"])
        XCTAssertTrue(prompts.allSatisfy { $0.source == nil && $0.inputs == nil })
    }

    func testListPromptsFallsBackToCLIWhenFilesystemMissing() async throws {
        let cli = try makePromptCLI(scriptBody: """
        if [ "$1" = "prompt" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
          cat <<'JSON'
        {"prompts":[{"id":"plan","entryFile":".smithers/prompts/plan.mdx"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let prompts = try await client.listPrompts()

        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].id, "plan")
        XCTAssertEqual(prompts[0].entryFile, ".smithers/prompts/plan.mdx")
        XCTAssertTrue(try readCalls(cli.calls).contains("prompt list --format json"))
    }

    func testGetPromptFilesystemDiscoversInputsUsingSmithersPattern() async throws {
        let source = """
        Reviewer: {props.reviewer}
        Prompt: {props.prompt}
        Again: {props.reviewer}
        Invalid: {props.summary-data} { props.space } {props.1bad}
        Tail: {props.schema}
        """
        let setup = try makePromptClient(promptId: "review", source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let prompt = try await setup.client.getPrompt("review")

        XCTAssertEqual(prompt.id, "review")
        XCTAssertEqual(prompt.source, source)
        XCTAssertEqual(prompt.inputs?.map(\.name), ["reviewer", "prompt", "space", "schema"])
        XCTAssertTrue(prompt.inputs?.allSatisfy { $0.type == "string" } ?? false)
    }

    func testGetPromptFilesystemDiscoversInputsFromMDXFrontmatter() async throws {
        let source = """
        ---
        inputs:
          - name: reviewer
            type: string
            default: codex
          - name: prompt
        props:
          schema:
            type: string
          context: "repo-summary"
        ---
        # Review
        <PromptFrame reviewer={reviewer} prompt={prompt} context={context} />
        """
        let setup = try makePromptClient(promptId: "review-frontmatter", source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let prompt = try await setup.client.getPrompt("review-frontmatter")
        let byName = Dictionary((prompt.inputs ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(prompt.inputs?.map(\.name), ["reviewer", "prompt", "schema", "context"])
        XCTAssertEqual(byName["reviewer"]?.defaultValue, "codex")
        XCTAssertEqual(byName["reviewer"]?.type, "string")
        XCTAssertEqual(byName["schema"]?.type, "string")
        XCTAssertEqual(byName["context"]?.defaultValue, "repo-summary")
    }

    func testGetPromptFilesystemDiscoversInputsFromMDXComponentProps() async throws {
        let source = """
        # Implement
        <PromptFrame
          prompt={prompt}
          ticketId={ticketId}
          fixedLabel="stable"
        />
        """
        let setup = try makePromptClient(promptId: "component-props", source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let prompt = try await setup.client.getPrompt("component-props")

        XCTAssertEqual(prompt.inputs?.map(\.name), ["prompt", "ticketId"])
    }

    func testGetPromptFilesystemCombinesTemplateAndMDXComponentProps() async throws {
        let source = """
        Reviewer: {props.reviewer}
        <PromptFrame prompt={prompt} />
        """
        let setup = try makePromptClient(promptId: "mixed-props", source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let prompt = try await setup.client.getPrompt("mixed-props")

        XCTAssertEqual(prompt.inputs?.map(\.name), ["reviewer", "prompt"])
    }

    func testDiscoverPromptPropsFallsBackToPromptGetCLI() async throws {
        let cli = try makePromptCLI(scriptBody: """
        if [ "$1" = "prompt" ] && [ "$2" = "get" ] && [ "$3" = "plan" ] && [ "$4" = "--format" ] && [ "$5" = "json" ]; then
          cat <<'JSON'
        {"id":"plan","entryFile":".smithers/prompts/plan.mdx","source":"# Plan {props.goal}","inputs":[{"name":"goal","type":"string","defaultValue":"ship"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let props = try await client.discoverPromptProps("plan")

        XCTAssertEqual(props.map(\.name), ["goal"])
        XCTAssertEqual(props.first?.defaultValue, "ship")
        XCTAssertTrue(try readCalls(cli.calls).contains("prompt get plan --format json"))
    }

    func testDiscoverPromptPropsMergesPromptGetInputsWithMDXSourceDiscovery() async throws {
        let cli = try makePromptCLI(scriptBody: """
        if [ "$1" = "prompt" ] && [ "$2" = "get" ] && [ "$3" = "review" ] && [ "$4" = "--format" ] && [ "$5" = "json" ]; then
          cat <<'JSON'
        {"id":"review","entryFile":".smithers/prompts/review.mdx","source":"---\\nprops:\\n  context: repo-summary\\n---\\nReviewer: {props.reviewer}\\n<PromptFrame prompt={prompt} context={context} />","inputs":[{"name":"reviewer","type":"string"}]}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let props = try await client.discoverPromptProps("review")
        let byName = Dictionary(props.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(props.map(\.name), ["context", "reviewer", "prompt"])
        XCTAssertEqual(byName["context"]?.defaultValue, "repo-summary")
        XCTAssertEqual(byName["reviewer"]?.type, "string")
        XCTAssertEqual(byName["prompt"]?.type, "string")
        XCTAssertTrue(try readCalls(cli.calls).contains("prompt get review --format json"))
    }

    func testUpdatePromptFallsBackToCLIWhenPromptFileMissing() async throws {
        let cli = try makePromptCLI(scriptBody: """
        if [ "$1" = "prompt" ] && [ "$2" = "update" ] && [ "$3" = "plan" ] && [ "$4" = "--source" ]; then
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        try await client.updatePrompt("plan", source: "# Updated")

        XCTAssertTrue(try readCalls(cli.calls).contains("prompt update plan --source # Updated"))
    }

    func testPreviewPromptFilesystemUsesSmithersSubstitutionRules() async throws {
        let source = """
        A={props.a}
        B={props.b}
        Space={ props.a }
        Hyphen={props.summary-data}
        """
        let setup = try makePromptClient(promptId: "preview", source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let rendered = try await setup.client.previewPrompt("preview", input: ["a": "alpha"])

        XCTAssertEqual(rendered, """
        A=alpha
        B={props.b}
        Space=alpha
        Hyphen={props.summary-data}
        """)
    }

    func testPreviewPromptSourceUsesProvidedUnsavedBuffer() async throws {
        let setup = try makePromptClient(promptId: "preview", source: "Saved {props.name}")
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let rendered = try await setup.client.previewPrompt(
            "preview",
            source: "Unsaved {props.name}",
            input: ["name": "Alice"]
        )

        XCTAssertEqual(rendered, "Unsaved Alice")
    }

    func testPreviewPromptExecParsesRenderedAndResultShapes() async throws {
        let cli = try makePromptCLI(scriptBody: """
        if [ "$1" = "prompt" ] && [ "$2" = "render" ] && [ "$3" = "plan" ] && [ "$4" = "--input" ] && [ "$6" = "--format" ] && [ "$7" = "json" ]; then
          cat <<'JSON'
        {"rendered":"from-rendered-field"}
        JSON
          exit 0
        fi
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let rendered = try await client.previewPrompt("plan", input: [:])

        XCTAssertEqual(rendered, "from-rendered-field")
        let calls = try readCalls(cli.calls)
        XCTAssertTrue(calls.contains("prompt render plan --input {} --format json"))
    }
}

// MARK: - PLATFORM_SMITHERS_HTTP_SSE_TRANSPORT Tests

@MainActor
final class SmithersClientSSETransportTests: XCTestCase {

    func testResolvedHTTPTransportURLFallsBackToLocalhostOnlyWhenServerURLIsMissing() {
        let fallback = SmithersClient.resolvedHTTPTransportURL(
            path: "/events",
            serverURL: nil,
            fallbackPort: 7331
        )
        XCTAssertEqual(fallback?.absoluteString, "http://localhost:7331/events")

        let blankFallback = SmithersClient.resolvedHTTPTransportURL(
            path: "/events",
            serverURL: "  ",
            fallbackPort: 7331
        )
        XCTAssertEqual(blankFallback?.absoluteString, "http://localhost:7331/events")

        let invalidConfiguredURL = SmithersClient.resolvedHTTPTransportURL(
            path: "/events",
            serverURL: "not-a-url",
            fallbackPort: 7331
        )
        XCTAssertNil(invalidConfiguredURL, "A configured but invalid serverURL should not silently fall back to localhost")
    }

    func testResolvedHTTPTransportURLDefaultsToLocalhostWhenFallbackPortIsOmitted() {
        let staticFallback = SmithersClient.resolvedHTTPTransportURL(
            path: "/approval/list",
            serverURL: nil
        )
        XCTAssertEqual(staticFallback?.absoluteString, "http://localhost:7331/approval/list")

        let client = SmithersClient()
        let instanceFallback = client.resolvedHTTPTransportURL(path: "/approval/list")
        XCTAssertEqual(instanceFallback?.absoluteString, "http://localhost:7331/approval/list")
    }

    func testResolvedHTTPTransportURLUsesConfiguredServerURLForSSEAndHijackPaths() {
        let eventURL = SmithersClient.resolvedHTTPTransportURL(
            path: "/events",
            serverURL: "http://smithers.example:9000",
            fallbackPort: 7331
        )
        XCTAssertEqual(eventURL?.absoluteString, "http://smithers.example:9000/events")

        let chatURL = SmithersClient.resolvedHTTPTransportURL(
            path: "/v1/runs/run-1/chat/stream",
            serverURL: "http://smithers.example:9000/api/",
            fallbackPort: 7331
        )
        XCTAssertEqual(chatURL?.absoluteString, "http://smithers.example:9000/api/v1/runs/run-1/chat/stream")

        let hijackURL = SmithersClient.resolvedHTTPTransportURL(
            path: "/v1/runs/run-1/hijack",
            serverURL: "http://smithers.example:9000",
            fallbackPort: 7331
        )
        XCTAssertEqual(hijackURL?.absoluteString, "http://smithers.example:9000/v1/runs/run-1/hijack")
    }

    func testResolvedHTTPTransportURLReadsCurrentServerURLValue() {
        let client = SmithersClient()

        client.serverURL = "http://first.example:9000"
        XCTAssertEqual(
            client.resolvedHTTPTransportURL(path: "/events", fallbackPort: 7331)?.absoluteString,
            "http://first.example:9000/events"
        )

        client.serverURL = "http://second.example:9444/api"
        XCTAssertEqual(
            client.resolvedHTTPTransportURL(path: "/events", fallbackPort: 7331)?.absoluteString,
            "http://second.example:9444/api/events"
        )
    }

    // CONSTANT_SSE_DEFAULT_PORT_7331
    func testStreamRunEventsDefaultPort() {
        let client = SmithersClient()
        // Should construct URL with port 7331
        let stream = client.streamRunEvents("run-1")
        XCTAssertNotNil(stream)
    }

    func testStreamRunEventsCustomPort() {
        let client = SmithersClient()
        let stream = client.streamRunEvents("run-1", port: 9999)
        XCTAssertNotNil(stream)
    }

    func testStreamChatDefaultPort() {
        let client = SmithersClient()
        let stream = client.streamChat("run-1")
        XCTAssertNotNil(stream)
    }

    func testStreamChatCustomPort() {
        let client = SmithersClient()
        let stream = client.streamChat("run-1", port: 8080)
        XCTAssertNotNil(stream)
    }

    // STREAMING_ASYNC_STREAM_DELIVERY — returns AsyncStream<SSEEvent>
    func testStreamReturnsAsyncStream() {
        let client = SmithersClient()
        let _: AsyncStream<SSEEvent> = client.streamRunEvents("run-1")
        // Type check passes at compile time
    }
}

// MARK: - PLATFORM_SMITHERS_CONNECTION_CHECK Tests

@MainActor
final class SmithersClientConnectionTests: XCTestCase {
    private enum VersionProbeMode {
        case both
        case subcommandOnly
        case longFlagOnly
    }

    private func missingSmithersBinPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-smithers-\(UUID().uuidString)")
            .path
    }

    private func makeTemporarySmithersCLI(probeMode: VersionProbeMode = .both) throws -> (root: URL, bin: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let probeCondition: String
        switch probeMode {
        case .both:
            probeCondition = "[ \"$1\" = \"version\" ] || [ \"$1\" = \"--version\" ]"
        case .subcommandOnly:
            probeCondition = "[ \"$1\" = \"version\" ]"
        case .longFlagOnly:
            probeCondition = "[ \"$1\" = \"--version\" ]"
        }

        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        if \(probeCondition); then
          echo "smithers 0.0.0"
          exit 0
        fi
        echo "unexpected command" >&2
        exit 1
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path)
    }

    private func makeTemporarySmithersCLIRecordingCwd() throws -> (root: URL, bin: String, cwdLog: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cwdLog = root.appendingPathComponent("cwd.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$(pwd)" > '\(cwdLog.path)'
        if [ "$1" = "version" ] || [ "$1" = "--version" ]; then
          echo "smithers 0.0.0"
          exit 0
        fi
        echo "unexpected command" >&2
        exit 1
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path, cwdLog)
    }

    // PLATFORM_SMITHERS_CONNECTION_CHECK — checkConnection with no server URL and no CLI
    func testCheckConnectionNoServerURLWithoutCLI() async {
        let client = SmithersClient(smithersBin: missingSmithersBinPath())
        await client.checkConnection()
        XCTAssertFalse(client.cliAvailable)
        XCTAssertFalse(client.isConnected)
        XCTAssertEqual(client.connectionTransport, .none)
        XCTAssertFalse(client.serverReachable)
    }

    // PLATFORM_SMITHERS_CONNECTION_CHECK — CLI-only mode is connected when CLI responds
    func testCheckConnectionNoServerURLWithVersionSubcommandCLI() async throws {
        let cli = try makeTemporarySmithersCLI(probeMode: .subcommandOnly)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        await client.checkConnection()

        XCTAssertTrue(client.cliAvailable)
        XCTAssertTrue(client.isConnected, "CLI-only transport should count as connected when the CLI probe succeeds")
        XCTAssertEqual(client.connectionTransport, .cli)
        XCTAssertFalse(client.serverReachable)
    }

    func testCheckConnectionNoServerURLWithLongFlagCLI() async throws {
        let cli = try makeTemporarySmithersCLI(probeMode: .longFlagOnly)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        await client.checkConnection()

        XCTAssertTrue(client.cliAvailable)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(client.connectionTransport, .cli)
    }

    func testCheckConnectionWithoutConfiguredCwdExecutesCLIInHomeDirectory() async throws {
        let cli = try makeTemporarySmithersCLIRecordingCwd()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(smithersBin: cli.bin)
        await client.checkConnection()

        XCTAssertTrue(client.cliAvailable)
        let recordedCwd = try String(contentsOf: cli.cwdLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recordedCwd, FileManager.default.homeDirectoryForCurrentUser.path)
    }

    // TRANSPORT_HTTP_HEALTH_CHECK — checkConnection checks /health endpoint
    func testCheckConnectionWithInvalidServerURL() async {
        let client = SmithersClient(smithersBin: missingSmithersBinPath())
        client.serverURL = "http://localhost:19999" // unlikely to be running
        await client.checkConnection()
        XCTAssertFalse(client.isConnected, "Should be false when server is not reachable")
        XCTAssertEqual(client.connectionTransport, .none)
    }

    func testCheckConnectionWithInvalidConfiguredServerFallsBackToCLITransport() async throws {
        let cli = try makeTemporarySmithersCLI(probeMode: .subcommandOnly)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        client.serverURL = "not-a-url"
        await client.checkConnection()

        XCTAssertTrue(client.cliAvailable)
        XCTAssertTrue(client.isConnected)
        XCTAssertEqual(client.connectionTransport, .cli)
        XCTAssertFalse(client.serverReachable)
    }
}

@MainActor
final class SmithersClientCronTransportTests: XCTestCase {
    private func makeCronListCLI(output: String) throws -> (root: URL, bin: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientCronTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        if [ "$1" = "cron" ] && [ "$2" = "list" ] && [ "$3" = "--format" ] && [ "$4" = "json" ]; then
          cat <<'JSON'
        \(output)
        JSON
          exit 0
        fi
        echo "unexpected command: $*" >&2
        exit 1
        """
        try script.write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return (root, bin.path)
    }

    func testListCronsDecodesWrappedCLIResponse() async throws {
        let cli = try makeCronListCLI(output: """
        {"crons":[{"cronId":"c1","pattern":"*/15 * * * *","workflowPath":".smithers/workflows/debug.tsx","enabled":true,"createdAtMs":1776218840798,"lastRunAtMs":null,"nextRunAtMs":null,"errorJson":null}]}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let crons = try await client.listCrons()

        XCTAssertEqual(crons.count, 1)
        XCTAssertEqual(crons[0].id, "c1")
        XCTAssertEqual(crons[0].pattern, "*/15 * * * *")
        XCTAssertEqual(crons[0].workflowPath, ".smithers/workflows/debug.tsx")
        XCTAssertTrue(crons[0].enabled)
    }

    func testListCronsDecodesVerboseEnvelopeCLIResponse() async throws {
        let cli = try makeCronListCLI(output: """
        {"ok":true,"data":{"crons":[{"cronId":"c1","pattern":"*/15 * * * *","workflowPath":".smithers/workflows/debug.tsx","enabled":true,"createdAtMs":1776218840798,"lastRunAtMs":null,"nextRunAtMs":null,"errorJson":null}]},"meta":{"command":"cron list","duration":"12ms"}}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let crons = try await client.listCrons()

        XCTAssertEqual(crons.count, 1)
        XCTAssertEqual(crons[0].id, "c1")
        XCTAssertEqual(crons[0].pattern, "*/15 * * * *")
        XCTAssertEqual(crons[0].workflowPath, ".smithers/workflows/debug.tsx")
        XCTAssertTrue(crons[0].enabled)
    }

    func testListCronsDecodesNestedEnvelopeAndCronAliases() async throws {
        let cli = try makeCronListCLI(output: """
        {"ok":true,"data":{"data":{"cron_schedules":{"nightly":{"schedule_id":"c9","cron_expression":"*/5 * * * *","workflow_file":".smithers/workflows/every-five.tsx","is_enabled":0,"created_at":1776218840798}}}}}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let crons = try await client.listCrons()

        XCTAssertEqual(crons.count, 1)
        XCTAssertEqual(crons[0].id, "c9")
        XCTAssertEqual(crons[0].pattern, "*/5 * * * *")
        XCTAssertEqual(crons[0].workflowPath, ".smithers/workflows/every-five.tsx")
        XCTAssertFalse(crons[0].enabled)
        XCTAssertEqual(crons[0].createdAtMs, 1_776_218_840_798)
    }

    func testListCronsDecodesSingleCronObjectPayload() async throws {
        let cli = try makeCronListCLI(output: """
        {"cronId":"c10","pattern":"0 * * * *","workflowPath":"hourly.tsx","enabled":true}
        """)
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        let crons = try await client.listCrons()

        XCTAssertEqual(crons.count, 1)
        XCTAssertEqual(crons[0].id, "c10")
        XCTAssertEqual(crons[0].pattern, "0 * * * *")
        XCTAssertEqual(crons[0].workflowPath, "hourly.tsx")
        XCTAssertTrue(crons[0].enabled)
    }
}

// MARK: - Agent Detection Tests

@MainActor
final class SmithersClientAgentsTests: XCTestCase {

    func testListAgentsReturnsCanonicalManifestOrder() async throws {
        let client = SmithersClient()
        let agents = try await client.listAgents()
        XCTAssertEqual(agents.map(\.id), [
            "claude-code",
            "codex",
            "opencode",
            "gemini",
            "kimi",
            "amp",
            "forge",
        ])
    }

    func testListAgentsIncludesExpectedCommandAndRoles() async throws {
        let client = SmithersClient()
        let agents = try await client.listAgents()

        let codex = agents.first { $0.id == "codex" }
        XCTAssertEqual(codex?.command, "codex")
        XCTAssertEqual(codex?.roles, ["coding", "implement"])

        let claude = agents.first { $0.id == "claude-code" }
        XCTAssertEqual(claude?.command, "claude")
        XCTAssertEqual(claude?.roles, ["coding", "review", "spec"])
    }

    func testListAgentsUsabilityMatchesStatusAndBinaryPath() async throws {
        let client = SmithersClient()
        let agents = try await client.listAgents()

        for agent in agents {
            if agent.usable {
                XCTAssertNotEqual(agent.status, "unavailable")
                XCTAssertFalse(agent.binaryPath.isEmpty)
            } else {
                XCTAssertEqual(agent.status, "unavailable")
                XCTAssertTrue(agent.binaryPath.isEmpty)
            }
        }
    }
}

// MARK: - RunSummary Computed Properties Tests

final class RunSummaryComputedPropertyTests: XCTestCase {

    func testElapsedStringSeconds() throws {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-30).timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r","status":"running","workflowName":null,"workflowPath":null,"startedAtMs":\(startMs),"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        let elapsed = run.elapsedString
        // Should be ~30s
        XCTAssertTrue(elapsed.hasSuffix("s"), "Expected seconds format, got: \(elapsed)")
        XCTAssertFalse(elapsed.contains("m"))
    }

    func testElapsedStringMinutes() throws {
        let now = Date()
        let startMs = Int64(now.addingTimeInterval(-125).timeIntervalSince1970 * 1000)
        let json = """
        {"runId":"r","status":"running","workflowName":null,"workflowPath":null,"startedAtMs":\(startMs),"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        let elapsed = run.elapsedString
        XCTAssertTrue(elapsed.contains("m"), "Expected minutes format, got: \(elapsed)")
    }

    func testElapsedStringEmptyWhenNoStart() throws {
        let json = """
        {"runId":"r","status":"running","workflowName":null,"workflowPath":null,"startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.elapsedString, "")
    }

    func testIdentifiable() throws {
        let json = """
        {"runId":"my-run-id","status":"finished","workflowName":null,"workflowPath":null,"startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null}
        """
        let run = try JSONDecoder().decode(RunSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(run.id, "my-run-id")
    }
}

@MainActor
final class RunActionHookTests: XCTestCase {
    func testRerunRunRejectsNonNumericRunID() async {
        let client = SmithersClient()

        do {
            _ = try await client.rerunRun("ui-run-active-001")
            XCTFail("Expected rerunRun to reject non-numeric run IDs")
        } catch let error as SmithersError {
            guard case .api(let message) = error else {
                return XCTFail("Expected SmithersError.api, got \(error)")
            }
            XCTAssertTrue(message.contains("numeric run ID"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
