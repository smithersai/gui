import Foundation

/// Client for Smithers — uses the `smithers` CLI as primary transport (like the TUI),
/// with optional HTTP fallback when a workflow is running with `--serve`.
@MainActor
class SmithersClient: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var cliAvailable: Bool = false

    private let cwd: String
    private let smithersBin: String
    private let decoder: JSONDecoder

    // Optional HTTP server (only when a workflow is running with --serve)
    var serverURL: String?
    private let session: URLSession

    init(cwd: String? = nil) {
        self.cwd = cwd ?? FileManager.default.currentDirectoryPath
        // Don't spawn a process during init — just use "smithers" and rely on PATH
        self.smithersBin = "smithers"
        self.decoder = JSONDecoder()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - CLI Execution

    private func exec(_ args: String...) async throws -> Data {
        try await execArgs(args)
    }

    private func execArgs(_ args: [String]) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached { [smithersBin, cwd] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [smithersBin] + args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                // Inherit PATH so smithers can find bun, node, etc.
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                process.environment = env

                let pipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus != 0 {
                        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        continuation.resume(throwing: SmithersError.cli(stderr.isEmpty ? "Exit code \(process.terminationStatus)" : stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } else {
                        continuation.resume(returning: data)
                    }
                } catch {
                    continuation.resume(throwing: SmithersError.cli("Failed to run smithers: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func execJSON<T: Decodable>(_ args: String...) async throws -> T {
        let data = try await execArgs(args)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Workflows

    func listWorkflows() async throws -> [Workflow] {
        struct Response: Decodable {
            let workflows: [DiscoveredWorkflow]
        }
        struct DiscoveredWorkflow: Decodable {
            let id: String
            let displayName: String
            let entryFile: String
            let sourceType: String
        }

        let data = try await exec("workflow", "list", "--format", "json")

        // Try wrapped format first, then bare array
        if let response = try? decoder.decode(Response.self, from: data) {
            return response.workflows.map { adaptWorkflow(id: $0.id, displayName: $0.displayName, entryFile: $0.entryFile) }
        }
        let bare = try decoder.decode([DiscoveredWorkflow].self, from: data)
        return bare.map { adaptWorkflow(id: $0.id, displayName: $0.displayName, entryFile: $0.entryFile) }
    }

    private func adaptWorkflow(id: String, displayName: String, entryFile: String) -> Workflow {
        Workflow(
            id: id,
            workspaceId: nil,
            name: displayName,
            relativePath: entryFile,
            status: .active,
            updatedAt: nil
        )
    }

    func getWorkflowDAG(_ workflowId: String) async throws -> WorkflowDAG {
        // Use smithers graph to get input fields
        let data = try await exec("graph", workflowId, "--format", "json")
        if let dag = try? decoder.decode(WorkflowDAG.self, from: data) {
            return dag
        }
        // Fallback: return empty DAG with a single "prompt" field
        return WorkflowDAG(entryTask: nil, fields: [
            WorkflowLaunchField(name: "Prompt", key: "prompt", type: "string", defaultValue: nil)
        ])
    }

    func runWorkflow(_ workflowId: String, inputs: [String: String] = [:]) async throws -> RunSummary {
        var args = ["up", workflowId, "-d", "--format", "json"]
        if !inputs.isEmpty {
            let inputJSON = try JSONEncoder().encode(inputs)
            args += ["--input", String(data: inputJSON, encoding: .utf8)!]
        }
        let data = try await execArgs(args)
        return try decoder.decode(RunSummary.self, from: data)
    }

    // MARK: - Runs

    func listRuns() async throws -> [RunSummary] {
        let data = try await exec("ps", "--format", "json")
        // ps may return wrapped or bare
        if let wrapped = try? decoder.decode(RunsResponse.self, from: data) {
            return wrapped.runs
        }
        return try decoder.decode([RunSummary].self, from: data)
    }

    func inspectRun(_ runId: String) async throws -> RunInspection {
        return try await execJSON("inspect", runId, "--format", "json")
    }

    func cancelRun(_ runId: String) async throws {
        _ = try await exec("cancel", runId)
    }

    func approveNode(runId: String, nodeId: String, iteration: Int = 0, note: String? = nil) async throws {
        var args = ["approve", "--run", runId, nodeId]
        if let note { args += ["--note", note] }
        _ = try await execArgs(args)
    }

    func denyNode(runId: String, nodeId: String, iteration: Int = 0, reason: String? = nil) async throws {
        var args = ["deny", "--run", runId, nodeId]
        if let reason { args += ["--reason", reason] }
        _ = try await execArgs(args)
    }

    // MARK: - Run Streaming (HTTP — requires --serve)

    func streamRunEvents(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        return sseStream(url: "http://localhost:\(port)/events")
    }

    func streamChat(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        return sseStream(url: "http://localhost:\(port)/chat/stream")
    }

    // MARK: - Memory

    func listMemoryFacts(namespace: String? = nil) async throws -> [MemoryFact] {
        var args = ["memory", "list", "--format", "json"]
        if let ns = namespace { args += ["--namespace", ns] }
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(MemoryResponse.self, from: data) {
            return wrapped.facts
        }
        return try decoder.decode([MemoryFact].self, from: data)
    }

    func recallMemory(query: String, namespace: String? = nil, topK: Int = 10) async throws -> [MemoryRecallResult] {
        var args = ["memory", "recall", query, "--format", "json", "--top-k", "\(topK)"]
        if let ns = namespace { args += ["--namespace", ns] }
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(RecallResponse.self, from: data) {
            return wrapped.results
        }
        return try decoder.decode([MemoryRecallResult].self, from: data)
    }

    // MARK: - Scores

    func listRecentScores(runId: String? = nil) async throws -> [ScoreRow] {
        var args = ["scores"]
        if let rid = runId { args.append(rid) }
        args += ["--format", "json"]
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(ScoresResponse.self, from: data) {
            return wrapped.scores
        }
        return try decoder.decode([ScoreRow].self, from: data)
    }

    func aggregateScores(limit: Int = 50) async throws -> [AggregateScore] {
        // Aggregate from the scores we have
        let scores = try await listRecentScores()
        var byScorer: [String: [Double]] = [:]
        for s in scores {
            let name = s.scorerName ?? s.scorerId ?? "unknown"
            byScorer[name, default: []].append(s.score)
        }
        return byScorer.map { name, values in
            let sorted = values.sorted()
            return AggregateScore(
                scorerName: name,
                count: values.count,
                mean: values.reduce(0, +) / Double(values.count),
                min: sorted.first ?? 0,
                max: sorted.last ?? 0,
                p50: sorted.count > 0 ? sorted[sorted.count / 2] : nil
            )
        }
    }

    // MARK: - Prompts (read from filesystem)

    func listPrompts() async throws -> [SmithersPrompt] {
        let promptsDir = (cwd as NSString).appendingPathComponent(".smithers/prompts")
        let fm = FileManager.default
        guard fm.fileExists(atPath: promptsDir),
              let files = try? fm.contentsOfDirectory(atPath: promptsDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".mdx") }
            .sorted()
            .map { file in
                let id = (file as NSString).deletingPathExtension
                let path = (promptsDir as NSString).appendingPathComponent(file)
                let source = try? String(contentsOfFile: path, encoding: .utf8)
                return SmithersPrompt(id: id, entryFile: ".smithers/prompts/\(file)", source: source, inputs: nil)
            }
    }

    func getPrompt(_ promptId: String) async throws -> SmithersPrompt {
        let path = (cwd as NSString).appendingPathComponent(".smithers/prompts/\(promptId).mdx")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return SmithersPrompt(id: promptId, entryFile: ".smithers/prompts/\(promptId).mdx", source: source, inputs: nil)
    }

    func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] {
        // Parse MDX for {props.xxx} patterns
        let prompt = try await getPrompt(promptId)
        guard let source = prompt.source else { return [] }

        var found: Set<String> = []
        let pattern = try NSRegularExpression(pattern: "\\{\\s*props\\.(\\w+)\\s*\\}")
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            if let range = Range(match.range(at: 1), in: source) {
                found.insert(String(source[range]))
            }
        }
        return found.sorted().map { PromptInput(name: $0, type: "string", defaultValue: nil) }
    }

    func updatePrompt(_ promptId: String, source: String) async throws {
        let path = (cwd as NSString).appendingPathComponent(".smithers/prompts/\(promptId).mdx")
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String {
        let prompt = try await getPrompt(promptId)
        var result = prompt.source ?? ""
        for (key, value) in input {
            result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
        }
        return result
    }

    // MARK: - Timeline / Snapshots

    func listSnapshots(runId: String) async throws -> [Snapshot] {
        return try await execJSON("timeline", runId, "--format", "json")
    }

    func forkRun(snapshotId: String) async throws -> RunSummary {
        return try await execJSON("fork", snapshotId, "--format", "json")
    }

    func replayRun(snapshotId: String) async throws -> RunSummary {
        return try await execJSON("replay", snapshotId, "--format", "json")
    }

    func diffSnapshots(fromId: String, toId: String) async throws -> SnapshotDiff {
        return try await execJSON("diff", fromId, toId, "--format", "json")
    }

    // MARK: - Crons

    func listCrons() async throws -> [CronSchedule] {
        return try await execJSON("cron", "list", "--format", "json")
    }

    // MARK: - Connection Check

    func checkConnection() async {
        do {
            _ = try await exec("--version")
            cliAvailable = true
        } catch {
            cliAvailable = false
        }

        // Check if a serve instance is running
        if let url = serverURL {
            do {
                let request = URLRequest(url: URL(string: "\(url)/health")!)
                let (_, response) = try await session.data(for: request)
                isConnected = (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                isConnected = false
            }
        }
    }

    // MARK: - Stubs for features that need JJHub/server

    func listPendingApprovals() async throws -> [Approval] {
        // Approvals come from running workflows — check ps for waiting-approval status
        let runs = try await listRuns()
        var approvals: [Approval] = []
        for run in runs where run.status == .waitingApproval {
            // Inspect the run to find blocked/waiting nodes
            if let inspection = try? await inspectRun(run.runId) {
                for task in inspection.tasks where task.state == "blocked" || task.state == "waiting-approval" {
                    approvals.append(Approval(
                        id: "\(run.runId):\(task.nodeId)",
                        runId: run.runId,
                        nodeId: task.nodeId,
                        workflowPath: run.workflowPath,
                        gate: task.label,
                        status: "pending",
                        payload: nil,
                        requestedAt: run.startedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000),
                        resolvedAt: nil,
                        resolvedBy: nil
                    ))
                }
            }
        }
        return approvals
    }

    func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] { return [] }
    func listLandings(state: String? = nil) async throws -> [Landing] { return [] }
    func getLanding(number: Int) async throws -> Landing { throw SmithersError.notAvailable("Landings require JJHub") }
    func landingDiff(number: Int) async throws -> String { throw SmithersError.notAvailable("Landings require JJHub") }
    func reviewLanding(number: Int, action: String, body: String?) async throws { throw SmithersError.notAvailable("Landings require JJHub") }
    func listIssues(state: String? = nil) async throws -> [SmithersIssue] { return [] }
    func getIssue(number: Int) async throws -> SmithersIssue { throw SmithersError.notAvailable("Issues require JJHub") }
    func createIssue(title: String, body: String?) async throws -> SmithersIssue { throw SmithersError.notAvailable("Issues require JJHub") }
    func closeIssue(number: Int, comment: String?) async throws { throw SmithersError.notAvailable("Issues require JJHub") }
    func listWorkspaces() async throws -> [Workspace] { return [] }
    func createWorkspace(name: String, snapshotId: String? = nil) async throws -> Workspace { throw SmithersError.notAvailable("Workspaces require JJHub") }
    func deleteWorkspace(_ workspaceId: String) async throws { throw SmithersError.notAvailable("Workspaces require JJHub") }
    func suspendWorkspace(_ workspaceId: String) async throws { throw SmithersError.notAvailable("Workspaces require JJHub") }
    func resumeWorkspace(_ workspaceId: String) async throws { throw SmithersError.notAvailable("Workspaces require JJHub") }
    func listWorkspaceSnapshots() async throws -> [WorkspaceSnapshot] { return [] }
    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws -> WorkspaceSnapshot { throw SmithersError.notAvailable("Workspace snapshots require JJHub") }
    func searchCode(query: String, limit: Int = 20) async throws -> [SearchResult] { return [] }
    func searchIssues(query: String, state: String? = nil, limit: Int = 20) async throws -> [SearchResult] { return [] }
    func searchRepos(query: String, limit: Int = 20) async throws -> [SearchResult] { return [] }

    // MARK: - SSE Stream (HTTP)

    private func sseStream(url: String) -> AsyncStream<SSEEvent> {
        let request = URLRequest(url: URL(string: url)!)
        return AsyncStream { continuation in
            let task = Task.detached { [session] in
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        continuation.finish()
                        return
                    }

                    var eventType: String? = nil
                    var dataBuffer = ""

                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !dataBuffer.isEmpty {
                                continuation.yield(SSEEvent(event: eventType, data: dataBuffer))
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
                    if !dataBuffer.isEmpty {
                        continuation.yield(SSEEvent(event: eventType, data: dataBuffer))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

}

// MARK: - Response wrappers (CLI JSON can be wrapped or bare)

private struct RunsResponse: Decodable { let runs: [RunSummary] }
private struct MemoryResponse: Decodable { let facts: [MemoryFact] }
private struct RecallResponse: Decodable { let results: [MemoryRecallResult] }
private struct ScoresResponse: Decodable { let scores: [ScoreRow] }

// MARK: - Errors

enum SmithersError: LocalizedError {
    case unauthorized
    case notFound
    case httpError(Int)
    case api(String)
    case cli(String)
    case noWorkspace
    case notAvailable(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Unauthorized – check your API token"
        case .notFound: return "Resource not found"
        case .httpError(let code): return "HTTP error \(code)"
        case .api(let msg): return msg
        case .cli(let msg): return msg
        case .noWorkspace: return "No workspace ID configured"
        case .notAvailable(let msg): return msg
        }
    }
}
