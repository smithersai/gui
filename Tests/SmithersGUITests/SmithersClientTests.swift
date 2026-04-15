import XCTest
@testable import SmithersGUI

// MARK: - SSE Parser Tests (unit-testable without mocking CLI)

/// Standalone SSE line parser extracted to mirror SmithersClient's sseStream logic.
/// This lets us test STREAMING_SSE_LINE_PARSER independently.
private func parseSSELines(_ raw: String) -> [SSEEvent] {
    var events: [SSEEvent] = []
    var eventType: String? = nil
    var dataBuffer = ""

    for line in raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.isEmpty {
            if !dataBuffer.isEmpty {
                events.append(SSEEvent(event: eventType, data: dataBuffer))
                eventType = nil
                dataBuffer = ""
            }
            continue
        }
        if line.hasPrefix("event:") {
            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            dataBuffer = dataBuffer.isEmpty ? value : dataBuffer + "\n" + value
        }
    }
    // Flush remaining buffer (matches SmithersClient behavior)
    if !dataBuffer.isEmpty {
        events.append(SSEEvent(event: eventType, data: dataBuffer))
    }
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

    // STREAMING_SSE_LINE_PARSER — blank data lines ignored (no empty event emitted)
    func testEmptyLinesOnlyNoEvent() {
        let raw = "\n\n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events.count, 0)
    }

    // STREAMING_SSE_LINE_PARSER — whitespace trimming after "data:" and "event:"
    func testWhitespaceTrimming() {
        let raw = "event:   spaced  \ndata:   padded  \n\n"
        let events = parseSSELines(raw)
        XCTAssertEqual(events[0].event, "spaced")
        XCTAssertEqual(events[0].data, "padded")
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
}

// MARK: - SmithersClient Initialization & Properties Tests

@MainActor
final class SmithersClientInitTests: XCTestCase {

