import Foundation
import CSmithersKit
#if canImport(SmithersStore)
import SmithersStore
#endif

@MainActor
class SmithersClient: ObservableObject {
    enum ConnectionTransport: String {
        case none
        case cli
        case http
    }

    struct LaunchResult: Decodable {
        let runId: String
    }

    struct QuickLaunchResult {
        let inputs: [String: JSONValue]
        let notes: String
        let parseRunId: String
    }

    @Published var isConnected = false
    @Published var cliAvailable = false
    @Published private(set) var orchestratorVersion: String?
    @Published private(set) var orchestratorVersionMeetsMinimum: Bool?
    @Published private(set) var connectionTransport: ConnectionTransport = .none
    @Published private(set) var serverReachable = false

    // Ticket 0124. When the user has signed in (0109) and the 0120 runtime
    // has a live session, the SwiftUI layer installs a `SmithersRemoteProvider`
    // here. Reads prefer the store's cached shape rows; writes go through
    // the pessimistic dispatcher (`smithers_core_write` + shape echo).
    // Local-mode (no-sign-in) continues to use the CLI/libsmithers path.
    weak var remoteProvider: SmithersRemoteProvider?
    var isRemoteModeActive: Bool { remoteProvider != nil }

    nonisolated static let minimumOrchestratorVersion = "0.16.0"
    nonisolated static let defaultHTTPTransportPort = 7331

    var serverURL: String?
    var workingDirectory: String { cwd }

    private let app: Smithers.App
    private let cwd: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var client: smithers_client_t?
    nonisolated(unsafe) private let clientHandle = MainThreadClientHandle()

    init(
        cwd: String? = nil,
        smithersBin: String = "smithers",
        jjhubBin: String = "jjhub",
        codexHome: String? = nil,
        app: Smithers.App? = nil
    ) {
        self.cwd = Smithers.CWD.resolve(cwd)
        self.app = app ?? Smithers.App()

        if let cApp = self.app.app {
            let created = smithers_client_new(cApp)
            client = created
            clientHandle.replace(created)
            _ = smithers_app_open_workspace(cApp, self.cwd)
        }
    }

    deinit {
        clientHandle.replace(nil)
    }

    // MARK: Generic ABI calls

    func call<Value: Decodable>(
        _ method: String,
        args: [String: AnyEncodable] = [:],
        as type: Value.Type = Value.self
    ) async throws -> Value {
        try decode(Value.self, from: try await callDataAsync(method, args: args))
    }

    func callVoid(_ method: String, args: [String: AnyEncodable] = [:]) async throws {
        _ = try await callDataAsync(method, args: args)
    }

    private func callDataAsync(_ method: String, args: [String: AnyEncodable] = [:]) async throws -> Data {
        guard let client else {
            throw SmithersError.notAvailable("libsmithers client is unavailable")
        }
        let argsData = try encoder.encode(args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        let context = ClientCallContext(client: client, method: method, argsJSON: argsJSON)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try Self.performClientCall(context))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func callData(_ method: String, args: [String: AnyEncodable] = [:]) throws -> Data {
        guard let client else {
            throw SmithersError.notAvailable("libsmithers client is unavailable")
        }
        let argsData = try encoder.encode(args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        return try Self.performClientCall(ClientCallContext(client: client, method: method, argsJSON: argsJSON))
    }

    private nonisolated static func performClientCall(_ context: ClientCallContext) throws -> Data {
        var outError = smithers_error_s(code: 0, msg: nil)
        let result = context.method.withCString { methodPtr in
            context.argsJSON.withCString { argsPtr in
                smithers_client_call(context.client, methodPtr, argsPtr, &outError)
            }
        }
        if let message = Smithers.message(from: outError) {
            smithers_string_free(result)
            throw SmithersError.api(message)
        }
        defer { smithers_string_free(result) }
        return Data(Smithers.string(from: result, free: false).utf8)
    }

    private func stream(_ method: String, args: [String: AnyEncodable] = [:]) throws -> Smithers.EventStream {
        guard let client else {
            throw SmithersError.notAvailable("libsmithers client is unavailable")
        }
        let argsData = try encoder.encode(args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        var outError = smithers_error_s(code: 0, msg: nil)
        let cStream = method.withCString { methodPtr in
            argsJSON.withCString { argsPtr in
                smithers_client_stream(client, methodPtr, argsPtr, &outError)
            }
        }
        if let message = Smithers.message(from: outError) {
            if let cStream {
                smithers_event_stream_free(cStream)
            }
            throw SmithersError.api(message)
        }
        guard let cStream else {
            throw SmithersError.notAvailable("libsmithers stream \(method) is unavailable")
        }
        return Smithers.EventStream(cStream)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        if Value.self == String.self {
            if let value = try? decoder.decode(String.self, from: data) {
                return value as! Value
            }
            return String(decoding: data, as: UTF8.self) as! Value
        }
        if let value = try? decoder.decode(Value.self, from: data) {
            return value
        }
        if let envelope = try? decoder.decode(APIEnvelope<Value>.self, from: data), let value = envelope.data {
            return value
        }
        if let envelope = try? decoder.decode(DataEnvelope<Value>.self, from: data) {
            return envelope.data
        }
        throw SmithersError.api("Unable to decode libsmithers response as \(Value.self)")
    }

    private func callList<Value: Decodable>(
        _ method: String,
        args: [String: AnyEncodable] = [:],
        keys: [String]
    ) async throws -> [Value] {
        let data = try await callDataAsync(method, args: args)
        if let value = try? decode([Value].self, from: data) {
            return value
        }
        return try decodeObjectPayload([Value].self, from: data, keys: keys)
    }

    private func callOne<Value: Decodable>(
        _ method: String,
        args: [String: AnyEncodable] = [:],
        keys: [String]
    ) async throws -> Value {
        let data = try await callDataAsync(method, args: args)
        if let value = try? decode(Value.self, from: data) {
            return value
        }
        return try decodeObjectPayload(Value.self, from: data, keys: keys)
    }

    private func decodeObjectPayload<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        keys: [String]
    ) throws -> Value {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dictionary = object as? [String: Any] else {
            throw SmithersError.api("Expected object response")
        }
        for key in keys + ["data", "item", "result"] {
            guard let payload = dictionary[key], !(payload is NSNull) else { continue }
            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
            if let decoded = try? decoder.decode(Value.self, from: payloadData) {
                return decoded
            }
        }
        throw SmithersError.api("Missing response payload")
    }

    // MARK: Workflows / runs

    func listWorkflows() async throws -> [Workflow] {
        try await callList("listWorkflows", keys: ["workflows"])
    }

    func getWorkflowDAG(_ workflow: Workflow) async throws -> WorkflowDAG {
        try await getWorkflowDAG(workflowPath: workflow.filePath ?? workflow.id)
    }

    func getWorkflowDAG(workflowPath: String) async throws -> WorkflowDAG {
        try await call("getWorkflowDAG", args: ["workflowPath": AnyEncodable(workflowPath)])
    }

    func runWorkflow(_ workflow: Workflow, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflow.filePath ?? workflow.id, inputs: inputs)
    }

    func runWorkflow(_ workflow: Workflow, inputs: [String: String]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflow.filePath ?? workflow.id, inputs: inputs)
    }

