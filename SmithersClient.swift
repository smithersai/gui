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

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

enum SmithersMemoryCLI {
    static let defaultNamespace = "global:default"

    static func normalizedNamespace(_ namespace: String?) -> String {
        guard let namespace = namespace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !namespace.isEmpty else {
            return defaultNamespace
        }
        return namespace
    }

    static func normalizedWorkflowPath(_ workflowPath: String?) -> String? {
        guard let workflowPath = workflowPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workflowPath.isEmpty else {
            return nil
        }
        return workflowPath
    }

    static func listArgs(namespace: String? = nil, workflowPath: String? = nil) -> [String] {
        var args = ["memory", "list", normalizedNamespace(namespace), "--format", "json"]
        if let workflowPath = normalizedWorkflowPath(workflowPath) {
            args += ["--workflow", workflowPath]
        }
        return args
    }

    static func recallArgs(query: String, namespace: String? = nil, workflowPath: String? = nil, topK: Int = 10) -> [String] {
        var args = [
            "memory", "recall", query,
            "--format", "json",
            "--namespace", normalizedNamespace(namespace),
            "--top-k", "\(topK)",
        ]
        if let workflowPath = normalizedWorkflowPath(workflowPath) {
            args += ["--workflow", workflowPath]
        }
        return args
    }
}

private func cliJSONPayloadCandidates(from data: Data) -> [Data] {
    guard let raw = String(data: data, encoding: .utf8) else {
        return []
    }

    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return []
    }

    var seen = Set<String>()
    var candidates: [Data] = []
    func append(_ candidate: String) {
        let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, seen.insert(normalized).inserted else {
            return
        }
        if let data = normalized.data(using: .utf8) {
            candidates.append(data)
        }
    }

    append(trimmed)
    for index in trimmed.indices where trimmed[index] == "{" || trimmed[index] == "[" {
        append(String(trimmed[index...]))
    }
    return candidates
}