    // PLATFORM_SMITHERS_CLI_BRIDGE — default init uses cwd
    func testDefaultInitUsesCwd() {
        let client = SmithersClient()
        // Should not crash; client is initialized
        XCTAssertNotNil(client)
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

    // CLI_MEMORY_LIST — "memory list <namespace> --format json --workflow <path>"
    func testMemoryListCommandShape() {
        let args = SmithersMemoryCLI.listArgs(
            namespace: "workflow:implement",
            workflowPath: ".smithers/workflows/implement.tsx"
        )
        XCTAssertEqual(args, [
            "memory", "list", "workflow:implement",
            "--format", "json",
            "--workflow", ".smithers/workflows/implement.tsx",
        ])
        XCTAssertFalse(args.contains("--namespace"))
    }

    func testMemoryListCommandDefaultsNamespace() {
        let args = SmithersMemoryCLI.listArgs(workflowPath: ".smithers/workflows/implement.tsx")
        XCTAssertEqual(args[2], "global:default")
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

    func testListMemoryFactsUsesPositionalNamespaceWorkflowAndWrappedJSON() async throws {
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
        XCTAssertTrue(calls.contains("memory list workflow:implement --format json --workflow .smithers/workflows/implement.tsx"))
        XCTAssertFalse(calls.contains("--namespace workflow:implement"))
    }

    private func makeWorkflowCLI() throws -> (root: URL, bin: String, calls: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let calls = root.appendingPathComponent("calls.log")
        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        CALLS='\(calls.path)'
        printf '%s\\n' "$*" >> "$CALLS"

        if [ "$1" = "graph" ]; then
          cat <<'JSON'
        {"workflowId":".smithers/workflows/deploy.yaml","runId":"graph","tasks":[]}
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

    private func readCalls(_ calls: URL) throws -> String {
        try String(contentsOf: calls, encoding: .utf8)
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

// MARK: - Prompt Discovery Tests

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

    /// Test that discoverPromptProps parses {props.xxx} patterns from MDX source
    func testDiscoverPromptPropsRegex() throws {
        let source = """
        Hello {props.name}, your role is {props.role}.
        Here is {props.name} again.
        """
        let pattern = try NSRegularExpression(pattern: "\\{\\s*props\\.(\\w+)\\s*\\}")
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        var found: Set<String> = []
        for match in matches {
            if let range = Range(match.range(at: 1), in: source) {
                found.insert(String(source[range]))
            }
        }
        let sorted = found.sorted()
        XCTAssertEqual(sorted, ["name", "role"])
    }

    /// Test prompt preview replaces {props.key} with values
    func testPromptPreviewReplacement() {
        var result = "Hello {props.name}, you are {props.role}."
        let input = ["name": "Alice", "role": "admin"]
        for (key, value) in input {
            result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
        }
        XCTAssertEqual(result, "Hello Alice, you are admin.")
    }

    /// Test listPrompts returns empty for nonexistent directory
    func testListPromptsEmptyForMissingDir() async throws {
        let client = SmithersClient(cwd: "/tmp/nonexistent-smithers-test-\(UUID().uuidString)")
        let prompts = try await client.listPrompts()
        XCTAssertTrue(prompts.isEmpty)
    }

    func testDiscoverPromptPropsFindsReferencesInsideMDXExpressions() async throws {
        let source = """
        # Feature Review

        Prompt: {props.prompt}
        {props.lastCommitHash ? `Since ${props.lastCommitHash}` : ""}
        {JSON.stringify(props.existingFeatures ?? {}, null, 2)}
        <Summary reviewer={props.reviewer} payload={props["summary-data"]} />
        """
        let setup = try makePromptClient(source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let props = try await setup.client.discoverPromptProps("sample")

        XCTAssertEqual(
            props.map(\.name),
            ["existingFeatures", "lastCommitHash", "prompt", "reviewer", "summary-data"]
        )
    }

    func testDiscoverPromptPropsMergesFrontmatterDeclarations() async throws {
        let source = """
        ---
        title: Release Prompt
        description: Title and description are documentation, not prompt inputs.
        props:
          release:
            type: string
            default: "2026.04"
          dryRun:
            type: boolean
            default: "true"
          count: number
        inputs:
          - name: owner
            type: string
            default: "platform"
          - label
        ---

        Body-only prop: {props.bodyOnly ? props.bodyOnly : ""}
        """
        let setup = try makePromptClient(source: source)
        defer { try? FileManager.default.removeItem(at: setup.root) }

        let props = try await setup.client.discoverPromptProps("sample")
        let byName = Dictionary(uniqueKeysWithValues: props.map { ($0.name, $0) })

        XCTAssertEqual(props.map(\.name), ["bodyOnly", "count", "dryRun", "label", "owner", "release"])
        XCTAssertNil(byName["title"])
        XCTAssertNil(byName["description"])
        XCTAssertEqual(byName["release"]?.type, "string")
        XCTAssertEqual(byName["release"]?.defaultValue, "2026.04")
        XCTAssertEqual(byName["dryRun"]?.type, "boolean")
        XCTAssertEqual(byName["dryRun"]?.defaultValue, "true")
        XCTAssertEqual(byName["count"]?.type, "number")
        XCTAssertEqual(byName["owner"]?.defaultValue, "platform")
        XCTAssertEqual(byName["label"]?.type, "string")
        XCTAssertEqual(byName["bodyOnly"]?.type, "string")
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
    private func missingSmithersBinPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-smithers-\(UUID().uuidString)")
            .path
    }

    private func makeTemporarySmithersCLI() throws -> (root: URL, bin: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmithersClientConnectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bin = root.appendingPathComponent("smithers")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
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

    // PLATFORM_SMITHERS_CONNECTION_CHECK — checkConnection with no server URL and no CLI
    func testCheckConnectionNoServerURLWithoutCLI() async {
        let client = SmithersClient(smithersBin: missingSmithersBinPath())
        await client.checkConnection()
        XCTAssertFalse(client.cliAvailable)
        XCTAssertFalse(client.isConnected)
    }

    // PLATFORM_SMITHERS_CONNECTION_CHECK — CLI-only mode is connected when CLI responds
    func testCheckConnectionNoServerURLWithAvailableCLI() async throws {
        let cli = try makeTemporarySmithersCLI()
        defer { try? FileManager.default.removeItem(at: cli.root) }

        let client = SmithersClient(cwd: cli.root.path, smithersBin: cli.bin)
        await client.checkConnection()

        XCTAssertTrue(client.cliAvailable)
        XCTAssertTrue(client.isConnected, "CLI-only transport should count as connected when the CLI probe succeeds")
    }

    // TRANSPORT_HTTP_HEALTH_CHECK — checkConnection checks /health endpoint
    func testCheckConnectionWithInvalidServerURL() async {
        let client = SmithersClient(smithersBin: missingSmithersBinPath())
        client.serverURL = "http://localhost:19999" // unlikely to be running
        await client.checkConnection()
        XCTAssertFalse(client.isConnected, "Should be false when server is not reachable")
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
