import Foundation
import CSmithersKit

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

    nonisolated static let minimumOrchestratorVersion = "0.16.0"
    nonisolated static let defaultHTTPTransportPort = 7331

    var serverURL: String?
    var workingDirectory: String { cwd }

    private let app: Smithers.App
    private let cwd: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var client: smithers_client_t?

    init(
        cwd: String? = nil,
        smithersBin: String = "smithers",
        jjhubBin: String = "jjhub",
        codexHome: String? = nil,
        app: Smithers.App? = nil
    ) {
        self.cwd = Smithers.CWD.resolve(cwd)
        self.app = app ?? Smithers.App()

        #if !SMITHERS_STUB
        if let cApp = self.app.app {
            client = smithers_client_new(cApp)
            _ = smithers_app_open_workspace(cApp, self.cwd)
        }
        #endif
    }

    deinit {
        #if !SMITHERS_STUB
        if let client {
            smithers_client_free(client)
        }
        #endif
    }

    // MARK: Generic ABI calls

    func call<Value: Decodable>(
        _ method: String,
        args: [String: AnyEncodable] = [:],
        as type: Value.Type = Value.self
    ) async throws -> Value {
        try decode(Value.self, from: try callData(method, args: args))
    }

    func callVoid(_ method: String, args: [String: AnyEncodable] = [:]) async throws {
        _ = try callData(method, args: args)
    }

    private func callData(_ method: String, args: [String: AnyEncodable] = [:]) throws -> Data {
        #if SMITHERS_STUB
        return Smithers.Stub.responseData(method: method)
        #else
        guard let client else {
            throw SmithersError.notAvailable("libsmithers client is unavailable")
        }
        let argsData = try encoder.encode(args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
        var outError = smithers_error_s(code: 0, msg: nil)
        let result = method.withCString { methodPtr in
            argsJSON.withCString { argsPtr in
                smithers_client_call(client, methodPtr, argsPtr, &outError)
            }
        }
        if let message = Smithers.message(from: outError) {
            smithers_string_free(result)
            throw SmithersError.api(message)
        }
        defer { smithers_string_free(result) }
        return Data(Smithers.string(from: result, free: false).utf8)
        #endif
    }

    private func stream(_ method: String, args: [String: AnyEncodable] = [:]) throws -> Smithers.EventStream {
        #if SMITHERS_STUB
        return Smithers.EventStream(nil)
        #else
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
            throw SmithersError.api(message)
        }
        return Smithers.EventStream(cStream)
        #endif
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
        let data = try callData(method, args: args)
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
        let data = try callData(method, args: args)
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
        try await callList("listRuns", keys: ["runs"])
    }

    func inspectRun(_ runId: String) async throws -> RunInspection {
        try await call("inspectRun", args: ["runId": AnyEncodable(runId)])
    }

    func cancelRun(_ runId: String) async throws {
        try await callVoid("cancelRun", args: ["runId": AnyEncodable(runId)])
    }

    func approveNode(runId: String, nodeId: String, iteration: Int? = nil, note: String? = nil) async throws {
        try await callVoid("approveNode", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
            "note": AnyEncodable(note),
        ])
    }

    func denyNode(runId: String, nodeId: String, iteration: Int? = nil, reason: String? = nil) async throws {
        try await callVoid("denyNode", args: [
            "runId": AnyEncodable(runId),
            "nodeId": AnyEncodable(nodeId),
            "iteration": AnyEncodable(iteration),
            "reason": AnyEncodable(reason),
        ])
    }

    func rerunRun(_ runId: String) async throws -> String {
        try await call("rerunRun", args: ["runId": AnyEncodable(runId)])
    }

    func hijackRun(_ runId: String, port: Int = defaultHTTPTransportPort) async throws -> HijackSession {
        try await callOne("hijackRun", args: ["runId": AnyEncodable(runId)], keys: ["session"])
    }

    // MARK: Devtools

    func streamDevTools(runId: String, fromSeq: Int? = nil) -> AsyncThrowingStream<DevToolsEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let stream = try self.stream("streamDevTools", args: [
                        "runId": AnyEncodable(runId),
                        "fromSeq": AnyEncodable(fromSeq),
                    ])
                    while !Task.isCancelled {
                        let event = stream.next()
                        switch event.tag {
                        case .json:
                            let data = Data(event.payload.utf8)
                            continuation.yield(try self.decoder.decode(DevToolsEvent.self, from: data))
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
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                guard let stream = try? self.stream(method, args: ["runId": AnyEncodable(runId)]) else {
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
    func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] { try await callList("discoverPromptProps", args: ["promptId": AnyEncodable(promptId)], keys: ["inputs", "props"]) }
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

    func listPendingApprovals() async throws -> [Approval] { try await callList("listPendingApprovals", keys: ["approvals"]) }
    func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] { try await callList("listRecentDecisions", args: ["limit": AnyEncodable(limit)], keys: ["decisions"]) }

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

    func listWorkspaces() async throws -> [Workspace] { try await callList("listWorkspaces", keys: ["workspaces", "items", "results"]) }
    func viewWorkspace(_ workspaceId: String) async throws -> Workspace { try await callOne("viewWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)], keys: ["workspace"]) }
    func createWorkspace(name: String, snapshotId: String? = nil) async throws -> Workspace { try await callOne("createWorkspace", args: ["name": AnyEncodable(name), "snapshotId": AnyEncodable(snapshotId)], keys: ["workspace"]) }
    func deleteWorkspace(_ workspaceId: String) async throws { try await callVoid("deleteWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)]) }
    func suspendWorkspace(_ workspaceId: String) async throws { try await callVoid("suspendWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)]) }
    func resumeWorkspace(_ workspaceId: String) async throws { try await callVoid("resumeWorkspace", args: ["workspaceId": AnyEncodable(workspaceId)]) }
    func forkWorkspace(_ workspaceId: String, name: String? = nil) async throws -> Workspace { try await callOne("forkWorkspace", args: ["workspaceId": AnyEncodable(workspaceId), "name": AnyEncodable(name)], keys: ["workspace"]) }
    func listWorkspaceSnapshots() async throws -> [WorkspaceSnapshot] { try await callList("listWorkspaceSnapshots", keys: ["snapshots", "items", "results"]) }
    func viewWorkspaceSnapshot(_ snapshotId: String) async throws -> WorkspaceSnapshot { try await callOne("viewWorkspaceSnapshot", args: ["snapshotId": AnyEncodable(snapshotId)], keys: ["snapshot"]) }
    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws -> WorkspaceSnapshot { try await callOne("createWorkspaceSnapshot", args: ["workspaceId": AnyEncodable(workspaceId), "name": AnyEncodable(name)], keys: ["snapshot"]) }
    func deleteWorkspaceSnapshot(_ snapshotId: String) async throws { try await callVoid("deleteWorkspaceSnapshot", args: ["snapshotId": AnyEncodable(snapshotId)]) }

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

    nonisolated static func discoverPromptInputs(in source: String) -> [PromptInput] {
        []
    }

    // MARK: Connection

    func getOrchestratorVersion() async -> String? {
        do {
            let version: String = try await call("getOrchestratorVersion")
            orchestratorVersion = version
            orchestratorVersionMeetsMinimum = Self.versionAtLeast(version, minimum: Self.minimumOrchestratorVersion)
            return version
        } catch {
            orchestratorVersionMeetsMinimum = nil
            return nil
        }
    }

    func checkConnection() async {
        let version = await getOrchestratorVersion()
        cliAvailable = version != nil
        isConnected = version != nil
        connectionTransport = version == nil ? .none : .cli
        serverReachable = false
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