/// Client for Smithers — uses the `smithers` CLI as primary transport (like the TUI),
/// with optional HTTP fallback when a workflow is running with `--serve`.
@MainActor
class SmithersClient: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var cliAvailable: Bool = false

    private let cwd: String
    private let smithersBin: String
    private let jjhubBin: String
    private let decoder: JSONDecoder

    var workingDirectory: String { cwd }

    // Optional HTTP server (only when a workflow is running with --serve)
    var serverURL: String?
    private let session: URLSession
    private let streamSession: URLSession
    private var uiResolvedApprovalIDs: Set<String> = []
    private var uiApprovalDecisions: [ApprovalDecision] = SmithersClient.makeUIApprovalDecisions()
    private var uiTickets: [Ticket] = SmithersClient.makeUITickets()
    private var uiCrons: [CronSchedule] = SmithersClient.makeUICrons()
    private var uiLandings: [Landing] = SmithersClient.makeUILandings()
    private var uiIssues: [SmithersIssue] = SmithersClient.makeUIIssues()
    private var uiWorkspaces: [Workspace] = SmithersClient.makeUIWorkspaces()
    private var uiWorkspaceSnapshots: [WorkspaceSnapshot] = SmithersClient.makeUIWorkspaceSnapshots()
    private var runWorkflowPathCache: [String: String] = [:]
    private var snapshotWorkflowPathCache: [String: String] = [:]

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
    private static let allRunsStreamRunId = "all-runs"

    nonisolated static func makeHTTPURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        return config
    }

    nonisolated static func makeSSEURLSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = .infinity
        config.timeoutIntervalForResource = .infinity
        return config
    }

    init(cwd: String? = nil, smithersBin: String = "smithers", jjhubBin: String = "jjhub") {
        self.cwd = CWDResolver.resolve(cwd)
        // Don't spawn a process during init — just use "smithers" and rely on PATH
        self.smithersBin = smithersBin
        self.jjhubBin = jjhubBin
        self.decoder = JSONDecoder()
        self.session = URLSession(configuration: Self.makeHTTPURLSessionConfiguration())
        self.streamSession = URLSession(configuration: Self.makeSSEURLSessionConfiguration())
    }

    nonisolated static func resolvedHTTPTransportURL(path: String, serverURL: String?, fallbackPort: Int? = nil) -> URL? {
        let trimmedServerURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL: URL

        if let trimmedServerURL, !trimmedServerURL.isEmpty {
            guard let configuredURL = URL(string: trimmedServerURL),
                  configuredURL.scheme != nil,
                  configuredURL.host != nil else {
                return nil
            }
            baseURL = configuredURL
        } else if let fallbackPort,
                  let fallbackURL = URL(string: "http://localhost:\(fallbackPort)") {
            baseURL = fallbackURL
        } else {
            return nil
        }

        return resolvedHTTPTransportURL(path: path, baseURL: baseURL)
    }

    func resolvedHTTPTransportURL(path: String, fallbackPort: Int? = nil) -> URL? {
        Self.resolvedHTTPTransportURL(path: path, serverURL: serverURL, fallbackPort: fallbackPort)
    }

    private nonisolated static func resolvedHTTPTransportURL(path: String, baseURL: URL) -> URL? {
        var base = baseURL.absoluteString
        if !base.hasSuffix("/") {
            base += "/"
        }

        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let normalizedBaseURL = URL(string: base) else {
            return nil
        }
        return URL(string: relativePath, relativeTo: normalizedBaseURL)?.absoluteURL
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

    private static func makeUITickets() -> [Ticket] {
        [
            Ticket(
                id: "0007-port-tickets-workflow",
                content: """
                # Port Tickets Workflow To GUI

                ## Problem

                The GUI has no tickets view or Smithers ticket methods.
                """,
                status: nil,
                createdAtMs: UITestSupport.nowMs - 86_400_000,
                updatedAtMs: UITestSupport.nowMs - 43_200_000
            ),
            Ticket(
                id: "0015-wire-issues-backend",
                content: """
                # Wire Issues Backend

                ## Summary

                Connect the issues view to real JJHub data.
                """,
                status: nil,
                createdAtMs: UITestSupport.nowMs - 64_800_000,
                updatedAtMs: UITestSupport.nowMs - 21_600_000
            ),
        ]
    }

    private static func makeUICrons() -> [CronSchedule] {
        let now = UITestSupport.nowMs
        return [
            CronSchedule(
                id: "cron-ui-1",
                pattern: "0 * * * *",
                workflowPath: ".smithers/workflows/hourly-checks.tsx",
                enabled: true,
                createdAtMs: now - 2_592_000_000,
                lastRunAtMs: now - 1_800_000,
                nextRunAtMs: now + 1_800_000,
                errorJson: nil
            ),
            CronSchedule(
                id: "cron-ui-2",
                pattern: "30 9 * * 1-5",
                workflowPath: ".smithers/workflows/weekday-standup.tsx",
                enabled: false,
                createdAtMs: now - 1_296_000_000,
                lastRunAtMs: now - 86_400_000,
                nextRunAtMs: nil,
                errorJson: "{\"message\":\"workflow not found\"}"
            ),
        ]
    }

    private static func makeUILandings() -> [Landing] {
        [
            Landing(
                id: "landing-201",
                number: 201,
                title: "UI fixture landing",
                description: "Landing fixture used for UI mode.",
                state: "open",
                targetBranch: "main",
                author: "smithers",
                createdAt: "2026-04-14T10:00:00Z",
                reviewStatus: "pending"
            ),
            Landing(
                id: "landing-202",
                number: 202,
                title: "Merged fixture landing",
                description: "Already merged fixture landing.",
                state: "merged",
                targetBranch: "main",
                author: "smithers",
                createdAt: "2026-04-13T10:00:00Z",
                reviewStatus: "approved"
            ),
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
        return try await execBinaryArgs(bin: jjhubBin, args: fullArgs, displayName: "jjhub")
    }

    private func execJJHubRawArgs(_ args: [String]) async throws -> String {
        let fullArgs = args + ["--no-color"]
        let data = try await execBinaryArgs(bin: jjhubBin, args: fullArgs, displayName: "jjhub")
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

    private func execFirstJSON<T: Decodable>(_ args: String...) async throws -> T {
        let data = try await execArgs(args)
        let jsonData = try Self.firstJSONValueData(in: data)
        return try decoder.decode(T.self, from: jsonData)
    }

    private func decodeCLIJSON<T: Decodable>(_: T.Type, from data: Data) throws -> T {
        var firstError: Error?
        for candidate in cliJSONPayloadCandidates(from: data) {
            do {
                return try decoder.decode(T.self, from: candidate)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        return try decoder.decode(T.self, from: data)
    }

    private nonisolated static func firstJSONValueData(in data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard let start = bytes.firstIndex(where: { $0 == 0x7B || $0 == 0x5B }) else {
            throw SmithersError.cli("No JSON value found in smithers output")
        }

        let open = bytes[start]
        let close: UInt8 = open == 0x7B ? 0x7D : 0x5D
        var depth = 0
        var inString = false
        var escaped = false

        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
                continue
            }

            if byte == 0x22 {
                inString = true
            } else if byte == open {
                depth += 1
            } else if byte == close {
                depth -= 1
                if depth == 0 {
                    return data.subdata(in: start..<(index + 1))
                }
            }
        }

        throw SmithersError.cli("Incomplete JSON value in smithers output")
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

    private func workflowEntryFile(for workflow: Workflow) throws -> String {
        guard let relativePath = workflow.relativePath else {
            throw SmithersError.api("Workflow \(workflow.id) is missing an entry file path")
        }
        return try normalizedWorkflowPath(relativePath)
    }

    private func normalizedWorkflowPath(_ workflowPath: String) throws -> String {
        let trimmed = workflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SmithersError.api("Workflow entry file path is required")
        }
        return trimmed
    }

    func getWorkflowDAG(_ workflow: Workflow) async throws -> WorkflowDAG {
        try await getWorkflowDAG(workflowPath: workflowEntryFile(for: workflow))
    }

    func getWorkflowDAG(workflowPath: String) async throws -> WorkflowDAG {
        let workflowPath = try normalizedWorkflowPath(workflowPath)
        if UITestSupport.isEnabled {
            let promptTask = WorkflowDAGTask(nodeId: "prompt", ordinal: 0, outputTableName: "prompt")
            let reviewTask = WorkflowDAGTask(nodeId: "review", ordinal: 1, outputTableName: "review")
            return WorkflowDAG(
                workflowID: workflowPath,
                mode: "inferred",
                runId: "graph",
                frameNo: 0,
                xml: WorkflowDAGXMLNode(
                    kind: "element",
                    tag: "smithers:workflow",
                    props: ["name": "fixture"],
                    children: [
                        WorkflowDAGXMLNode(
                            kind: "element",
                            tag: "smithers:sequence",
                            children: [
                                WorkflowDAGXMLNode(kind: "element", tag: "smithers:task", props: ["id": "prompt"]),
                                WorkflowDAGXMLNode(kind: "element", tag: "smithers:task", props: ["id": "review"]),
                            ]
                        ),
                    ]
                ),
                tasks: [promptTask, reviewTask],
                entryTaskID: "prompt",
                fields: [
                    WorkflowLaunchField(name: "Prompt", key: "prompt", type: "string", defaultValue: "Ship the fixture"),
                    WorkflowLaunchField(name: "Environment", key: "environment", type: "string", defaultValue: "staging"),
                ],
                message: nil
            )
        }

        // Use smithers graph to get the real rendered workflow XML and task list.
        let data = try await exec("graph", workflowPath, "--format", "json")
        if let envelope = try? decodeCLIJSON(APIEnvelope<WorkflowDAG>.self, from: data),
           let dag = envelope.data,
           !dag.isEmpty {
            return dag
        }
        if let dag = try? decodeCLIJSON(WorkflowDAG.self, from: data), !dag.isEmpty {
            return dag
        }
        // Fallback: return a generic single-field DAG so launch still works.
        return WorkflowDAG(
            workflowID: workflowPath,
            mode: "fallback",
            entryTask: nil,
            entryTaskID: nil,
            fields: [
                WorkflowLaunchField(name: "Prompt", key: "prompt", type: "string", defaultValue: nil),
            ],
            message: "Launch fields inferred via CLI fallback; daemon API unavailable."
        )
    }

    struct LaunchResult: Decodable {
        let runId: String
    }

    func runWorkflow(_ workflow: Workflow, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowEntryFile(for: workflow), inputs: inputs)
    }

    func runWorkflow(_ workflow: Workflow, inputs: [String: String]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowEntryFile(for: workflow), inputs: inputs)
    }

    func runWorkflow(_ workflowPath: String, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowPath, inputs: inputs)
    }

    func runWorkflow(_ workflowPath: String, inputs: [String: String]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowPath, inputs: inputs)
    }

    func runWorkflow(workflowPath: String, inputs: [String: String]) async throws -> LaunchResult {
        try await runWorkflow(workflowPath: workflowPath, inputs: inputs.mapValues { .string($0) })
    }

    func runWorkflow(workflowPath: String, inputs: [String: JSONValue] = [:]) async throws -> LaunchResult {
        let workflowPath = try normalizedWorkflowPath(workflowPath)
        if UITestSupport.isEnabled {
            return LaunchResult(runId: "ui-run-launched-\(workflowPath)")
        }

        var args = ["up", workflowPath, "-d", "--format", "json"]
        if !inputs.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let inputJSON = try encoder.encode(inputs)
            args += ["--input", String(data: inputJSON, encoding: .utf8)!]
        }
        let data = try await execArgs(args)
        return try decoder.decode(LaunchResult.self, from: data)
    }

    func runWorkflowDoctor(_ workflow: Workflow) async -> [WorkflowDoctorIssue] {
        var issues: [WorkflowDoctorIssue] = []

        do {
            _ = try await resolveSmithersBinaryPath()
            issues.append(
                WorkflowDoctorIssue(
                    severity: "ok",
                    check: "smithers-binary",
                    message: "smithers binary found on PATH."
                )
            )
        } catch {
            issues.append(
                WorkflowDoctorIssue(
                    severity: "error",
                    check: "smithers-binary",
                    message: "smithers binary not found on PATH. Install smithers and ensure it is accessible."
                )
            )
        }

        do {
            let dag = try await getWorkflowDAG(workflow)
            let fields = dag.launchFields

            issues.append(
                WorkflowDoctorIssue(
                    severity: "ok",
                    check: "launch-fields",
                    message: "Launch fields fetched (\(fields.count) field(s) found)."
                )
            )

            if dag.isFallbackMode {
                var message = "Workflow analysis fell back to generic mode."
                if let dagMessage = dag.message?.trimmingCharacters(in: .whitespacesAndNewlines), !dagMessage.isEmpty {
                    message += " \(dagMessage)"
                }
                issues.append(
                    WorkflowDoctorIssue(
                        severity: "warning",
                        check: "dag-analysis",
                        message: message
                    )
                )
            } else {
                let mode = dag.mode?.trimmingCharacters(in: .whitespacesAndNewlines)
                let modeLabel = (mode?.isEmpty == false) ? mode! : "inferred"
                issues.append(
                    WorkflowDoctorIssue(
                        severity: "ok",
                        check: "dag-analysis",
                        message: "Workflow analysed successfully (mode: \(modeLabel))."
                    )
                )
            }

            if fields.isEmpty {
                issues.append(
                    WorkflowDoctorIssue(
                        severity: "warning",
                        check: "input-fields",
                        message: "No input fields defined. The workflow may not accept any parameters."
                    )
                )
            } else {
                let invalidFields = fields.filter { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                if invalidFields > 0 {
                    issues.append(
                        WorkflowDoctorIssue(
                            severity: "warning",
                            check: "input-fields",
                            message: "\(invalidFields) input field(s) have an empty key. Check the workflow source."
                        )
                    )
                } else {
                    issues.append(
                        WorkflowDoctorIssue(
                            severity: "ok",
                            check: "input-fields",
                            message: "All \(fields.count) input field(s) have valid keys."
                        )
                    )
                }
            }
        } catch {
            issues.append(
                WorkflowDoctorIssue(
                    severity: "error",
                    check: "launch-fields",
                    message: "Could not fetch workflow launch fields: \(error.localizedDescription)"
                )
            )
        }

        return issues
    }

    private func resolveSmithersBinaryPath() async throws -> String {
        if UITestSupport.isEnabled {
            return "/usr/local/bin/\(smithersBin)"
        }

        let data = try await execBinaryArgs(bin: "which", args: [smithersBin], displayName: "which")
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw SmithersError.cli("smithers binary not found on PATH")
        }
        return path
    }

    // MARK: - Workflow Source (filesystem)

    /// Resolve and validate a path under .smithers/ (workflows, components, prompts).
    private func smithersFilePath(_ relativePath: String) throws -> String {
        let smithersDir = (cwd as NSString).appendingPathComponent(".smithers")
        let full = (cwd as NSString).appendingPathComponent(relativePath)
        let standardizedDir = (smithersDir as NSString).standardizingPath
        let standardizedPath = (full as NSString).standardizingPath
        guard standardizedPath.hasPrefix(standardizedDir + "/") else {
            throw SmithersError.api("Invalid path: must be under .smithers/")
        }
        return standardizedPath
    }

    func readWorkflowSource(_ relativePath: String) async throws -> String {
        if UITestSupport.isEnabled {
            return "// Mock workflow source for \(relativePath)"
        }
        let path = try smithersFilePath(relativePath)
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    func saveWorkflowSource(_ relativePath: String, source: String) async throws {
        if UITestSupport.isEnabled { return }
        let path = try smithersFilePath(relativePath)
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Parse import statements from a workflow .tsx file to find referenced components and prompts.
    func parseWorkflowImports(_ source: String) -> (components: [(name: String, path: String)], prompts: [(name: String, path: String)]) {
        var components: [(String, String)] = []
        var prompts: [(String, String)] = []

        let lines = source.components(separatedBy: .newlines)
        // Match: import ... from "../components/Foo" or "../prompts/bar.mdx"
        let importPattern = try! NSRegularExpression(
            pattern: #"import\s+.*from\s+["\'](\.\./(?:components|prompts)/[^"\']+)["\']"#
        )
        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            if let match = importPattern.firstMatch(in: line, range: range),
               let pathRange = Range(match.range(at: 1), in: line) {
                let importPath = String(line[pathRange])
                // Resolve relative to workflows/ → strip "../"
                let resolved = importPath.replacingOccurrences(of: "../", with: ".smithers/")
                let fileName = (resolved as NSString).lastPathComponent
                let name = (fileName as NSString).deletingPathExtension

                if importPath.contains("/components/") {
                    let fullPath = resolved.hasSuffix(".tsx") ? resolved : resolved + ".tsx"
                    components.append((name, fullPath))
                } else if importPath.contains("/prompts/") {
                    prompts.append((name, resolved))
                }
            }
        }
        return (components, prompts)
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
        // ps may return wrapped or bare — try native RunSummary first, then CLI format
        if let wrapped = try? decoder.decode(RunsResponse.self, from: data) {
            return wrapped.runs
        }
        if let bare = try? decoder.decode([RunSummary].self, from: data) {
            return bare
        }
        // CLI may return different field names (id/workflow/started vs runId/workflowName/startedAtMs)
        if let cliWrapped = try? decoder.decode(CLIRunsResponse.self, from: data) {
            return cliWrapped.runs.map { $0.toRunSummary() }
        }
        let cliBare = try decoder.decode([CLIRunEntry].self, from: data)
        return cliBare.map { $0.toRunSummary() }
    }

    func inspectRun(_ runId: String) async throws -> RunInspection {
        if UITestSupport.isEnabled {
            let run = Self.makeUIRuns().first { $0.runId == runId } ?? Self.makeUIRuns()[0]
            return RunInspection(run: run, tasks: [
                RunTask(nodeId: "prepare", label: "Prepare", iteration: 0, state: "finished", lastAttempt: 1, updatedAtMs: UITestSupport.nowMs - 300_000),
                RunTask(nodeId: "deploy-gate", label: "Deploy gate", iteration: 0, state: "blocked", lastAttempt: 1, updatedAtMs: UITestSupport.nowMs - 120_000),
            ])
        }

        let data = try await exec("inspect", runId, "--format", "json")
        do {
            return try Self.decodeRunInspection(from: data, decoder: decoder)
        } catch {
            do {
                return try await inspectRunPaged(runId)
            } catch {
                throw error
            }
        }
    }

    nonisolated static func decodeRunInspection(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> RunInspection {
        if let inspection = try? decoder.decode(RunInspection.self, from: data) {
            return inspection
        }
        if let envelope = try? decoder.decode(APIEnvelope<RunInspection>.self, from: data),
           let inspection = envelope.data {
            return inspection
        }
        if let envelope = try? decoder.decode(DataEnvelope<RunInspection>.self, from: data) {
            return envelope.data
        }
        if let cliInspection = try? decoder.decode(CLIInspectResponse.self, from: data) {
            return cliInspection.toRunInspection()
        }
        if let envelope = try? decoder.decode(APIEnvelope<CLIInspectResponse>.self, from: data),
           let cliInspection = envelope.data {
            return cliInspection.toRunInspection()
        }
        if let envelope = try? decoder.decode(DataEnvelope<CLIInspectResponse>.self, from: data) {
            return envelope.data.toRunInspection()
        }

        return try decoder.decode(CLIInspectResponse.self, from: data).toRunInspection()
    }

    private func inspectRunPaged(_ runId: String) async throws -> RunInspection {
        let pageSize = 200
        var offset = 0
        var run: RunSummary?
        var tasks: [RunTask] = []

        while true {
            let filter = "run,steps[\(offset),\(offset + pageSize)]"
            let data = try await exec("inspect", runId, "--format", "json", "--filter-output", filter)
            let page = try Self.decodeRunInspection(from: data, decoder: decoder)
            if run == nil {
                run = page.run
            }
            tasks.append(contentsOf: page.tasks)

            if page.tasks.count < pageSize {
                break
            }
            offset += pageSize
        }

        guard let baseRun = run else {
            throw SmithersError.api("Failed to parse inspect JSON for run \(runId)")
        }

        let mergedRun = RunSummary(
            runId: baseRun.runId,
            workflowName: baseRun.workflowName,
            workflowPath: baseRun.workflowPath,
            status: baseRun.status,
            startedAtMs: baseRun.startedAtMs,
            finishedAtMs: baseRun.finishedAtMs,
            summary: makeRunTaskSummary(tasks),
            errorJson: baseRun.errorJson
        )
        return RunInspection(run: mergedRun, tasks: tasks)
    }

    func cancelRun(_ runId: String) async throws {
        if UITestSupport.isEnabled { return }
        _ = try await exec("cancel", runId)
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

    func approveNode(runId: String, nodeId: String, iteration: Int? = nil, note: String? = nil) async throws {
        if UITestSupport.isEnabled {
            uiResolvedApprovalIDs.insert("\(runId):\(nodeId)")
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)-approved", runId: runId, nodeId: nodeId, action: "approved", note: note, reason: nil, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        let args = Self.approveNodeCLIArgs(runId: runId, nodeId: nodeId, iteration: iteration, note: note)
        _ = try await execArgs(args)
    }

    func denyNode(runId: String, nodeId: String, iteration: Int? = nil, reason: String? = nil) async throws {
        if UITestSupport.isEnabled {
            uiResolvedApprovalIDs.insert("\(runId):\(nodeId)")
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)-denied", runId: runId, nodeId: nodeId, action: "denied", note: nil, reason: reason, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        let args = Self.denyNodeCLIArgs(runId: runId, nodeId: nodeId, iteration: iteration, reason: reason)
        _ = try await execArgs(args)
    }

    // MARK: - Run Streaming (HTTP — requires --serve)

    func streamRunEvents(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        let filterRunId = Self.sseFilterRunId(runId)
        guard let url = resolvedHTTPTransportURL(path: Self.runEventsPath(runId: filterRunId), fallbackPort: port) else {
            return emptySSEStream()
        }
        return sseStream(url: url, runId: filterRunId)
    }

    func streamChat(_ runId: String, port: Int = 7331) -> AsyncStream<SSEEvent> {
        let encodedRunId = runId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? runId
        let paths = [
            "/v1/runs/\(encodedRunId)/chat/stream",
            "/chat/stream?runId=\(encodedRunId)",
            "/chat/stream",
        ]
        let urls = paths.compactMap { resolvedHTTPTransportURL(path: $0, fallbackPort: port) }
        guard !urls.isEmpty else {
            return emptySSEStream()
        }
        return sseStream(urls: urls, runId: SSEEvent.normalizedRunId(runId))
    }

    private nonisolated static func sseFilterRunId(_ runId: String?) -> String? {
        guard let runId = SSEEvent.normalizedRunId(runId),
              runId != allRunsStreamRunId else {
            return nil
        }
        return runId
    }

    private nonisolated static func runEventsPath(runId: String?) -> String {
        guard let runId else { return "/events" }
        var components = URLComponents()
        components.path = "/events"
        components.queryItems = [URLQueryItem(name: "runId", value: runId)]
        return components.string ?? "/events"
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

    func rerunRun(_ runId: String) async throws -> String {
        if UITestSupport.isEnabled {
            return "Triggered JJHub rerun for run #\(runId)"
        }

        guard let numericRunID = Int(runId) else {
            throw SmithersError.api("JJHub rerun expects a numeric run ID")
        }

        do {
            let data = try await execJJHubJSONArgs(["run", "rerun", "\(numericRunID)"])
            if let rerunID = parseJJHubRunID(from: data) {
                return "Triggered JJHub rerun #\(rerunID) from run #\(numericRunID)"
            }
            return "Triggered JJHub rerun for run #\(numericRunID)"
        } catch {
            if let output = try? await execJJHubRawArgs(["run", "rerun", "\(numericRunID)"]) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            throw error
        }
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

    private func parseJJHubRunID(from data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extractRunID(object)
    }

    private func extractRunID(_ value: Any) -> Int? {
        if let dict = value as? [String: Any] {
            let keys = ["workflow_run_id", "workflowRunId", "run_id", "runId", "id"]
            for key in keys {
                if let intValue = dict[key] as? Int {
                    return intValue
                }
                if let stringValue = dict[key] as? String, let intValue = Int(stringValue) {
                    return intValue
                }
            }
            for nested in dict.values {
                if let found = extractRunID(nested) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for nested in array {
                if let found = extractRunID(nested) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - Memory

    func listMemoryFacts(namespace: String? = nil, workflowPath: String? = nil) async throws -> [MemoryFact] {
        if UITestSupport.isEnabled {
            let facts = [
                MemoryFact(namespace: "project", key: "language", valueJson: "\"Swift\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 86_400_000, updatedAtMs: UITestSupport.nowMs - 3_600_000, ttlMs: nil),
                MemoryFact(namespace: "workflow", key: "default-env", valueJson: "\"staging\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 43_200_000, updatedAtMs: UITestSupport.nowMs - 1_800_000, ttlMs: nil),
            ]
            guard let namespace else { return facts }
            return facts.filter { $0.namespace == namespace }
        }

        let args = SmithersMemoryCLI.listArgs(
            namespace: namespace,
            workflowPath: try resolvedMemoryWorkflowPath(workflowPath)
        )
        let data = try await execArgs(args)
        return try decodeMemoryFacts(from: data)
    }

    func recallMemory(query: String, namespace: String? = nil, workflowPath: String? = nil, topK: Int = 10) async throws -> [MemoryRecallResult] {
        if UITestSupport.isEnabled {
            return [
                MemoryRecallResult(score: 0.94, content: "SmithersGUI UI test memory result for \(query)", metadata: "namespace=project"),
            ]
        }

        let args = SmithersMemoryCLI.recallArgs(
            query: query,
            namespace: namespace,
            workflowPath: try resolvedMemoryWorkflowPath(workflowPath),
            topK: topK
        )
        let data = try await execArgs(args)
        return try decodeMemoryRecallResults(from: data)
    }

    private func resolvedMemoryWorkflowPath(_ workflowPath: String?) throws -> String {
        if let workflowPath = SmithersMemoryCLI.normalizedWorkflowPath(workflowPath) {
            return workflowPath
        }
        if let discovered = discoverDefaultWorkflowPath() {
            return discovered
        }
        throw SmithersError.api("Memory commands require a workflow path; no .smithers/workflows/*.tsx file was found.")
    }

    private func discoverDefaultWorkflowPath() -> String? {
        let workflowsDir = URL(fileURLWithPath: cwd)
            .appendingPathComponent(".smithers")
            .appendingPathComponent("workflows")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: workflowsDir,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }

        return entries
            .filter { $0.pathExtension == "tsx" }
            .map { ".smithers/workflows/\($0.lastPathComponent)" }
            .sorted()
            .first
    }

    private func decodeMemoryFacts(from data: Data) throws -> [MemoryFact] {
        if let wrapped = try? decodeCLIJSON(MemoryResponse.self, from: data) {
            return wrapped.facts
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<MemoryResponse>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.facts
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<MemoryResponse>.self, from: data) {
            return envelope.data.facts
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<[MemoryFact]>.self, from: data),
           envelope.ok,
           let facts = envelope.data {
            return facts
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<[MemoryFact]>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON([MemoryFact].self, from: data)
    }

    private func decodeMemoryRecallResults(from data: Data) throws -> [MemoryRecallResult] {
        if let wrapped = try? decodeCLIJSON(RecallResponse.self, from: data) {
            return wrapped.results
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<RecallResponse>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.results
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<RecallResponse>.self, from: data) {
            return envelope.data.results
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<[MemoryRecallResult]>.self, from: data),
           envelope.ok,
           let results = envelope.data {
            return results
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<[MemoryRecallResult]>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON([MemoryRecallResult].self, from: data)
    }

    // MARK: - Scores

    func listRecentScores(runId: String) async throws -> [ScoreRow] {
        let trimmedRunId = runId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRunId.isEmpty else {
            throw SmithersError.cli("Run ID is required to list scores")
        }

        if UITestSupport.isEnabled {
            return [
                ScoreRow(id: "score-1", runId: trimmedRunId, nodeId: "test", iteration: 0, attempt: 1, scorerId: "quality", scorerName: "Quality", source: "live", score: 0.91, reason: "Fixture score", metaJson: nil, latencyMs: 42, scoredAtMs: UITestSupport.nowMs - 600_000),
                ScoreRow(id: "score-2", runId: trimmedRunId, nodeId: "lint", iteration: 0, attempt: 1, scorerId: "lint", scorerName: "Lint", source: "batch", score: 0.72, reason: "Fixture lint score", metaJson: nil, latencyMs: 31, scoredAtMs: UITestSupport.nowMs - 500_000),
            ]
        }

        let args = ["scores", trimmedRunId, "--format", "json"]
        let data = try await execArgs(args)
        if let wrapped = try? decoder.decode(ScoresResponse.self, from: data) {
            return wrapped.scores
        }
        return try decoder.decode([ScoreRow].self, from: data)
    }

    func aggregateScores(from scores: [ScoreRow], limit: Int = 50) async throws -> [AggregateScore] {
        AggregateScore.aggregate(scores)
    }

    // MARK: - Tickets (filesystem + optional HTTP)

    private func ticketsDirectoryPath() -> String {
        let ticketsDir = (cwd as NSString).appendingPathComponent(".smithers/tickets")
        return (ticketsDir as NSString).standardizingPath
    }

    private func ticketPath(for ticketId: String) throws -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:")
        guard !ticketId.isEmpty,
              ticketId != ".",
              ticketId != "..",
              !ticketId.contains(".."),
              ticketId.rangeOfCharacter(from: invalidCharacters) == nil
        else {
            throw SmithersError.api("Invalid ticket id")
        }

        let ticketsDir = ticketsDirectoryPath()
        let path = (ticketsDir as NSString).appendingPathComponent("\(ticketId).md")
        let standardizedPath = (path as NSString).standardizingPath
        guard standardizedPath.hasPrefix(ticketsDir + "/") else {
            throw SmithersError.api("Invalid ticket id")
        }
        return standardizedPath
    }

    private func loadTicketsFromFilesystem() throws -> [Ticket] {
        let ticketsDir = ticketsDirectoryPath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: ticketsDir) else { return [] }

        let files = try fm.contentsOfDirectory(atPath: ticketsDir)
            .filter { $0.hasSuffix(".md") }
            .sorted()

        return files.compactMap { file in
            let id = (file as NSString).deletingPathExtension
            let path = (ticketsDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return nil
            }
            return Ticket(id: id, content: content, status: nil, createdAtMs: nil, updatedAtMs: nil)
        }
    }

    private func decodeTicket(_ data: Data) throws -> Ticket {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<Ticket>.self, from: payload) {
            guard !wrapped.data.id.isEmpty else {
                throw SmithersError.api("parse ticket: missing id field in response")
            }
            return wrapped.data
        }
        let ticket = try decoder.decode(Ticket.self, from: payload)
        guard !ticket.id.isEmpty else {
            throw SmithersError.api("parse ticket: missing id field in response")
        }
        return ticket
    }

    private func decodeTickets(_ data: Data) throws -> [Ticket] {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<[Ticket]>.self, from: payload) {
            return wrapped.data
        }
        return try decoder.decode([Ticket].self, from: payload)
    }

    private func isTicketNotFoundError(_ error: Error) -> Bool {
        if case SmithersError.notFound = error {
            return true
        }
        if case SmithersError.httpError(let code) = error, code == 404 {
            return true
        }
        let msg = error.localizedDescription.uppercased()
        return msg.contains("TICKET_NOT_FOUND") || msg.contains("NOT FOUND") || msg.contains("404")
    }

    private func isTicketExistsError(_ error: Error) -> Bool {
        if case SmithersError.httpError(let code) = error, code == 409 {
            return true
        }
        let msg = error.localizedDescription.uppercased()
        return msg.contains("TICKET_EXISTS") || msg.contains("ALREADY EXISTS") || msg.contains("409")
    }

    private func defaultTicketContent(for ticketId: String) -> String {
        let titleWords = ticketId
            .split(separator: "-")
            .map { word in
                let raw = String(word)
                guard let first = raw.first else { return raw }
                return first.uppercased() + raw.dropFirst()
            }
            .joined(separator: " ")
        let title = titleWords.isEmpty ? ticketId : titleWords

        return """
        # \(title)

        ## Problem

        Describe the problem.

        ## Current State

        - TBD

        ## Goal

        Describe the intended outcome.

        ## Proposed Changes

        - TBD

        ## Acceptance Criteria

        - [ ] TBD
        """
    }

    func listTickets() async throws -> [Ticket] {
        if UITestSupport.isEnabled {
            return uiTickets.sorted { $0.id < $1.id }
        }

        if let data = try? await httpRequestRaw(method: "GET", path: "/ticket/list"),
           let tickets = try? decodeTickets(data) {
            return tickets
        }

        return try loadTicketsFromFilesystem()
    }

    func getTicket(_ ticketId: String) async throws -> Ticket {
        let trimmedId = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SmithersError.api("ticketID must not be empty")
        }

        if UITestSupport.isEnabled {
            guard let ticket = uiTickets.first(where: { $0.id == trimmedId }) else {
                throw SmithersError.notFound
            }
            return ticket
        }

        let encodedId = trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId
        do {
            let data = try await httpRequestRaw(method: "GET", path: "/ticket/get/\(encodedId)")
            return try decodeTicket(data)
        } catch {
            if isTicketNotFoundError(error) {
                throw SmithersError.notFound
            }
        }

        let path = try ticketPath(for: trimmedId)
        guard FileManager.default.fileExists(atPath: path) else {
            throw SmithersError.notFound
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        return Ticket(id: trimmedId, content: content, status: nil, createdAtMs: nil, updatedAtMs: nil)
    }

    func createTicket(id ticketId: String, content: String? = nil) async throws -> Ticket {
        let trimmedId = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SmithersError.api("CreateTicketInput.ID must not be empty")
        }

        let contentToWrite: String
        if let content, !content.isEmpty {
            contentToWrite = content
        } else {
            contentToWrite = defaultTicketContent(for: trimmedId)
        }

        if UITestSupport.isEnabled {
            if uiTickets.contains(where: { $0.id == trimmedId }) {
                throw SmithersError.api("TICKET_EXISTS")
            }
            let now = UITestSupport.nowMs
            let ticket = Ticket(id: trimmedId, content: contentToWrite, status: nil, createdAtMs: now, updatedAtMs: now)
            uiTickets.insert(ticket, at: 0)
            return ticket
        }

        do {
            let body = try JSONEncoder().encode(CreateTicketInput(id: trimmedId, content: content))
            let data = try await httpRequestRaw(method: "POST", path: "/ticket/create", jsonBody: body)
            return try decodeTicket(data)
        } catch {
            if isTicketExistsError(error) {
                throw SmithersError.api("TICKET_EXISTS")
            }
        }

        let path = try ticketPath(for: trimmedId)
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            throw SmithersError.api("TICKET_EXISTS")
        }
        try fm.createDirectory(atPath: ticketsDirectoryPath(), withIntermediateDirectories: true)
        try contentToWrite.write(toFile: path, atomically: true, encoding: .utf8)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Ticket(id: trimmedId, content: contentToWrite, status: nil, createdAtMs: now, updatedAtMs: now)
    }

    func updateTicket(_ ticketId: String, content: String) async throws -> Ticket {
        let trimmedId = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SmithersError.api("ticketID must not be empty")
        }
        guard !content.isEmpty else {
            throw SmithersError.api("UpdateTicketInput.Content must not be empty")
        }

        if UITestSupport.isEnabled {
            guard let index = uiTickets.firstIndex(where: { $0.id == trimmedId }) else {
                throw SmithersError.notFound
            }
            let existing = uiTickets[index]
            let updated = Ticket(
                id: existing.id,
                content: content,
                status: existing.status,
                createdAtMs: existing.createdAtMs,
                updatedAtMs: UITestSupport.nowMs
            )
            uiTickets[index] = updated
            return updated
        }

        let encodedId = trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId
        do {
            let body = try JSONEncoder().encode(UpdateTicketInput(content: content))
            let data = try await httpRequestRaw(method: "POST", path: "/ticket/update/\(encodedId)", jsonBody: body)
            return try decodeTicket(data)
        } catch {
            if isTicketNotFoundError(error) {
                throw SmithersError.notFound
            }
        }

        let path = try ticketPath(for: trimmedId)
        guard FileManager.default.fileExists(atPath: path) else {
            throw SmithersError.notFound
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return Ticket(id: trimmedId, content: content, status: nil, createdAtMs: nil, updatedAtMs: now)
    }

    func deleteTicket(_ ticketId: String) async throws {
        let trimmedId = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SmithersError.api("ticketID must not be empty")
        }

        if UITestSupport.isEnabled {
            guard uiTickets.contains(where: { $0.id == trimmedId }) else {
                throw SmithersError.notFound
            }
            uiTickets.removeAll { $0.id == trimmedId }
            return
        }

        let encodedId = trimmedId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmedId
        do {
            _ = try await httpRequestRaw(method: "POST", path: "/ticket/delete/\(encodedId)")
            return
        } catch {
            if isTicketNotFoundError(error) {
                throw SmithersError.notFound
            }
        }

        let path = try ticketPath(for: trimmedId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw SmithersError.notFound
        }
        try fm.removeItem(atPath: path)
    }

    func searchTickets(query: String) async throws -> [Ticket] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SmithersError.api("query must not be empty")
        }

        if UITestSupport.isEnabled {
            let q = trimmedQuery.lowercased()
            return uiTickets.filter {
                $0.id.lowercased().contains(q) || ($0.content ?? "").lowercased().contains(q)
            }
        }

        let encodedQuery = trimmedQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmedQuery
        if let data = try? await httpRequestRaw(method: "GET", path: "/ticket/search?q=\(encodedQuery)"),
           let tickets = try? decodeTickets(data) {
            return tickets
        }

        let tickets = try loadTicketsFromFilesystem()
        let q = trimmedQuery.lowercased()
        return tickets.filter {
            $0.id.lowercased().contains(q) || ($0.content ?? "").lowercased().contains(q)
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

        let prompt = try await getPrompt(promptId)
        guard let source = prompt.source else { return [] }

        return Self.discoverPromptInputs(in: source)
    }

    private static func discoverPromptInputs(in source: String) -> [PromptInput] {
        var inputsByName: [String: PromptInput] = [:]

        for input in promptInputsFromFrontmatter(in: source) {
            inputsByName[input.name] = input
        }

        for name in promptPropReferences(in: source).sorted() where inputsByName[name] == nil {
            inputsByName[name] = PromptInput(name: name, type: "string", defaultValue: nil)
        }

        return inputsByName.values.sorted { $0.name < $1.name }
    }

    private static func promptPropReferences(in source: String) -> Set<String> {
        var found: Set<String> = []
        let patterns: [(pattern: String, captureIndex: Int)] = [
            (#"(?:^|[^A-Za-z0-9_$])props\s*(?:\?\.|\.)\s*([A-Za-z_$][A-Za-z0-9_$]*(?:[-.][A-Za-z_$][A-Za-z0-9_$]*)*)"#, 1),
            (#"(?:^|[^A-Za-z0-9_$])props\s*\[\s*["']([^"'\]]+)["']\s*\]"#, 1),
        ]

        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { continue }
            let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
            for match in matches {
                if let range = Range(match.range(at: entry.captureIndex), in: source) {
                    found.insert(String(source[range]))
                }
            }
        }

        return found
    }

    private static func promptInputsFromFrontmatter(in source: String) -> [PromptInput] {
        guard let frontmatter = mdxFrontmatterBlock(in: source) else { return [] }
        let lines = frontmatter.components(separatedBy: .newlines)
        var inputsByName: [String: PromptInput] = [:]

        for sectionName in ["props", "inputs"] {
            for section in yamlSections(named: sectionName, in: lines) {
                for input in promptInputsFromYamlSection(section) {
                    inputsByName[input.name] = input
                }
            }
        }

        return inputsByName.values.sorted { $0.name < $1.name }
    }

    private static func mdxFrontmatterBlock(in source: String) -> String? {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return nil
        }

        var block: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return block.joined(separator: "\n")
            }
            block.append(line)
        }

        return nil
    }

    private struct YamlLine {
        let indent: Int
        let text: String
    }

    private static func yamlSections(named sectionName: String, in lines: [String]) -> [[YamlLine]] {
        var sections: [[YamlLine]] = []
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let pair = yamlKeyValue(trimmed),
                  pair.key == sectionName
            else {
                index += 1
                continue
            }

            let baseIndent = leadingWhitespaceCount(rawLine)
            var sectionLines: [YamlLine] = []
            if !pair.value.isEmpty {
                sectionLines.append(YamlLine(indent: baseIndent + 2, text: pair.value))
            }

            index += 1
            while index < lines.count {
                let childRawLine = lines[index]
                let childTrimmed = childRawLine.trimmingCharacters(in: .whitespaces)
                if childTrimmed.isEmpty || childTrimmed.hasPrefix("#") {
                    index += 1
                    continue
                }

                let childIndent = leadingWhitespaceCount(childRawLine)
                if childIndent <= baseIndent {
                    break
                }

                sectionLines.append(YamlLine(indent: childIndent, text: childTrimmed))
                index += 1
            }

            sections.append(sectionLines)
        }

        return sections
    }

    private static func promptInputsFromYamlSection(_ lines: [YamlLine]) -> [PromptInput] {
        guard !lines.isEmpty else { return [] }

        if lines.count == 1, let inlineNames = yamlInlineArray(lines[0].text) {
            return inlineNames.map { PromptInput(name: $0, type: "string", defaultValue: nil) }
        }

        if lines.contains(where: { $0.text.hasPrefix("-") }) {
            return promptInputsFromYamlList(lines)
        }

        return promptInputsFromYamlMap(lines)
    }

    private static func promptInputsFromYamlList(_ lines: [YamlLine]) -> [PromptInput] {
        var inputs: [PromptInput] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.text.hasPrefix("-") else {
                index += 1
                continue
            }

            let itemText = line.text.dropFirst().trimmingCharacters(in: .whitespaces)
            let nestedStart = index + 1
            var nestedEnd = nestedStart
            while nestedEnd < lines.count && !lines[nestedEnd].text.hasPrefix("-") {
                nestedEnd += 1
            }
            let nested = Array(lines[nestedStart..<nestedEnd])

            if let pair = yamlKeyValue(itemText), pair.key == "name" {
                let metadata = yamlMetadata(from: nested)
                inputs.append(PromptInput(
                    name: yamlScalarValue(pair.value),
                    type: metadata.type ?? "string",
                    defaultValue: metadata.defaultValue
                ))
            } else if let pair = yamlKeyValue(itemText) {
                inputs.append(inputFromYamlProperty(
                    name: pair.key,
                    value: pair.value,
                    nested: nested
                ))
            } else {
                let name = yamlScalarValue(itemText)
                if !name.isEmpty {
                    inputs.append(PromptInput(name: name, type: "string", defaultValue: nil))
                }
            }

            index = nestedEnd
        }

        return inputs
    }

    private static func promptInputsFromYamlMap(_ lines: [YamlLine]) -> [PromptInput] {
        guard let itemIndent = lines.map(\.indent).min() else { return [] }
        var inputs: [PromptInput] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard line.indent == itemIndent,
                  let pair = yamlKeyValue(line.text)
            else {
                index += 1
                continue
            }

            let nestedStart = index + 1
            var nestedEnd = nestedStart
            while nestedEnd < lines.count && lines[nestedEnd].indent > line.indent {
                nestedEnd += 1
            }
            let nested = Array(lines[nestedStart..<nestedEnd])
            inputs.append(inputFromYamlProperty(name: pair.key, value: pair.value, nested: nested))
            index = nestedEnd
        }

        return inputs
    }

    private static func inputFromYamlProperty(name: String, value: String, nested: [YamlLine]) -> PromptInput {
        let metadata = yamlMetadata(from: nested)
        let inlineMetadata = yamlInlineObject(value)
        let type = inlineMetadata.type ?? metadata.type ?? yamlTypeValue(value) ?? "string"
        let defaultValue = inlineMetadata.defaultValue ?? metadata.defaultValue
        return PromptInput(name: name, type: type, defaultValue: defaultValue)
    }

    private static func yamlMetadata(from lines: [YamlLine]) -> (type: String?, defaultValue: String?) {
        var type: String?
        var defaultValue: String?

        for line in lines {
            guard let pair = yamlKeyValue(line.text) else { continue }
            switch pair.key {
            case "type":
                type = yamlScalarValue(pair.value)
            case "default", "defaultValue":
                defaultValue = yamlScalarValue(pair.value)
            default:
                continue
            }
        }

        return (type?.isEmpty == true ? nil : type, defaultValue)
    }

    private static func yamlKeyValue(_ text: String) -> (key: String, value: String)? {
        guard let colonIndex = text.firstIndex(of: ":") else { return nil }
        let key = String(text[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let valueStart = text.index(after: colonIndex)
        let value = String(text[valueStart...]).trimmingCharacters(in: .whitespaces)
        return (yamlScalarValue(key), value)
    }

    private static func yamlInlineArray(_ text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast()
        return inner
            .split(separator: ",")
            .map { yamlScalarValue(String($0)) }
            .filter { !$0.isEmpty }
    }

    private static func yamlInlineObject(_ text: String) -> (type: String?, defaultValue: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return (nil, nil) }
        let inner = trimmed.dropFirst().dropLast()
        var type: String?
        var defaultValue: String?

        for entry in inner.split(separator: ",") {
            guard let pair = yamlKeyValue(String(entry).trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            switch pair.key {
            case "type":
                type = yamlScalarValue(pair.value)
            case "default", "defaultValue":
                defaultValue = yamlScalarValue(pair.value)
            default:
                continue
            }
        }

        return (type, defaultValue)
    }

    private static func yamlTypeValue(_ text: String) -> String? {
        let value = yamlScalarValue(text)
        guard !value.isEmpty else { return nil }
        if value.contains(":") || value.hasPrefix("[") || value.hasPrefix("{") {
            return nil
        }
        return value
    }

    private static func yamlScalarValue(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
            || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func leadingWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for character in text {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 2
            } else {
                break
            }
        }
        return count
    }

    func updatePrompt(_ promptId: String, source: String) async throws {
        if UITestSupport.isEnabled { return }
        let path = try promptPath(for: promptId)
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func renderPromptSource(_ source: String, input: [String: String]) -> String {
        var result = source
        for (key, value) in input {
            if let regex = try? NSRegularExpression(pattern: "\\{\\s*props\\.\(NSRegularExpression.escapedPattern(for: key))\\s*\\}") {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: value))
            }
        }
        return result
    }

    func previewPrompt(_ promptId: String, source: String, input: [String: String]) async throws -> String {
        if !UITestSupport.isEnabled {
            _ = try promptPath(for: promptId)
        }
        return renderPromptSource(source, input: input)
    }

    func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String {
        if UITestSupport.isEnabled {
            return renderPromptSource("Write release notes for {props.version}.", input: input)
        }

        let prompt = try await getPrompt(promptId)
        return renderPromptSource(prompt.source ?? "", input: input)
    }

    // MARK: - Timeline / Snapshots

    func listSnapshots(runId: String) async throws -> [Snapshot] {
        if UITestSupport.isEnabled {
            return [
                Snapshot(id: "ui-snapshot-run", runId: runId, nodeId: "prepare", label: "Before deploy", kind: "manual", parentId: nil, createdAtMs: UITestSupport.nowMs - 600_000),
            ]
        }

        let timeline: Timeline = try await execFirstJSON("timeline", runId, "--json=true", "--format", "json")
        let workflowPath = try? await resolveWorkflowPath(forRunId: runId)
        let snapshots = timeline.snapshots(workflowPath: workflowPath)
        if let workflowPath {
            runWorkflowPathCache[runId] = workflowPath
            for snapshot in snapshots {
                snapshotWorkflowPathCache[snapshot.id] = workflowPath
            }
        }
        return snapshots
    }

    func forkRun(snapshotId: String) async throws -> RunSummary {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()[0]
        }

        let ref = try parseSnapshotRef(snapshotId)
        let workflowPath = try await resolveWorkflowPath(forSnapshotRef: ref)
        let response: ForkRunResponse = try await execJSON(
            "fork",
            workflowPath,
            "--run-id",
            ref.runId,
            "--frame",
            String(ref.frameNo),
            "--format",
            "json"
        )
        return response.toRunSummary(workflowPath: workflowPath)
    }

    func replayRun(snapshotId: String) async throws -> RunSummary {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()[0]
        }

        let ref = try parseSnapshotRef(snapshotId)
        let workflowPath = try await resolveWorkflowPath(forSnapshotRef: ref)
        let response: ForkRunResponse = try await execJSON(
            "replay",
            workflowPath,
            "--run-id",
            ref.runId,
            "--frame",
            String(ref.frameNo),
            "--format",
            "json"
        )
        return response.toRunSummary(workflowPath: workflowPath)
    }

    func diffSnapshots(fromId: String, toId: String) async throws -> SnapshotDiff {
        if UITestSupport.isEnabled {
            return SnapshotDiff(fromId: fromId, toId: toId, changes: ["Fixture diff"])
        }

        return try await execFirstJSON("diff", fromId, toId, "--json=true", "--format", "json")
    }

    private func parseSnapshotRef(_ snapshotId: String) throws -> SnapshotRef {
        let parts = snapshotId.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              let frameNo = Int(parts[1]) else {
            throw SmithersError.api("Invalid snapshot ref '\(snapshotId)'. Expected runId:frameNo.")
        }
        return SnapshotRef(runId: String(parts[0]), frameNo: frameNo, rawValue: snapshotId)
    }

    private func resolveWorkflowPath(forSnapshotRef ref: SnapshotRef) async throws -> String {
        if let cached = snapshotWorkflowPathCache[ref.rawValue] ?? runWorkflowPathCache[ref.runId] {
            return cached
        }
        let workflowPath = try await resolveWorkflowPath(forRunId: ref.runId)
        snapshotWorkflowPathCache[ref.rawValue] = workflowPath
        return workflowPath
    }

    private func resolveWorkflowPath(forRunId runId: String) async throws -> String {
        if let cached = runWorkflowPathCache[runId] {
            return cached
        }

        let workflowName = try await workflowName(forRunId: runId)
        let workflowPath = try await resolveWorkflowPath(named: workflowName)
        runWorkflowPathCache[runId] = workflowPath
        return workflowPath
    }

    private func workflowName(forRunId runId: String) async throws -> String {
        let data = try await exec("inspect", runId, "--format", "json")
        if let response = try? decoder.decode(CLIInspectWorkflowResponse.self, from: data),
           let workflow = response.run.workflow?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workflow.isEmpty,
           workflow != "—" {
            return workflow
        }

        let runs = try await listRuns()
        if let run = runs.first(where: { $0.runId == runId }),
           let workflowName = run.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workflowName.isEmpty {
            return workflowName
        }

        throw SmithersError.api("Unable to resolve workflow for run \(runId)")
    }

    private func resolveWorkflowPath(named workflowName: String) async throws -> String {
        let candidates = workflowNameCandidates(for: workflowName)
        for candidate in candidates {
            if candidate.hasSuffix(".tsx") {
                return candidate
            }
            do {
                let response: WorkflowPathResponse = try await execJSON("workflow", "path", candidate, "--format", "json")
                if !response.path.isEmpty {
                    return response.path
                }
            } catch {
                continue
            }
        }

        let workflows = try await listWorkflows()
        for candidate in candidates {
            if let workflow = workflows.first(where: { workflow in
                workflow.id == candidate
                    || workflow.name == candidate
                    || workflow.relativePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == candidate } == true
            }), let path = workflow.relativePath {
                return path
            }
        }

        throw SmithersError.api("Unable to resolve workflow path for '\(workflowName)'")
    }

    private func workflowNameCandidates(for workflowName: String) -> [String] {
        let trimmed = workflowName.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = trimmed
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var candidates: [String] = []
        for value in [trimmed, slug] where !value.isEmpty && !candidates.contains(value) {
            candidates.append(value)
        }
        return candidates
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
        if UITestSupport.isEnabled { return uiCrons }

        let data = try await exec("cron", "list", "--format", "json")
        if let response = try? decoder.decode(CronResponse.self, from: data) {
            return response.crons
        }
        return try decoder.decode([CronSchedule].self, from: data)
    }

    func createCron(pattern: String, workflowPath: String) async throws -> CronSchedule {
        let normalizedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedWorkflowPath = workflowPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty, !normalizedWorkflowPath.isEmpty else {
            throw SmithersError.api("pattern and workflow path are required")
        }

        if UITestSupport.isEnabled {
            let now = UITestSupport.nowMs
            let cron = CronSchedule(
                id: "cron-ui-\(uiCrons.count + 1)",
                pattern: normalizedPattern,
                workflowPath: normalizedWorkflowPath,
                enabled: true,
                createdAtMs: now,
                lastRunAtMs: nil,
                nextRunAtMs: nil,
                errorJson: nil
            )
            uiCrons.insert(cron, at: 0)
            return cron
        }

        return try await execJSON("cron", "add", normalizedPattern, normalizedWorkflowPath, "--format", "json")
    }

    func toggleCron(cronID: String, enabled: Bool) async throws {
        if UITestSupport.isEnabled {
            guard let index = uiCrons.firstIndex(where: { $0.id == cronID }) else { return }
            let existing = uiCrons[index]
            uiCrons[index] = CronSchedule(
                id: existing.id,
                pattern: existing.pattern,
                workflowPath: existing.workflowPath,
                enabled: enabled,
                createdAtMs: existing.createdAtMs,
                lastRunAtMs: existing.lastRunAtMs,
                nextRunAtMs: existing.nextRunAtMs,
                errorJson: existing.errorJson
            )
            return
        }

        let subcommand = enabled ? "enable" : "disable"
        _ = try await exec("cron", subcommand, cronID)
    }

    func deleteCron(cronID: String) async throws {
        if UITestSupport.isEnabled {
            uiCrons.removeAll { $0.id == cronID }
            return
        }
        _ = try await exec("cron", "rm", cronID)
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

        let configuredServerURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = configuredServerURL, !url.isEmpty else {
            isConnected = cliAvailable
            return
        }

        // Check if a serve instance is running
        guard let healthURL = Self.resolvedHTTPTransportURL(path: "/health", serverURL: url) else {
            isConnected = false
            return
        }

        do {
            let request = URLRequest(url: healthURL)
            let (_, response) = try await session.data(for: request)
            isConnected = (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            isConnected = false
        }
    }

    func hasSmithersProject() -> Bool {
        if UITestSupport.isEnabled {
            return true
        }

        let path = (cwd as NSString).appendingPathComponent(".smithers")
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func initializeSmithers() async throws {
        if UITestSupport.isEnabled {
            let path = (cwd as NSString).appendingPathComponent(".smithers")
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return
        }
        _ = try await exec("init")
    }

    // MARK: - Approvals and JJHub-backed views

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

    private func jjhubLandingStateFilter(_ state: String?) -> String {
        let value = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "all":
            return "all"
        case "ready", "open":
            return "open"
        case "landed", "merged":
            return "merged"
        case "draft", "closed":
            return value
        default:
            return value
        }
    }

    private func jjhubIssueStateFilter(_ state: String?) -> String {
        let value = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "", "all":
            return "all"
        case "open", "opened":
            return "open"
        case "closed", "close":
            return "closed"
        default:
            return value
        }
    }

    private func decodeLandingList(_ data: Data) throws -> [Landing] {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<[Landing]>.self, from: payload) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(LandingListResponse.self, from: payload) {
            return wrapped.landings ?? wrapped.items ?? []
        }
        return try decoder.decode([Landing].self, from: payload)
    }

    private func decodeLanding(_ data: Data) throws -> Landing {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<Landing>.self, from: payload) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(LandingDetailResponse.self, from: payload) {
            return wrapped.landing
        }
        return try decoder.decode(Landing.self, from: payload)
    }

    private func decodeLandingDetail(_ data: Data) throws -> LandingDetailResponse {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<LandingDetailResponse>.self, from: payload) {
            return wrapped.data
        }
        if let detail = try? decoder.decode(LandingDetailResponse.self, from: payload) {
            return detail
        }
        if let wrapped = try? decoder.decode(DataEnvelope<Landing>.self, from: payload) {
            return LandingDetailResponse(landing: wrapped.data, changes: nil)
        }
        let landing = try decoder.decode(Landing.self, from: payload)
        return LandingDetailResponse(landing: landing, changes: nil)
    }

    private func getLandingDetail(number: Int) async throws -> LandingDetailResponse {
        let data = try await execJJHubJSONArgs(["land", "view", "\(number)"])
        return try decodeLandingDetail(data)
    }

    func listLandings(state: String? = nil) async throws -> [Landing] {
        if UITestSupport.isEnabled {
            guard let state else { return uiLandings }
            let normalizedState = jjhubLandingStateFilter(state)
            guard normalizedState != "all" else { return uiLandings }
            return uiLandings.filter { jjhubLandingStateFilter($0.state) == normalizedState }
        }

        let data = try await execJJHubJSONArgs([
            "land", "list",
            "-s", jjhubLandingStateFilter(state),
            "-L", "100",
        ])
        return try decodeLandingList(data)
    }

    func getLanding(number: Int) async throws -> Landing {
        if UITestSupport.isEnabled {
            let landings = try await listLandings()
            return landings.first { $0.number == number } ?? landings[0]
        }
        return try await getLandingDetail(number: number).landing
    }

    func createLanding(title: String, body: String?, target: String?, stack: Bool = true) async throws -> Landing {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            throw SmithersError.api("title must not be empty")
        }
        let normalizedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTarget = target?.trimmingCharacters(in: .whitespacesAndNewlines)

        if UITestSupport.isEnabled {
            let nextNumber = (uiLandings.compactMap(\.number).max() ?? 200) + 1
            let landing = Landing(
                id: "landing-\(nextNumber)",
                number: nextNumber,
                title: normalizedTitle,
                description: normalizedBody?.isEmpty == false ? normalizedBody : nil,
                state: "open",
                targetBranch: normalizedTarget?.isEmpty == false ? normalizedTarget : "main",
                author: "smithers",
                createdAt: ISO8601DateFormatter().string(from: Date()),
                reviewStatus: "pending"
            )
            uiLandings.insert(landing, at: 0)
            return landing
        }

        var args = ["land", "create", "-t", normalizedTitle]
        if let normalizedBody, !normalizedBody.isEmpty {
            args += ["-b", normalizedBody]
        }
        if let normalizedTarget, !normalizedTarget.isEmpty {
            args += ["--target", normalizedTarget]
        }
        if stack {
            args.append("--stack")
        }
        let data = try await execJJHubJSONArgs(args)
        return try decodeLanding(data)
    }

    func landingDiff(number: Int) async throws -> String {
        if UITestSupport.isEnabled { return "diff --git a/file.swift b/file.swift\n+fixture change" }
        let detail = try await getLandingDetail(number: number)
        guard let changes = detail.changes, !changes.isEmpty else {
            return ""
        }

        var chunks: [String] = []
        for change in changes {
            let diff = (try await changeDiff(change.changeID))
                .trimmingCharacters(in: .newlines)
            chunks.append("Change \(change.changeID)\n\n\(diff)")
        }
        return chunks.joined(separator: "\n\n------------------------------------------------------------------------\n")
    }

    func landLanding(number: Int) async throws {
        if UITestSupport.isEnabled {
            guard let index = uiLandings.firstIndex(where: { $0.number == number }) else { return }
            let existing = uiLandings[index]
            uiLandings[index] = Landing(
                id: existing.id,
                number: existing.number,
                title: existing.title,
                description: existing.description,
                state: "merged",
                targetBranch: existing.targetBranch,
                author: existing.author,
                createdAt: existing.createdAt,
                reviewStatus: "approved"
            )
            return
        }
        _ = try await execJJHubRawArgs(["land", "land", "\(number)"])
    }

    func reviewLanding(number: Int, action: String, body: String?) async throws {
        if UITestSupport.isEnabled {
            guard let index = uiLandings.firstIndex(where: { $0.number == number }) else { return }
            let existing = uiLandings[index]
            let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let reviewStatus: String
            switch normalizedAction {
            case "approve", "approved":
                reviewStatus = "approved"
            case "request_changes", "changes_requested":
                reviewStatus = "changes_requested"
            case "comment":
                reviewStatus = existing.reviewStatus ?? "pending"
            case "land", "merge", "merged":
                try await landLanding(number: number)
                return
            default:
                throw SmithersError.api("Invalid landing review action: \(action)")
            }
            uiLandings[index] = Landing(
                id: existing.id,
                number: existing.number,
                title: existing.title,
                description: existing.description,
                state: existing.state,
                targetBranch: existing.targetBranch,
                author: existing.author,
                createdAt: existing.createdAt,
                reviewStatus: reviewStatus
            )
            return
        }
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        var args = ["land", "review", "\(number)"]
        switch normalizedAction {
        case "approve", "approved":
            args.append("-a")
        case "request_changes", "changes_requested":
            args.append("-r")
        case "comment":
            args.append("-c")
        case "land", "merge", "merged":
            try await landLanding(number: number)
            return
        default:
            throw SmithersError.api("Invalid landing review action: \(action)")
        }

        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-b", body]
        }
        _ = try await execJJHubRawArgs(args)
    }

    func landingChecks(number: Int) async throws -> String {
        if UITestSupport.isEnabled {
            return """
            ci/unit: pass
            ci/lint: pass
            """
        }
        return try await execJJHubRawArgs(["land", "checks", "\(number)"])
    }

    private func decodeIssue(_ data: Data) throws -> SmithersIssue {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<SmithersIssue>.self, from: payload) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(IssueResponse.self, from: payload) {
            return wrapped.issue
        }
        return try decoder.decode(SmithersIssue.self, from: payload)
    }

    private func decodeIssueList(_ data: Data) throws -> [SmithersIssue] {
        let payload = try unwrapLegacyEnvelope(data)
        if let wrapped = try? decoder.decode(DataEnvelope<[SmithersIssue]>.self, from: payload) {
            return wrapped.data
        }
        if let wrapped = try? decoder.decode(IssueListResponse.self, from: payload) {
            return wrapped.issues ?? wrapped.items ?? []
        }
        return try decoder.decode([SmithersIssue].self, from: payload)
    }

    func listIssues(state: String? = nil) async throws -> [SmithersIssue] {
        if UITestSupport.isEnabled {
            let normalizedState = jjhubIssueStateFilter(state)
            guard normalizedState != "all" else { return uiIssues }
            return uiIssues.filter { jjhubIssueStateFilter($0.state) == normalizedState }
        }

        let jjhubState = jjhubIssueStateFilter(state)
        let data = try await execJJHubJSONArgs(["issue", "list", "-s", jjhubState, "-L", "100"])
        return try decodeIssueList(data)
    }

    func getIssue(number: Int) async throws -> SmithersIssue {
        if UITestSupport.isEnabled {
            guard let issue = uiIssues.first(where: { $0.number == number }) else {
                throw SmithersError.notFound
            }
            return issue
        }

        let data = try await execJJHubJSONArgs(["issue", "view", "\(number)"])
        return try decodeIssue(data)
    }

    func createIssue(title: String, body: String?) async throws -> SmithersIssue {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw SmithersError.api("title must not be empty")
        }

        if UITestSupport.isEnabled {
            let issue = SmithersIssue(id: "issue-\(uiIssues.count + 200)", number: uiIssues.count + 200, title: trimmedTitle, body: body, state: "open", labels: ["ui-test"], assignees: ["smithers"], commentCount: 0)
            uiIssues.insert(issue, at: 0)
            return issue
        }

        var args = ["issue", "create", "-t", trimmedTitle]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-b", body]
        }
        let data = try await execJJHubJSONArgs(args)
        return try decodeIssue(data)
    }

    func closeIssue(number: Int, comment: String?) async throws {
        if UITestSupport.isEnabled {
            guard let index = uiIssues.firstIndex(where: { $0.number == number }) else { return }
            let issue = uiIssues[index]
            uiIssues[index] = SmithersIssue(id: issue.id, number: issue.number, title: issue.title, body: issue.body, state: "closed", labels: issue.labels, assignees: issue.assignees, commentCount: issue.commentCount)
            return
        }

        var args = ["issue", "close", "\(number)"]
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-c", comment]
        }
        let data = try await execJJHubJSONArgs(args)
        if (try? decodeIssue(data)) == nil {
            _ = try await getIssue(number: number)
        }
    }

    func listWorkspaces() async throws -> [Workspace] {
        if UITestSupport.isEnabled { return uiWorkspaces }

        let data = try await execJJHubJSONArgs(["workspace", "list", "-L", "100"])
        return try decodeWorkspaces(from: data)
    }

    func viewWorkspace(_ workspaceId: String) async throws -> Workspace {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }

        if UITestSupport.isEnabled {
            guard let workspace = uiWorkspaces.first(where: { $0.id == normalizedWorkspaceId }) else {
                throw SmithersError.notFound
            }
            return workspace
        }

        let data = try await execJJHubJSONArgs(["workspace", "view", normalizedWorkspaceId])
        return try decodeWorkspace(from: data)
    }

    func createWorkspace(name: String, snapshotId: String? = nil) async throws -> Workspace {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if UITestSupport.isEnabled {
            let workspaceName = normalizedName.isEmpty ? "Workspace \(uiWorkspaces.count + 1)" : normalizedName
            let workspace = Workspace(id: "ui-workspace-\(uiWorkspaces.count + 1)", name: workspaceName, status: "active", createdAt: "2026-04-14")
            uiWorkspaces.insert(workspace, at: 0)
            return workspace
        }

        var args = ["workspace", "create"]
        if !normalizedName.isEmpty {
            args += ["--name", normalizedName]
        }
        if let snapshotId, !snapshotId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--snapshot", snapshotId.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let data = try await execJJHubJSONArgs(args)
        return try decodeWorkspace(from: data)
    }

    func deleteWorkspace(_ workspaceId: String) async throws {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }

        if UITestSupport.isEnabled {
            uiWorkspaces.removeAll { $0.id == normalizedWorkspaceId }
            return
        }

        _ = try await execJJHubRawArgs(["workspace", "delete", normalizedWorkspaceId])
    }

    func suspendWorkspace(_ workspaceId: String) async throws {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }

        if UITestSupport.isEnabled {
            updateUIWorkspace(normalizedWorkspaceId, status: "suspended")
            return
        }

        _ = try await execJJHubJSONArgs(["workspace", "suspend", normalizedWorkspaceId])
    }

    func resumeWorkspace(_ workspaceId: String) async throws {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }

        if UITestSupport.isEnabled {
            updateUIWorkspace(normalizedWorkspaceId, status: "active")
            return
        }

        _ = try await execJJHubJSONArgs(["workspace", "resume", normalizedWorkspaceId])
    }

    func forkWorkspace(_ workspaceId: String, name: String? = nil) async throws -> Workspace {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)

        if UITestSupport.isEnabled {
            guard let parent = uiWorkspaces.first(where: { $0.id == normalizedWorkspaceId }) else {
                throw SmithersError.notFound
            }
            let fallbackName = "\(parent.name)-fork"
            let forkName = (normalizedName?.isEmpty == false) ? (normalizedName ?? fallbackName) : fallbackName
            let workspace = Workspace(
                id: "ui-workspace-\(uiWorkspaces.count + 1)",
                name: forkName,
                status: "active",
                createdAt: "2026-04-14"
            )
            uiWorkspaces.insert(workspace, at: 0)
            return workspace
        }

        var args = ["workspace", "fork", normalizedWorkspaceId]
        if let normalizedName, !normalizedName.isEmpty {
            args += ["--name", normalizedName]
        }
        let data = try await execJJHubJSONArgs(args)
        return try decodeWorkspace(from: data)
    }

    func listWorkspaceSnapshots() async throws -> [WorkspaceSnapshot] {
        if UITestSupport.isEnabled { return uiWorkspaceSnapshots }

        let data = try await execJJHubJSONArgs(["workspace", "snapshot", "list", "-L", "100"])
        return try decodeWorkspaceSnapshots(from: data)
    }

    func viewWorkspaceSnapshot(_ snapshotId: String) async throws -> WorkspaceSnapshot {
        let normalizedSnapshotId = snapshotId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSnapshotId.isEmpty else {
            throw SmithersError.api("snapshotId must not be empty")
        }

        if UITestSupport.isEnabled {
            guard let snapshot = uiWorkspaceSnapshots.first(where: { $0.id == normalizedSnapshotId }) else {
                throw SmithersError.notFound
            }
            return snapshot
        }

        let data = try await execJJHubJSONArgs(["workspace", "snapshot", "view", normalizedSnapshotId])
        return try decodeWorkspaceSnapshot(from: data)
    }

    func createWorkspaceSnapshot(workspaceId: String, name: String) async throws -> WorkspaceSnapshot {
        let normalizedWorkspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspaceId.isEmpty else {
            throw SmithersError.api("workspaceId must not be empty")
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        if UITestSupport.isEnabled {
            let snapshot = WorkspaceSnapshot(id: "ui-snapshot-\(uiWorkspaceSnapshots.count + 1)", workspaceId: normalizedWorkspaceId, name: normalizedName, createdAt: "2026-04-14")
            uiWorkspaceSnapshots.insert(snapshot, at: 0)
            return snapshot
        }

        var args = ["workspace", "snapshot", "create", normalizedWorkspaceId]
        if !normalizedName.isEmpty {
            args += ["--name", normalizedName]
        }
        let data = try await execJJHubJSONArgs(args)
        return try decodeWorkspaceSnapshot(from: data)
    }

    func deleteWorkspaceSnapshot(_ snapshotId: String) async throws {
        let normalizedSnapshotId = snapshotId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSnapshotId.isEmpty else {
            throw SmithersError.api("snapshotId must not be empty")
        }

        if UITestSupport.isEnabled {
            uiWorkspaceSnapshots.removeAll { $0.id == normalizedSnapshotId }
            return
        }

        _ = try await execJJHubRawArgs(["workspace", "snapshot", "delete", normalizedSnapshotId])
    }

    private func decodeWorkspace(from data: Data) throws -> Workspace {
        if let direct = try? decoder.decode(Workspace.self, from: data) {
            return direct
        }
        if let envelope = try? decoder.decode(APIEnvelope<Workspace>.self, from: data),
           let workspace = envelope.data {
            return workspace
        }
        if let envelope = try? decoder.decode(DataEnvelope<Workspace>.self, from: data) {
            return envelope.data
        }
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaces(from data: Data) throws -> [Workspace] {
        if let direct = try? decoder.decode([Workspace].self, from: data) {
            return direct
        }
        if let wrapped = try? decoder.decode(WorkspacesResponse.self, from: data) {
            return wrapped.workspaces
        }
        if let envelope = try? decoder.decode(APIEnvelope<[Workspace]>.self, from: data),
           let workspaces = envelope.data {
            return workspaces
        }
        if let envelope = try? decoder.decode(DataEnvelope<[Workspace]>.self, from: data) {
            return envelope.data
        }
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspaces: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaceSnapshot(from data: Data) throws -> WorkspaceSnapshot {
        if let direct = try? decoder.decode(WorkspaceSnapshot.self, from: data) {
            return direct
        }
        if let envelope = try? decoder.decode(APIEnvelope<WorkspaceSnapshot>.self, from: data),
           let snapshot = envelope.data {
            return snapshot
        }
        if let envelope = try? decoder.decode(DataEnvelope<WorkspaceSnapshot>.self, from: data) {
            return envelope.data
        }
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace snapshot: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaceSnapshots(from data: Data) throws -> [WorkspaceSnapshot] {
        if let direct = try? decoder.decode([WorkspaceSnapshot].self, from: data) {
            return direct
        }
        if let wrapped = try? decoder.decode(WorkspaceSnapshotsResponse.self, from: data) {
            return wrapped.snapshots
        }
        if let envelope = try? decoder.decode(APIEnvelope<[WorkspaceSnapshot]>.self, from: data),
           let snapshots = envelope.data {
            return snapshots
        }
        if let envelope = try? decoder.decode(DataEnvelope<[WorkspaceSnapshot]>.self, from: data) {
            return envelope.data
        }
        let snippet = String(decoding: data.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace snapshots: unsupported JSON response \(snippet)")
    }

    func searchCode(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SmithersError.api("query must not be empty")
        }

        if UITestSupport.isEnabled {
            return [SearchResult(id: "code-1", title: "ContentView.swift", description: "SwiftUI root view", snippet: "ContentView launches \(trimmedQuery)", filePath: "ContentView.swift", lineNumber: 1, kind: "code")]
        }

        let data = try await execJJHubJSONArgs(["search", "code", trimmedQuery, "--limit", "\(limit)"])
        return try Self.decodeCodeSearchResults(data)
    }

    func searchIssues(query: String, state: String? = nil, limit: Int = 20) async throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SmithersError.api("query must not be empty")
        }

        if UITestSupport.isEnabled {
            return try await listIssues(state: state).map {
                SearchResult(id: $0.id, title: $0.title, description: $0.body, snippet: nil, filePath: nil, lineNumber: nil, kind: "issue")
            }
        }

        var args = ["search", "issues", trimmedQuery, "--limit", "\(limit)"]
        if let state = state?.trimmingCharacters(in: .whitespacesAndNewlines),
           !state.isEmpty,
           state.caseInsensitiveCompare("all") != .orderedSame {
            args += ["--state", state]
        }
        let data = try await execJJHubJSONArgs(args)
        return try Self.decodeIssueSearchResults(data)
    }

    func searchRepos(query: String, limit: Int = 20) async throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SmithersError.api("query must not be empty")
        }

        if UITestSupport.isEnabled {
            return [SearchResult(id: "repo-1", title: "smithers/gui", description: "Fixture repository for \(trimmedQuery)", snippet: nil, filePath: nil, lineNumber: nil, kind: "repo")]
        }

        let data = try await execJJHubJSONArgs(["search", "repos", trimmedQuery, "--limit", "\(limit)"])
        return try Self.decodeRepositorySearchResults(data)
    }

    static func decodeRepositorySearchResults(_ data: Data) throws -> [SearchResult] {
        try searchPageItems(from: data).enumerated().map { offset, item in
            let owner = searchString(item["owner"])
            let name = searchString(item["name"])
            let fullName = searchString(item["full_name"])
                ?? searchString(item["fullName"])
                ?? searchRepositoryName(item["repository"])
                ?? [owner, name].compactMap { $0 }.joined(separator: "/").nilIfEmpty
                ?? name
                ?? "Repository"
            let rawId = searchString(item["id"]) ?? fullName
            return SearchResult(
                id: searchID(prefix: "repo", raw: rawId, fallback: "\(offset)"),
                title: fullName,
                description: searchString(item["description"]),
                snippet: nil,
                filePath: nil,
                lineNumber: nil,
                kind: "repo"
            )
        }
    }

    static func decodeIssueSearchResults(_ data: Data) throws -> [SearchResult] {
        try searchPageItems(from: data).enumerated().map { offset, item in
            let number = searchInt(item["number"])
            let title = searchString(item["title"]) ?? number.map { "Issue #\($0)" } ?? "Issue"
            let state = searchString(item["state"])
            let repo = searchString(item["repository_name"])
                ?? searchString(item["repositoryName"])
                ?? searchString(item["repository_full_name"])
                ?? searchString(item["repositoryFullName"])
                ?? searchRepositoryName(item["repository"])
            let metadata = [
                number.map { "#\($0)" },
                state,
                repo,
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
            let rawId = searchString(item["id"])
                ?? number.map { String($0) }
                ?? title
            return SearchResult(
                id: searchID(prefix: "issue", raw: rawId, fallback: "\(offset)"),
                title: title,
                description: searchString(item["body"]) ?? searchString(item["description"]) ?? metadata,
                snippet: nil,
                filePath: nil,
                lineNumber: nil,
                kind: "issue"
            )
        }
    }

    static func decodeCodeSearchResults(_ data: Data) throws -> [SearchResult] {
        try searchPageItems(from: data).enumerated().map { offset, item in
            let repository = searchString(item["repository"])
                ?? searchString(item["repository_name"])
                ?? searchString(item["repositoryName"])
                ?? searchString(item["repository_full_name"])
                ?? searchString(item["repositoryFullName"])
                ?? searchRepositoryName(item["repository"])
            let filePath = searchString(item["file_path"])
                ?? searchString(item["filePath"])
                ?? searchString(item["path"])
                ?? searchString(item["filename"])
            var matches = searchTextMatches(from: item["text_matches"])
            if matches.isEmpty {
                matches = searchTextMatches(from: item["matches"])
            }
            if matches.isEmpty {
                matches = searchTextMatches(from: item["snippets"])
            }
            if matches.isEmpty, let content = searchString(item["content"]) {
                matches = [(content, searchInt(item["line_number"]) ?? searchInt(item["lineNumber"]))]
            }

            let snippet = matches
                .map { $0.content }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
                .nilIfEmpty
            let lineNumber = matches.first { $0.lineNumber != nil }?.lineNumber
            let rawId = searchString(item["id"])
                ?? [repository, filePath, lineNumber.map { String($0) }].compactMap { $0 }.joined(separator: ":").nilIfEmpty
                ?? "\(offset)"
            return SearchResult(
                id: searchID(prefix: "code", raw: rawId, fallback: "\(offset)"),
                title: filePath.map { ($0 as NSString).lastPathComponent }.flatMap { $0.nilIfEmpty } ?? repository ?? "Code result",
                description: repository,
                snippet: snippet,
                filePath: filePath,
                lineNumber: lineNumber,
                kind: "code"
            )
        }
    }

    private static func searchPageItems(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try searchPageItems(from: object)
    }

    private static func searchPageItems(from object: Any) throws -> [[String: Any]] {
        if object is NSNull {
            return []
        }
        if let items = object as? [[String: Any]] {
            return items
        }
        guard let page = object as? [String: Any] else {
            throw SmithersError.api("Unexpected search response format")
        }

        if let ok = page["ok"] as? Bool {
            if !ok {
                throw SmithersError.api(searchString(page["error"]) ?? "Smithers API error")
            }
            return try searchPageItems(from: page["data"] ?? NSNull())
        }

        for key in ["items", "data", "results"] {
            if let items = page[key] as? [[String: Any]] {
                return items
            }
            if let nestedPage = page[key] as? [String: Any] {
                return try searchPageItems(from: nestedPage)
            }
        }

        if page["total_count"] != nil || page["totalCount"] != nil {
            return []
        }
        throw SmithersError.api("Unexpected search response format")
    }

    private static func searchID(prefix: String, raw: String?, fallback: String) -> String {
        let value = (raw?.nilIfEmpty ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\(prefix)-") {
            return value
        }
        return "\(prefix)-\(value)"
    }

    private static func searchRepositoryName(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else {
            return nil
        }
        return searchString(object["full_name"])
            ?? searchString(object["fullName"])
            ?? [searchString(object["owner"]), searchString(object["name"])]
                .compactMap { $0 }
                .joined(separator: "/")
                .nilIfEmpty
            ?? searchString(object["name"])
    }

    private static func searchTextMatches(from value: Any?) -> [(content: String, lineNumber: Int?)] {
        if let text = searchString(value) {
            return [(text, nil)]
        }
        if let strings = value as? [String] {
            return strings.compactMap { text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (text, nil)
            }
        }
        guard let values = value as? [Any] else {
            return []
        }
        return values.compactMap { value in
            if let text = searchString(value) {
                return (text, nil)
            }
            guard let object = value as? [String: Any] else {
                return nil
            }
            guard let content = searchString(object["content"])
                    ?? searchString(object["text"])
                    ?? searchString(object["line"])
                    ?? searchString(object["fragment"]) else {
                return nil
            }
            return (
                content,
                searchInt(object["line_number"]) ?? searchInt(object["lineNumber"]) ?? searchInt(object["line"])
            )
        }
    }

    private static func searchString(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let string = value as? String {
            return string.nilIfEmpty
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let double = number.doubleValue
            if double.rounded() == double {
                return String(number.int64Value)
            }
            return String(double)
        }
        return nil
    }

    private static func searchInt(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let int = value as? Int {
            return int
        }
        if let int64 = value as? Int64 {
            return Int(int64)
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
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
        guard let url = resolvedHTTPTransportURL(path: path) else {
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
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let asDouble = number.doubleValue
            if asDouble.rounded() == asDouble {
                return String(number.int64Value)
            }
            return String(asDouble)
        }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        if let int64 = value as? Int64 { return String(int64) }
        if let double = value as? Double {
            if double.rounded() == double {
                return String(Int64(double))
            }
            return String(double)
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
        guard let url = resolvedHTTPTransportURL(path: "/v1/runs/\(encodedRunId)/chat", fallbackPort: port) else {
            throw SmithersError.api("Invalid server URL while loading run chat")
        }
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
            return deduplicatedChatBlocks(direct)
        }
        if let wrapped = try? decoder.decode(ChatBlocksResponse.self, from: data) {
            return deduplicatedChatBlocks(wrapped.blocks)
        }
        if let envelope = try? decoder.decode(APIEnvelope<[ChatBlock]>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return deduplicatedChatBlocks(payload)
        }
        if let envelope = try? decoder.decode(DataEnvelope<[ChatBlock]>.self, from: data) {
            return deduplicatedChatBlocks(envelope.data)
        }
        if let lineMap = try? decoder.decode([String: String].self, from: data) {
            let parsed = parseLegacyChatMap(lineMap)
            if !parsed.isEmpty {
                return deduplicatedChatBlocks(parsed)
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
        guard let url = resolvedHTTPTransportURL(path: "/v1/runs/\(encodedRunId)/hijack", fallbackPort: port) else {
            throw SmithersError.api("Invalid server URL while hijacking run")
        }
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

    private func emptySSEStream() -> AsyncStream<SSEEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    private func sseStream(url: URL, runId: String?) -> AsyncStream<SSEEvent> {
        return sseStream(urls: [url], runId: runId)
    }

    private func sseStream(urls: [URL], runId: String?) -> AsyncStream<SSEEvent> {
        return AsyncStream { continuation in
            let task = Task.detached { [streamSession] in
                guard !urls.isEmpty else {
                    continuation.finish()
                    return
                }

                for (index, url) in urls.enumerated() {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: url)
                    request.timeoutInterval = .infinity
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                    do {
                        let (bytes, response) = try await streamSession.bytes(for: request)
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
                                    if let event = SSEEvent.filtered(event: eventType, data: dataBuffer, expectedRunId: runId) {
                                        continuation.yield(event)
                                    }
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
                            if let event = SSEEvent.filtered(event: eventType, data: dataBuffer, expectedRunId: runId) {
                                continuation.yield(event)
                            }
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
private struct SnapshotRef {
    let runId: String
    let frameNo: Int
    let rawValue: String
}

private struct WorkflowPathResponse: Decodable {
    let path: String
}

private struct CLIInspectWorkflowResponse: Decodable {
    let run: Run

    struct Run: Decodable {
        let workflow: String?
    }
}

private struct ForkRunResponse: Decodable {
    let forkedRunId: String
    let parentRunId: String?
    let parentFrame: Int?
    let started: Bool?
    let status: String?

    func toRunSummary(workflowPath: String?) -> RunSummary {
        RunSummary(
            runId: forkedRunId,
            workflowName: nil,
            workflowPath: workflowPath,
            status: RunStatus(rawValue: status ?? "") ?? .running,
            startedAtMs: nil,
            finishedAtMs: nil,
            summary: nil,
            errorJson: nil
        )
    }
}

private struct CLIRunEntry: Decodable {
    let id: String
    let workflow: String?
    let status: String
    let step: String?
    let started: String?
    let startedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case workflow
        case status
        case step
        case started
        case startedAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.workflow = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .workflow))
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? RunStatus.running.rawValue
        self.step = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .step))
        self.started = try container.decodeIfPresent(String.self, forKey: .started)
        self.startedAtMs = decodeCLIInt64(container, forKey: .startedAtMs)
            ?? parseCLITimestampMs(started)
    }

    func toRunSummary() -> RunSummary {
        RunSummary(
            runId: id,
            workflowName: workflow,
            workflowPath: nil,
            status: normalizeCLIRunStatus(status),
            startedAtMs: startedAtMs,
            finishedAtMs: nil,
            summary: nil,
            errorJson: nil
        )
    }
}

private struct CLIRunsResponse: Decodable {
    let runs: [CLIRunEntry]
}

private struct CLIInspectResponse: Decodable {
    let run: CLIInspectRun
    let steps: [CLIInspectStep]

    enum CodingKeys: String, CodingKey {
        case run
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.run = try container.decode(CLIInspectRun.self, forKey: .run)
        self.steps = try container.decodeIfPresent([CLIInspectStep].self, forKey: .steps) ?? []
    }

    func toRunInspection() -> RunInspection {
        let tasks = steps.map { $0.toRunTask() }
        return RunInspection(run: run.toRunSummary(tasks: tasks), tasks: tasks)
    }
}

private struct CLIInspectRun: Decodable {
    let id: String
    let workflow: String?
    let workflowPath: String?
    let status: String
    let startedAtMs: Int64?
    let finishedAtMs: Int64?
    let errorJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId
        case workflow
        case workflowName
        case workflowPath
        case status
        case started
        case startedAtMs
        case finished
        case finishedAtMs
        case error
        case errorJson
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idValue = try container.decodeIfPresent(String.self, forKey: .id)
        let runIdValue = try container.decodeIfPresent(String.self, forKey: .runId)
        guard let id = idValue ?? runIdValue else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected inspect run id")
            )
        }

        self.id = id
        let workflow = try container.decodeIfPresent(String.self, forKey: .workflow)
        let workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        self.workflow = normalizeCLIString(workflow ?? workflowName)
        self.workflowPath = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .workflowPath))
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? RunStatus.running.rawValue
        let started = try container.decodeIfPresent(String.self, forKey: .started)
        let finished = try container.decodeIfPresent(String.self, forKey: .finished)
        self.startedAtMs = decodeCLIInt64(container, forKey: .startedAtMs)
            ?? parseCLITimestampMs(started)
        self.finishedAtMs = decodeCLIInt64(container, forKey: .finishedAtMs)
            ?? parseCLITimestampMs(finished)
        let errorJson = try container.decodeIfPresent(String.self, forKey: .errorJson)
        let error = try container.decodeIfPresent(CLIJSONValue.self, forKey: .error)
        self.errorJson = errorJson ?? encodeCLIJSON(error)
    }

    func toRunSummary(tasks: [RunTask]) -> RunSummary {
        RunSummary(
            runId: id,
            workflowName: workflow,
            workflowPath: workflowPath,
            status: normalizeCLIRunStatus(status),
            startedAtMs: startedAtMs,
            finishedAtMs: finishedAtMs,
            summary: makeRunTaskSummary(tasks),
            errorJson: errorJson
        )
    }
}