    func runWorkflow(_ workflowPath: String, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowPath, inputs: inputs)
    }

    func runWorkflow(_ workflowPath: String, inputs: [String: String]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowPath, inputs: inputs)
    }

    func runWorkflow(workflowPath: String, inputs: [String: String]) async throws -> LaunchResult {
        try await call("runWorkflow", args: [
            "workflowPath": AnyEncodable(workflowPath),
            "inputs": AnyEncodable(inputs),
        ])
    }

    func runWorkflow(workflowPath: String, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        try await call("runWorkflow", args: [
            "workflowPath": AnyEncodable(workflowPath),
            "inputs": AnyEncodable(inputs),
        ])
    }

    func runQuickLaunchParser(target: Workflow, prompt: String) async throws -> QuickLaunchResult {
        struct Response: Decodable {
            let inputs: [String: JSONValue]
            let notes: String
            let parseRunId: String
        }
        let response: Response = try await call("runQuickLaunchParser", args: [
            "workflowPath": AnyEncodable(target.filePath ?? target.id),
            "prompt": AnyEncodable(prompt),
        ])
        return QuickLaunchResult(inputs: response.inputs, notes: response.notes, parseRunId: response.parseRunId)
    }

    func runWorkflowDoctor(_ workflow: Workflow) async -> [WorkflowDoctorIssue] {
        (try? await callList("runWorkflowDoctor", args: ["workflowPath": AnyEncodable(workflow.filePath ?? workflow.id)], keys: ["issues"])) ?? []
    }

    func listRuns() async throws -> [RunSummary] {
        if let remote = remoteProvider {
            return remote.listRuns()
        }
        return try await callList("listRuns", keys: ["runs"])
    }

    func inspectRun(_ runId: String) async throws -> RunInspection {
        try await call("inspectRun", args: ["runId": AnyEncodable(runId)])
    }

    func cancelRun(_ runId: String) async throws {
        if let remote = remoteProvider {
            try await remote.cancelRun(runId, repo: try await requireRemoteRepoRef())
            return
        }
        try await callVoid("cancelRun", args: ["runId": AnyEncodable(runId)])
    }

    func approveNode(
        runId: String,
        nodeId: String,
        iteration: Int? = nil,
        approvalId: String? = nil,
        note: String? = nil
    ) async throws {
        if let remote = remoteProvider {
            try await remote.approveNode(
                repo: try await requireRemoteRepoRef(),
                approvalID: approvalId,
                runId: runId,
                nodeId: nodeId,
                iteration: iteration,
                note: note
            )
            return
        }
        try await callVoid("approveNode", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
            "note": AnyEncodable(note),
        ])
    }

    func denyNode(
        runId: String,
        nodeId: String,
        iteration: Int? = nil,
        approvalId: String? = nil,
        reason: String? = nil
    ) async throws {
        if let remote = remoteProvider {
            try await remote.denyNode(
                repo: try await requireRemoteRepoRef(),
                approvalID: approvalId,
                runId: runId,
                nodeId: nodeId,
                iteration: iteration,
                reason: reason
            )
            return
        }
        try await callVoid("denyNode", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
            "reason": AnyEncodable(reason),
        ])
    }

    func rerunRun(_ runId: String) async throws -> String {
        if let remote = remoteProvider {
            try await remote.rerunRun(runId, repo: try await requireRemoteRepoRef())
            return runId
        }
        return try await call("rerunRun", args: ["runId": AnyEncodable(runId)])
    }

    func hijackRun(_ runId: String, port: Int = defaultHTTPTransportPort) async throws -> HijackSession {
        try await callOne("hijackRun", args: ["runId": AnyEncodable(runId)], keys: ["session"])
    }

    // MARK: Devtools

    func streamDevTools(runId: String, afterSeq: Int? = nil) -> AsyncThrowingStream<DevToolsEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let stream = try await MainActor.run {
                        try self.stream("streamDevTools", args: [
                            "runId": AnyEncodable(runId),
                            "afterSeq": AnyEncodable(afterSeq),
                            // Keep legacy compatibility with older gateways that still
                            // consume `fromSeq`.
                            "fromSeq": AnyEncodable(afterSeq),
                        ])
                    }
                    let decoder = JSONDecoder()
                    while !Task.isCancelled {
                        let event = stream.next()
                        switch event.tag {
                        case .json:
                            let data = Data(event.payload.utf8)
                            continuation.yield(try decoder.decode(DevToolsEvent.self, from: data))
                        case .none:
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        case .end:
                            continuation.finish()
                            return
                        case .error:
                            continuation.finish(throwing: SmithersError.api(event.payload))
                            return
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func getDevToolsSnapshot(runId: String, frameNo: Int? = nil) async throws -> DevToolsSnapshot {
        try await call("getDevToolsSnapshot", args: [
            "runId": AnyEncodable(runId),
            "frameNo": AnyEncodable(frameNo),
        ])
    }

    func getNodeOutput(runId: String, nodeId: String, iteration: Int? = nil) async throws -> NodeOutputResponse {
        try await call("getNodeOutput", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
        ])
    }

    func getNodeDiff(runId: String, nodeId: String, iteration: Int) async throws -> NodeDiffBundle {
        try await call("getNodeDiff", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
        ])
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool = true) async throws -> DevToolsJumpResult {
        try await call("jumpToFrame", args: [
            "runId": AnyEncodable(runId),
            "frameNo": AnyEncodable(frameNo),
            "confirm": AnyEncodable(confirm),
        ])
    }

    // MARK: Chat / streams

    func streamRunEvents(_ runId: String, port: Int = defaultHTTPTransportPort) -> AsyncStream<SSEEvent> {
        sseStream(method: "streamRunEvents", runId: runId)
    }

    func streamChat(_ runId: String, port: Int = defaultHTTPTransportPort) -> AsyncStream<SSEEvent> {
        sseStream(method: "streamChat", runId: runId)
    }

    func getChatOutput(_ runId: String, port: Int = defaultHTTPTransportPort) async throws -> [ChatBlock] {
        try await callList("getChatOutput", args: ["runId": AnyEncodable(runId)], keys: ["blocks"])
    }

    private func sseStream(method: String, runId: String) -> AsyncStream<SSEEvent> {
        AsyncStream { continuation in
            let task = Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let stream: Smithers.EventStream
                do {
                    stream = try await MainActor.run {
                        try self.stream(method, args: ["runId": AnyEncodable(runId)])
                    }
                } catch {
                    continuation.finish()
                    return
                }
                while !Task.isCancelled {
                    let event = stream.next()
                    switch event.tag {
                    case .json:
                        continuation.yield(Self.decodeSSEEvent(event.payload, fallbackRunId: runId))
                    case .none:
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    case .end, .error:
                        continuation.finish()
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated static func decodeSSEEvent(_ payload: String, fallbackRunId: String?) -> SSEEvent {
        struct Payload: Decodable {
            let event: String?
            let data: String?
            let runId: String?
        }
        if let data = payload.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            return SSEEvent(event: decoded.event, data: decoded.data ?? payload, runId: decoded.runId ?? fallbackRunId)
        }
        return SSEEvent(event: nil, data: payload, runId: fallbackRunId)
    }

    // MARK: Models backed by generic client calls

    func listAgents() async throws -> [SmithersAgent] { try await callList("listAgents", keys: ["agents"]) }
    func listMemoryFacts(namespace: String? = nil, workflowPath: String? = nil) async throws -> [MemoryFact] {
        try await callList("listMemoryFacts", args: ["namespace": AnyEncodable(namespace), "workflowPath": AnyEncodable(workflowPath)], keys: ["facts"])
    }
    func listAllMemoryFacts(namespace: String? = nil, workflowPath: String? = nil) async throws -> [MemoryFact] {
        try await callList("listAllMemoryFacts", args: ["namespace": AnyEncodable(namespace), "workflowPath": AnyEncodable(workflowPath)], keys: ["facts"])
    }
    func recallMemory(query: String, namespace: String? = nil, workflowPath: String? = nil, topK: Int = 10) async throws -> [MemoryRecallResult] {
        try await callList("recallMemory", args: ["query": AnyEncodable(query), "namespace": AnyEncodable(namespace), "workflowPath": AnyEncodable(workflowPath), "topK": AnyEncodable(topK)], keys: ["results"])
    }
    func listRecentScores(runId: String) async throws -> [ScoreRow] { try await callList("listRecentScores", args: ["runId": AnyEncodable(runId)], keys: ["scores"]) }
    func aggregateScores(from scores: [ScoreRow], limit: Int = 50) async throws -> [AggregateScore] {
        do {
            return try await callList("aggregateScores", args: ["scores": AnyEncodable(scores), "limit": AnyEncodable(limit)], keys: ["aggregates"])
        } catch {
            return Array(AggregateScore.aggregate(scores).prefix(limit))
        }
    }
    func getTokenUsageMetrics(filters: MetricsFilter = MetricsFilter()) async throws -> TokenMetrics { try await call("getTokenUsageMetrics", args: ["filters": AnyEncodable(filters)]) }
    func getLatencyMetrics(filters: MetricsFilter = MetricsFilter()) async throws -> LatencyMetrics { try await call("getLatencyMetrics", args: ["filters": AnyEncodable(filters)]) }
    func getCostTracking(filters: MetricsFilter = MetricsFilter()) async throws -> CostReport { try await call("getCostTracking", args: ["filters": AnyEncodable(filters)]) }

    func listTickets() async throws -> [Ticket] { try await callList("listTickets", keys: ["tickets", "items"]) }
    func getTicket(_ ticketId: String) async throws -> Ticket { try await callOne("getTicket", args: ["ticketId": AnyEncodable(ticketId)], keys: ["ticket"]) }
    func createTicket(id ticketId: String, content: String? = nil) async throws -> Ticket { try await callOne("createTicket", args: ["ticketId": AnyEncodable(ticketId), "content": AnyEncodable(content)], keys: ["ticket"]) }
    func updateTicket(_ ticketId: String, content: String) async throws -> Ticket { try await callOne("updateTicket", args: ["ticketId": AnyEncodable(ticketId), "content": AnyEncodable(content)], keys: ["ticket"]) }
    func deleteTicket(_ ticketId: String) async throws { try await callVoid("deleteTicket", args: ["ticketId": AnyEncodable(ticketId)]) }
    func searchTickets(query: String) async throws -> [Ticket] { try await callList("searchTickets", args: ["query": AnyEncodable(query)], keys: ["tickets", "items"]) }

    func listPrompts() async throws -> [SmithersPrompt] { try await callList("listPrompts", keys: ["prompts"]) }
    func getPrompt(_ promptId: String) async throws -> SmithersPrompt { try await callOne("getPrompt", args: ["promptId": AnyEncodable(promptId)], keys: ["prompt"]) }
    func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] {
        var transportInputs: [PromptInput] = []
        var transportError: Error?
        do {
            transportInputs = try await callList("discoverPromptProps", args: ["promptId": AnyEncodable(promptId)], keys: ["inputs", "props"])
        } catch {
            transportError = error
        }

        do {
            let prompt = try await getPrompt(promptId)
            let promptInputs = prompt.inputs ?? []
            let sourceInputs = Self.discoverPromptInputs(in: prompt.source ?? "")
            let fallbackInputs = Self.mergedPromptInputs(preferred: promptInputs, fallback: transportInputs)
            return Self.mergedPromptInputs(preferred: sourceInputs, fallback: fallbackInputs)
        } catch {
            if !transportInputs.isEmpty {
                return transportInputs
            }
            throw transportError ?? error
        }
    }
    func updatePrompt(_ promptId: String, source: String) async throws { try await callVoid("updatePrompt", args: ["promptId": AnyEncodable(promptId), "source": AnyEncodable(source)]) }
    func previewPrompt(_ promptId: String, source: String, input: [String: String]) async throws -> String { try await call("previewPrompt", args: ["promptId": AnyEncodable(promptId), "source": AnyEncodable(source), "input": AnyEncodable(input)]) }
    func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String { try await call("previewPrompt", args: ["promptId": AnyEncodable(promptId), "input": AnyEncodable(input)]) }

    func listSnapshots(runId: String) async throws -> [Snapshot] { try await callList("listSnapshots", args: ["runId": AnyEncodable(runId)], keys: ["snapshots"]) }
    func forkRun(snapshotId: String) async throws -> RunSummary { try await callOne("forkRun", args: ["snapshotId": AnyEncodable(snapshotId)], keys: ["run", "fork"]) }
    func replayRun(snapshotId: String) async throws -> RunSummary { try await callOne("replayRun", args: ["snapshotId": AnyEncodable(snapshotId)], keys: ["run", "replay"]) }
    func diffSnapshots(fromId: String, toId: String) async throws -> SnapshotDiff { try await call("diffSnapshots", args: ["fromId": AnyEncodable(fromId), "toId": AnyEncodable(toId)]) }

    func getCurrentRepo() async throws -> JJHubRepo { try await callOne("getCurrentRepo", keys: ["repo"]) }
    func listJJHubWorkflows(limit: Int = 100) async throws -> [JJHubWorkflow] { try await callList("listJJHubWorkflows", args: ["limit": AnyEncodable(limit)], keys: ["workflows"]) }
    func triggerJJHubWorkflow(workflowID: Int, ref: String) async throws -> JJHubWorkflowRun { try await callOne("triggerJJHubWorkflow", args: ["workflowID": AnyEncodable(workflowID), "ref": AnyEncodable(ref)], keys: ["run"]) }
    func listChanges(limit: Int = 50) async throws -> [JJHubChange] { try await callList("listChanges", args: ["limit": AnyEncodable(limit)], keys: ["changes"]) }
    func viewChange(_ changeID: String) async throws -> JJHubChange { try await callOne("viewChange", args: ["changeID": AnyEncodable(changeID)], keys: ["change"]) }
    func changeDiff(_ changeID: String? = nil) async throws -> String { try await call("changeDiff", args: ["changeID": AnyEncodable(changeID)]) }
    func workingCopyDiff() async throws -> String { try await call("workingCopyDiff") }
    func status() async throws -> String { try await call("status") }
    func createBookmark(name: String, changeID: String, remote: Bool = true) async throws -> JJHubBookmark { try await callOne("createBookmark", args: ["name": AnyEncodable(name), "changeID": AnyEncodable(changeID), "remote": AnyEncodable(remote)], keys: ["bookmark"]) }
    func deleteBookmark(name: String, remote: Bool = true) async throws { try await callVoid("deleteBookmark", args: ["name": AnyEncodable(name), "remote": AnyEncodable(remote)]) }

    func listSQLTables() async throws -> [SQLTableInfo] { try await callList("listSQLTables", keys: ["tables"]) }
    func getSQLTableSchema(_ tableName: String) async throws -> SQLTableSchema { try await call("getSQLTableSchema", args: ["tableName": AnyEncodable(tableName)]) }
    func executeSQL(_ query: String) async throws -> SQLResult { try await call("executeSQL", args: ["query": AnyEncodable(query)]) }

    func listCrons() async throws -> [CronSchedule] { try await callList("listCrons", keys: ["crons", "items"]) }
    func createCron(pattern: String, workflowPath: String) async throws -> CronSchedule { try await callOne("createCron", args: ["pattern": AnyEncodable(pattern), "workflowPath": AnyEncodable(workflowPath)], keys: ["cron"]) }
    func toggleCron(cronID: String, enabled: Bool) async throws { try await callVoid("toggleCron", args: ["cronID": AnyEncodable(cronID), "enabled": AnyEncodable(enabled)]) }
    func deleteCron(cronID: String) async throws { try await callVoid("deleteCron", args: ["cronID": AnyEncodable(cronID)]) }

    func listPendingApprovals() async throws -> [Approval] {
        if let remote = remoteProvider { return remote.listPendingApprovals() }
        return try await callList("listPendingApprovals", keys: ["approvals"])
    }
    func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] {
        if let remote = remoteProvider { return remote.listRecentDecisions() }
        return try await callList("listRecentDecisions", args: ["limit": AnyEncodable(limit)], keys: ["decisions"])
    }

    func listLandings(state: String? = nil) async throws -> [Landing] { try await callList("listLandings", args: ["state": AnyEncodable(state)], keys: ["landings", "items"]) }
    func getLanding(number: Int) async throws -> Landing { try await callOne("getLanding", args: ["number": AnyEncodable(number)], keys: ["landing"]) }
    func createLanding(title: String, body: String?, target: String?, stack: Bool = true) async throws -> Landing { try await callOne("createLanding", args: ["title": AnyEncodable(title), "body": AnyEncodable(body), "target": AnyEncodable(target), "stack": AnyEncodable(stack)], keys: ["landing"]) }
    func landingDiff(number: Int) async throws -> String { try await call("landingDiff", args: ["number": AnyEncodable(number)]) }
    func landLanding(number: Int) async throws { try await callVoid("landLanding", args: ["number": AnyEncodable(number)]) }
    func reviewLanding(number: Int, action: String, body: String?) async throws { try await callVoid("reviewLanding", args: ["number": AnyEncodable(number), "action": AnyEncodable(action), "body": AnyEncodable(body)]) }
    func landingChecks(number: Int) async throws -> String { try await call("landingChecks", args: ["number": AnyEncodable(number)]) }

    func listIssues(state: String? = nil) async throws -> [SmithersIssue] { try await callList("listIssues", args: ["state": AnyEncodable(state)], keys: ["issues", "items", "results"]) }
    func getIssue(number: Int) async throws -> SmithersIssue { try await callOne("getIssue", args: ["number": AnyEncodable(number)], keys: ["issue"]) }
    func createIssue(title: String, body: String?) async throws -> SmithersIssue { try await callOne("createIssue", args: ["title": AnyEncodable(title), "body": AnyEncodable(body)], keys: ["issue"]) }
    func closeIssue(number: Int, comment: String?) async throws -> SmithersIssue { try await callOne("closeIssue", args: ["number": AnyEncodable(number), "comment": AnyEncodable(comment)], keys: ["issue"]) }
    func reopenIssue(number: Int) async throws -> SmithersIssue { try await callOne("reopenIssue", args: ["number": AnyEncodable(number)], keys: ["issue"]) }

    func listWorkspaces() async throws -> [Workspace] {
        if let remote = remoteProvider { return remote.listWorkspaces() }
        return try await callList("listWorkspaces", keys: ["workspaces", "items", "results"])
    }
    func viewWorkspace(_ workspaceId: String) async throws -> Workspace {
        if let remote = remoteProvider, let ws = remote.listWorkspaces().first(where: { $0.id == workspaceId }) { return ws }
        return try await callOne("viewWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)], keys: ["workspace"])
    }
    func createWorkspace(name: String, snapshotId: String? = nil) async throws -> Workspace {
        if let remote = remoteProvider {
            try await remote.createWorkspace(repo: try await requireRemoteRepoRef(), name: name, snapshotId: snapshotId)
            return remote.listWorkspaces().first(where: { $0.name == name }) ?? Workspace(id: "pending", name: name)
        }
        return try await callOne("createWorkspace", args: ["name": AnyEncodable(name), "snapshotId": AnyEncodable(snapshotId)], keys: ["workspace"])
    }
    func deleteWorkspace(_ workspaceId: String) async throws {
        if let remote = remoteProvider { try await remote.deleteWorkspace(workspaceId, repo: try await requireRemoteRepoRef()); return }
        try await callVoid("deleteWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)])
    }
    func suspendWorkspace(_ workspaceId: String) async throws {
        if let remote = remoteProvider { try await remote.suspendWorkspace(workspaceId, repo: try await requireRemoteRepoRef()); return }
        try await callVoid("suspendWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)])
    }
    func resumeWorkspace(_ workspaceId: String) async throws {
        if let remote = remoteProvider { try await remote.resumeWorkspace(workspaceId, repo: try await requireRemoteRepoRef()); return }
        try await callVoid("resumeWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)])
    }
    func forkWorkspace(_ workspaceId: String, name: String? = nil) async throws -> Workspace {
        if let remote = remoteProvider {
            try await remote.forkWorkspace(workspaceId, repo: try await requireRemoteRepoRef(), name: name)
            return remote.listWorkspaces().first(where: { name == nil ? $0.id != workspaceId : $0.name == name }) ?? Workspace(id: "pending", name: name ?? workspaceId)
        }
        return try await callOne("forkWorkspace", args: ["workspaceId": AnyEncodable(workspaceId), "name": AnyEncodable(name)], keys: ["workspace"])
    }
    func listWorkspaceSnapshots() async throws -> [WorkspaceSnapshot] {
        if let remote = remoteProvider { return remote.listWorkspaceSnapshots() }
        return try await callList("listWorkspaceSnapshots", keys: ["snapshots", "items", "results"])
    }
    func viewWorkspaceSnapshot(_ snapshotId: String) async throws -> WorkspaceSnapshot { try await callOne("viewWorkspaceSnapshot", args: ["snapshotId": AnyEncodable(snapshotId)], keys: ["snapshot"]) }
    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws -> WorkspaceSnapshot {
        if let remote = remoteProvider {
            try await remote.createWorkspaceSnapshot(repo: try await requireRemoteRepoRef(), workspaceId: workspaceId, name: name)
            return WorkspaceSnapshot(id: "pending", workspaceId: workspaceId, name: name)
        }
        return try await callOne("createWorkspaceSnapshot", args: ["workspaceId": AnyEncodable(workspaceId), "name": AnyEncodable(name)], keys: ["snapshot"])
    }
    func deleteWorkspaceSnapshot(_ snapshotId: String) async throws {
        if let remote = remoteProvider { try await remote.deleteWorkspaceSnapshot(snapshotId, repo: try await requireRemoteRepoRef()); return }
        try await callVoid("deleteWorkspaceSnapshot", args: ["snapshotId": AnyEncodable(snapshotId)])
    }

    func search(query: String, scope: SearchScope, issueState: String? = nil, limit: Int = 20) async throws -> [SearchResult] {
        try await callList("search", args: ["query": AnyEncodable(query), "scope": AnyEncodable(scope), "issueState": AnyEncodable(issueState), "limit": AnyEncodable(limit)], keys: ["results", "items"])
    }
    func searchCode(query: String, limit: Int = 20) async throws -> [SearchResult] { try await search(query: query, scope: .code, limit: limit) }
    func searchIssues(query: String, state: String? = nil, limit: Int = 20) async throws -> [SearchResult] { try await search(query: query, scope: .issues, issueState: state, limit: limit) }
    func searchRepos(query: String, limit: Int = 20) async throws -> [SearchResult] { try await search(query: query, scope: .repos, limit: limit) }

    // MARK: Local project helpers delegated to libsmithers

    func localSmithersFilePath(_ relativePath: String) throws -> String {
        try decode(String.self, from: try callData("localSmithersFilePath", args: ["relativePath": AnyEncodable(relativePath)]))
    }

    func localTicketFilePath(for ticketId: String, requireExisting: Bool = true) throws -> String {
        try decode(String.self, from: try callData("localTicketFilePath", args: ["ticketId": AnyEncodable(ticketId), "requireExisting": AnyEncodable(requireExisting)]))
    }

    func readWorkflowSource(_ relativePath: String) async throws -> String {
        try await call("readWorkflowSource", args: ["relativePath": AnyEncodable(relativePath)])
    }

    func saveWorkflowSource(_ relativePath: String, source: String) async throws {
        try await callVoid("saveWorkflowSource", args: ["relativePath": AnyEncodable(relativePath), "source": AnyEncodable(source)])
    }

    func parseWorkflowImports(_ source: String) -> (components: [(name: String, path: String)], prompts: [(name: String, path: String)]) {
        struct Imports: Decodable {
            struct Import: Decodable { let name: String; let path: String }
            let components: [Import]
            let prompts: [Import]
        }
        guard let imports = try? decode(Imports.self, from: try callData("parseWorkflowImports", args: ["source": AnyEncodable(source)])) else {
            return ([], [])
        }
        return (
            imports.components.map { ($0.name, $0.path) },
            imports.prompts.map { ($0.name, $0.path) }
        )
    }

    nonisolated private static let promptInterpolationRegex = try! NSRegularExpression(
        pattern: #"\{\s*props\.([A-Za-z_][A-Za-z0-9_.-]*)\s*\}"#
    )
    nonisolated private static let promptInputNameRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_.-]*$"#
    )
    nonisolated private static let mdxComponentTagRegex = try! NSRegularExpression(
        pattern: #"<[A-Z][A-Za-z0-9_.:-]*\b[^>]*>"#,
        options: [.dotMatchesLineSeparators]
    )
    nonisolated private static let mdxComponentPropsMemberRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*\{\s*props\.([A-Za-z_][A-Za-z0-9_.-]*)\s*\}"#
    )
    nonisolated private static let mdxComponentPassThroughRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_.-]*)\s*=\s*\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}"#
    )
    nonisolated private static let frontmatterSectionKeys: Set<String> = ["inputs", "props", "parameters", "params", "variables", "args"]
    nonisolated private static let frontmatterMetadataKeys: Set<String> = [
        "title",
        "description",
        "tags",
        "date",
        "updated",
        "slug",
        "layout",
        "author",
        "summary",
    ]

    nonisolated static func discoverPromptInputs(in source: String) -> [PromptInput] {
        let normalized = normalizePromptSource(source)
        let (frontmatter, body) = splitFrontmatter(from: normalized)

        var order: [String] = []
        var inputsByName: [String: PromptInput] = [:]

        if let frontmatter {
            for input in discoverPromptInputsFromFrontmatter(frontmatter) {
                appendPromptInput(
                    name: input.name,
                    type: input.type ?? "string",
                    defaultValue: input.defaultValue,
                    order: &order,
                    byName: &inputsByName
                )
            }
        }

        let bodyRange = NSRange(body.startIndex..<body.endIndex, in: body)
        for match in promptInterpolationRegex.matches(in: body, range: bodyRange) {
            guard let nameRange = Range(match.range(at: 1), in: body) else { continue }
            appendPromptInput(
                name: String(body[nameRange]),
                type: "string",
                defaultValue: nil,
                order: &order,
                byName: &inputsByName
            )
        }

        for input in discoverPromptInputsFromMDXComponents(in: body) {
            appendPromptInput(
                name: input.name,
                type: input.type ?? "string",
                defaultValue: input.defaultValue,
                order: &order,
                byName: &inputsByName
            )
        }

        return order.compactMap { inputsByName[$0] }
    }

    nonisolated private static func discoverPromptInputsFromMDXComponents(in source: String) -> [PromptInput] {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let tags = mdxComponentTagRegex.matches(in: source, range: range)
        guard !tags.isEmpty else { return [] }

        var order: [String] = []
        var inputsByName: [String: PromptInput] = [:]

        for tagMatch in tags {
            guard let tagRange = Range(tagMatch.range, in: source) else { continue }
            let tag = String(source[tagRange])
            let tagNSRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)

            for match in mdxComponentPropsMemberRegex.matches(in: tag, range: tagNSRange) {
                guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
                appendPromptInput(
                    name: String(tag[nameRange]),
                    type: "string",
                    defaultValue: nil,
                    order: &order,
                    byName: &inputsByName
                )
            }

            for match in mdxComponentPassThroughRegex.matches(in: tag, range: tagNSRange) {
                guard let propRange = Range(match.range(at: 1), in: tag),
                      let valueRange = Range(match.range(at: 2), in: tag) else { continue }
                let propName = String(tag[propRange])
                let valueName = String(tag[valueRange])
                guard propName == valueName else { continue }
                appendPromptInput(
                    name: propName,
                    type: "string",
                    defaultValue: nil,
                    order: &order,
                    byName: &inputsByName
                )
            }
        }

        return order.compactMap { inputsByName[$0] }
    }

    nonisolated private static func discoverPromptInputsFromFrontmatter(_ frontmatter: String) -> [PromptInput] {
        let lines = frontmatter.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var order: [String] = []
        var inputsByName: [String: PromptInput] = [:]

        var activeSection: String?
        var sectionIndent = 0
        var currentName: String?
        var currentNameIndent = -1
        var isTopLevelProp = false

        for rawLine in lines {
            let line = stripInlineYAMLComment(from: rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let indent = leadingIndent(in: line)

            if let listItem = parseYAMLListItem(from: trimmed) {
                guard activeSection != nil else { continue }
                if let (key, value) = parseYAMLKeyValue(from: listItem),
                   key.lowercased() == "name" {
                    currentName = normalizedPromptInputName(from: value)
                    currentNameIndent = indent
                    if let currentName {
                        appendPromptInput(
                            name: currentName,
                            type: "string",
                            defaultValue: nil,
                            order: &order,
                            byName: &inputsByName
                        )
                    }
                } else if let name = normalizedPromptInputName(from: listItem) {
                    currentName = name
                    currentNameIndent = indent
                    appendPromptInput(
                        name: name,
                        type: "string",
                        defaultValue: nil,
                        order: &order,
                        byName: &inputsByName
                    )
                } else {
                    currentName = nil
                    currentNameIndent = -1
                }
                continue
            }

            guard let (key, value) = parseYAMLKeyValue(from: trimmed) else { continue }
            let loweredKey = key.lowercased()

            if indent == 0 {
                currentName = nil
                currentNameIndent = -1
                isTopLevelProp = false
                activeSection = nil

                if frontmatterSectionKeys.contains(loweredKey) {
                    activeSection = loweredKey
                    sectionIndent = indent
                    if !value.isEmpty {
                        parseInlineFrontmatterInputList(
                            value,
                            order: &order,
                            byName: &inputsByName
                        )
                    }
                    continue
                }

                guard !frontmatterMetadataKeys.contains(loweredKey),
                      let name = normalizedPromptInputName(from: key) else {
                    continue
                }

                isTopLevelProp = true
                currentName = name
                currentNameIndent = indent
                appendPromptInput(
                    name: name,
                    type: "string",
                    defaultValue: parseYAMLScalar(value),
                    order: &order,
                    byName: &inputsByName
                )
                continue
            }

            if activeSection != nil && indent <= sectionIndent {
                activeSection = nil
            }

            if let activeSection {
                if loweredKey == "name" {
                    currentName = normalizedPromptInputName(from: value)
                    currentNameIndent = indent
                    if let currentName {
                        appendPromptInput(
                            name: currentName,
                            type: "string",
                            defaultValue: nil,
                            order: &order,
                            byName: &inputsByName
                        )
                    }
                    continue
                }

                if let currentName, indent > currentNameIndent {
                    if loweredKey == "type" {
                        appendPromptInput(
                            name: currentName,
                            type: parseYAMLScalar(value) ?? "string",
                            defaultValue: nil,
                            order: &order,
                            byName: &inputsByName
                        )
                        continue
                    }
                    if loweredKey == "default" || loweredKey == "defaultvalue" || loweredKey == "value" {
                        appendPromptInput(
                            name: currentName,
                            type: nil,
                            defaultValue: parseYAMLScalar(value),
                            order: &order,
                            byName: &inputsByName
                        )
                        continue
                    }
                }

                if frontmatterSectionKeys.contains(activeSection),
                   (currentName == nil || indent <= currentNameIndent),
                   let nestedName = normalizedPromptInputName(from: key) {
                    currentName = nestedName
                    currentNameIndent = indent
                    appendPromptInput(
                        name: nestedName,
                        type: "string",
                        defaultValue: parseYAMLScalar(value),
                        order: &order,
                        byName: &inputsByName
                    )
                }
                continue
            }

            guard isTopLevelProp, let currentName, indent > currentNameIndent else { continue }
            if loweredKey == "type" {
                appendPromptInput(
                    name: currentName,
                    type: parseYAMLScalar(value) ?? "string",
                    defaultValue: nil,
                    order: &order,
                    byName: &inputsByName
                )
            } else if loweredKey == "default" || loweredKey == "defaultvalue" || loweredKey == "value" {
                appendPromptInput(
                    name: currentName,
                    type: nil,
                    defaultValue: parseYAMLScalar(value),
                    order: &order,
                    byName: &inputsByName
                )
            }
        }

        return order.compactMap { inputsByName[$0] }
    }

    nonisolated private static func parseInlineFrontmatterInputList(
        _ value: String,
        order: inout [String],
        byName: inout [String: PromptInput]
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let rawItems: [String]
        if trimmed.first == "[", trimmed.last == "]" {
            rawItems = trimmed
                .dropFirst()
                .dropLast()
                .split(separator: ",")
                .map(String.init)
        } else {
            rawItems = trimmed.split(separator: ",").map(String.init)
        }

        for rawItem in rawItems {
            if let (key, defaultRaw) = parseYAMLKeyValue(from: rawItem),
               let name = normalizedPromptInputName(from: key) {
                appendPromptInput(
                    name: name,
                    type: "string",
                    defaultValue: parseYAMLScalar(defaultRaw),
                    order: &order,
                    byName: &byName
                )
                continue
            }

            guard let name = normalizedPromptInputName(from: rawItem) else { continue }
            appendPromptInput(
                name: name,
                type: "string",
                defaultValue: nil,
                order: &order,
                byName: &byName
            )
        }
    }

    nonisolated private static func splitFrontmatter(from source: String) -> (frontmatter: String?, body: String) {
        let lines = source.components(separatedBy: "\n")
        guard !lines.isEmpty else { return (nil, source) }

        var firstLine = lines[0]
        if firstLine.hasPrefix("\u{FEFF}") {
            firstLine.removeFirst()
        }
        guard firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return (nil, source)
        }

        guard let closingIndex = lines.dropFirst().firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "---" || trimmed == "..."
        }) else {
            return (nil, source)
        }

        let frontmatter = lines[1..<closingIndex].joined(separator: "\n")
        let body = lines[(closingIndex + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    nonisolated private static func normalizePromptSource(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    nonisolated private static func normalizedPromptInputName(from raw: String) -> String? {
        guard let scalar = parseYAMLScalar(raw) else { return nil }
        let candidate = scalar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, isValidPromptInputName(candidate) else { return nil }
        return candidate
    }

    nonisolated private static func isValidPromptInputName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return promptInputNameRegex.firstMatch(in: name, range: range) != nil
    }

    nonisolated private static func appendPromptInput(
        name: String,
        type: String?,
        defaultValue: String?,
        order: inout [String],
        byName: inout [String: PromptInput]
    ) {
        guard isValidPromptInputName(name) else { return }

        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).emptyToNil
        let normalizedDefault = defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = byName[name] {
            byName[name] = PromptInput(
                name: name,
                type: existing.type ?? normalizedType,
                defaultValue: existing.defaultValue ?? normalizedDefault
            )
            return
        }

        order.append(name)
        byName[name] = PromptInput(
            name: name,
            type: normalizedType,
            defaultValue: normalizedDefault
        )
    }

    nonisolated private static func mergedPromptInputs(
        preferred: [PromptInput],
        fallback: [PromptInput]
    ) -> [PromptInput] {
        var order: [String] = []
        var inputsByName: [String: PromptInput] = [:]

        for input in preferred {
            appendPromptInput(
                name: input.name,
                type: input.type,
                defaultValue: input.defaultValue,
                order: &order,
                byName: &inputsByName
            )
        }

        for input in fallback {
            appendPromptInput(
                name: input.name,
                type: input.type,
                defaultValue: input.defaultValue,
                order: &order,
                byName: &inputsByName
            )
        }

        return order.compactMap { inputsByName[$0] }
    }

    nonisolated private static func parseYAMLKeyValue(from line: String) -> (String, String)? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    nonisolated private static func parseYAMLListItem(from line: String) -> String? {
        guard line.hasPrefix("-") else { return nil }
        let content = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    nonisolated private static func leadingIndent(in line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " || character == "\t" {
                count += 1
                continue
            }
            break
        }
        return count
    }

    nonisolated private static func stripInlineYAMLComment(from line: String) -> String {
        var isSingleQuoted = false
        var isDoubleQuoted = false
        var escaped = false

        for (index, character) in line.enumerated() {
            if escaped {
                escaped = false
                continue
            }

            if isDoubleQuoted, character == "\\" {
                escaped = true
                continue
            }

            if character == "'" && !isDoubleQuoted {
                isSingleQuoted.toggle()
                continue
            }
            if character == "\"" && !isSingleQuoted {
                isDoubleQuoted.toggle()
                continue
            }
            if character == "#", !isSingleQuoted, !isDoubleQuoted {
                let end = line.index(line.startIndex, offsetBy: index)
                return String(line[..<end]).trimmingCharacters(in: .whitespaces)
            }
        }

        return line
    }

    nonisolated private static func parseYAMLScalar(_ raw: String) -> String? {
        let trimmed = stripInlineYAMLComment(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        if lowered == "null" || lowered == "~" {
            return nil
        }

        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    // MARK: Connection

    func getOrchestratorVersion() async -> String? {
        do {
            let rawVersion: String = try await call("getOrchestratorVersion")
            guard let version = Self.normalizeOrchestratorVersion(rawVersion) else {
                orchestratorVersion = nil
                orchestratorVersionMeetsMinimum = nil
                return nil
            }
            orchestratorVersion = version
            orchestratorVersionMeetsMinimum = Self.versionAtLeast(version, minimum: Self.minimumOrchestratorVersion)
            return version
        } catch {
            orchestratorVersion = nil
            orchestratorVersionMeetsMinimum = nil
            return nil
        }
    }

    nonisolated static func normalizeOrchestratorVersion(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "unknown" { return nil }
        guard let first = trimmed.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) else {
            return nil
        }
        return trimmed
    }

    func checkConnection() async {
        // Ticket 0124. Prefer the 0120 runtime's http transport when a
        // sign-in session is active. The legacy CLI probe still runs so
        // the dev-tools view can report whether the local binary is
        // installed, but it is NOT the authoritative transport any more.
        let version = await getOrchestratorVersion()
        cliAvailable = version != nil
        if isRemoteModeActive {
            isConnected = true
            connectionTransport = .http
            serverReachable = true
        } else {
            isConnected = version != nil
            // Remote mode absent → local-only; transport is .none. We
            // intentionally do NOT fall back to .cli for the remote data
            // plane — tickets 0124/0126 require a real sign-in before the
            // remote UI renders against shape reads.
            connectionTransport = version == nil ? .none : .none
            serverReachable = false
        }
    }

    func hasSmithersProject() -> Bool {
        (try? decode(Bool.self, from: try callData("hasSmithersProject", args: ["cwd": AnyEncodable(cwd)]))) ?? false
    }

    func initializeSmithers() async throws {
        try await callVoid("initializeSmithers", args: ["cwd": AnyEncodable(cwd)])
    }

    func resolvedHTTPTransportURL(path: String, fallbackPort: Int? = defaultHTTPTransportPort) -> URL? {
        Self.resolvedHTTPTransportURL(path: path, serverURL: serverURL, fallbackPort: fallbackPort)
    }

    nonisolated static func resolvedHTTPTransportURL(path: String, serverURL: String?, fallbackPort: Int? = defaultHTTPTransportPort) -> URL? {
        let baseURL: URL
        if let serverURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines), !serverURL.isEmpty {
            guard let configured = URL(string: serverURL), configured.scheme != nil, configured.host != nil else {
                return nil
            }
            baseURL = configured
        } else if let fallbackPort, let fallback = URL(string: "http://localhost:\(fallbackPort)") {
            baseURL = fallback
        } else {
            return nil
        }
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") { base += "/" }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: relative, relativeTo: URL(string: base))?.absoluteURL
    }

    nonisolated static func approveNodeCLIArgs(runId: String, nodeId: String, iteration: Int? = nil, note: String? = nil) -> [String] {
        var args = ["approve", runId, "--node", nodeId]
        if let iteration { args += ["--iteration", String(iteration)] }
        if let note { args += ["--note", note] }
        return args
    }

    nonisolated static func denyNodeCLIArgs(runId: String, nodeId: String, iteration: Int? = nil, reason: String? = nil) -> [String] {
        var args = ["deny", runId, "--node", nodeId]
        if let iteration { args += ["--iteration", String(iteration)] }
        if let reason { args += ["--reason", reason] }
        return args
    }

    nonisolated static func hijackRunCLIArgs(runId: String) -> [String] {
        ["hijack", runId, "--launch=false", "--format", "json"]
    }

    nonisolated static func versionAtLeast(_ version: String, minimum: String) -> Bool {
        guard let lhs = parseSemver(version), let rhs = parseSemver(minimum) else {
            return true
        }
        for (left, right) in zip(lhs, rhs) where left != right {
            return left > right
        }
        return true
    }

    nonisolated private static func parseSemver(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = withoutPrefix.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? withoutPrefix
        let parts = core.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var values: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            values.append(value)
        }
        while values.count < 3 { values.append(0) }
        return values
    }

    nonisolated static func decodeRunInspection(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> RunInspection {
        if let direct = try? decoder.decode(RunInspection.self, from: data) {
            return direct
        }
        if let envelope = try? decoder.decode(APIEnvelope<RunInspection>.self, from: data), let value = envelope.data {
            return value
        }
        if let envelope = try? decoder.decode(DataEnvelope<RunInspection>.self, from: data) {
            return envelope.data
        }
        throw SmithersError.api("Unable to decode run inspection")
    }

    nonisolated static func makeHTTPURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return config
    }

    nonisolated static func makeSSEURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        return config
    }

    nonisolated static func enrichedProcessEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }
}

