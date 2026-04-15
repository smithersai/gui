import Foundation

private final class PipeOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let current = data
        lock.unlock()
        return current
    }
}

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
    private var uiResolvedApprovalIDs: Set<String> = []
    private var uiApprovalDecisions: [ApprovalDecision] = SmithersClient.makeUIApprovalDecisions()
    private var uiIssues: [SmithersIssue] = SmithersClient.makeUIIssues()
    private var uiWorkspaces: [Workspace] = SmithersClient.makeUIWorkspaces()
    private var uiWorkspaceSnapshots: [WorkspaceSnapshot] = SmithersClient.makeUIWorkspaceSnapshots()

    private struct AgentManifestEntry {
        let id: String
        let name: String
        let command: String
        let roles: [String]
        let authDir: String?
        let apiKeyEnv: String?
    }

    private static let knownAgents: [AgentManifestEntry] = [
        AgentManifestEntry(
            id: "claude-code",
            name: "Claude Code",
            command: "claude",
            roles: ["coding", "review", "spec"],
            authDir: ".claude",
            apiKeyEnv: "ANTHROPIC_API_KEY"
        ),
        AgentManifestEntry(
            id: "codex",
            name: "Codex",
            command: "codex",
            roles: ["coding", "implement"],
            authDir: ".codex",
            apiKeyEnv: "OPENAI_API_KEY"
        ),
        AgentManifestEntry(
            id: "opencode",
            name: "OpenCode",
            command: "opencode",
            roles: ["coding", "chat"],
            authDir: nil,
            apiKeyEnv: nil
        ),
        AgentManifestEntry(
            id: "gemini",
            name: "Gemini",
            command: "gemini",
            roles: ["coding", "research"],
            authDir: ".gemini",
            apiKeyEnv: "GEMINI_API_KEY"
        ),
        AgentManifestEntry(
            id: "kimi",
            name: "Kimi",
            command: "kimi",
            roles: ["research", "plan"],
            authDir: nil,
            apiKeyEnv: "KIMI_API_KEY"
        ),
        AgentManifestEntry(
            id: "amp",
            name: "Amp",
            command: "amp",
            roles: ["coding", "validate"],
            authDir: ".amp",
            apiKeyEnv: nil
        ),
        AgentManifestEntry(
            id: "forge",
            name: "Forge",
            command: "forge",
            roles: ["coding"],
            authDir: nil,
            apiKeyEnv: "FORGE_API_KEY"
        ),
    ]

    private static let noSQLTransportMessage =
        "no smithers transport available: SQL requires a running smithers server; start with: smithers up --serve"

    init(cwd: String? = nil) {
        self.cwd = cwd ?? FileManager.default.currentDirectoryPath
        // Don't spawn a process during init — just use "smithers" and rely on PATH
        self.smithersBin = "smithers"
        self.decoder = JSONDecoder()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - UI Test Fixtures

    private static func makeUIRuns() -> [RunSummary] {
        let now = UITestSupport.nowMs
        return [
            RunSummary(
                runId: "ui-run-active-001",
                workflowName: "Deploy Preview",
                workflowPath: ".smithers/workflows/deploy-preview.yml",
                status: .running,
                startedAtMs: now - 120_000,
                finishedAtMs: nil,
                summary: ["total": 4, "finished": 2, "failed": 0],
                errorJson: nil
            ),
            RunSummary(
                runId: "ui-run-approval-001",
                workflowName: "Release Gate",
                workflowPath: ".smithers/workflows/release-gate.yml",
                status: .waitingApproval,
                startedAtMs: now - 900_000,
                finishedAtMs: nil,
                summary: ["total": 3, "finished": 2, "failed": 0],
                errorJson: nil
            ),
            RunSummary(
                runId: "ui-run-finished-001",
                workflowName: "Nightly Checks",
                workflowPath: ".smithers/workflows/nightly-checks.yml",
                status: .finished,
                startedAtMs: now - 7_200_000,
                finishedAtMs: now - 7_080_000,
                summary: ["total": 5, "finished": 5, "failed": 0],
                errorJson: nil
            ),
            RunSummary(
                runId: "ui-run-failed-001",
                workflowName: "Regression Sweep",
                workflowPath: ".smithers/workflows/regression-sweep.yml",
                status: .failed,
                startedAtMs: now - 10_800_000,
                finishedAtMs: now - 10_740_000,
                summary: ["total": 4, "finished": 3, "failed": 1],
                errorJson: "{\"message\":\"Fixture failure\"}"
            ),
        ]
    }

    private static func makeUIWorkflows() -> [Workflow] {
        [
            Workflow(id: "deploy-preview", workspaceId: "ui-workspace-1", name: "Deploy Preview", relativePath: ".smithers/workflows/deploy-preview.yml", status: .active, updatedAt: "2026-04-14T12:00:00Z"),
            Workflow(id: "release-gate", workspaceId: "ui-workspace-1", name: "Release Gate", relativePath: ".smithers/workflows/release-gate.yml", status: .hot, updatedAt: "2026-04-14T12:10:00Z"),
        ]
    }

    private static func makeUIApprovals() -> [Approval] {
        let now = UITestSupport.nowMs
        return [
            Approval(id: "ui-run-approval-001:deploy-gate", runId: "ui-run-approval-001", nodeId: "deploy-gate", workflowPath: ".smithers/workflows/release-gate.yml", gate: "Deploy gate", status: "pending", payload: "{\"environment\":\"staging\"}", requestedAt: now - 420_000, resolvedAt: nil, resolvedBy: nil),
            Approval(id: "ui-run-approval-002:release-gate", runId: "ui-run-approval-002", nodeId: "release-gate", workflowPath: ".smithers/workflows/release-gate.yml", gate: "Release gate", status: "pending", payload: "{\"environment\":\"production\"}", requestedAt: now - 780_000, resolvedAt: nil, resolvedBy: nil),
        ]
    }

    private static func makeUIApprovalDecisions() -> [ApprovalDecision] {
        [
            ApprovalDecision(id: "decision-existing", runId: "ui-run-finished-001", nodeId: "review-gate", action: "approved", note: "Looks good", reason: nil, resolvedAt: UITestSupport.nowMs - 1_800_000, resolvedBy: "ui-test"),
        ]
    }

    private static func makeUIIssues() -> [SmithersIssue] {
        [
            SmithersIssue(id: "issue-101", number: 101, title: "Open fixture issue", body: "This issue is available in UI test mode.", state: "open", labels: ["bug"], assignees: ["smithers"], commentCount: 2),
            SmithersIssue(id: "issue-102", number: 102, title: "Closed fixture issue", body: "This closed issue is available in UI test mode.", state: "closed", labels: ["done"], assignees: [], commentCount: 1),
        ]
    }

    private static func makeUIWorkspaces() -> [Workspace] {
        [
            Workspace(id: "ui-workspace-1", name: "Main Workspace", status: "active", createdAt: "2026-04-14"),
            Workspace(id: "ui-workspace-2", name: "Paused Workspace", status: "suspended", createdAt: "2026-04-13"),
        ]
    }

    private static func makeUIWorkspaceSnapshots() -> [WorkspaceSnapshot] {
        [
            WorkspaceSnapshot(id: "ui-snapshot-1", workspaceId: "ui-workspace-1", name: "Morning Snapshot", createdAt: "2026-04-14"),
        ]
    }

    private static func makeUIJJHubRepo() -> JJHubRepo {
        JJHubRepo(
            id: 101,
            name: "gui",
            fullName: "smithers/gui",
            owner: "smithers",
            description: "Smithers GUI fixture repo",
            defaultBookmark: "main",
            isPublic: false,
            isArchived: false,
            numIssues: 12,
            numStars: 7,
            createdAt: "2026-04-10T12:00:00Z",
            updatedAt: "2026-04-14T12:00:00Z"
        )
    }

    private static func makeUIJJHubWorkflows() -> [JJHubWorkflow] {
        [
            JJHubWorkflow(
                id: 301,
                repositoryID: 101,
                name: "Deploy Preview",
                path: ".jjhub/workflows/deploy-preview.yaml",
                isActive: true,
                createdAt: "2026-04-10T12:00:00Z",
                updatedAt: "2026-04-14T12:00:00Z"
            ),
            JJHubWorkflow(
                id: 302,
                repositoryID: 101,
                name: "Release Gate",
                path: ".jjhub/workflows/release-gate.yaml",
                isActive: false,
                createdAt: "2026-04-11T12:00:00Z",
                updatedAt: "2026-04-13T16:15:00Z"
            ),
        ]
    }

    private static func makeUIJJHubWorkflowRun(workflowID: Int, ref: String) -> JJHubWorkflowRun {
        JJHubWorkflowRun(
            id: 9_000 + workflowID,
            workflowDefinitionID: workflowID,
            status: "running",
            triggerEvent: "manual",
            triggerRef: ref,
            triggerCommitSHA: "fixture-sha-\(workflowID)",
            startedAt: "2026-04-14T12:30:00Z",
            completedAt: nil,
            sessionID: "ui-session-\(workflowID)",
            steps: ["setup", "run"]
        )
    }

    // MARK: - CLI Execution

    private func exec(_ args: String...) async throws -> Data {
        try await execArgs(args)
    }

    private func execArgs(_ args: [String]) async throws -> Data {
        try await execBinaryArgs(bin: smithersBin, args: args, displayName: "smithers")
    }

    private func execBinaryArgs(bin: String, args: [String], displayName: String) async throws -> Data {
        let cwd = self.cwd
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached { [cwd, bin, args, displayName] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [bin] + args
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)

                // Inherit PATH so subcommands can find their dependencies.
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let stdoutCollector = PipeOutputCollector()
                let stderrCollector = PipeOutputCollector()

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    stdoutCollector.append(handle.availableData)
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    stderrCollector.append(handle.availableData)
                }
                defer {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                }

                do {
                    try process.run()
                    process.waitUntilExit()

                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    stdoutCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    stderrCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                    let stdout = stdoutCollector.snapshot()
                    let stderr = stderrCollector.snapshot()

                    if process.terminationStatus != 0 {
                        let message = Self.parseCLIErrorMessage(
                            stdout: stdout,
                            stderr: stderr,
                            exitCode: process.terminationStatus
                        )
                        continuation.resume(throwing: SmithersError.cli(message))
                    } else {
                        continuation.resume(returning: stdout)
                    }
                } catch {
                    continuation.resume(throwing: SmithersError.cli("Failed to run \(displayName): \(error.localizedDescription)"))
                }
            }
        }
    }

    private func execJJHubJSONArgs(_ args: [String]) async throws -> Data {
        let fullArgs = args + ["--json", "--no-color"]
        return try await execBinaryArgs(bin: "jjhub", args: fullArgs, displayName: "jjhub")
    }

    private func execJJHubRawArgs(_ args: [String]) async throws -> String {
        let fullArgs = args + ["--no-color"]
        let data = try await execBinaryArgs(bin: "jjhub", args: fullArgs, displayName: "jjhub")
        return String(decoding: data, as: UTF8.self)
    }

    private func execJJRawArgs(_ args: [String]) async throws -> String {
        let data = try await execBinaryArgs(bin: "jj", args: args, displayName: "jj")
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func parseCLIErrorMessage(stdout: Data, stderr: Data, exitCode: Int32) -> String {
        let stderrText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stderrText.isEmpty ? stdoutText : stderrText
        guard !text.isEmpty else {
            return "Exit code \(exitCode)"
        }
        if let range = text.range(of: "Error:") {
            let stripped = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return stripped.isEmpty ? text : stripped
        }
        return text
    }

    private func execJSON<T: Decodable>(_ args: String...) async throws -> T {
        let data = try await execArgs(args)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Workflows

    func listWorkflows() async throws -> [Workflow] {
        if UITestSupport.isEnabled {
            return Self.makeUIWorkflows()
        }

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
        if UITestSupport.isEnabled {
            return WorkflowDAG(entryTask: "prompt", fields: [
                WorkflowLaunchField(name: "Prompt", key: "prompt", type: "string", defaultValue: "Ship the fixture"),
                WorkflowLaunchField(name: "Environment", key: "environment", type: "string", defaultValue: "staging"),
            ])
        }

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

    struct LaunchResult: Decodable {
        let runId: String
    }

    func runWorkflow(_ workflowId: String, inputs: [String: String] = [:]) async throws -> LaunchResult {
        if UITestSupport.isEnabled {
            return LaunchResult(runId: "ui-run-launched-\(workflowId)")
        }

        var args = ["up", workflowId, "-d", "--format", "json"]
        if !inputs.isEmpty {
            let inputJSON = try JSONEncoder().encode(inputs)
            args += ["--input", String(data: inputJSON, encoding: .utf8)!]
        }
        let data = try await execArgs(args)
        return try decoder.decode(LaunchResult.self, from: data)
    }

    // MARK: - Runs

    func listRuns() async throws -> [RunSummary] {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()
        }

        let data: Data
        do {
            data = try await exec("ps", "--format", "json")
        } catch SmithersError.cli(let msg) where msg.contains("PS_FAILED") || msg.contains("No smithers.db") {
            return []
        }
        // ps may return wrapped or bare
        if let wrapped = try? decoder.decode(RunsResponse.self, from: data) {
            return wrapped.runs
        }
        return try decoder.decode([RunSummary].self, from: data)
    }

    func inspectRun(_ runId: String) async throws -> RunInspection {
        if UITestSupport.isEnabled {
            let run = Self.makeUIRuns().first { $0.runId == runId } ?? Self.makeUIRuns()[0]
            return RunInspection(run: run, tasks: [
                RunTask(nodeId: "prepare", label: "Prepare", iteration: 0, state: "finished", lastAttempt: 1, updatedAtMs: UITestSupport.nowMs - 300_000),
                RunTask(nodeId: "deploy-gate", label: "Deploy gate", iteration: 0, state: "blocked", lastAttempt: 1, updatedAtMs: UITestSupport.nowMs - 120_000),
            ])
        }

        return try await execJSON("inspect", runId, "--format", "json")
    }

    func cancelRun(_ runId: String) async throws {
        if UITestSupport.isEnabled { return }
        _ = try await exec("cancel", runId)
    }

    func approveNode(runId: String, nodeId: String, iteration: Int = 0, note: String? = nil) async throws {
        if UITestSupport.isEnabled {
            uiResolvedApprovalIDs.insert("\(runId):\(nodeId)")
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)-approved", runId: runId, nodeId: nodeId, action: "approved", note: note, reason: nil, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        var args = ["approve", "--run", runId, nodeId]
        if let note { args += ["--note", note] }
        _ = try await execArgs(args)
    }

    func denyNode(runId: String, nodeId: String, iteration: Int = 0, reason: String? = nil) async throws {
        if UITestSupport.isEnabled {
            uiResolvedApprovalIDs.insert("\(runId):\(nodeId)")
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)-denied", runId: runId, nodeId: nodeId, action: "denied", note: nil, reason: reason, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        var args = ["deny", "--run", runId, nodeId]
        if let reason { args += ["--reason", reason] }
        _ = try await execArgs(args)
    }

    // MARK: - Run Streaming (HTTP — requires --serve)

    func streamRunEvents(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        return sseStream(url: "http://localhost:\(port)/events")
    }

    func streamChat(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        let encodedRunId = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        return sseStream(urls: [
            "http://localhost:\(port)/v1/runs/\(encodedRunId)/chat/stream",
            "http://localhost:\(port)/chat/stream?runId=\(encodedRunId)",
            "http://localhost:\(port)/chat/stream",
        ])
    }

    func getChatOutput(_ runId: String, port: Int = 7331) async throws -> [ChatBlock] {
        if UITestSupport.isEnabled {
            let now = UITestSupport.nowMs
            return [
                ChatBlock(id: "ui-chat-1", runId: runId, nodeId: "prepare", attempt: 0, role: "user", content: "Implement the requested GUI ticket.", timestampMs: now - 20_000),
                ChatBlock(id: "ui-chat-2", runId: runId, nodeId: "prepare", attempt: 0, role: "assistant", content: "I will inspect the existing views and wire a new live chat route.", timestampMs: now - 15_000),
                ChatBlock(id: "ui-chat-3", runId: runId, nodeId: "review", attempt: 1, role: "assistant", content: "Second attempt is active with updated context.", timestampMs: now - 4_000),
            ]
        }

        if let blocks = try? await getChatOutputHTTP(runId, port: port) {
            return blocks
        }

        if let blocks = try? await getChatOutputCLI(["run", "chat", runId, "--format", "json"]) {
            return blocks
        }

        if let blocks = try? await getChatOutputCLI([
            "chat", runId, "--all", "true", "--follow", "false", "--stderr", "true", "--format", "json",
        ]) {
            return blocks
        }

        return try await getChatOutputCLI([
            "chat", runId, "--all", "true", "--tail", "500", "--format", "json",
        ])
    }

    func hijackRun(_ runId: String, port: Int = 7331) async throws -> HijackSession {
        if UITestSupport.isEnabled {
            return HijackSession(
                runId: runId,
                agentEngine: "codex",
                agentBinary: "codex",
                resumeToken: "ui-session-token",
                cwd: cwd,
                supportsResume: true
            )
        }

        if let session = try? await hijackRunHTTP(runId, port: port) {
            return session
        }

        let data = try await exec("hijack", runId, "--launch", "false", "--format", "json")
        return try decodeHijackSession(from: data)
    }

    // MARK: - Agents

    func listAgents() async throws -> [SmithersAgent] {
        if UITestSupport.isEnabled {
            return Self.knownAgents.map { manifest in
                let id = manifest.id
                let usable = id == "claude-code" || id == "codex" || id == "gemini" || id == "amp"
                let hasAuth = id == "claude-code"
                let hasAPIKey = id == "codex"

                let status: String
                if !usable {
                    status = "unavailable"
                } else if hasAuth {
                    status = "likely-subscription"
                } else if hasAPIKey {
                    status = "api-key"
                } else {
                    status = "binary-only"
                }

                return SmithersAgent(
                    id: id,
                    name: manifest.name,
                    command: manifest.command,
                    binaryPath: usable ? "/usr/bin/\(manifest.command)" : "",
                    status: status,
                    hasAuth: hasAuth,
                    hasAPIKey: hasAPIKey,
                    usable: usable,
                    roles: manifest.roles,
                    version: nil,
                    authExpired: nil
                )
            }
        }

        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let homeDir = NSHomeDirectory()

        return Self.knownAgents.map { manifest in
            guard let binaryPath = resolveBinaryPath(manifest.command) else {
                return SmithersAgent(
                    id: manifest.id,
                    name: manifest.name,
                    command: manifest.command,
                    binaryPath: "",
                    status: "unavailable",
                    hasAuth: false,
                    hasAPIKey: false,
                    usable: false,
                    roles: manifest.roles,
                    version: nil,
                    authExpired: nil
                )
            }

            let hasAuth: Bool = {
                guard let authDir = manifest.authDir, !authDir.isEmpty else { return false }
                let path = (homeDir as NSString).appendingPathComponent(authDir)
                return fm.fileExists(atPath: path)
            }()

            let hasAPIKey: Bool = {
                guard let envName = manifest.apiKeyEnv, !envName.isEmpty else { return false }
                return !(env[envName] ?? "").isEmpty
            }()

            let status: String
            if hasAuth {
                status = "likely-subscription"
            } else if hasAPIKey {
                status = "api-key"
            } else {
                status = "binary-only"
            }

            return SmithersAgent(
                id: manifest.id,
                name: manifest.name,
                command: manifest.command,
                binaryPath: binaryPath,
                status: status,
                hasAuth: hasAuth,
                hasAPIKey: hasAPIKey,
                usable: true,
                roles: manifest.roles,
                version: nil,
                authExpired: nil
            )
        }
    }

    // MARK: - Memory

    func listMemoryFacts(namespace: String? = nil) async throws -> [MemoryFact] {
        if UITestSupport.isEnabled {
            let facts = [
                MemoryFact(namespace: "project", key: "language", valueJson: "\"Swift\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 86_400_000, updatedAtMs: UITestSupport.nowMs - 3_600_000, ttlMs: nil),
                MemoryFact(namespace: "workflow", key: "default-env", valueJson: "\"staging\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 43_200_000, updatedAtMs: UITestSupport.nowMs - 1_800_000, ttlMs: nil),
            ]
            guard let namespace else { return facts }
            return facts.filter { $0.namespace == namespace }
        }

        var args = ["memory", "list", "--format", "json"]
        if let ns = namespace { args += ["--namespace", ns] }
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(MemoryResponse.self, from: data) {
            return wrapped.facts
        }
        return try decoder.decode([MemoryFact].self, from: data)
    }

    func recallMemory(query: String, namespace: String? = nil, topK: Int = 10) async throws -> [MemoryRecallResult] {
        if UITestSupport.isEnabled {
            return [
                MemoryRecallResult(score: 0.94, content: "SmithersGUI UI test memory result for \(query)", metadata: "namespace=project"),
            ]
        }

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
        if UITestSupport.isEnabled {
            return [
                ScoreRow(id: "score-1", runId: "ui-run-finished-001", nodeId: "test", iteration: 0, attempt: 1, scorerId: "quality", scorerName: "Quality", source: "live", score: 0.91, reason: "Fixture score", metaJson: nil, latencyMs: 42, scoredAtMs: UITestSupport.nowMs - 600_000),
                ScoreRow(id: "score-2", runId: "ui-run-finished-001", nodeId: "lint", iteration: 0, attempt: 1, scorerId: "lint", scorerName: "Lint", source: "batch", score: 0.72, reason: "Fixture lint score", metaJson: nil, latencyMs: 31, scoredAtMs: UITestSupport.nowMs - 500_000),
            ]
        }

        var args = ["scores"]
        if let rid = runId { args.append(rid) }
        args += ["--format", "json"]
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(ScoresResponse.self, from: data) {
            return wrapped.scores
        }
        return try decoder.decode([ScoreRow].self, from: data)
    }

    func aggregateScores(from scores: [ScoreRow]? = nil, limit: Int = 50) async throws -> [AggregateScore] {
        if UITestSupport.isEnabled {
            return [
                AggregateScore(scorerName: "Quality", count: 2, mean: 0.91, min: 0.88, max: 0.94, p50: 0.91),
                AggregateScore(scorerName: "Lint", count: 1, mean: 0.72, min: 0.72, max: 0.72, p50: 0.72),
            ]
        }

        // Aggregate from the scores we have
        let scores = try await { if let scores { return scores } else { return try await listRecentScores() } }()
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
                p50: sorted.count > 0 ? (sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0 : sorted[sorted.count / 2]) : nil
            )
        }
    }

    // MARK: - Prompts (read from filesystem)

    private func promptPath(for promptId: String) throws -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        guard !promptId.isEmpty,
              promptId != ".",
              promptId != "..",
              !promptId.contains(".."),
              promptId.rangeOfCharacter(from: invalidCharacters) == nil
        else {
            throw SmithersError.api("Invalid prompt id")
        }

        let promptsDir = (cwd as NSString).appendingPathComponent(".smithers/prompts")
        let path = (promptsDir as NSString).appendingPathComponent("\(promptId).mdx")
        let standardizedPromptsDir = (promptsDir as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        guard standardizedPath.hasPrefix(standardizedPromptsDir + "/") else {
            throw SmithersError.api("Invalid prompt id")
        }
        return standardizedPath
    }

    func listPrompts() async throws -> [SmithersPrompt] {
        if UITestSupport.isEnabled {
            return [
                SmithersPrompt(id: "release-notes", entryFile: ".smithers/prompts/release-notes.mdx", source: "Write release notes for {props.version}.", inputs: [PromptInput(name: "version", type: "string", defaultValue: nil)]),
            ]
        }

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
        if UITestSupport.isEnabled {
            return SmithersPrompt(id: promptId, entryFile: ".smithers/prompts/\(promptId).mdx", source: "Write release notes for {props.version}.", inputs: [PromptInput(name: "version", type: "string", defaultValue: nil)])
        }

        let path = try promptPath(for: promptId)
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return SmithersPrompt(id: promptId, entryFile: ".smithers/prompts/\(promptId).mdx", source: source, inputs: nil)
    }

    func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] {
        if UITestSupport.isEnabled {
            return [PromptInput(name: "version", type: "string", defaultValue: nil)]
        }

        // Parse MDX for {props.xxx} patterns
        let prompt = try await getPrompt(promptId)
        guard let source = prompt.source else { return [] }

        var found: Set<String> = []
        let pattern = try NSRegularExpression(pattern: "\\{\\s*props\\.([\\w.-]+)\\s*\\}")
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            if let range = Range(match.range(at: 1), in: source) {
                found.insert(String(source[range]))
            }
        }
        return found.sorted().map { PromptInput(name: $0, type: "string", defaultValue: nil) }
    }

    func updatePrompt(_ promptId: String, source: String) async throws {
        if UITestSupport.isEnabled { return }
        let path = try promptPath(for: promptId)
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String {
        if UITestSupport.isEnabled {
            var result = "Write release notes for {props.version}."
            for (key, value) in input {
                result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
            }
            return result
        }

        let prompt = try await getPrompt(promptId)
        var result = prompt.source ?? ""
        for (key, value) in input {
            if let regex = try? NSRegularExpression(pattern: "\\{\\s*props\\.\(NSRegularExpression.escapedPattern(for: key))\\s*\\}") {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: value))
            }
        }
        return result
    }

    // MARK: - Timeline / Snapshots

    func listSnapshots(runId: String) async throws -> [Snapshot] {
        if UITestSupport.isEnabled {
            return [
                Snapshot(id: "ui-snapshot-run", runId: runId, nodeId: "prepare", label: "Before deploy", kind: "manual", parentId: nil, createdAtMs: UITestSupport.nowMs - 600_000),
            ]
        }

        return try await execJSON("timeline", runId, "--format", "json")
    }

    func forkRun(snapshotId: String) async throws -> RunSummary {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()[0]
        }

        return try await execJSON("fork", snapshotId, "--format", "json")
    }

    func replayRun(snapshotId: String) async throws -> RunSummary {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()[0]
        }

        return try await execJSON("replay", snapshotId, "--format", "json")
    }

    func diffSnapshots(fromId: String, toId: String) async throws -> SnapshotDiff {
        if UITestSupport.isEnabled {
            return SnapshotDiff(fromId: fromId, toId: toId, changes: ["Fixture diff"])
        }

        return try await execJSON("diff", fromId, toId, "--format", "json")
    }

    // MARK: - Changes / Status (JJHub)

    func getCurrentRepo() async throws -> JJHubRepo {
        if UITestSupport.isEnabled {
            return Self.makeUIJJHubRepo()
        }

        let data = try await execJJHubJSONArgs(["repo", "view"])
        return try decoder.decode(JJHubRepo.self, from: data)
    }

    func listJJHubWorkflows(limit: Int = 100) async throws -> [JJHubWorkflow] {
        if UITestSupport.isEnabled {
            return Array(Self.makeUIJJHubWorkflows().prefix(max(0, limit)))
        }

        let data = try await execJJHubJSONArgs(["workflow", "list", "-L", "\(limit)"])
        return try decoder.decode([JJHubWorkflow].self, from: data)
    }

    func triggerJJHubWorkflow(workflowID: Int, ref: String) async throws -> JJHubWorkflowRun {
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let refToUse = trimmedRef.isEmpty ? "main" : trimmedRef
        if UITestSupport.isEnabled {
            return Self.makeUIJJHubWorkflowRun(workflowID: workflowID, ref: refToUse)
        }

        var args = ["workflow", "run", "\(workflowID)"]
        if !trimmedRef.isEmpty {
            args += ["--ref", trimmedRef]
        }
        let data = try await execJJHubJSONArgs(args)
        return try decoder.decode(JJHubWorkflowRun.self, from: data)
    }

    func listChanges(limit: Int = 50) async throws -> [JJHubChange] {
        let data = try await execJJHubJSONArgs(["change", "list", "--limit", "\(limit)"])
        return try decoder.decode([JJHubChange].self, from: data)
    }

    func viewChange(_ changeID: String) async throws -> JJHubChange {
        let data = try await execJJHubJSONArgs(["change", "show", changeID])
        return try decoder.decode(JJHubChange.self, from: data)
    }

    func changeDiff(_ changeID: String? = nil) async throws -> String {
        var args = ["change", "diff"]
        if let changeID, !changeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args.append(changeID)
        }
        return try await execJJHubRawArgs(args)
    }

    func workingCopyDiff() async throws -> String {
        return try await execJJRawArgs(["diff", "--no-color"])
    }

    func status() async throws -> String {
        return try await execJJHubRawArgs(["status"])
    }

    func createBookmark(name: String, changeID: String, remote: Bool = true) async throws -> JJHubBookmark {
        var args = ["bookmark", "create", name]
        if !changeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--change-id", changeID]
        }
        if remote {
            args.append("-r")
        }
        let data = try await execJJHubJSONArgs(args)
        return try decoder.decode(JJHubBookmark.self, from: data)
    }

    func deleteBookmark(name: String, remote: Bool = true) async throws {
        var args = ["bookmark", "delete", name]
        if remote {
            args.append("-r")
        }
        _ = try await execJJHubRawArgs(args)
    }

    // MARK: - SQL Browser

    func listSQLTables() async throws -> [SQLTableInfo] {
        if UITestSupport.isEnabled {
            return [
                SQLTableInfo(name: "_smithers_runs", rowCount: 3, type: "table"),
                SQLTableInfo(name: "_smithers_nodes", rowCount: 12, type: "table"),
                SQLTableInfo(name: "_smithers_scores", rowCount: 4, type: "view"),
            ]
        }

        if let tables = try? await fetchSQLTablesOverHTTP() {
            return tables
        }

        if let dbPath = resolvedSmithersDBPath() {
            do {
                return try await listSQLTablesFromSQLite(dbPath: dbPath)
            } catch {
                throw mapSQLTransportError(error)
            }
        }

        let query = """
        SELECT name, type FROM sqlite_master
        WHERE type IN ('table','view')
          AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
        do {
            let data = try await exec("sql", "--query", query, "--format", "json")
            return try parseTableInfoJSON(data)
        } catch {
            throw mapSQLTransportError(error)
        }
    }

    func getSQLTableSchema(_ tableName: String) async throws -> SQLTableSchema {
        let normalized = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SmithersError.api("tableName must not be empty")
        }

        if UITestSupport.isEnabled {
            return SQLTableSchema(
                tableName: normalized,
                columns: [
                    SQLTableColumn(cid: 0, name: "id", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: true),
                    SQLTableColumn(cid: 1, name: "status", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: false),
                ]
            )
        }

        if let schema = try? await fetchSQLTableSchemaOverHTTP(tableName: normalized) {
            return schema
        }

        if let dbPath = resolvedSmithersDBPath() {
            do {
                let query = "PRAGMA table_info(\(quoteSQLiteIdentifier(normalized)))"
                let data = try await execSQLiteJSON(dbPath: dbPath, query: query)
                let columns = try parseTableColumnsJSON(data)
                return SQLTableSchema(tableName: normalized, columns: columns)
            } catch {
                throw mapSQLTransportError(error)
            }
        }

        do {
            let query = "PRAGMA table_info(\(quoteSQLiteIdentifier(normalized)))"
            let data = try await exec("sql", "--query", query, "--format", "json")
            let columns = try parseTableColumnsJSON(data)
            return SQLTableSchema(tableName: normalized, columns: columns)
        } catch {
            throw mapSQLTransportError(error)
        }
    }

    func executeSQL(_ query: String) async throws -> SQLResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SQLResult() }

        if UITestSupport.isEnabled {
            return SQLResult(
                columns: ["run_id", "status"],
                rows: [
                    ["ui-run-running-001", "running"],
                    ["ui-run-finished-001", "finished"],
                ]
            )
        }

        if let result = try? await executeSQLOverHTTP(trimmed) {
            return result
        }

        if let dbPath = resolvedSmithersDBPath(), Self.isSafeReadOnlySQL(trimmed) {
            do {
                let data = try await execSQLiteJSON(dbPath: dbPath, query: trimmed)
                return try parseSQLResultFromObjectRows(data)
            } catch {
                throw mapSQLTransportError(error)
            }
        }

        throw SmithersError.notAvailable(Self.noSQLTransportMessage)
    }

    // MARK: - Crons

    func listCrons() async throws -> [CronSchedule] {
        return try await execJSON("cron", "list", "--format", "json")
    }

    // MARK: - Connection Check

    func checkConnection() async {
        if UITestSupport.isEnabled {
            cliAvailable = true
            isConnected = true
            return
        }

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

    // MARK: - Stubs for features not yet wired in GUI

    func listPendingApprovals() async throws -> [Approval] {
        if UITestSupport.isEnabled {
            return Self.makeUIApprovals().filter { !uiResolvedApprovalIDs.contains($0.id) }
        }

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

    func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] {
        if UITestSupport.isEnabled {
            return Array(uiApprovalDecisions.prefix(limit))
        }
        return []
    }

    func listLandings(state: String? = nil) async throws -> [Landing] {
        let landings = [
            Landing(id: "landing-1", number: 1, title: "Fixture landing", description: "Landing fixture for UI tests.", state: "ready", targetBranch: "main", author: "smithers", createdAt: "2026-04-14", reviewStatus: "pending"),
            Landing(id: "landing-2", number: 2, title: "Landed fixture", description: "Already landed fixture.", state: "landed", targetBranch: "main", author: "smithers", createdAt: "2026-04-13", reviewStatus: "approved"),
        ]
        guard UITestSupport.isEnabled else { return [] }
        guard let state else { return landings }
        return landings.filter { $0.state == state }
    }

    func getLanding(number: Int) async throws -> Landing {
        if UITestSupport.isEnabled {
            let landings = try await listLandings()
            return landings.first { $0.number == number } ?? landings[0]
        }
        throw SmithersError.notAvailable("Landings require JJHub")
    }

    func landingDiff(number: Int) async throws -> String {
        if UITestSupport.isEnabled { return "diff --git a/file.swift b/file.swift\n+fixture change" }
        throw SmithersError.notAvailable("Landings require JJHub")
    }

    func reviewLanding(number: Int, action: String, body: String?) async throws {
        if UITestSupport.isEnabled { return }
        throw SmithersError.notAvailable("Landings require JJHub")
    }

    func listIssues(state: String? = nil) async throws -> [SmithersIssue] {
        if UITestSupport.isEnabled {
            guard let state else { return uiIssues }
            return uiIssues.filter { $0.state == state }
        }
        return []
    }

    func getIssue(number: Int) async throws -> SmithersIssue {
        if UITestSupport.isEnabled {
            return uiIssues.first { $0.number == number } ?? uiIssues[0]
        }
        throw SmithersError.notAvailable("Issues require JJHub")
    }

    func createIssue(title: String, body: String?) async throws -> SmithersIssue {
        if UITestSupport.isEnabled {
            let issue = SmithersIssue(id: "issue-\(uiIssues.count + 200)", number: uiIssues.count + 200, title: title, body: body, state: "open", labels: ["ui-test"], assignees: ["smithers"], commentCount: 0)
            uiIssues.insert(issue, at: 0)
            return issue
        }
        throw SmithersError.notAvailable("Issues require JJHub")
    }

    func closeIssue(number: Int, comment: String?) async throws {
        if UITestSupport.isEnabled {
            guard let index = uiIssues.firstIndex(where: { $0.number == number }) else { return }
            let issue = uiIssues[index]
            uiIssues[index] = SmithersIssue(id: issue.id, number: issue.number, title: issue.title, body: issue.body, state: "closed", labels: issue.labels, assignees: issue.assignees, commentCount: issue.commentCount)
            return
        }
        throw SmithersError.notAvailable("Issues require JJHub")
    }

    func listWorkspaces() async throws -> [Workspace] {
        if UITestSupport.isEnabled { return uiWorkspaces }
        return []
    }

    func createWorkspace(name: String, snapshotId: String? = nil) async throws -> Workspace {
        if UITestSupport.isEnabled {
            let workspace = Workspace(id: "ui-workspace-\(uiWorkspaces.count + 1)", name: name, status: "active", createdAt: "2026-04-14")
            uiWorkspaces.insert(workspace, at: 0)
            return workspace
        }
        throw SmithersError.notAvailable("Workspaces require JJHub")
    }

    func deleteWorkspace(_ workspaceId: String) async throws {
        if UITestSupport.isEnabled {
            uiWorkspaces.removeAll { $0.id == workspaceId }
            return
        }
        throw SmithersError.notAvailable("Workspaces require JJHub")
    }

    func suspendWorkspace(_ workspaceId: String) async throws {
        if UITestSupport.isEnabled {
            updateUIWorkspace(workspaceId, status: "suspended")
            return
        }
        throw SmithersError.notAvailable("Workspaces require JJHub")
    }

    func resumeWorkspace(_ workspaceId: String) async throws {
        if UITestSupport.isEnabled {
            updateUIWorkspace(workspaceId, status: "active")
            return
        }
        throw SmithersError.notAvailable("Workspaces require JJHub")
    }

    func listWorkspaceSnapshots() async throws -> [WorkspaceSnapshot] {
        if UITestSupport.isEnabled { return uiWorkspaceSnapshots }
        return []
    }

    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws -> WorkspaceSnapshot {
        if UITestSupport.isEnabled {
            let snapshot = WorkspaceSnapshot(id: "ui-snapshot-\(uiWorkspaceSnapshots.count + 1)", workspaceId: workspaceId, name: name, createdAt: "2026-04-14")
            uiWorkspaceSnapshots.insert(snapshot, at: 0)
            return snapshot
        }
        throw SmithersError.notAvailable("Workspace snapshots require JJHub")
    }

    func searchCode(query: String, limit: Int = 20) async throws -> [SearchResult] {
        if UITestSupport.isEnabled {
            return [SearchResult(id: "code-1", title: "ContentView.swift", description: "SwiftUI root view", snippet: "ContentView launches \(query)", filePath: "ContentView.swift", lineNumber: 1, kind: "code")]
        }
        return []
    }

    func searchIssues(query: String, state: String? = nil, limit: Int = 20) async throws -> [SearchResult] {
        if UITestSupport.isEnabled {
            return try await listIssues(state: state).map {
                SearchResult(id: $0.id, title: $0.title, description: $0.body, snippet: nil, filePath: nil, lineNumber: nil, kind: "issue")
            }
        }
        return []
    }

    func searchRepos(query: String, limit: Int = 20) async throws -> [SearchResult] {
        if UITestSupport.isEnabled {
            return [SearchResult(id: "repo-1", title: "smithers/gui", description: "Fixture repository for \(query)", snippet: nil, filePath: nil, lineNumber: nil, kind: "repo")]
        }
        return []
    }

    private func fetchSQLTablesOverHTTP() async throws -> [SQLTableInfo] {
        let data = try await httpRequestRaw(method: "GET", path: "/sql/tables")
        let payload = try unwrapLegacyEnvelope(data)
        return try parseTableInfoJSON(payload)
    }

    private func fetchSQLTableSchemaOverHTTP(tableName: String) async throws -> SQLTableSchema {
        let encoded = tableName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tableName
        let data = try await httpRequestRaw(method: "GET", path: "/sql/schema/\(encoded)")
        let payload = try unwrapLegacyEnvelope(data)

        if let schema = try? decoder.decode(SQLTableSchema.self, from: payload) {
            return schema
        }
        let columns = try parseTableColumnsJSON(payload)
        return SQLTableSchema(tableName: tableName, columns: columns)
    }

    private func executeSQLOverHTTP(_ query: String) async throws -> SQLResult {
        let body = try JSONEncoder().encode(["query": query])
        let data = try await httpRequestRaw(method: "POST", path: "/sql", jsonBody: body)
        let payload = try unwrapLegacyEnvelope(data)
        return try parseSQLResultFromObjectRows(payload)
    }

    private func listSQLTablesFromSQLite(dbPath: String) async throws -> [SQLTableInfo] {
        let query = """
        SELECT name, type FROM sqlite_master
        WHERE type IN ('table','view')
          AND name NOT LIKE 'sqlite_%'
        ORDER BY name
        """
        let data = try await execSQLiteJSON(dbPath: dbPath, query: query)
        var tables = try parseTableInfoJSON(data)
        for index in tables.indices {
            let name = tables[index].name
            let countQuery = "SELECT count(*) AS rowCount FROM \(quoteSQLiteIdentifier(name))"
            guard
                let countData = try? await execSQLiteJSON(dbPath: dbPath, query: countQuery),
                let rows = try? parseJSONRows(countData),
                let row = rows.first
            else {
                continue
            }
            let rowCount = int64Value(from: row["rowCount"] ?? row["count(*)"]) ?? tables[index].rowCount
            tables[index] = SQLTableInfo(name: name, rowCount: rowCount, type: tables[index].type)
        }
        return tables
    }

    private func resolvedSmithersDBPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let explicit = env["SMITHERS_DB_PATH"], !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(explicit)
        }
        if let explicit = env["SMITHERS_DB"], !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(explicit)
        }
        candidates += ["smithers.db", ".smithers/smithers.db"]

        let fm = FileManager.default
        for candidate in candidates {
            let path = normalizedAbsolutePath(candidate)
            var isDirectory = ObjCBool(false)
            if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return path
            }
        }
        return nil
    }

    private func normalizedAbsolutePath(_ candidate: String) -> String {
        let expanded = (candidate as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return URL(fileURLWithPath: cwd).appendingPathComponent(expanded).path
    }

    private func httpRequestRaw(method: String, path: String, jsonBody: Data? = nil) async throws -> Data {
        guard
            let base = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !base.isEmpty,
            let baseURL = URL(string: base),
            let url = URL(string: path, relativeTo: baseURL)
        else {
            throw SmithersError.notAvailable(Self.noSQLTransportMessage)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SmithersError.api(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SmithersError.api("Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401:
                throw SmithersError.unauthorized
            case 404:
                throw SmithersError.notFound
            default:
                if let message = extractServerErrorMessage(data), !message.isEmpty {
                    throw SmithersError.api(message)
                }
                throw SmithersError.httpError(http.statusCode)
            }
        }
        return data
    }

    private func unwrapLegacyEnvelope(_ data: Data) throws -> Data {
        guard
            let rootAny = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let root = rootAny as? [String: Any],
            root["ok"] != nil
        else {
            return data
        }

        let ok = (root["ok"] as? Bool) ?? false
        if !ok {
            let message = (root["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SmithersError.api((message?.isEmpty == false ? message : nil) ?? "Smithers API error")
        }

        let payload = root["data"] ?? NSNull()
        return try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
    }

    private func extractServerErrorMessage(_ data: Data) -> String? {
        if
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        {
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
        }

        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            return text
        }
        return nil
    }

    private func execSQLiteJSON(dbPath: String, query: String) async throws -> Data {
        return try await execBinaryArgs(
            bin: "sqlite3",
            args: ["-readonly", "-json", dbPath, query],
            displayName: "sqlite3"
        )
    }

    private func parseTableInfoJSON(_ data: Data) throws -> [SQLTableInfo] {
        if let tables = try? decoder.decode([SQLTableInfo].self, from: data) {
            return tables
        }
        if let result = try? decoder.decode(SQLResult.self, from: data) {
            var nameIndex: Int?
            var typeIndex: Int?
            for (index, column) in result.columns.enumerated() {
                if column == "name" { nameIndex = index }
                if column == "type" { typeIndex = index }
            }
            guard let nameIndex else {
                throw SmithersError.api("Table list response is missing 'name' column")
            }
            return result.rows.map { row in
                let name = nameIndex < row.count ? row[nameIndex] : ""
                let type = (typeIndex != nil && typeIndex! < row.count) ? row[typeIndex!] : "table"
                return SQLTableInfo(name: name, type: type)
            }
        }

        let rows = try parseJSONRows(data)
        return rows.compactMap { row in
            guard let nameAny = row["name"] else { return nil }
            let name = stringValue(from: nameAny)
            guard !name.isEmpty else { return nil }
            let rowCount = int64Value(from: row["rowCount"]) ?? 0
            let type = stringValue(from: row["type"])
            return SQLTableInfo(name: name, rowCount: rowCount, type: type.isEmpty ? "table" : type)
        }
    }

    private func parseTableColumnsJSON(_ data: Data) throws -> [SQLTableColumn] {
        if let columns = try? decoder.decode([SQLTableColumn].self, from: data) {
            return columns
        }

        if let result = try? decoder.decode(SQLResult.self, from: data), !result.columns.isEmpty {
            func rowValue(_ row: [String], column: String) -> String {
                guard let index = result.columns.firstIndex(of: column), index < row.count else {
                    return ""
                }
                return row[index]
            }

            return result.rows.enumerated().map { offset, row in
                let cid = Int(rowValue(row, column: "cid")) ?? offset
                let name = rowValue(row, column: "name")
                let type = rowValue(row, column: "type")
                let notNull = (Int(rowValue(row, column: "notnull")) ?? 0) != 0
                let defaultValue = rowValue(row, column: "dflt_value")
                let primaryKey = (Int(rowValue(row, column: "pk")) ?? 0) != 0
                return SQLTableColumn(
                    cid: cid,
                    name: name,
                    type: type,
                    notNull: notNull,
                    defaultValue: defaultValue.isEmpty ? nil : defaultValue,
                    primaryKey: primaryKey
                )
            }
        }

        let rows = try parseJSONRows(data)
        return rows.enumerated().map { offset, row in
            let cid = Int(stringValue(from: row["cid"])) ?? offset
            let name = stringValue(from: row["name"])
            let type = stringValue(from: row["type"])
            let notNull = (int64Value(from: row["notnull"]) ?? 0) != 0
            let defaultValue = stringValue(from: row["dflt_value"])
            let primaryKey = (int64Value(from: row["pk"]) ?? 0) != 0
            return SQLTableColumn(
                cid: cid,
                name: name,
                type: type,
                notNull: notNull,
                defaultValue: defaultValue.isEmpty ? nil : defaultValue,
                primaryKey: primaryKey
            )
        }
    }

    private func parseSQLResultFromObjectRows(_ data: Data) throws -> SQLResult {
        if let result = try? decoder.decode(SQLResult.self, from: data),
           !result.columns.isEmpty || !result.rows.isEmpty {
            return result
        }
        let rows = try parseJSONRows(data)
        return convertObjectRowsToSQLResult(rows)
    }

    private func parseJSONRows(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let rows = object as? [[String: Any]] {
            return rows
        }
        if let wrapped = object as? [String: Any], let rows = wrapped["results"] as? [[String: Any]] {
            return rows
        }
        throw SmithersError.api("Unexpected SQL response format")
    }

    private func convertObjectRowsToSQLResult(_ rows: [[String: Any]]) -> SQLResult {
        guard let first = rows.first else {
            return SQLResult()
        }
        let columns = Array(first.keys).sorted()
        let resultRows = rows.map { row in
            columns.map { column in
                stringValue(from: row[column])
            }
        }
        return SQLResult(columns: columns, rows: resultRows)
    }

    private func int64Value(from value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private func stringValue(from value: Any?) -> String {
        guard let value else { return "NULL" }
        if value is NSNull { return "NULL" }
        if let string = value as? String { return string }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let int64 = value as? Int64 { return String(int64) }
        if let double = value as? Double {
            if double.rounded() == double {
                return String(Int64(double))
            }
            return String(double)
        }
        if let number = value as? NSNumber {
            let asDouble = number.doubleValue
            if asDouble.rounded() == asDouble {
                return String(number.int64Value)
            }
            return String(asDouble)
        }
        if let object = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: object, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let array = value as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: array, options: []),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return "\(value)"
    }

    private static func isSafeReadOnlySQL(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.hasPrefix("SELECT")
            || normalized.hasPrefix("PRAGMA")
            || normalized.hasPrefix("EXPLAIN")
    }

    private func mapSQLTransportError(_ error: Error) -> Error {
        guard case let SmithersError.cli(message) = error else {
            return error
        }
        if Self.isNoSQLTransportCLIMessage(message) {
            return SmithersError.notAvailable(Self.noSQLTransportMessage)
        }
        return error
    }

    private static func isNoSQLTransportCLIMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if normalized.contains("failed to run sqlite3") {
            return true
        }
        if normalized.contains("failed to run smithers") {
            return true
        }
        if normalized.contains("unknown command") && normalized.contains("sql") {
            return true
        }
        if normalized.contains("unrecognized") && normalized.contains("sql") {
            return true
        }
        if normalized.contains("command not found") && normalized.contains("sql") {
            return true
        }
        return false
    }

    private func quoteSQLiteIdentifier(_ name: String) -> String {
        return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func updateUIWorkspace(_ workspaceId: String, status: String) {
        guard let index = uiWorkspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = uiWorkspaces[index]
        uiWorkspaces[index] = Workspace(id: workspace.id, name: workspace.name, status: status, createdAt: workspace.createdAt)
    }

    private func getChatOutputHTTP(_ runId: String, port: Int) async throws -> [ChatBlock] {
        let encodedRunId = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let url = URL(string: "http://localhost:\(port)/v1/runs/\(encodedRunId)/chat")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SmithersError.api("Invalid response while loading run chat")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SmithersError.httpError(http.statusCode)
        }
        return try decodeChatBlocks(from: data)
    }

    private func getChatOutputCLI(_ args: [String]) async throws -> [ChatBlock] {
        let data = try await execArgs(args)
        return try decodeChatBlocks(from: data)
    }

    private func decodeChatBlocks(from data: Data) throws -> [ChatBlock] {
        if let direct = try? decoder.decode([ChatBlock].self, from: data) {
            return direct
        }
        if let wrapped = try? decoder.decode(ChatBlocksResponse.self, from: data) {
            return wrapped.blocks
        }
        if let envelope = try? decoder.decode(APIEnvelope<[ChatBlock]>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return payload
        }
        if let envelope = try? decoder.decode(DataEnvelope<[ChatBlock]>.self, from: data) {
            return envelope.data
        }
        if let lineMap = try? decoder.decode([String: String].self, from: data) {
            let parsed = parseLegacyChatMap(lineMap)
            if !parsed.isEmpty {
                return parsed
            }
        }

        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("Failed to parse chat transcript JSON: \(snippet)")
    }

    private func parseLegacyChatMap(_ lineMap: [String: String]) -> [ChatBlock] {
        let orderedLines = lineMap
            .compactMap { key, value -> (Int, String)? in
                guard let index = Int(key) else { return nil }
                return (index, value)
            }
            .sorted { $0.0 < $1.0 }

        guard !orderedLines.isEmpty else { return [] }

        let headerPattern = #"^===\s+(.+?)\s+·\s+attempt\s+(\d+)\b.*===$"#
        let rowPattern = #"^\[[^\]]+\]\s+([^\s]+)\s+([^:]+):\s*(.*)$"#
        let headerRegex = try? NSRegularExpression(pattern: headerPattern)
        let rowRegex = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators])

        var currentNodeId: String?
        var currentAttempt = 0
        var blocks: [ChatBlock] = []

        for (index, rawLine) in orderedLines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let headerRegex,
               let match = headerRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let ns = line as NSString
                let node = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let attemptText = ns.substring(with: match.range(at: 2))
                let parsedAttempt = (Int(attemptText) ?? 1) - 1
                currentAttempt = max(0, parsedAttempt)
                currentNodeId = node
                continue
            }

            if let rowRegex,
               let match = rowRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let ns = line as NSString
                let rawRole = ns.substring(with: match.range(at: 1))
                var nodeToken = ns.substring(with: match.range(at: 2))
                let message = ns.substring(with: match.range(at: 3))

                var attempt = currentAttempt
                var nodeId = currentNodeId

                if let hashIndex = nodeToken.lastIndex(of: "#") {
                    let attemptToken = String(nodeToken[nodeToken.index(after: hashIndex)...])
                    nodeToken = String(nodeToken[..<hashIndex])
                    if let oneBasedAttempt = Int(attemptToken) {
                        attempt = max(0, oneBasedAttempt - 1)
                    }
                }

                let trimmedNode = nodeToken.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNode.isEmpty {
                    nodeId = trimmedNode
                }

                blocks.append(
                    ChatBlock(
                        id: "legacy-\(index)",
                        runId: nil,
                        nodeId: nodeId,
                        attempt: attempt,
                        role: normalizeChatRole(rawRole),
                        content: message.isEmpty ? line : message,
                        timestampMs: nil
                    )
                )
            } else {
                blocks.append(
                    ChatBlock(
                        id: "legacy-\(index)",
                        runId: nil,
                        nodeId: currentNodeId,
                        attempt: currentAttempt,
                        role: "system",
                        content: line,
                        timestampMs: nil
                    )
                )
            }
        }

        return blocks
    }

    private func normalizeChatRole(_ role: String) -> String {
        switch role.lowercased() {
        case "assistant", "agent":
            return "assistant"
        case "user":
            return "user"
        case "tool", "tool_call", "tool_result":
            return "tool"
        default:
            return "system"
        }
    }

    private func hijackRunHTTP(_ runId: String, port: Int) async throws -> HijackSession {
        let encodedRunId = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let url = URL(string: "http://localhost:\(port)/v1/runs/\(encodedRunId)/hijack")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SmithersError.api("Invalid response while hijacking run")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SmithersError.httpError(http.statusCode)
        }
        return try decodeHijackSession(from: data)
    }

    private func decodeHijackSession(from data: Data) throws -> HijackSession {
        if let direct = try? decoder.decode(HijackSession.self, from: data) {
            return direct
        }
        if let wrapped = try? decoder.decode(HijackSessionResponse.self, from: data) {
            return wrapped.session
        }
        if let envelope = try? decoder.decode(APIEnvelope<HijackSession>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return payload
        }
        if let envelope = try? decoder.decode(DataEnvelope<HijackSession>.self, from: data) {
            return envelope.data
        }

        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("Failed to parse hijack session JSON: \(snippet)")
    }

    // MARK: - SSE Stream (HTTP)

    private func sseStream(url: String) -> AsyncStream<SSEEvent> {
        return sseStream(urls: [url])
    }

    private func sseStream(urls: [String]) -> AsyncStream<SSEEvent> {
        return AsyncStream { continuation in
            let task = Task.detached { [session] in
                for (index, rawURL) in urls.enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    guard let url = URL(string: rawURL) else { continue }
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                    do {
                        let (bytes, response) = try await session.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            if index == urls.count - 1 {
                                continuation.finish()
                            }
                            continue
                        }
                        guard http.statusCode == 200 else {
                            if index == urls.count - 1 {
                                continuation.finish()
                            }
                            continue
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
                        return
                    } catch {
                        if index == urls.count - 1 {
                            continuation.finish()
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolveBinaryPath(_ command: String) -> String? {
        let fm = FileManager.default
        if command.contains("/") {
            let directPath = (command as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: directPath) ? directPath : nil
        }

        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"], !pathEnv.isEmpty else {
            return nil
        }

        for dir in pathEnv.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(command).path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

}

// MARK: - Response wrappers (CLI JSON can be wrapped or bare)

private struct RunsResponse: Decodable { let runs: [RunSummary] }
private struct MemoryResponse: Decodable { let facts: [MemoryFact] }
private struct RecallResponse: Decodable { let results: [MemoryRecallResult] }
private struct ScoresResponse: Decodable { let scores: [ScoreRow] }
private struct ChatBlocksResponse: Decodable { let blocks: [ChatBlock] }
private struct HijackSessionResponse: Decodable { let session: HijackSession }
private struct DataEnvelope<T: Decodable>: Decodable { let data: T }

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