private struct CLIInspectStep: Decodable {
    let id: String
    let label: String?
    let iteration: Int?
    let state: String
    let attempt: Int?
    let updatedAtMs: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case nodeId
        case label
        case iteration
        case state
        case attempt
        case lastAttempt
        case updatedAt
        case updatedAtMs
        case startedAtMs
        case finishedAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idValue = try container.decodeIfPresent(String.self, forKey: .id)
        let nodeIdValue = try container.decodeIfPresent(String.self, forKey: .nodeId)
        guard let id = idValue ?? nodeIdValue else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected inspect step id")
            )
        }

        self.id = id
        self.label = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .label))
        self.iteration = decodeCLIInt(container, forKey: .iteration)
        self.state = normalizeCLIInspectStepState(try container.decodeIfPresent(String.self, forKey: .state) ?? "pending")
        self.attempt = decodeCLIInt(container, forKey: .attempt)
            ?? decodeCLIInt(container, forKey: .lastAttempt)
        let updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        self.updatedAtMs = decodeCLIInt64(container, forKey: .updatedAtMs)
            ?? parseCLITimestampMs(updatedAt)
            ?? decodeCLIInt64(container, forKey: .finishedAtMs)
            ?? decodeCLIInt64(container, forKey: .startedAtMs)
    }

    func toRunTask() -> RunTask {
        RunTask(
            nodeId: id,
            label: label,
            iteration: iteration,
            state: state,
            lastAttempt: attempt,
            updatedAtMs: updatedAtMs
        )
    }
}