extension Smithers {
    typealias Client = SmithersClient
}

extension SmithersClient: @preconcurrency DevToolsStreamProvider, NodeOutputProvider {}

private struct DataEnvelope<Value: Decodable>: Decodable {
    let data: Value
}

private struct ClientCallContext: @unchecked Sendable {
    let client: smithers_client_t
    let method: String
    let argsJSON: String
}

struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init<Value: Encodable>(_ value: Value) {
        encodeBody = value.encode(to:)
    }

    init<Value: Encodable>(_ value: Value?) {
        encodeBody = { encoder in
            guard let value else {
                var container = encoder.singleValueContainer()
                try container.encodeNil()
                return
            }
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}

private extension SmithersClient {
    func requireRemoteRepoRef() async throws -> ActionRepoRef {
        let repo = try await getCurrentRepo()
        guard
            let owner = repo.owner?.trimmingCharacters(in: .whitespacesAndNewlines),
            !owner.isEmpty,
            let name = repo.name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty
        else {
            throw ActionContractError.missingRepoContext
        }
        return ActionRepoRef(owner: owner, name: name)
    }
}

private extension String {
    var emptyToNil: String? {
        isEmpty ? nil : self
    }
}

private final class MainThreadClientHandle {
    private var client: smithers_client_t?

    func replace(_ newValue: smithers_client_t?) {
        if let client {
            Self.free(client)
        }
        client = newValue
    }

    deinit {
        if let client {
            Self.free(client)
        }
    }

    private static func free(_ client: smithers_client_t) {
        if Thread.isMainThread {
            smithers_client_free(client)
        } else {
            DispatchQueue.main.sync {
                smithers_client_free(client)
            }
        }
    }
}