private enum CLIJSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: CLIJSONValue])
    case array([CLIJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CLIJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CLIJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

private func normalizeCLIString(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        return nil
    }
    return trimmed == "—" || trimmed == "-" ? nil : trimmed
}

private func parseCLITimestampMs(_ value: String?) -> Int64? {
    guard let raw = normalizeCLIString(value) else { return nil }
    if let ms = Int64(raw) {
        return ms
    }

    let fractionalFormatter = ISO8601DateFormatter()
    fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractionalFormatter.date(from: raw) {
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: raw) {
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    return nil
}

private func normalizeCLIRunStatus(_ status: String?) -> RunStatus {
    switch status {
    case RunStatus.waitingApproval.rawValue:
        return .waitingApproval
    case RunStatus.finished.rawValue:
        return .finished
    case RunStatus.failed.rawValue:
        return .failed
    case RunStatus.cancelled.rawValue:
        return .cancelled
    default:
        return .running
    }
}

private func normalizeCLIInspectStepState(_ state: String) -> String {
    switch state {
    case "in-progress", "started":
        return "running"
    default:
        return state
    }
}

private func makeRunTaskSummary(_ tasks: [RunTask]) -> [String: Int] {
    var summary = ["total": tasks.count]
    for task in tasks {
        summary[task.state, default: 0] += 1
    }
    return summary
}

private func decodeCLIInt<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return Int(value)
    }
    return nil
}

private func decodeCLIInt64<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int64? {
    if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return Int64(value)
    }
    return nil
}

private func encodeCLIJSON(_ value: CLIJSONValue?) -> String? {
    guard let value else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}

private struct MemoryResponse: Decodable { let facts: [MemoryFact] }
private struct RecallResponse: Decodable { let results: [MemoryRecallResult] }
private struct ScoresResponse: Decodable { let scores: [ScoreRow] }
private struct LandingListResponse: Decodable {
    let landings: [Landing]?
    let items: [Landing]?
}
private struct LandingDetailResponse: Decodable {
    let landing: Landing
    let changes: [LandingChangeResponse]?
}
private struct LandingChangeResponse: Decodable {
    let changeID: String

    enum CodingKeys: String, CodingKey {
        case changeID
        case changeIDSnake = "change_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changeID = try container.decodeIfPresent(String.self, forKey: .changeIDSnake) ??
            container.decode(String.self, forKey: .changeID)
    }
}
private struct IssueResponse: Decodable { let issue: SmithersIssue }
private struct IssueListResponse: Decodable {
    let issues: [SmithersIssue]?
    let items: [SmithersIssue]?
}
private struct WorkspacesResponse: Decodable { let workspaces: [Workspace] }
private struct WorkspaceSnapshotsResponse: Decodable { let snapshots: [WorkspaceSnapshot] }
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
