import Foundation
import Darwin

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

private final class ProcessCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func setProcess(_ process: Process) {
        lock.lock()
        let shouldTerminate = cancelled
        if !shouldTerminate {
            self.process = process
        }
        lock.unlock()

        if shouldTerminate {
            terminate(process)
        }
    }

    func clearProcess(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()

        if let process {
            terminate(process)
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

enum SmithersMemoryCLI {
    static let defaultNamespace = "global:default"

    static func normalizedNamespace(_ namespace: String?) -> String? {
        guard let namespace = namespace?.trimmingCharacters(in: .whitespacesAndNewlines),
              !namespace.isEmpty else {
            return nil
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
        var args = ["memory", "list", "--format", "json"]
        if let namespace = normalizedNamespace(namespace) {
            args += ["--namespace", namespace]
        }
        if let workflowPath = normalizedWorkflowPath(workflowPath) {
            args += ["--workflow", workflowPath]
        }
        return args
    }

    static func listAllArgs(namespace: String? = nil, workflowPath: String? = nil) -> [String] {
        listArgs(namespace: namespace, workflowPath: workflowPath)
    }

    static func legacyListArgs(namespace: String, workflowPath: String? = nil) -> [String] {
        var args = ["memory", "list", namespace, "--format", "json"]
        if let workflowPath = normalizedWorkflowPath(workflowPath) {
            args += ["--workflow", workflowPath]
        }
        return args
    }

    static func recallArgs(query: String, namespace: String? = nil, workflowPath: String? = nil, topK: Int = 10) -> [String] {
        var args = ["memory", "recall", query, "--format", "json"]
        if let namespace = normalizedNamespace(namespace) {
            args += ["--namespace", namespace]
        }
        if topK > 0 {
            args += ["--top-k", "\(topK)"]
        }
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

    // Try extracting just the first balanced JSON value (handles CLI output
    // that appends non-JSON text such as TOON after the JSON object).
    if let firstJSON = cliFirstBalancedJSON(from: data),
       let firstJSONString = String(data: firstJSON, encoding: .utf8) {
        append(firstJSONString)
    }

    append(trimmed)
    for index in trimmed.indices where trimmed[index] == "{" || trimmed[index] == "[" {
        append(String(trimmed[index...]))
    }
    return candidates
}

/// Extracts the first balanced JSON object or array from data that may contain
/// trailing non-JSON content (e.g. TOON output appended by the CLI).
private func cliFirstBalancedJSON(from data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard let start = bytes.firstIndex(where: { $0 == 0x7B || $0 == 0x5B }) else {
        return nil
    }
    let open = bytes[start]
    let close: UInt8 = open == 0x7B ? 0x7D : 0x5D
    var depth = 0
    var inString = false
    var escaped = false
    for index in start..<bytes.count {
        let byte = bytes[index]
        if inString {
            if escaped { escaped = false }
            else if byte == 0x5C { escaped = true }
            else if byte == 0x22 { inString = false }
            continue
        }
        if byte == 0x22 { inString = true }
        else if byte == open { depth += 1 }
        else if byte == close {
            depth -= 1
            if depth == 0 {
                return data.subdata(in: start..<(index + 1))
            }
        }
    }
    return nil
}

/// Client for Smithers — uses the `smithers` CLI as primary transport (like the TUI),
/// with optional HTTP fallback when a workflow is running with `--serve`.
@MainActor
class SmithersClient: ObservableObject {
    enum ConnectionTransport: String {
        case none
        case cli
        case http
    }

    @Published var isConnected: Bool = false
    @Published var cliAvailable: Bool = false
    @Published private(set) var orchestratorVersion: String?
    /// `nil` until probed; `true` once a version >= `minimumOrchestratorVersion`
    /// is observed; `false` when the installed CLI is too old.
    @Published private(set) var orchestratorVersionMeetsMinimum: Bool?
    private var cachedOrchestratorVersion: String?
    @Published private(set) var connectionTransport: ConnectionTransport = .none
    @Published private(set) var serverReachable: Bool = false

    /// Minimum supported `smithers-orchestrator` version. Older releases
    /// silently mislabel orphaned heartbeats as "continued"/"succeeded" and
    /// lack the `state`/`unhealthy` fields the dashboard now expects.
    static let minimumOrchestratorVersion = "0.16.0"

    private let cwd: String
    private let smithersBin: String
    private let jjhubBin: String
    private let codexHomeOverride: String?
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
    private var uiNodeOutputFetchCounts: [String: Int] = [:]
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
    private nonisolated static let allRunsStreamRunId = "all-runs"
    nonisolated static let defaultHTTPTransportPort = 7331
    private static let costPerMInputTokens = 3.0
    private static let costPerMOutputTokens = 15.0

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

    init(
        cwd: String? = nil,
        smithersBin: String = "smithers",
        jjhubBin: String = "jjhub",
        codexHome: String? = nil
    ) {
        let trimmedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCwd = (trimmedCwd?.isEmpty == false) ? trimmedCwd : nil
        let workingDir = CWDResolver.resolve(resolvedCwd)
        self.cwd = workingDir
        // Prefer a project-local CLI (e.g. .smithers/node_modules/.bin/smithers)
        // so the GUI uses the same build the project's workflows depend on,
        // rather than whatever stale `smithers` happens to be on $PATH.
        self.smithersBin = Self.resolveProjectBinary(name: smithersBin, cwd: workingDir)
        self.jjhubBin = Self.resolveProjectBinary(name: jjhubBin, cwd: workingDir)
        self.codexHomeOverride = codexHome
        self.decoder = JSONDecoder()
        self.session = URLSession(configuration: Self.makeHTTPURLSessionConfiguration())
        self.streamSession = URLSession(configuration: Self.makeSSEURLSessionConfiguration())
    }

    nonisolated static func resolvedHTTPTransportURL(
        path: String,
        serverURL: String?,
        fallbackPort: Int? = SmithersClient.defaultHTTPTransportPort
    ) -> URL? {
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

    private nonisolated static var pathComponentAllowedCharacters: CharacterSet {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }

    private nonisolated static func encodedURLPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: pathComponentAllowedCharacters) ?? value
    }

    func resolvedHTTPTransportURL(
        path: String,
        fallbackPort: Int? = SmithersClient.defaultHTTPTransportPort
    ) -> URL? {
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

    private static func makeUINodeDiffBundle(nodeId: String, iteration: Int) -> NodeDiffBundle {
        let safeNodeId = nodeId.replacingOccurrences(of: ":", with: "-")
        let pathPrefix = "fixtures/\(safeNodeId)-\(max(0, iteration))"
        return NodeDiffBundle(
            seq: max(1, iteration + 1),
            baseRef: "ui-base-\(safeNodeId)",
            patches: [
                NodeDiffPatch(
                    path: "\(pathPrefix).swift",
                    oldPath: nil,
                    operation: .modify,
                    diff: """
                    @@ -1,4 +1,6 @@
                     struct Example {
                    -    let status = "pending"
                    +    let status = "running"
                    +    let attempt = \(max(0, iteration))
                     }
                    """,
                    binaryContent: nil
                ),
                NodeDiffPatch(
                    path: "\(pathPrefix).md",
                    oldPath: nil,
                    operation: .add,
                    diff: """
                    @@ -0,0 +1,3 @@
                    +# Diff Fixture
                    +nodeId: \(nodeId)
                    +iteration: \(max(0, iteration))
                    """,
                    binaryContent: nil
                ),
                NodeDiffPatch(
                    path: "assets/\(safeNodeId)-image.png",
                    oldPath: nil,
                    operation: .modify,
                    diff: "",
                    binaryContent: "aGVsbG8="
                ),
            ]
        )
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

    private nonisolated static func makeOperationID(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8))"
    }

    private nonisolated static func commandSummary(displayName: String, args: [String]) -> String {
        let visibleArgLimit = 4
        let renderedArgs = args.prefix(visibleArgLimit).enumerated().map { index, arg in
            sanitizedCommandArgument(arg, at: index, in: args, displayName: displayName)
        }
        let suffix = args.count > visibleArgLimit ? " ..." : ""
        return ([displayName] + renderedArgs).joined(separator: " ") + suffix
    }

    private nonisolated static func sanitizedCommandArgument(
        _ arg: String,
        at index: Int,
        in args: [String],
        displayName: String
    ) -> String {
        if shouldRedactCommandArgument(arg, at: index, in: args, displayName: displayName) {
            return "[redacted]"
        }

        let normalized = arg
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        guard normalized.count > 96 else { return normalized }
        return "\(String(normalized.prefix(96)))...(truncated)"
    }

    private nonisolated static func shouldRedactCommandArgument(
        _ arg: String,
        at index: Int,
        in args: [String],
        displayName: String
    ) -> Bool {
        let lower = arg.lowercased()
        let sensitiveFlags = [
            "--api-key",
            "--api_key",
            "--authorization",
            "--password",
            "--secret",
            "--token",
        ]

        if lower.contains("api_key=") ||
            lower.contains("apikey=") ||
            lower.contains("authorization=") ||
            lower.contains("password=") ||
            lower.contains("secret=") ||
            lower.contains("token=") {
            return true
        }

        if index > 0, sensitiveFlags.contains(args[index - 1].lowercased()) {
            return true
        }

        if displayName == "sqlite3", index >= 2 {
            return true
        }

        if args.count > 2,
           args[0].lowercased() == "memory",
           args[1].lowercased() == "recall",
           index == 2 {
            return true
        }

        return false
    }

    private nonisolated static func waitForProcessExit(_ process: Process, timeoutSeconds: Double) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !process.isRunning
    }

    private nonisolated static func terminateProcess(_ process: Process) async {
        guard process.isRunning else { return }

        process.terminate()
        if await waitForProcessExit(process, timeoutSeconds: 0.5) { return }

        if process.isRunning {
            process.interrupt()
        }
        if await waitForProcessExit(process, timeoutSeconds: 0.5) { return }

        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        _ = await waitForProcessExit(process, timeoutSeconds: 0.5)
    }

    private func exec(_ args: String...) async throws -> Data {
        try await execArgs(args)
    }

    private func execArgs(_ args: [String]) async throws -> Data {
        try await execBinaryArgs(bin: smithersBin, args: args, displayName: "smithers")
    }

    private func execBinaryArgs(bin: String, args: [String], displayName: String, timeoutSeconds: Double = 30, workingDirectoryOverride: String? = nil) async throws -> Data {
        let cwd = workingDirectoryOverride ?? self.cwd
        let cancellationBox = ProcessCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task.detached { [cwd, bin, args, displayName, timeoutSeconds, cancellationBox] in
                    let operationID = Self.makeOperationID(prefix: "cli")
                    let startTime = CFAbsoluteTimeGetCurrent()
                    let cmdSummary = Self.commandSummary(displayName: displayName, args: args)
                    func commandMetadata(_ extra: [String: String] = [:]) -> [String: String] {
                        var metadata = [
                            "operation_id": operationID,
                            "bin": displayName,
                            "cwd": cwd,
                            "arg_count": String(args.count),
                        ]
                        for (key, value) in extra {
                            metadata[key] = value
                        }
                        return metadata
                    }

                    AppLogger.network.debug("CLI start: \(cmdSummary)", metadata: commandMetadata([
                        "timeout_s": String(Int(timeoutSeconds))
                    ]))

                    let process = Process()
                    cancellationBox.setProcess(process)
                    defer { cancellationBox.clearProcess(process) }

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
                        try Task.checkCancellation()
                        if cancellationBox.isCancelled {
                            throw CancellationError()
                        }

                        try process.run()

                        // Wait with timeout to prevent hanging on CLI commands that stream indefinitely
                        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
                        while process.isRunning && Date() < deadline {
                            if Task.isCancelled || cancellationBox.isCancelled {
                                await Self.terminateProcess(process)
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }

                        if Task.isCancelled || cancellationBox.isCancelled {
                            if process.isRunning {
                                await Self.terminateProcess(process)
                            }
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        if process.isRunning {
                            await Self.terminateProcess(process)
                            outPipe.fileHandleForReading.readabilityHandler = nil
                            errPipe.fileHandleForReading.readabilityHandler = nil
                            let durationMs = String(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
                            AppLogger.network.error("CLI timeout: \(cmdSummary)", metadata: commandMetadata([
                                "timeout_s": String(Int(timeoutSeconds)),
                                "duration_ms": durationMs
                            ]))
                            continuation.resume(throwing: SmithersError.cli("Command timed out after \(Int(timeoutSeconds))s: \(cmdSummary)"))
                            return
                        }

                        outPipe.fileHandleForReading.readabilityHandler = nil
                        errPipe.fileHandleForReading.readabilityHandler = nil
                        stdoutCollector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                        stderrCollector.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                        let stdout = stdoutCollector.snapshot()
                        let stderr = stderrCollector.snapshot()

                        let durationMs = String(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))

                        if process.terminationStatus != 0 {
                            let message = Self.parseCLIErrorMessage(
                                stdout: stdout,
                                stderr: stderr,
                                exitCode: process.terminationStatus
                            )
                            AppLogger.network.error("CLI failed: \(cmdSummary)", metadata: commandMetadata([
                                "exit_code": String(process.terminationStatus),
                                "duration_ms": durationMs,
                                "stdout_bytes": String(stdout.count),
                                "stderr_bytes": String(stderr.count),
                                "stderr": String(data: stderr.prefix(500), encoding: .utf8) ?? ""
                            ]))
                            continuation.resume(throwing: SmithersError.cli(message))
                        } else {
                            AppLogger.network.debug("CLI ok: \(cmdSummary)", metadata: commandMetadata([
                                "duration_ms": durationMs,
                                "bytes": String(stdout.count)
                            ]))
                            continuation.resume(returning: stdout)
                        }
                    } catch is CancellationError {
                        if process.isRunning {
                            await Self.terminateProcess(process)
                        }
                        continuation.resume(throwing: CancellationError())
                    } catch {
                        let durationMs = String(Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000))
                        AppLogger.error.error("CLI exception: \(cmdSummary)", metadata: commandMetadata([
                            "error": error.localizedDescription,
                            "duration_ms": durationMs
                        ]))
                        continuation.resume(throwing: SmithersError.cli("Failed to run \(displayName): \(error.localizedDescription)"))
                    }
                }
            }
        } onCancel: {
            cancellationBox.cancel()
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
        struct WorkflowResponse: Decodable {
            let workflows: [Workflow]
        }
        struct DiscoveredWorkflow: Decodable {
            let id: String
            let displayName: String?
            let entryFile: String?
            let relativePath: String?
            let path: String?
            let workflowPath: String?
            let sourceType: String?

            enum CodingKeys: String, CodingKey {
                case id, displayName, entryFile, relativePath, path, workflowPath, sourceType
                case workflowPathSnake = "workflow_path"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
                entryFile = try container.decodeIfPresent(String.self, forKey: .entryFile)
                relativePath = try container.decodeIfPresent(String.self, forKey: .relativePath)
                path = try container.decodeIfPresent(String.self, forKey: .path)
                let workflowPathCamel = try container.decodeIfPresent(String.self, forKey: .workflowPath)
                let workflowPathSnake = try container.decodeIfPresent(String.self, forKey: .workflowPathSnake)
                workflowPath = workflowPathCamel ?? workflowPathSnake
                sourceType = try container.decodeIfPresent(String.self, forKey: .sourceType)
            }

            var resolvedDisplayName: String {
                let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? id : trimmed
            }

            var resolvedEntryFile: String? {
                normalizedPath(entryFile)
                    ?? normalizedPath(relativePath)
                    ?? normalizedPath(path)
                    ?? normalizedPath(workflowPath)
            }

            private func normalizedPath(_ value: String?) -> String? {
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }

        let data = try await exec("workflow", "list", "--format", "json")

        // Try wrapped format first, then bare array
        if let response = try? decoder.decode(Response.self, from: data) {
            return response.workflows.map {
                adaptWorkflow(id: $0.id, displayName: $0.resolvedDisplayName, entryFile: $0.resolvedEntryFile)
            }
        }
        if let bare = try? decoder.decode([DiscoveredWorkflow].self, from: data) {
            return bare.map {
                adaptWorkflow(id: $0.id, displayName: $0.resolvedDisplayName, entryFile: $0.resolvedEntryFile)
            }
        }
        if let response = try? decoder.decode(WorkflowResponse.self, from: data) {
            return response.workflows
        }
        return try decoder.decode([Workflow].self, from: data)
    }

    private func adaptWorkflow(id: String, displayName: String, entryFile: String?) -> Workflow {
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
        guard let workflowPath = workflow.filePath else {
            throw SmithersError.api("Workflow \(workflow.id) is missing an entry file path")
        }
        return try normalizedWorkflowPath(workflowPath)
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

        // Prefer workflow graph on newer CLIs; fall back to legacy top-level graph command.
        let data: Data
        do {
            data = try await exec("workflow", "graph", workflowPath, "--format", "json")
        } catch {
            data = try await exec("graph", workflowPath, "--format", "json")
        }
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

    // MARK: - Quick Launch

    struct QuickLaunchResult {
        let inputs: [String: JSONValue]
        let notes: String
        let parseRunId: String
    }

    /// Kicks off the `quick-launch` workflow to turn a natural-language prompt into a
    /// `[String: JSONValue]` input dictionary for `target`. Polls the run log until the
    /// parse task finishes and returns the structured result.
    func runQuickLaunchParser(
        target: Workflow,
        prompt: String,
        timeoutSeconds: Double = 90
    ) async throws -> QuickLaunchResult {
        let dag = try await getWorkflowDAG(target)
        let fields = dag.launchFields
        let schemaJSON = Self.encodeQuickLaunchSchema(fields)

        let quickLaunchPath = (cwd as NSString).appendingPathComponent(".smithers/workflows/quick-launch.tsx")
        let launch = try await runWorkflow(workflowPath: quickLaunchPath, inputs: [
            "target": .string(target.name),
            "prompt": .string(prompt),
            "schema": .string(schemaJSON),
        ])
        let parseRunId = launch.runId

        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            let inspection = try await inspectRun(parseRunId)
            switch inspection.run.status {
            case .finished:
                let (inputs, notes) = try Self.readQuickLaunchOutput(runId: parseRunId, cwd: cwd)
                return QuickLaunchResult(inputs: inputs, notes: notes, parseRunId: parseRunId)
            case .failed, .cancelled:
                throw SmithersError.api("quick-launch parser run \(parseRunId) \(inspection.run.status.rawValue)")
            default:
                try await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        throw SmithersError.api("quick-launch parser run \(parseRunId) timed out after \(Int(timeoutSeconds))s")
    }

    private static func encodeQuickLaunchSchema(_ fields: [WorkflowLaunchField]) -> String {
        let arr: [[String: JSONValue]] = fields.map { field in
            var obj: [String: JSONValue] = [
                "key": .string(field.key),
                "name": .string(field.name),
                "required": .bool(field.required),
            ]
            if let type = field.type { obj["type"] = .string(type) }
            if let def = field.defaultValue { obj["default"] = .string(def) }
            return obj
        }
        return JSONValue.array(arr.map { .object($0) }).compactJSONString ?? "[]"
    }

    private static func readQuickLaunchOutput(
        runId: String,
        cwd: String
    ) throws -> (inputs: [String: JSONValue], notes: String) {
        let logPath = (cwd as NSString)
            .appendingPathComponent(".smithers/executions/\(runId)/logs/stream.ndjson")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
              let contents = String(data: data, encoding: .utf8) else {
            throw SmithersError.api("quick-launch log not found at \(logPath)")
        }

        var lastStdoutText: String?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            guard (obj["type"] as? String) == "NodeOutput",
                  (obj["nodeId"] as? String) == "parse",
                  (obj["stream"] as? String) == "stdout",
                  let text = obj["text"] as? String else { continue }
            lastStdoutText = text
        }

        guard let rawText = lastStdoutText else {
            throw SmithersError.api("quick-launch parse produced no output for run \(runId)")
        }

        let jsonText = Self.extractJSONObject(from: rawText) ?? rawText
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any] else {
            throw SmithersError.api("quick-launch output was not valid JSON: \(rawText.prefix(200))")
        }

        let inputsAny = (parsed["inputs"] as? [String: Any]) ?? [:]
        var inputs: [String: JSONValue] = [:]
        for (k, v) in inputsAny {
            inputs[k] = Self.jsonValue(from: v)
        }
        let notes = (parsed["notes"] as? String) ?? ""
        return (inputs, notes)
    }

    private static func extractJSONObject(from raw: String) -> String? {
        // Strip markdown fences and find the first {...} balanced block.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = trimmed
        if candidate.hasPrefix("```") {
            if let fenceEnd = candidate.range(of: "\n") {
                candidate = String(candidate[fenceEnd.upperBound...])
            }
            if let closing = candidate.range(of: "```", options: .backwards) {
                candidate = String(candidate[..<closing.lowerBound])
            }
        }
        guard let start = candidate.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < candidate.endIndex {
            let ch = candidate[idx]
            if escape { escape = false }
            else if ch == "\\" && inString { escape = true }
            else if ch == "\"" { inString.toggle() }
            else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(candidate[start...idx])
                    }
                }
            }
            idx = candidate.index(after: idx)
        }
        return nil
    }

    private static func jsonValue(from any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber {
            // Disambiguate Bool-as-NSNumber already handled above.
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] { return .array(arr.map { jsonValue(from: $0) }) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = jsonValue(from: v) }
            return .object(out)
        }
        return .null
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

        // If init resolved to an absolute path via node_modules/.bin, use it.
        if smithersBin.hasPrefix("/") {
            return smithersBin
        }

        let data = try await execBinaryArgs(bin: "which", args: [smithersBin], displayName: "which")
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw SmithersError.cli("smithers binary not found on PATH")
        }
        return path
    }

    /// Resolve a CLI name to a project-local node_modules/.bin path when available,
    /// falling back to the bare name so $PATH resolution still applies.
    ///
    /// Precedence:
    ///   1. `<cwd>/.smithers/node_modules/.bin/<name>`
    ///   2. `<cwd>/node_modules/.bin/<name>`, walking up toward the filesystem root
    ///   3. `<name>` (unchanged — resolved via $PATH at exec time)
    static func resolveProjectBinary(name: String, cwd: String) -> String {
        // Respect absolute or explicit paths from the caller.
        if name.contains("/") { return name }

        let fm = FileManager.default
        let smithersLocal = (cwd as NSString).appendingPathComponent(".smithers/node_modules/.bin/\(name)")
        if fm.isExecutableFile(atPath: smithersLocal) {
            return smithersLocal
        }

        var dir = cwd
        while !dir.isEmpty, dir != "/" {
            let candidate = (dir as NSString).appendingPathComponent("node_modules/.bin/\(name)")
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }

        return name
    }

    // MARK: - Workflow Source (filesystem)

    /// Resolve and validate a path under .smithers/ (workflows, components, prompts).
    private func smithersFilePath(_ relativePath: String) throws -> String {
        let smithersDir = (cwd as NSString).appendingPathComponent(".smithers")
        let resolvedDir = (smithersDir as NSString).resolvingSymlinksInPath
        // Handle absolute paths that are already under the smithers directory
        let full: String
        if relativePath.hasPrefix("/") {
            full = relativePath
        } else {
            full = (cwd as NSString).appendingPathComponent(relativePath)
        }
        let resolvedPath = (full as NSString).resolvingSymlinksInPath
        guard resolvedPath.hasPrefix(resolvedDir + "/") else {
            throw SmithersError.api("Invalid path: must be under .smithers/")
        }
        return resolvedPath
    }

    func localSmithersFilePath(_ relativePath: String) throws -> String {
        try smithersFilePath(relativePath)
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
        do {
            return try decoder.decode(RunInspection.self, from: data)
        } catch {
            if let envelope = try? decoder.decode(APIEnvelope<RunInspection>.self, from: data),
               let inspection = envelope.data {
                return inspection
            }
            if let envelope = try? decoder.decode(DataEnvelope<RunInspection>.self, from: data) {
                return envelope.data
            }
            throw error
        }
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

    nonisolated static func hijackRunCLIArgs(runId: String) -> [String] {
        ["hijack", runId, "--launch=false", "--format", "json"]
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
            let approvalID = iteration.map { "\(runId):\(nodeId):\($0)" } ?? "\(runId):\(nodeId)"
            let decisionSuffix = iteration.map { "-\($0)" } ?? ""
            uiResolvedApprovalIDs.insert(approvalID)
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)\(decisionSuffix)-approved", runId: runId, nodeId: nodeId, iteration: iteration, action: "approved", note: note, reason: nil, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        let normalizedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedRunId = Self.encodedURLPathComponent(runId)
        let encodedNodeId = Self.encodedURLPathComponent(nodeId)
        var requestPayload: [String: Any] = ["note": normalizedNote ?? ""]
        if let iteration {
            requestPayload["iteration"] = iteration
        }

        if resolvedHTTPTransportURL(path: "/v1/runs/\(encodedRunId)/nodes/\(encodedNodeId)/approve") != nil,
           let body = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) {
            if let _ = try? await httpRequestRaw(
                method: "POST",
                path: "/v1/runs/\(encodedRunId)/nodes/\(encodedNodeId)/approve",
                jsonBody: body
            ) {
                return
            }
        }

        var args = Self.approveNodeCLIArgs(
            runId: runId,
            nodeId: nodeId,
            iteration: iteration,
            note: normalizedNote?.nilIfEmpty ?? nil
        )
        args += ["--format", "json"]
        _ = try await execArgs(args)
    }

    func denyNode(runId: String, nodeId: String, iteration: Int? = nil, reason: String? = nil) async throws {
        if UITestSupport.isEnabled {
            let approvalID = iteration.map { "\(runId):\(nodeId):\($0)" } ?? "\(runId):\(nodeId)"
            let decisionSuffix = iteration.map { "-\($0)" } ?? ""
            uiResolvedApprovalIDs.insert(approvalID)
            uiApprovalDecisions.insert(
                ApprovalDecision(id: "decision-\(runId)-\(nodeId)\(decisionSuffix)-denied", runId: runId, nodeId: nodeId, iteration: iteration, action: "denied", note: nil, reason: reason, resolvedAt: UITestSupport.nowMs, resolvedBy: "ui-test"),
                at: 0
            )
            return
        }

        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let encodedRunId = Self.encodedURLPathComponent(runId)
        let encodedNodeId = Self.encodedURLPathComponent(nodeId)
        var requestPayload: [String: Any] = ["reason": normalizedReason ?? ""]
        if let iteration {
            requestPayload["iteration"] = iteration
        }

        if resolvedHTTPTransportURL(path: "/v1/runs/\(encodedRunId)/nodes/\(encodedNodeId)/deny") != nil,
           let body = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) {
            if let _ = try? await httpRequestRaw(
                method: "POST",
                path: "/v1/runs/\(encodedRunId)/nodes/\(encodedNodeId)/deny",
                jsonBody: body
            ) {
                return
            }
        }

        var args = Self.denyNodeCLIArgs(
            runId: runId,
            nodeId: nodeId,
            iteration: iteration,
            reason: normalizedReason?.nilIfEmpty ?? nil
        )
        args += ["--format", "json"]
        _ = try await execArgs(args)
    }

    // MARK: - DevTools Stream (CLI + sqlite3 — primary path)

    /// Streams DevTools snapshots derived from `smithers events <runId> --watch --json`
    /// plus snapshots synthesized from the `_smithers_frames` sqlite table. An initial
    /// snapshot is emitted immediately; every frame-related event re-snapshots so the
    /// gui tree stays in sync without requiring a running `smithers --serve` server.
    func streamDevTools(runId: String, fromSeq: Int? = nil) -> AsyncThrowingStream<DevToolsEvent, Error> {
        do {
            try DevToolsInputValidator.validate(runId: runId)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }

        let smithersBin = self.smithersBin
        let cwd = self.cwd
        let dbPath = resolvedSmithersDBPath()

        return AsyncThrowingStream { continuation in
            let cancellationBox = ProcessCancellationBox()

            continuation.onTermination = { @Sendable _ in
                cancellationBox.cancel()
            }

            Task.detached { [runId, smithersBin, cwd, dbPath] in
                AppLogger.network.info("DevTools CLI stream connect", metadata: [
                    "run_id": runId,
                    "from_seq": fromSeq.map(String.init) ?? "nil",
                ])

                // 1. Emit initial snapshot.
                if let dbPath {
                    do {
                        let snap = try await Self.loadDevToolsSnapshot(runId: runId, frameNo: nil, dbPath: dbPath)
                        continuation.yield(.snapshot(snap))
                    } catch let err as DevToolsClientError {
                        // If the run doesn't exist yet, keep going — the event stream may still be valid.
                        if case .runNotFound = err {
                            // fall through
                        } else {
                            AppLogger.error.warning("DevTools initial snapshot failed", metadata: [
                                "run_id": runId,
                                "error": err.displayMessage,
                            ])
                        }
                    } catch {
                        AppLogger.error.warning("DevTools initial snapshot failed", metadata: [
                            "run_id": runId,
                            "error": String(describing: error),
                        ])
                    }
                }

                // 2. Spawn `smithers events <runId> --watch --json` and track frame-related events.
                let process = Process()
                cancellationBox.setProcess(process)
                defer { cancellationBox.clearProcess(process) }

                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [
                    smithersBin,
                    "events",
                    runId,
                    "--watch",
                    "--json",
                    "--interval", "1",
                ]
                process.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                env["NO_COLOR"] = "1"
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try Task.checkCancellation()
                    if cancellationBox.isCancelled {
                        continuation.finish()
                        return
                    }
                    try process.run()
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch {
                    continuation.finish(throwing: DevToolsClientError.unknown("smithers events failed to start: \(error.localizedDescription)"))
                    return
                }

                // Line-buffered reader over stdout.
                let readHandle = outPipe.fileHandleForReading
                var buffer = Data()
                let decoder = JSONDecoder()
                var lastEmittedFrameNo = -1

                while !Task.isCancelled, !cancellationBox.isCancelled {
                    let chunk = readHandle.availableData
                    if chunk.isEmpty {
                        // Process exited or pipe closed.
                        if !process.isRunning { break }
                        // Give the process a short breath.
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }
                    buffer.append(chunk)

                    while let newlineRange = buffer.range(of: Data([0x0a])) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                        buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                        guard !lineData.isEmpty else { continue }

                        // Parse `{"type":..., "runId":..., "payload":..., "seq":...}`.
                        struct MinimalEvent: Decodable {
                            let runId: String?
                            let type: String?
                            let seq: Int?
                            let payload: Payload?
                            struct Payload: Decodable {
                                let frameNo: Int?
                                let nodeId: String?
                            }
                        }
                        guard let evt = try? decoder.decode(MinimalEvent.self, from: lineData) else {
                            continue
                        }
                        let type = evt.type ?? ""
                        let isFrameEvent = type == "FrameCommitted"
                            || type == "SnapshotCaptured"
                            || type == "NodeStarted"
                            || type == "NodePending"
                            || type == "NodeFinished"
                            || type == "NodeFailed"
                            || type == "NodeRetrying"

                        if isFrameEvent, let dbPath {
                            do {
                                let snap = try await Self.loadDevToolsSnapshot(runId: runId, frameNo: nil, dbPath: dbPath)
                                if snap.frameNo != lastEmittedFrameNo {
                                    lastEmittedFrameNo = snap.frameNo
                                    continuation.yield(.snapshot(snap))
                                }
                            } catch {
                                AppLogger.error.warning("DevTools re-snapshot failed", metadata: [
                                    "run_id": runId,
                                    "error": String(describing: error),
                                ])
                            }
                        }

                        if type == "RunFinished" {
                            // Emit one last snapshot and terminate.
                            if let dbPath, let snap = try? await Self.loadDevToolsSnapshot(runId: runId, frameNo: nil, dbPath: dbPath) {
                                continuation.yield(.snapshot(snap))
                            }
                            if process.isRunning {
                                process.terminate()
                            }
                            continuation.finish()
                            return
                        }
                    }
                }

                if process.isRunning {
                    process.terminate()
                }
                continuation.finish()
            }
        }
    }

    /// Fetches a DevTools snapshot directly from `smithers.db`. The XML is assembled by
    /// reading the most recent keyframe at or before `frameNo` (defaulting to the latest
    /// frame) and applying any delta frames between the keyframe and the target frame.
    func getDevToolsSnapshot(runId: String, frameNo: Int? = nil) async throws -> DevToolsSnapshot {
        try DevToolsInputValidator.validate(runId: runId)
        if let frameNo { try DevToolsInputValidator.validate(frameNo: frameNo) }

        guard let dbPath = resolvedSmithersDBPath() else {
            AppLogger.network.warning("DevTools snapshot: smithers.db not found", metadata: [
                "run_id": runId,
            ])
            throw DevToolsClientError.runNotFound(runId)
        }

        AppLogger.network.debug("DevTools snapshot request (sqlite3)", metadata: [
            "run_id": runId,
            "frame_no": frameNo.map(String.init) ?? "latest",
            "db_path": dbPath,
        ])

        return try await Self.loadDevToolsSnapshot(runId: runId, frameNo: frameNo, dbPath: dbPath)
    }

    /// Worker used by both `getDevToolsSnapshot` and the `streamDevTools` subprocess loop.
    /// Detached from the main actor so the stream reader task can use it.
    ///
    /// When `frameNo` is `nil`, the snapshot reflects the *current* per-node state
    /// from `_smithers_nodes` (live mode). When `frameNo` is provided, the snapshot
    /// reconstructs per-node state as it was *at that frame's wall-clock timestamp*
    /// by querying `_smithers_attempts` — see the historical-scrubber UX fix.
    private nonisolated static func loadDevToolsSnapshot(
        runId: String,
        frameNo: Int?,
        dbPath: String
    ) async throws -> DevToolsSnapshot {
        let quotedRunId = DevToolsSQL.quote(runId)

        // Resolve target frameNo (default to latest).
        let targetFrame: Int
        if let frameNo {
            targetFrame = frameNo
        } else {
            let query = "SELECT MAX(frame_no) AS m FROM _smithers_frames WHERE run_id=\(quotedRunId);"
            let rows = try await execSQLite(dbPath: dbPath, query: query)
            guard let firstRow = rows.first,
                  let maxFrame = intValue(from: firstRow["m"]) else {
                throw DevToolsClientError.runNotFound(runId)
            }
            targetFrame = Int(maxFrame)
        }

        // Fetch the latest keyframe at or before target (and its created_at_ms so we
        // can reconstruct per-frame state for historical mode).
        let keyframeQuery = """
        SELECT frame_no, xml_json, task_index_json, created_at_ms
        FROM _smithers_frames
        WHERE run_id=\(quotedRunId)
          AND encoding='keyframe'
          AND frame_no <= \(targetFrame)
        ORDER BY frame_no DESC
        LIMIT 1;
        """
        let keyframeRows = try await execSQLite(dbPath: dbPath, query: keyframeQuery)
        guard let keyframeRow = keyframeRows.first,
              let keyframeNo = intValue(from: keyframeRow["frame_no"]),
              let xmlText = stringValue(from: keyframeRow["xml_json"]),
              let xmlData = xmlText.data(using: .utf8) else {
            // Either the run doesn't exist or we're asking for a frame before the first keyframe.
            if targetFrame < 0 {
                throw DevToolsClientError.frameOutOfRange(targetFrame)
            }
            throw DevToolsClientError.runNotFound(runId)
        }
        let taskIndexText = stringValue(from: keyframeRow["task_index_json"]) ?? "[]"

        let decoder = JSONDecoder()
        let rootXML: DevToolsFrameXMLNode
        do {
            rootXML = try decoder.decode(DevToolsFrameXMLNode.self, from: xmlData)
        } catch {
            throw DevToolsClientError.malformedEvent("Failed to decode keyframe xml_json: \(error)")
        }

        var taskIndex: [DevToolsTaskIndexEntry] = []
        if let taskIndexData = taskIndexText.data(using: .utf8) {
            taskIndex = (try? decoder.decode([DevToolsTaskIndexEntry].self, from: taskIndexData)) ?? []
        }

        // Fetch + apply any deltas between the keyframe and target.
        var finalXML = rootXML
        if targetFrame > Int(keyframeNo) {
            let deltaQuery = """
            SELECT frame_no, xml_json FROM _smithers_frames
            WHERE run_id=\(quotedRunId)
              AND encoding='delta'
              AND frame_no > \(keyframeNo) AND frame_no <= \(targetFrame)
            ORDER BY frame_no ASC;
            """
            let deltaRows = try await execSQLite(dbPath: dbPath, query: deltaQuery)
            var decodedDeltas: [DevToolsFrameDelta] = []
            decodedDeltas.reserveCapacity(deltaRows.count)
            for row in deltaRows {
                guard let text = stringValue(from: row["xml_json"]),
                      let data = text.data(using: .utf8),
                      let delta = try? decoder.decode(DevToolsFrameDelta.self, from: data) else {
                    continue
                }
                decodedDeltas.append(delta)
            }
            if !decodedDeltas.isEmpty {
                finalXML = (try? DevToolsFrameApplier.apply(deltas: decodedDeltas, toKeyframe: rootXML)) ?? rootXML
            }
        }

        // Resolve the wall-clock timestamp for the target frame. We fetched `created_at_ms`
        // from the keyframe already; if the target is a delta frame, re-query for its ts.
        var frameTimestampMs: Int64? = nil
        if frameNo != nil {
            if Int(keyframeNo) == targetFrame {
                frameTimestampMs = intValue(from: keyframeRow["created_at_ms"])
            } else {
                let tsQuery = """
                SELECT created_at_ms FROM _smithers_frames
                WHERE run_id=\(quotedRunId) AND frame_no=\(targetFrame) LIMIT 1;
                """
                if let tsRow = (try? await execSQLite(dbPath: dbPath, query: tsQuery))?.first {
                    frameTimestampMs = intValue(from: tsRow["created_at_ms"])
                }
            }
        }

        // Load per-node execution state. In live mode (frameNo == nil) we pull from
        // `_smithers_nodes` (the authoritative terminal/current state). In historical
        // mode we reconstruct state at `frameTimestampMs` from `_smithers_attempts`.
        var nodeStates: [String: DevToolsNodeStateEntry] = [:]
        do {
            if let ts = frameTimestampMs {
                let attemptRows = try await execSQLite(
                    dbPath: dbPath,
                    query: DevToolsAttemptQuery.query(runId: runId)
                )
                let attempts = DevToolsAttemptQuery.makeEntries(fromRows: attemptRows)
                nodeStates = devToolsNodeStatesAtTimestamp(
                    attempts: attempts,
                    frameTimestampMs: ts
                )
            } else {
                let stateRows = try await execSQLite(
                    dbPath: dbPath,
                    query: DevToolsNodeStateQuery.query(runId: runId)
                )
                nodeStates = DevToolsNodeStateQuery.makeDict(fromRows: stateRows)
            }
        } catch {
            // Non-fatal: we still return a structural tree. The per-node badges will
            // fall back to "pending" and we log the error so operators see it.
            AppLogger.network.warning("DevTools node state load failed", metadata: [
                "run_id": runId,
                "error": String(describing: error),
                "historical": frameTimestampMs != nil ? "1" : "0",
            ])
        }

        let tree = DevToolsTreeBuilder.build(
            xml: finalXML,
            taskIndex: taskIndex,
            nodeStates: nodeStates
        )
        return DevToolsSnapshot(
            runId: runId,
            frameNo: targetFrame,
            seq: targetFrame,
            root: tree
        )
    }

    private nonisolated static func execSQLite(
        dbPath: String,
        query: String
    ) async throws -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", dbPath, query]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw DevToolsClientError.unknown("sqlite3 exited with status \(process.terminationStatus): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let trimmed = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [[String: Any]] else {
            return []
        }
        return json
    }

    private nonisolated static func intValue(from any: Any?) -> Int64? {
        if let v = any as? Int64 { return v }
        if let v = any as? Int { return Int64(v) }
        if let v = any as? NSNumber { return v.int64Value }
        if let v = any as? String, let parsed = Int64(v) { return parsed }
        return nil
    }

    private nonisolated static func stringValue(from any: Any?) -> String? {
        if let v = any as? String { return v }
        if let v = any as? NSNumber { return v.stringValue }
        return nil
    }

    func getNodeOutput(runId: String, nodeId: String, iteration: Int? = nil) async throws -> NodeOutputResponse {
        if UITestSupport.isEnabled {
            let key = "\(runId)|\(nodeId)|\(iteration ?? -1)"
            let fetchCount = uiNodeOutputFetchCounts[key, default: 0]
            uiNodeOutputFetchCounts[key] = fetchCount + 1
            return try fixtureNodeOutput(nodeId: nodeId, fetchCount: fetchCount)
        }

        try DevToolsInputValidator.validate(runId: runId)
        try DevToolsInputValidator.validate(nodeId: nodeId)
        if let iteration { try DevToolsInputValidator.validate(iteration: iteration) }

        let startedAt = CFAbsoluteTimeGetCurrent()
        AppLogger.network.debug("DevTools node output request (CLI)", metadata: [
            "run_id": runId,
            "node_id": nodeId,
            "iteration": iteration.map(String.init) ?? "nil",
        ])

        var args = ["node", nodeId, "--run-id", runId, "--format", "json"]
        if let iteration { args += ["--iteration", String(iteration)] }

        let data: Data
        do {
            data = try await execArgs(args)
        } catch let err as SmithersError {
            // Try to infer a meaningful DevTools error from the CLI message.
            throw Self.devToolsErrorFromCLI(err, defaultNodeId: nodeId)
        } catch {
            throw DevToolsClientError.unknown(String(describing: error))
        }

        // Parse the `smithers node` JSON envelope into a NodeOutputResponse.
        let parsed = try Self.parseNodeOutputFromCLI(data: data)
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        AppLogger.network.debug("DevTools node output response (CLI)", metadata: [
            "run_id": runId,
            "node_id": nodeId,
            "iteration": iteration.map(String.init) ?? "nil",
            "status": parsed.status.rawValue,
            "duration_ms": String(durationMs),
            "bytes": String(data.count),
        ])
        return parsed
    }

    private nonisolated static func parseNodeOutputFromCLI(data: Data) throws -> NodeOutputResponse {
        for candidate in cliJSONPayloadCandidates(from: data) {
            guard let obj = try? JSONSerialization.jsonObject(with: candidate, options: [.fragmentsAllowed]) as? [String: Any] else {
                continue
            }
            // `smithers node` returns: { node: {...}, status: "finished"|"failed"|"pending", attempts: [...], ... }
            let statusString = ((obj["status"] as? String) ?? (obj["node"] as? [String: Any])?["state"] as? String ?? "").lowercased()
            let attempts = (obj["attempts"] as? [[String: Any]]) ?? []
            let latest = attempts.last
            let responseText = latest?["responseText"] as? String
            let heartbeatRaw = latest?["heartbeatData"] ?? latest?["heartbeat_data_json"]

            let status: NodeOutputStatus
            switch statusString {
            case "finished", "complete", "completed", "success", "succeeded":
                status = .produced
            case "failed", "error":
                status = .failed
            default:
                status = .pending
            }

            // Row: parse responseText as JSON (produced path).
            var row: [String: JSONValue]? = nil
            if status == .produced, let responseText, !responseText.isEmpty,
               let rowData = responseText.data(using: .utf8),
               let rowJSON = try? JSONDecoder().decode(JSONValue.self, from: rowData),
               case .object(let rowObj) = rowJSON {
                row = rowObj
            }

            // Partial: extract from failure heartbeatData if present.
            var partial: [String: JSONValue]? = nil
            if status == .failed {
                if let responseText, !responseText.isEmpty,
                   let rowData = responseText.data(using: .utf8),
                   let rowJSON = try? JSONDecoder().decode(JSONValue.self, from: rowData),
                   case .object(let rowObj) = rowJSON {
                    partial = rowObj
                } else if let hb = heartbeatRaw {
                    if let hbData = try? JSONSerialization.data(withJSONObject: hb),
                       let hbJSON = try? JSONDecoder().decode(JSONValue.self, from: hbData),
                       case .object(let hbObj) = hbJSON {
                        partial = hbObj
                    }
                }
            }

            // Schema is not directly exposed by `smithers node`, keep nil for now.
            return NodeOutputResponse(status: status, row: row, schema: nil, partial: partial)
        }
        throw DevToolsClientError.malformedEvent("Unable to parse smithers node output")
    }

    private nonisolated static func devToolsErrorFromCLI(_ err: SmithersError, defaultNodeId: String) -> DevToolsClientError {
        let msg: String
        switch err {
        case .cli(let m), .api(let m), .notAvailable(let m):
            msg = m
        default:
            msg = err.errorDescription ?? ""
        }
        let lower = msg.lowercased()
        if lower.contains("not found") || lower.contains("no such") {
            return .nodeNotFound(defaultNodeId)
        }
        if lower.contains("no output") {
            return .nodeHasNoOutput
        }
        if lower.contains("still running") || lower.contains("pending") || lower.contains("not finished") {
            return .attemptNotFinished
        }
        return .unknown(msg)
    }

    private func fixtureNodeOutput(nodeId: String, fetchCount: Int) throws -> NodeOutputResponse {
        let reviewSchema = OutputSchemaDescriptor(fields: [
            OutputSchemaFieldDescriptor(
                name: "rating",
                type: .string,
                optional: false,
                nullable: false,
                description: "Overall review recommendation.",
                enumValues: [.string("approve"), .string("changes_requested")]
            ),
            OutputSchemaFieldDescriptor(
                name: "score",
                type: .number,
                optional: false,
                nullable: false,
                description: "Numerical quality score.",
                enumValues: nil
            ),
            OutputSchemaFieldDescriptor(
                name: "notes",
                type: .object,
                optional: true,
                nullable: true,
                description: "Structured reviewer notes.",
                enumValues: nil
            ),
        ])

        switch nodeId {
        case "task:fetch":
            return NodeOutputResponse(
                status: .produced,
                row: ["count": .number(3), "status": .string("ready")],
                schema: OutputSchemaDescriptor(fields: [
                    OutputSchemaFieldDescriptor(
                        name: "status",
                        type: .string,
                        optional: false,
                        nullable: false,
                        description: "Fetch status.",
                        enumValues: [.string("ready"), .string("stale")]
                    ),
                    OutputSchemaFieldDescriptor(
                        name: "count",
                        type: .number,
                        optional: false,
                        nullable: false,
                        description: "Number of fetched artifacts.",
                        enumValues: nil
                    ),
                ])
            )

        case "task:review:0":
            if fetchCount == 0 {
                return NodeOutputResponse(status: .pending, row: nil, schema: reviewSchema)
            }
            return NodeOutputResponse(
                status: .produced,
                row: [
                    "rating": .string("approve"),
                    "score": .number(9),
                    "notes": .object([
                        "summary": .string("Looks good overall."),
                        "checks": .array([.string("lint"), .string("tests")]),
                    ]),
                ],
                schema: reviewSchema
            )

        case "task:review:1":
            return NodeOutputResponse(
                status: .failed,
                row: nil,
                schema: reviewSchema,
                partial: [
                    "rating": .string("changes_requested"),
                    "score": .number(4),
                    "notes": .object([
                        "summary": .string("Partial analysis before tool timeout."),
                    ]),
                ]
            )

        case "task:merge":
            return NodeOutputResponse(
                status: .produced,
                row: [
                    "merged": .bool(true),
                    "files": .array([.string("Sources/App.swift"), .string("Tests/AppTests.swift")]),
                ],
                schema: OutputSchemaDescriptor(fields: [
                    OutputSchemaFieldDescriptor(
                        name: "merged",
                        type: .boolean,
                        optional: false,
                        nullable: false,
                        description: "Whether the merge succeeded.",
                        enumValues: nil
                    ),
                    OutputSchemaFieldDescriptor(
                        name: "files",
                        type: .array,
                        optional: false,
                        nullable: false,
                        description: "Changed files.",
                        enumValues: nil
                    ),
                ])
            )

        default:
            throw DevToolsClientError.nodeHasNoOutput
        }
    }

    func getNodeDiff(runId: String, nodeId: String, iteration: Int) async throws -> NodeDiffBundle {
        if UITestSupport.isEnabled {
            return Self.makeUINodeDiffBundle(nodeId: nodeId, iteration: iteration)
        }

        try DevToolsInputValidator.validate(runId: runId)
        try DevToolsInputValidator.validate(nodeId: nodeId)
        try DevToolsInputValidator.validate(iteration: iteration)

        // 1. Look up the VCS pointer for this attempt in sqlite.
        guard let dbPath = resolvedSmithersDBPath() else {
            throw DevToolsClientError.runNotFound(runId)
        }

        let quotedRunId = DevToolsSQL.quote(runId)
        let quotedNodeId = DevToolsSQL.quote(nodeId)
        let query = """
        SELECT jj_pointer AS p, jj_cwd AS cwd
        FROM _smithers_attempts
        WHERE run_id=\(quotedRunId)
          AND node_id=\(quotedNodeId)
          AND iteration=\(iteration)
        ORDER BY attempt DESC
        LIMIT 1;
        """

        let rows: [[String: Any]]
        do {
            rows = try await Self.execSQLite(dbPath: dbPath, query: query)
        } catch {
            throw DevToolsClientError.vcsError("Failed to query _smithers_attempts: \(error)")
        }

        guard let row = rows.first,
              let pointer = Self.stringValue(from: row["p"]),
              !pointer.isEmpty else {
            throw DevToolsClientError.attemptNotFound("\(runId):\(nodeId):\(iteration)")
        }
        let vcsCwd = Self.stringValue(from: row["cwd"])?.nilIfEmpty ?? cwd

        // 2. Produce unified diff. Prefer jj if this is a jj repo, else fall back to git.
        let diffText: String
        do {
            diffText = try await generateVCSDiff(pointer: pointer, workingDirectory: vcsCwd)
        } catch let err as DevToolsClientError {
            throw err
        } catch {
            throw DevToolsClientError.vcsError(String(describing: error))
        }

        // 3. Parse unified diff → NodeDiffBundle.
        let patches = Self.splitUnifiedDiff(diffText)
        return NodeDiffBundle(seq: 0, baseRef: pointer, patches: patches)
    }

    /// Runs `jj diff -r <pointer>` or `git diff <pointer>^ <pointer>` in the given working
    /// directory, returning the unified diff text. Walks up from `workingDirectory` to find
    /// the nearest `.jj` or `.git` marker, since the stored `jj_cwd` is typically a
    /// subdirectory (e.g. the workflow rootDir) that isn't itself a VCS root.
    private func generateVCSDiff(pointer: String, workingDirectory: String) async throws -> String {
        guard let (vcsRoot, kind) = Self.findVCSRoot(startingAt: workingDirectory) else {
            throw DevToolsClientError.vcsError("No VCS found at \(workingDirectory) or any parent directory")
        }

        switch kind {
        case .jj:
            // jj diff produces a git-style patch with --git.
            let args = ["diff", "-r", pointer, "--git"]
            let data = try await execBinaryArgs(
                bin: "jj",
                args: args,
                displayName: "jj",
                workingDirectoryOverride: vcsRoot
            )
            return String(decoding: data, as: UTF8.self)
        case .git:
            // Produce a diff of just the commit referenced by pointer.
            let args = ["diff", "\(pointer)^", pointer]
            let data = try await execBinaryArgs(
                bin: "git",
                args: args,
                displayName: "git",
                workingDirectoryOverride: vcsRoot
            )
            return String(decoding: data, as: UTF8.self)
        }
    }

    private enum VCSKind { case jj, git }

    /// Walks up from `startingAt` looking for a `.jj` or `.git` directory. Returns the first
    /// directory containing one. `.jj` wins if both are present in the same directory (jj
    /// repos often have a co-located `.git` backing store).
    private static func findVCSRoot(startingAt startPath: String) -> (root: String, kind: VCSKind)? {
        let fm = FileManager.default
        var current = (startPath as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            let jjMarker = (current as NSString).appendingPathComponent(".jj")
            let gitMarker = (current as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: jjMarker) { return (current, .jj) }
            if fm.fileExists(atPath: gitMarker) { return (current, .git) }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    /// Splits a full unified diff into per-file NodeDiffPatch entries.
    private nonisolated static func splitUnifiedDiff(_ diff: String) -> [NodeDiffPatch] {
        guard !diff.isEmpty else { return [] }
        // Split on `diff --git ` boundaries — the canonical file-start marker.
        let lines = diff.components(separatedBy: "\n")
        var patches: [NodeDiffPatch] = []
        var currentLines: [String] = []
        var currentPath: String?
        var currentOldPath: String?

        func flush() {
            guard let path = currentPath else {
                currentLines.removeAll()
                return
            }
            let body = currentLines.joined(separator: "\n")
            let operation: NodeDiffPatch.Operation = deriveOperation(from: currentLines)
            patches.append(NodeDiffPatch(
                path: path,
                oldPath: currentOldPath,
                operation: operation,
                diff: body,
                binaryContent: nil
            ))
            currentLines.removeAll()
            currentPath = nil
            currentOldPath = nil
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                currentLines.append(line)
                // Parse `diff --git a/path b/path`
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 4 {
                    var a = String(parts[2])
                    var b = String(parts[3])
                    if a.hasPrefix("a/") { a.removeFirst(2) }
                    if b.hasPrefix("b/") { b.removeFirst(2) }
                    currentOldPath = a
                    currentPath = b
                }
            } else {
                currentLines.append(line)
                // Fallback path extraction via --- / +++ headers.
                if currentPath == nil {
                    if line.hasPrefix("+++ ") {
                        var p = String(line.dropFirst(4))
                        if p.hasPrefix("b/") { p.removeFirst(2) }
                        currentPath = p
                    } else if line.hasPrefix("--- "), currentOldPath == nil {
                        var p = String(line.dropFirst(4))
                        if p.hasPrefix("a/") { p.removeFirst(2) }
                        if p != "/dev/null" {
                            currentOldPath = p
                        }
                    }
                }
            }
        }
        flush()
        return patches
    }

    private nonisolated static func deriveOperation(from lines: [String]) -> NodeDiffPatch.Operation {
        var sawRenameFrom = false
        var sawDeletedFileMode = false
        var sawNewFileMode = false
        for l in lines {
            if l.hasPrefix("rename from ") { sawRenameFrom = true }
            if l.hasPrefix("new file mode ") { sawNewFileMode = true }
            if l.hasPrefix("deleted file mode ") { sawDeletedFileMode = true }
        }
        if sawRenameFrom { return .rename }
        if sawNewFileMode { return .add }
        if sawDeletedFileMode { return .delete }
        return .modify
    }

    func jumpToFrame(runId: String, frameNo: Int, confirm: Bool = true) async throws -> DevToolsJumpResult {
        if UITestSupport.isEnabled {
            return DevToolsJumpResult(
                ok: true,
                newFrameNo: frameNo,
                revertedSandboxes: 1,
                deletedFrames: 0,
                deletedAttempts: 0,
                invalidatedDiffs: 0,
                durationMs: 10
            )
        }

        try DevToolsInputValidator.validate(runId: runId)
        try DevToolsInputValidator.validate(frameNo: frameNo)
        guard confirm else { throw DevToolsClientError.confirmationRequired }

        guard let dbPath = resolvedSmithersDBPath() else {
            throw DevToolsClientError.runNotFound(runId)
        }

        // Resolve nodeId + workflow_path for this (runId, frameNo) pair by looking at events.
        let quotedRunId = DevToolsSQL.quote(runId)
        let runQuery = "SELECT workflow_path FROM _smithers_runs WHERE run_id=\(quotedRunId) LIMIT 1;"
        let runRows: [[String: Any]]
        do {
            runRows = try await Self.execSQLite(dbPath: dbPath, query: runQuery)
        } catch {
            throw DevToolsClientError.rewindFailed("Unable to resolve run: \(error)")
        }
        let workflowPath = Self.stringValue(from: runRows.first?["workflow_path"])?.nilIfEmpty

        // Find the NodeFinished event whose seq is immediately before the FrameCommitted event
        // for frameNo — that is the node responsible for this frame and thus the revert target.
        let eventQuery = """
        SELECT json_extract(n.payload_json, '$.nodeId') AS node_id,
               json_extract(n.payload_json, '$.iteration') AS iteration
        FROM _smithers_events n
        WHERE n.run_id=\(quotedRunId)
          AND n.type IN ('NodeFinished','NodeFailed')
          AND n.seq < (
            SELECT MIN(seq) FROM _smithers_events
            WHERE run_id=\(quotedRunId)
              AND type='FrameCommitted'
              AND json_extract(payload_json, '$.frameNo')=\(frameNo)
          )
        ORDER BY n.seq DESC
        LIMIT 1;
        """

        let evtRows: [[String: Any]]
        do {
            evtRows = try await Self.execSQLite(dbPath: dbPath, query: eventQuery)
        } catch {
            throw DevToolsClientError.rewindFailed("Unable to resolve frame node: \(error)")
        }

        guard let targetNodeId = Self.stringValue(from: evtRows.first?["node_id"]), !targetNodeId.isEmpty else {
            // If the requested frame has no associated NodeFinished event, we can't map it
            // to a revert target. The server's `smithers revert` CLI requires a node id.
            throw DevToolsClientError.rewindFailed("Frame \(frameNo) has no associated node to revert to. Use `smithers revert` from the command line for advanced time travel.")
        }
        let iteration = Self.intValue(from: evtRows.first?["iteration"]).map { Int($0) } ?? 0

        let startedAt = CFAbsoluteTimeGetCurrent()
        AppLogger.network.info("DevTools jumpToFrame request (CLI)", metadata: [
            "run_id": runId,
            "frame_no": String(frameNo),
            "target_node": targetNodeId,
            "iteration": String(iteration),
            "workflow_path": workflowPath ?? "",
        ])

        var args = ["revert"]
        if let workflowPath { args.append(workflowPath) }
        args += ["--run-id", runId, "--node-id", targetNodeId]
        if iteration > 0 { args += ["--iteration", String(iteration)] }
        args += ["--format", "json"]

        do {
            _ = try await execArgs(args)
        } catch let err as SmithersError {
            // Translate common CLI failure signals into DevTools error cases.
            let msg: String
            switch err {
            case .cli(let m), .api(let m), .notAvailable(let m): msg = m
            default: msg = err.errorDescription ?? ""
            }
            let lower = msg.lowercased()
            if lower.contains("dirty") {
                throw DevToolsClientError.workingTreeDirty(msg)
            }
            if lower.contains("busy") {
                throw DevToolsClientError.busy
            }
            if lower.contains("sandbox") {
                throw DevToolsClientError.unsupportedSandbox(msg)
            }
            throw DevToolsClientError.rewindFailed(msg)
        } catch {
            throw DevToolsClientError.rewindFailed(String(describing: error))
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        return DevToolsJumpResult(
            ok: true,
            newFrameNo: frameNo,
            revertedSandboxes: 1,
            deletedFrames: 0,
            deletedAttempts: 0,
            invalidatedDiffs: 0,
            durationMs: durationMs
        )
    }

    // MARK: - Run Streaming (HTTP — requires --serve)

    func streamRunEvents(_ runId: String, port: Int = SmithersClient.defaultHTTPTransportPort) -> AsyncStream<SSEEvent> {
        let filterRunId = Self.sseFilterRunId(runId)
        guard let url = resolvedHTTPTransportURL(path: Self.runEventsPath(runId: filterRunId), fallbackPort: port) else {
            return emptySSEStream()
        }
        return sseStream(url: url, runId: filterRunId, requireAttributedRunId: filterRunId != nil)
    }

    func streamChat(_ runId: String, port: Int = SmithersClient.defaultHTTPTransportPort) -> AsyncStream<SSEEvent> {
        let encodedRunId = Self.encodedURLPathComponent(runId)
        let candidates = [
            (path: "/v1/runs/\(encodedRunId)/chat/stream", requireAttributedRunId: false),
            (path: "/chat/stream?runId=\(encodedRunId)", requireAttributedRunId: false),
            (path: "/chat/stream", requireAttributedRunId: true),
        ]
        let resolvedCandidates = candidates.compactMap { candidate -> SSECandidateURL? in
            guard let url = resolvedHTTPTransportURL(path: candidate.path, fallbackPort: port) else {
                return nil
            }
            return SSECandidateURL(url: url, requireAttributedRunId: candidate.requireAttributedRunId)
        }
        guard !resolvedCandidates.isEmpty else {
            return emptySSEStream()
        }
        return sseStream(candidates: resolvedCandidates, runId: SSEEvent.normalizedRunId(runId))
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

    func getChatOutput(_ runId: String, port: Int = SmithersClient.defaultHTTPTransportPort) async throws -> [ChatBlock] {
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

        if let blocks = try? await getChatOutputCLI(["run", "chat", runId, "--format", "json"], timeoutSeconds: 10) {
            return blocks
        }

        if let blocks = try? await getChatOutputCLI([
            "chat", runId, "--all", "true", "--follow", "false", "--stderr", "true", "--format", "json",
        ], timeoutSeconds: 10) {
            return blocks
        }

        // Try without --tail first (gets earliest blocks), then with --tail (gets latest).
        // Merge both so we cover the full run despite per-call output truncation.
        var allBlocks: [ChatBlock] = []
        if let early = try? await getChatOutputCLI([
            "chat", runId, "--all", "true", "--format", "json",
        ], timeoutSeconds: 10) {
            allBlocks = early
        }
        if let recent = try? await getChatOutputCLI([
            "chat", runId, "--all", "true", "--tail", "500", "--format", "json",
        ], timeoutSeconds: 10) {
            // Merge: add recent blocks not already present
            let existingIds = Set(allBlocks.compactMap(\.lifecycleId))
            for block in recent where block.lifecycleId == nil || !existingIds.contains(block.lifecycleId!) {
                allBlocks.append(block)
            }
        }
        if !allBlocks.isEmpty {
            return allBlocks
        }
        throw SmithersError.api("Unable to load chat output for run \(runId)")
    }

    func hijackRun(_ runId: String, port: Int = SmithersClient.defaultHTTPTransportPort) async throws -> HijackSession {
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

        let data = try await execArgs(Self.hijackRunCLIArgs(runId: runId))
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

    // MARK: - Codex Auth

    func codexAuthState() -> CodexAuthState {
        if UITestSupport.isEnabled {
            return CodexAuthState(
                hasCodexCLI: true,
                codexCLIPath: "/usr/bin/codex",
                hasAuthFile: true,
                hasAPIKey: true,
                authFilePath: codexAuthFilePath()
            )
        }

        let codexBinary = resolveBinaryPath("codex")
        let authFilePath = codexAuthFilePath()
        let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CodexAuthState(
            hasCodexCLI: codexBinary != nil,
            codexCLIPath: codexBinary,
            hasAuthFile: FileManager.default.fileExists(atPath: authFilePath),
            hasAPIKey: !apiKey.isEmpty,
            authFilePath: authFilePath
        )
    }

    func loginCodexWithAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SmithersError.api("API key is required.")
        }

        let authFilePath = codexAuthFilePath()
        let authDirPath = (authFilePath as NSString).deletingLastPathComponent
        let payload: [String: Any] = [
            "OPENAI_API_KEY": trimmed,
            "tokens": NSNull(),
            "last_refresh": NSNull(),
        ]

        do {
            try FileManager.default.createDirectory(atPath: authDirPath, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: authFilePath), options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: authFilePath
            )
        } catch {
            throw SmithersError.api("Failed to save Codex API key: \(error.localizedDescription)")
        }
    }

    func logoutCodex() throws -> Bool {
        let authFilePath = codexAuthFilePath()
        let fm = FileManager.default
        guard fm.fileExists(atPath: authFilePath) else {
            return false
        }

        do {
            try fm.removeItem(atPath: authFilePath)
            return true
        } catch {
            throw SmithersError.api("Failed to log out Codex: \(error.localizedDescription)")
        }
    }

    private func codexHomePath() -> String {
        if let override = codexHomeOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }

        if let envValue = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return (envValue as NSString).expandingTildeInPath
        }

        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }

    private func codexAuthFilePath() -> String {
        (codexHomePath() as NSString).appendingPathComponent("auth.json")
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

        let namespaceArg = SmithersMemoryCLI.normalizedNamespace(namespace)
        let workflowArg = SmithersMemoryCLI.normalizedWorkflowPath(workflowPath)
        if workflowArg == nil, let dbPath = resolvedSmithersDBPath() {
            do {
                return try await queryMemoryFactsSQLite(dbPath: dbPath, namespace: namespaceArg)
            } catch {
                if !shouldFallbackToExecForMemorySQLiteError(error) {
                    throw error
                }
            }
        }

        let data = try await execMemoryList(namespace: namespaceArg, workflowPath: workflowArg)
        return try decodeMemoryFacts(from: data)
    }

    func listAllMemoryFacts(namespace: String? = nil, workflowPath: String? = nil) async throws -> [MemoryFact] {
        if UITestSupport.isEnabled {
            let facts = [
                MemoryFact(namespace: "project", key: "language", valueJson: "\"Swift\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 86_400_000, updatedAtMs: UITestSupport.nowMs - 3_600_000, ttlMs: nil),
                MemoryFact(namespace: "workflow", key: "default-env", valueJson: "\"staging\"", schemaSig: nil, createdAtMs: UITestSupport.nowMs - 43_200_000, updatedAtMs: UITestSupport.nowMs - 1_800_000, ttlMs: nil),
            ]
            guard let namespace else { return facts }
            return facts.filter { $0.namespace == namespace }
        }

        let namespaceArg = SmithersMemoryCLI.normalizedNamespace(namespace)
        let workflowArg = SmithersMemoryCLI.normalizedWorkflowPath(workflowPath)
        if workflowArg == nil, let dbPath = resolvedSmithersDBPath() {
            do {
                return try await queryMemoryFactsSQLite(dbPath: dbPath, namespace: namespaceArg)
            } catch {
                if !shouldFallbackToExecForMemorySQLiteError(error) {
                    throw error
                }
            }
        }

        let data = try await execMemoryList(namespace: namespaceArg, workflowPath: workflowArg)
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
            workflowPath: SmithersMemoryCLI.normalizedWorkflowPath(workflowPath),
            topK: topK
        )
        let data = try await execArgs(args)
        return try decodeMemoryRecallResults(from: data)
    }

    private func queryMemoryFactsSQLite(dbPath: String, namespace: String?) async throws -> [MemoryFact] {
        let whereClause: String
        if let namespace {
            whereClause = " WHERE namespace = \(quoteSQLiteStringLiteral(namespace))"
        } else {
            whereClause = ""
        }
        let orderClause = namespace == nil ? " ORDER BY updated_at_ms DESC" : ""
        let query = """
        SELECT
            namespace AS namespace,
            key AS key,
            value_json AS valueJson,
            schema_sig AS schemaSig,
            created_at_ms AS createdAtMs,
            updated_at_ms AS updatedAtMs,
            ttl_ms AS ttlMs
        FROM _smithers_memory_facts\(whereClause)\(orderClause)
        """
        let data = try await execSQLiteJSON(dbPath: dbPath, query: query)
        let rows = try parseJSONRows(data)
        return try decodeMemoryFactsSQLiteRows(rows)
    }

    private func decodeMemoryFactsSQLiteRows(_ rows: [[String: Any]]) throws -> [MemoryFact] {
        try rows.map { row in
            guard
                let namespace = Self.searchString(row["namespace"]), !namespace.isEmpty,
                let key = Self.searchString(row["key"]), !key.isEmpty,
                let valueJson = Self.searchString(row["valueJson"] ?? row["value_json"]),
                let createdAtMs = int64Value(from: row["createdAtMs"] ?? row["created_at_ms"]),
                let updatedAtMs = int64Value(from: row["updatedAtMs"] ?? row["updated_at_ms"])
            else {
                throw SmithersError.api("Invalid memory fact row in SQLite response")
            }

            let schemaSig = Self.searchString(row["schemaSig"] ?? row["schema_sig"])?.nilIfEmpty
            let ttlMs = int64Value(from: row["ttlMs"] ?? row["ttl_ms"])

            return MemoryFact(
                namespace: namespace,
                key: key,
                valueJson: valueJson,
                schemaSig: schemaSig,
                createdAtMs: createdAtMs,
                updatedAtMs: updatedAtMs,
                ttlMs: ttlMs
            )
        }
    }

    private func shouldFallbackToExecForMemorySQLiteError(_ error: Error) -> Bool {
        guard case let SmithersError.cli(message) = error else {
            return false
        }
        return message.lowercased().contains("failed to run sqlite3")
    }

    private func shouldRetryMemoryListWithLegacyArgs(_ error: Error) -> Bool {
        guard case let SmithersError.cli(message) = error else {
            return false
        }
        let lower = message.lowercased()
        if lower.contains("unknown flag: --namespace") {
            return true
        }
        if lower.contains("namespace"), (lower.contains("required") || lower.contains("expected string") || lower.contains("missing")) {
            return true
        }
        return false
    }

    private func execMemoryList(namespace: String?, workflowPath: String?) async throws -> Data {
        let args = SmithersMemoryCLI.listArgs(namespace: namespace, workflowPath: workflowPath)
        do {
            return try await execArgs(args)
        } catch {
            guard shouldRetryMemoryListWithLegacyArgs(error) else {
                throw error
            }
            let legacyNamespace = namespace ?? SmithersMemoryCLI.defaultNamespace
            let legacyArgs = SmithersMemoryCLI.legacyListArgs(
                namespace: legacyNamespace,
                workflowPath: workflowPath
            )
            return try await execArgs(legacyArgs)
        }
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
        Array(AggregateScore.aggregate(scores).prefix(limit))
    }

    func getTokenUsageMetrics(filters: MetricsFilter = MetricsFilter()) async throws -> TokenMetrics {
        if UITestSupport.isEnabled {
            let day = DateFormatters.yearMonthDay.string(from: Date())
            return TokenMetrics(
                totalInputTokens: 24_000,
                totalOutputTokens: 9_200,
                totalTokens: 33_200,
                cacheReadTokens: 8_600,
                cacheWriteTokens: 1_200,
                byPeriod: [
                    TokenPeriodBatch(label: day, inputTokens: 24_000, outputTokens: 9_200, cacheReadTokens: 8_600, cacheWriteTokens: 1_200),
                ]
            )
        }

        if let data = try? await httpRequestRaw(method: "GET", path: metricsPath(basePath: "/metrics/tokens", filters: filters)),
           let payload = try? unwrapLegacyEnvelope(data),
           let metrics = try? decodeTokenMetricsResponse(from: payload) {
            return metrics
        }

        if let dbPath = resolvedSmithersDBPath(),
           let metrics = try? await queryTokenUsageMetricsSQLite(dbPath: dbPath, filters: filters) {
            return metrics
        }

        let data = try await execArgs(metricsCLIArgs(subcommand: "token-usage", filters: filters))
        return try decodeTokenMetricsResponse(from: data)
    }

    func getLatencyMetrics(filters: MetricsFilter = MetricsFilter()) async throws -> LatencyMetrics {
        if UITestSupport.isEnabled {
            return LatencyMetrics(
                count: 18,
                meanMs: 812,
                minMs: 122,
                maxMs: 2_110,
                p50Ms: 640,
                p95Ms: 1_980
            )
        }

        if let data = try? await httpRequestRaw(method: "GET", path: metricsPath(basePath: "/metrics/latency", filters: filters)),
           let payload = try? unwrapLegacyEnvelope(data),
           let metrics = try? decodeLatencyMetricsResponse(from: payload) {
            return metrics
        }

        if let dbPath = resolvedSmithersDBPath(),
           let metrics = try? await queryLatencyMetricsSQLite(dbPath: dbPath, filters: filters) {
            return metrics
        }

        let data = try await execArgs(metricsCLIArgs(subcommand: "latency", filters: filters))
        return try decodeLatencyMetricsResponse(from: data)
    }

    func getCostTracking(filters: MetricsFilter = MetricsFilter()) async throws -> CostReport {
        if UITestSupport.isEnabled {
            let calendar = Calendar.current
            let today = Date()
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
            let todayLabel = DateFormatters.yearMonthDay.string(from: today)
            let yesterdayLabel = DateFormatters.yearMonthDay.string(from: yesterday)
            return CostReport(
                totalCostUSD: 0.358_800,
                inputCostUSD: 0.072_000,
                outputCostUSD: 0.286_800,
                runCount: 6,
                byPeriod: [
                    CostPeriodBatch(label: yesterdayLabel, totalCostUSD: 0.141_300, inputCostUSD: 0.026_400, outputCostUSD: 0.114_900, runCount: 2),
                    CostPeriodBatch(label: todayLabel, totalCostUSD: 0.217_500, inputCostUSD: 0.045_600, outputCostUSD: 0.171_900, runCount: 4),
                ]
            )
        }

        if let data = try? await httpRequestRaw(method: "GET", path: metricsPath(basePath: "/metrics/cost", filters: filters)),
           let payload = try? unwrapLegacyEnvelope(data),
           let report = try? decodeCostReportResponse(from: payload) {
            return report
        }

        if let dbPath = resolvedSmithersDBPath(),
           let report = try? await queryCostTrackingSQLite(dbPath: dbPath, filters: filters) {
            return report
        }

        let data = try await execArgs(metricsCLIArgs(subcommand: "cost", filters: filters))
        return try decodeCostReportResponse(from: data)
    }

    private func decodeTokenMetricsResponse(from data: Data) throws -> TokenMetrics {
        if let envelope = try? decodeCLIJSON(APIEnvelope<TokenMetrics>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return payload
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<TokenMetrics>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON(TokenMetrics.self, from: data)
    }

    private func decodeLatencyMetricsResponse(from data: Data) throws -> LatencyMetrics {
        if let envelope = try? decodeCLIJSON(APIEnvelope<LatencyMetrics>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return payload
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<LatencyMetrics>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON(LatencyMetrics.self, from: data)
    }

    private func decodeCostReportResponse(from data: Data) throws -> CostReport {
        if let envelope = try? decodeCLIJSON(APIEnvelope<CostReport>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            return payload
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<CostReport>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON(CostReport.self, from: data)
    }

    private func metricsPath(basePath: String, filters: MetricsFilter) -> String {
        var queryItems: [URLQueryItem] = []
        if let runId = filters.runId?.nilIfEmpty {
            queryItems.append(URLQueryItem(name: "runId", value: runId))
        }
        if let nodeId = filters.nodeId?.nilIfEmpty {
            queryItems.append(URLQueryItem(name: "nodeId", value: nodeId))
        }
        if let workflowPath = filters.workflowPath?.nilIfEmpty {
            queryItems.append(URLQueryItem(name: "workflowPath", value: workflowPath))
        }
        if let startMs = filters.startMs, startMs > 0 {
            queryItems.append(URLQueryItem(name: "startMs", value: "\(startMs)"))
        }
        if let endMs = filters.endMs, endMs > 0 {
            queryItems.append(URLQueryItem(name: "endMs", value: "\(endMs)"))
        }
        if let groupBy = filters.groupBy?.nilIfEmpty {
            queryItems.append(URLQueryItem(name: "groupBy", value: groupBy))
        }
        guard !queryItems.isEmpty else { return basePath }
        var components = URLComponents()
        components.queryItems = queryItems
        let query = components.percentEncodedQuery ?? ""
        return query.isEmpty ? basePath : "\(basePath)?\(query)"
    }

    private func metricsCLIArgs(subcommand: String, filters: MetricsFilter) -> [String] {
        var args = ["metrics", subcommand, "--format", "json"]
        if let runId = filters.runId?.nilIfEmpty {
            args += ["--run", runId]
        }
        if let nodeId = filters.nodeId?.nilIfEmpty {
            args += ["--node", nodeId]
        }
        if let workflowPath = filters.workflowPath?.nilIfEmpty {
            args += ["--workflow", workflowPath]
        }
        if let startMs = filters.startMs, startMs > 0 {
            args += ["--start", "\(startMs)"]
        }
        if let endMs = filters.endMs, endMs > 0 {
            args += ["--end", "\(endMs)"]
        }
        if let groupBy = filters.groupBy?.nilIfEmpty {
            args += ["--group-by", groupBy]
        }
        return args
    }

    private func queryTokenUsageMetricsSQLite(dbPath: String, filters: MetricsFilter) async throws -> TokenMetrics {
        let query = """
        SELECT
            COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
            COALESCE(SUM(output_tokens), 0) AS totalOutputTokens,
            COALESCE(SUM(cache_read_tokens), 0) AS cacheReadTokens,
            COALESCE(SUM(cache_write_tokens), 0) AS cacheWriteTokens
        FROM _smithers_chat_attempts\(tokenMetricsWhereClause(filters: filters))
        """
        let data = try await execSQLiteJSON(dbPath: dbPath, query: query)
        let rows = try parseJSONRows(data)
        let row = rows.first ?? [:]
        let totalInputTokens = int64Value(from: row["totalInputTokens"]) ?? 0
        let totalOutputTokens = int64Value(from: row["totalOutputTokens"]) ?? 0
        let cacheReadTokens = int64Value(from: row["cacheReadTokens"]) ?? 0
        let cacheWriteTokens = int64Value(from: row["cacheWriteTokens"]) ?? 0
        return TokenMetrics(
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            totalTokens: totalInputTokens + totalOutputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    private func tokenMetricsWhereClause(filters: MetricsFilter) -> String {
        var conditions: [String] = []
        if let runId = filters.runId?.nilIfEmpty {
            conditions.append("run_id = \(quoteSQLiteStringLiteral(runId))")
        }
        if let nodeId = filters.nodeId?.nilIfEmpty {
            conditions.append("node_id = \(quoteSQLiteStringLiteral(nodeId))")
        }
        if let startMs = filters.startMs, startMs > 0 {
            conditions.append("started_at_ms >= \(startMs)")
        }
        if let endMs = filters.endMs, endMs > 0 {
            conditions.append("started_at_ms <= \(endMs)")
        }
        return sqlWhereClause(conditions)
    }

    private func queryLatencyMetricsSQLite(dbPath: String, filters: MetricsFilter) async throws -> LatencyMetrics {
        var conditions: [String] = ["duration_ms IS NOT NULL"]
        if let runId = filters.runId?.nilIfEmpty {
            conditions.append("run_id = \(quoteSQLiteStringLiteral(runId))")
        }
        if let nodeId = filters.nodeId?.nilIfEmpty {
            conditions.append("id = \(quoteSQLiteStringLiteral(nodeId))")
        }
        if let workflowPath = filters.workflowPath?.nilIfEmpty {
            conditions.append("workflow_path = \(quoteSQLiteStringLiteral(workflowPath))")
        }
        if let startMs = filters.startMs, startMs > 0 {
            conditions.append("started_at_ms >= \(startMs)")
        }
        if let endMs = filters.endMs, endMs > 0 {
            conditions.append("started_at_ms <= \(endMs)")
        }
        let query = """
        SELECT CAST(duration_ms AS REAL) AS durationMs
        FROM _smithers_nodes\(sqlWhereClause(conditions))
        ORDER BY duration_ms
        """
        let data = try await execSQLiteJSON(dbPath: dbPath, query: query)
        let rows = try parseJSONRows(data)
        let durations = rows.compactMap { row in
            doubleValue(from: row["durationMs"] ?? row["duration_ms"] ?? row["duration_ms as real"])
        }
        return latencyMetrics(from: durations)
    }

    private func latencyMetrics(from durations: [Double]) -> LatencyMetrics {
        guard !durations.isEmpty else {
            return LatencyMetrics()
        }
        let sorted = durations.sorted()
        let count = sorted.count
        let mean = sorted.reduce(0, +) / Double(count)
        return LatencyMetrics(
            count: count,
            meanMs: mean,
            minMs: sorted.first ?? 0,
            maxMs: sorted.last ?? 0,
            p50Ms: percentile(sortedValues: sorted, percentile: 0.50),
            p95Ms: percentile(sortedValues: sorted, percentile: 0.95)
        )
    }

    private func percentile(sortedValues: [Double], percentile: Double) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        guard sortedValues.count > 1 else { return sortedValues[0] }
        let index = percentile * Double(sortedValues.count - 1)
        let lower = Int(floor(index))
        let upper = Int(ceil(index))
        if lower == upper {
            return sortedValues[lower]
        }
        let fraction = index - Double(lower)
        return sortedValues[lower] * (1 - fraction) + sortedValues[upper] * fraction
    }

    private func queryCostTrackingSQLite(dbPath: String, filters: MetricsFilter) async throws -> CostReport {
        let tokenMetrics = try await queryTokenUsageMetricsSQLite(dbPath: dbPath, filters: filters)

        let runCountQuery = """
        SELECT COUNT(DISTINCT run_id) AS runCount
        FROM _smithers_chat_attempts\(costRunCountWhereClause(filters: filters))
        """
        let runCountData = try await execSQLiteJSON(dbPath: dbPath, query: runCountQuery)
        let runCountRows = try parseJSONRows(runCountData)
        let runCount = Int(int64Value(from: runCountRows.first?["runCount"]) ?? 0)

        let inputCost = Double(tokenMetrics.totalInputTokens) / 1_000_000 * Self.costPerMInputTokens
        let outputCost = Double(tokenMetrics.totalOutputTokens) / 1_000_000 * Self.costPerMOutputTokens
        return CostReport(
            totalCostUSD: inputCost + outputCost,
            inputCostUSD: inputCost,
            outputCostUSD: outputCost,
            runCount: runCount
        )
    }

    private func costRunCountWhereClause(filters: MetricsFilter) -> String {
        var conditions: [String] = []
        if let runId = filters.runId?.nilIfEmpty {
            conditions.append("run_id = \(quoteSQLiteStringLiteral(runId))")
        }
        if let startMs = filters.startMs, startMs > 0 {
            conditions.append("started_at_ms >= \(startMs)")
        }
        if let endMs = filters.endMs, endMs > 0 {
            conditions.append("started_at_ms <= \(endMs)")
        }
        return sqlWhereClause(conditions)
    }

    private func sqlWhereClause(_ conditions: [String]) -> String {
        guard !conditions.isEmpty else { return "" }
        return " WHERE " + conditions.joined(separator: " AND ")
    }

    private func quoteSQLiteStringLiteral(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
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

    func localTicketFilePath(for ticketId: String, requireExisting: Bool = true) throws -> String {
        let trimmedId = ticketId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SmithersError.api("ticketID must not be empty")
        }

        let path = try ticketPath(for: trimmedId)
        if requireExisting && !FileManager.default.fileExists(atPath: path) {
            throw SmithersError.notFound
        }

        return path
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

        let encodedId = Self.encodedURLPathComponent(trimmedId)
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

        let encodedId = Self.encodedURLPathComponent(trimmedId)
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

        let encodedId = Self.encodedURLPathComponent(trimmedId)
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

    // MARK: - Prompts (Smithers parity: HTTP -> filesystem -> CLI)

    private struct PromptListResponse: Decodable {
        let prompts: [SmithersPrompt]
    }

    private struct PromptRenderResponse: Decodable {
        let result: String?
        let rendered: String?
    }

    nonisolated private static let promptInterpolationRegex = try! NSRegularExpression(
        pattern: #"\{\s*props\.([A-Za-z_][A-Za-z0-9_]*)\s*\}"#
    )
    nonisolated private static let promptInputNameRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#
    )
    nonisolated private static let mdxComponentTagRegex = try! NSRegularExpression(
        pattern: #"<[A-Z][A-Za-z0-9_.:-]*\b[^>]*>"#,
        options: [.dotMatchesLineSeparators]
    )
    nonisolated private static let mdxComponentPropsMemberRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z_][A-Za-z0-9_]*\s*=\s*\{\s*props\.([A-Za-z_][A-Za-z0-9_]*)\s*\}"#
    )
    nonisolated private static let mdxComponentPassThroughRegex = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}"#
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

    private func promptsDirectoryPath() -> String {
        (cwd as NSString).appendingPathComponent(".smithers/prompts")
    }

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

        let promptsDir = promptsDirectoryPath()
        let path = (promptsDir as NSString).appendingPathComponent("\(promptId).mdx")
        let standardizedPromptsDir = (promptsDir as NSString).standardizingPath
        let standardizedPath = (path as NSString).standardizingPath
        guard standardizedPath.hasPrefix(standardizedPromptsDir + "/") else {
            throw SmithersError.api("Invalid prompt id")
        }
        return standardizedPath
    }

    private func decodedPromptPayload(from data: Data) throws -> Data {
        try unwrapLegacyEnvelope(data)
    }

    private func decodePromptList(from data: Data) throws -> [SmithersPrompt] {
        let payload = try decodedPromptPayload(from: data)
        if let prompts = try? decodeCLIJSON([SmithersPrompt].self, from: payload) {
            return prompts
        }
        return try decodeCLIJSON(PromptListResponse.self, from: payload).prompts
    }

    private func decodePrompt(from data: Data) throws -> SmithersPrompt {
        let payload = try decodedPromptPayload(from: data)
        return try decodeCLIJSON(SmithersPrompt.self, from: payload)
    }

    private func decodePromptProps(from data: Data) throws -> [PromptInput] {
        let payload = try decodedPromptPayload(from: data)
        return try decodeCLIJSON([PromptInput].self, from: payload)
    }

    private func decodePromptRenderResult(from data: Data) throws -> String {
        let payload = try decodedPromptPayload(from: data)
        if let value = try? decodeCLIJSON(String.self, from: payload) {
            return value
        }
        let response = try decodeCLIJSON(PromptRenderResponse.self, from: payload)
        if let result = response.result, !result.isEmpty {
            return result
        }
        return response.rendered ?? ""
    }

    private func listPromptsFromFilesystem() throws -> [SmithersPrompt] {
        let dirURL = URL(fileURLWithPath: promptsDirectoryPath(), isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )

        return entries
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { entry in
                let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true, entry.pathExtension == "mdx" else {
                    return nil
                }
                let fileName = entry.lastPathComponent
                let promptID = entry.deletingPathExtension().lastPathComponent
                return SmithersPrompt(
                    id: promptID,
                    entryFile: ".smithers/prompts/\(fileName)",
                    source: nil,
                    inputs: nil
                )
            }
    }

    private func getPromptFromFilesystem(_ promptId: String) throws -> SmithersPrompt {
        let path = try promptPath(for: promptId)
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let inputs = Self.discoverPromptInputs(in: source)
        return SmithersPrompt(
            id: promptId,
            entryFile: ".smithers/prompts/\(promptId).mdx",
            source: source,
            inputs: inputs
        )
    }

    private func updatePromptOnFilesystem(_ promptId: String, source: String) throws {
        let path = try promptPath(for: promptId)
        guard FileManager.default.fileExists(atPath: path) else {
            throw SmithersError.notFound
        }
        try source.write(toFile: path, atomically: true, encoding: .utf8)
    }

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
        guard !candidate.isEmpty else { return nil }
        guard isValidPromptInputName(candidate) else { return nil }
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

        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
        return content.nilIfEmpty
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

    private func renderPromptTemplate(_ source: String, input: [String: String]) -> String {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = Self.promptInterpolationRegex.matches(in: source, range: range)
        guard !matches.isEmpty else { return source }

        var rendered = source
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: source) else { continue }
            let key = String(source[nameRange])
            guard let value = input[key],
                  let fullRange = Range(match.range(at: 0), in: rendered)
            else {
                continue
            }
            rendered.replaceSubrange(fullRange, with: value)
        }
        return rendered
    }

    func listPrompts() async throws -> [SmithersPrompt] {
        if UITestSupport.isEnabled {
            return [
                SmithersPrompt(
                    id: "release-notes",
                    entryFile: ".smithers/prompts/release-notes.mdx",
                    source: "Write release notes for {props.version}.",
                    inputs: [PromptInput(name: "version", type: "string", defaultValue: nil)]
                ),
            ]
        }

        if let data = try? await httpRequestRaw(method: "GET", path: "/prompt/list"),
           let prompts = try? decodePromptList(from: data) {
            return prompts
        }

        if let prompts = try? listPromptsFromFilesystem() {
            return prompts
        }

        let data = try await exec("prompt", "list", "--format", "json")
        return try decodePromptList(from: data)
    }

    func getPrompt(_ promptId: String) async throws -> SmithersPrompt {
        if UITestSupport.isEnabled {
            return SmithersPrompt(
                id: promptId,
                entryFile: ".smithers/prompts/\(promptId).mdx",
                source: "Write release notes for {props.version}.",
                inputs: [PromptInput(name: "version", type: "string", defaultValue: nil)]
            )
        }

        let encodedID = Self.encodedURLPathComponent(promptId)
        if let data = try? await httpRequestRaw(method: "GET", path: "/prompt/get/\(encodedID)"),
           let prompt = try? decodePrompt(from: data) {
            return prompt
        }

        if let prompt = try? getPromptFromFilesystem(promptId) {
            return prompt
        }

        let data = try await exec("prompt", "get", promptId, "--format", "json")
        return try decodePrompt(from: data)
    }

    func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] {
        if UITestSupport.isEnabled {
            return [PromptInput(name: "version", type: "string", defaultValue: nil)]
        }

        let encodedID = Self.encodedURLPathComponent(promptId)
        var transportInputs: [PromptInput] = []
        if let data = try? await httpRequestRaw(method: "GET", path: "/prompt/props/\(encodedID)"),
           let props = try? decodePromptProps(from: data) {
            transportInputs = props
        }

        do {
            // Always parse source locally so MDX frontmatter/component props are included
            // even when transport-provided inputs only include template syntax.
            let prompt = try await getPrompt(promptId)
            let promptInputs = prompt.inputs ?? []
            let sourceInputs = Self.discoverPromptInputs(in: prompt.source ?? "")

            let fallbackInputs = Self.mergedPromptInputs(
                preferred: promptInputs,
                fallback: transportInputs
            )
            return Self.mergedPromptInputs(
                preferred: sourceInputs,
                fallback: fallbackInputs
            )
        } catch {
            if !transportInputs.isEmpty {
                return transportInputs
            }
            throw error
        }
    }

    func updatePrompt(_ promptId: String, source: String) async throws {
        if UITestSupport.isEnabled {
            return
        }

        let encodedID = Self.encodedURLPathComponent(promptId)
        if let body = try? JSONEncoder().encode(["source": source]),
           (try? await httpRequestRaw(
               method: "POST",
               path: "/prompt/update/\(encodedID)",
               jsonBody: body
           )) != nil {
            return
        }

        if (try? updatePromptOnFilesystem(promptId, source: source)) != nil {
            return
        }

        _ = try await exec("prompt", "update", promptId, "--source", source)
    }

    func previewPrompt(_ promptId: String, source: String, input: [String: String]) async throws -> String {
        if UITestSupport.isEnabled {
            return renderPromptTemplate(source, input: input)
        }

        struct PromptRenderRequest: Encodable {
            let input: [String: String]
            let source: String
        }

        let encodedID = Self.encodedURLPathComponent(promptId)
        if let body = try? JSONEncoder().encode(PromptRenderRequest(input: input, source: source)),
           let data = try? await httpRequestRaw(
               method: "POST",
               path: "/prompt/render/\(encodedID)",
               jsonBody: body
           ),
           let rendered = try? decodePromptRenderResult(from: data) {
            return rendered
        }

        // Use the caller-provided source so previews reflect unsaved editor changes.
        return renderPromptTemplate(source, input: input)
    }

    func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String {
        if UITestSupport.isEnabled {
            return renderPromptTemplate("Write release notes for {props.version}.", input: input)
        }

        let encodedID = Self.encodedURLPathComponent(promptId)
        if let body = try? JSONEncoder().encode(["input": input]),
           let data = try? await httpRequestRaw(
               method: "POST",
               path: "/prompt/render/\(encodedID)",
               jsonBody: body
           ),
           let rendered = try? decodePromptRenderResult(from: data) {
            return rendered
        }

        if let prompt = try? getPromptFromFilesystem(promptId) {
            return renderPromptTemplate(prompt.source ?? "", input: input)
        }

        let inputJSON = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
        let data = try await exec("prompt", "render", promptId, "--input", inputJSON, "--format", "json")
        return try decodePromptRenderResult(from: data)
    }

    // MARK: - Timeline / Snapshots

    func listSnapshots(runId: String) async throws -> [Snapshot] {
        if UITestSupport.isEnabled {
            return [
                Snapshot(id: "ui-snapshot-run", runId: runId, nodeId: "prepare", label: "Before deploy", kind: "manual", parentId: nil, createdAtMs: UITestSupport.nowMs - 600_000),
            ]
        }

        let timelineData = try await exec("timeline", runId, "--json=true")
        let timeline = try decodeTimelineResponse(from: timelineData)
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
        let responseData = try await exec(
            "fork",
            workflowPath,
            "--run-id",
            ref.runId,
            "--frame",
            String(ref.frameNo),
            "--run=false",
            "--format",
            "json"
        )
        let response = try decodeForkRunResponse(from: responseData)
        return response.toRunSummary(workflowPath: workflowPath)
    }

    func replayRun(snapshotId: String) async throws -> RunSummary {
        if UITestSupport.isEnabled {
            return Self.makeUIRuns()[0]
        }

        let ref = try parseSnapshotRef(snapshotId)
        let workflowPath = try await resolveWorkflowPath(forSnapshotRef: ref)
        let responseData = try await exec(
            "replay",
            workflowPath,
            "--run-id",
            ref.runId,
            "--frame",
            String(ref.frameNo),
            "--restore-vcs=false",
            "--format",
            "json"
        )
        let response = try decodeForkRunResponse(from: responseData)
        return response.toRunSummary(workflowPath: workflowPath)
    }

    func diffSnapshots(fromId: String, toId: String) async throws -> SnapshotDiff {
        if UITestSupport.isEnabled {
            return SnapshotDiff(fromId: fromId, toId: toId, changes: ["Fixture diff"])
        }

        let diffData = try await exec("diff", fromId, toId, "--json=true")
        return try decodeSnapshotDiffResponse(from: diffData)
    }

    private func decodeTimelineResponse(from data: Data) throws -> Timeline {
        if let timeline = try? decodeCLIJSON(Timeline.self, from: data) {
            return timeline
        }
        if let wrapped = try? decodeCLIJSON(TimelineResponse.self, from: data) {
            return wrapped.timeline
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<TimelineResponse>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.timeline
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<TimelineResponse>.self, from: data) {
            return envelope.data.timeline
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<Timeline>.self, from: data),
           envelope.ok,
           let timeline = envelope.data {
            return timeline
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<Timeline>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON(Timeline.self, from: data)
    }

    private func decodeSnapshotDiffResponse(from data: Data) throws -> SnapshotDiff {
        if let diff = try? decodeCLIJSON(SnapshotDiff.self, from: data) {
            return diff
        }
        if let wrapped = try? decodeCLIJSON(SnapshotDiffResponse.self, from: data) {
            return wrapped.diff
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<SnapshotDiffResponse>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.diff
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<SnapshotDiffResponse>.self, from: data) {
            return envelope.data.diff
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<SnapshotDiff>.self, from: data),
           envelope.ok,
           let diff = envelope.data {
            return diff
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<SnapshotDiff>.self, from: data) {
            return envelope.data
        }
        return try decodeCLIJSON(SnapshotDiff.self, from: data)
    }

    private func decodeForkRunResponse(from data: Data) throws -> ForkRunResponse {
        if let response = try? decodeCLIJSON(ForkRunResponse.self, from: data) {
            return response
        }
        if let wrapped = try? decodeCLIJSON(APIEnvelope<ForkRunResponse>.self, from: data),
           wrapped.ok,
           let response = wrapped.data {
            return response
        }
        if let wrapped = try? decodeCLIJSON(DataEnvelope<ForkRunResponse>.self, from: data) {
            return wrapped.data
        }
        if let wrapped = try? decodeCLIJSON(ForkRunWrapper.self, from: data) {
            return wrapped.fork
        }
        if let wrapped = try? decodeCLIJSON(ReplayRunWrapper.self, from: data) {
            return wrapped.replay
        }
        return try decodeCLIJSON(ForkRunResponse.self, from: data)
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
        if let inspection = try? Self.decodeRunInspection(from: data, decoder: decoder),
           let workflow = inspection.run.workflowName?.trimmingCharacters(in: .whitespacesAndNewlines),
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
                    || workflow.filePath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == candidate } == true
            }), let path = workflow.filePath {
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
        guard Self.isSafeReadOnlySQL(trimmed) else {
            throw SmithersError.notAvailable(Self.noSQLTransportMessage)
        }

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

        if let dbPath = resolvedSmithersDBPath() {
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
        return try decodeCronSchedules(from: data)
    }

    private func decodeCronSchedules(from data: Data) throws -> [CronSchedule] {
        if let wrapped = try? decodeCLIJSON(CronResponse.self, from: data) {
            return wrapped.crons
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<CronResponse>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.crons
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<DataEnvelope<CronResponse>>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.data.crons
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<CronResponse>.self, from: data) {
            return envelope.data.crons
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<[CronSchedule]>.self, from: data),
           envelope.ok,
           let crons = envelope.data {
            return crons
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<DataEnvelope<[CronSchedule]>>.self, from: data),
           envelope.ok,
           let wrapped = envelope.data {
            return wrapped.data
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<[CronSchedule]>.self, from: data) {
            return envelope.data
        }
        if let single = try? decodeCLIJSON(CronSchedule.self, from: data) {
            return [single]
        }
        return try decodeCLIJSON([CronSchedule].self, from: data)
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

    private func applyConnectionState(serverReachable: Bool) {
        self.serverReachable = serverReachable

        if serverReachable {
            connectionTransport = .http
            isConnected = true
            return
        }

        if cliAvailable {
            connectionTransport = .cli
            isConnected = true
            return
        }

        connectionTransport = .none
        isConnected = false
    }

    /// Returns the smithers-orchestrator version string (e.g. "1.2.3"). Runs
     /// `bunx smithers-orchestrator --version` out-of-band of the standard CLI
     /// transport so we can surface the underlying engine version even when
     /// the `smithers` binary is a thin wrapper. Caches the result for the
     /// lifetime of the client.
    func getOrchestratorVersion() async -> String? {
        if let cached = cachedOrchestratorVersion {
            return cached
        }

        let resolved = await runOrchestratorVersionProbe()
        if let resolved {
            cachedOrchestratorVersion = resolved
            orchestratorVersion = resolved
            orchestratorVersionMeetsMinimum = Self.versionAtLeast(
                resolved,
                minimum: Self.minimumOrchestratorVersion
            )
        }
        return resolved
    }

    /// Returns `true` if `version` is greater than or equal to `minimum` under
    /// semver. Pre-release suffixes (e.g. `1.2.3-beta.1`) are stripped before
    /// comparison — a `0.16.0-rc.1` build is treated as `0.16.0` for gating.
    /// Returns `false` only when both inputs parse and `version` < `minimum`.
    /// Returns `true` if either input is unparseable, so we never block a user
    /// on a version string we don't understand.
    nonisolated static func versionAtLeast(_ version: String, minimum: String) -> Bool {
        guard let lhs = parseSemver(version), let rhs = parseSemver(minimum) else {
            return true
        }
        for (l, r) in zip(lhs, rhs) {
            if l != r { return l > r }
        }
        return true
    }

    nonisolated static func parseSemver(_ raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let core = withoutPrefix.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? withoutPrefix
        let parts = core.split(separator: ".").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var ints: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            ints.append(n)
        }
        while ints.count < 3 { ints.append(0) }
        return ints
    }

    private func runOrchestratorVersionProbe() async -> String? {
        let probes: [(executable: String, args: [String])] = [
            ("/usr/bin/env", ["bunx", "smithers-orchestrator", "--version"]),
            ("/usr/bin/env", ["smithers-orchestrator", "--version"]),
        ]

        for probe in probes {
            if let output = try? await runShellCapture(executable: probe.executable, args: probe.args, timeoutSeconds: 15),
               let version = Self.extractVersion(from: output) {
                return version
            }
        }
        return nil
    }

    private nonisolated func runShellCapture(
        executable: String,
        args: [String],
        timeoutSeconds: Double
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                throw SmithersError.cli("version probe timed out")
            }

            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }

    nonisolated static func extractVersion(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Grab the last whitespace-delimited token on the last non-empty line.
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let tokens = last.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens.last ?? last
    }

    private func probeCLIAvailability() async -> Bool {
        let probes: [[String]] = [
            ["version"],
            ["--version"],
        ]
        var lastError: Error?

        for args in probes {
            do {
                _ = try await execArgs(args)
                AppLogger.network.info("SmithersClient CLI available", metadata: [
                    "probe": args.joined(separator: " "),
                ])
                return true
            } catch {
                lastError = error
            }
        }

        AppLogger.network.warning("SmithersClient CLI not available", metadata: [
            "error": lastError?.localizedDescription ?? "unknown",
        ])
        return false
    }

    func checkConnection() async {
        AppLogger.network.info("SmithersClient checkConnection starting")
        if UITestSupport.isEnabled {
            cliAvailable = true
            applyConnectionState(serverReachable: false)
            return
        }

        cliAvailable = await probeCLIAvailability()
        if cliAvailable {
            _ = await getOrchestratorVersion()
        }

        let configuredServerURL = serverURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = configuredServerURL, !url.isEmpty else {
            applyConnectionState(serverReachable: false)
            return
        }

        // Check if a serve instance is running
        guard let healthURL = Self.resolvedHTTPTransportURL(path: "/health", serverURL: url) else {
            applyConnectionState(serverReachable: false)
            AppLogger.network.warning("SmithersClient health URL invalid", metadata: ["serverURL": url])
            return
        }

        let operationID = Self.makeOperationID(prefix: "health")
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let request = URLRequest(url: healthURL)
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            applyConnectionState(serverReachable: status == 200)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            AppLogger.network.info("SmithersClient health check complete", metadata: [
                "operation_id": operationID,
                "url": healthURL.absoluteString,
                "status": status.map(String.init) ?? "unknown",
                "connected": String(isConnected),
                "transport": connectionTransport.rawValue,
                "duration_ms": String(ms)
            ])
        } catch {
            applyConnectionState(serverReachable: false)
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            AppLogger.network.warning("SmithersClient health check failed", metadata: [
                "operation_id": operationID,
                "url": healthURL.absoluteString,
                "error": error.localizedDescription,
                "duration_ms": String(ms)
            ])
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

        if let approvals = try? await listPendingApprovalsOverHTTP() {
            return approvals
        }
        if let approvals = try? await listPendingApprovalsFromSQLite() {
            return approvals
        }
        if let approvals = try? await listPendingApprovalsOverExec() {
            return approvals
        }
        return try await listPendingApprovalsSynthetic()
    }

    func listRecentDecisions(limit: Int = 20) async throws -> [ApprovalDecision] {
        if UITestSupport.isEnabled {
            return Array(uiApprovalDecisions.prefix(limit))
        }

        let normalizedLimit = max(1, limit)
        if let decisions = try await listRecentDecisionsOverHTTP(limit: normalizedLimit) {
            return Array(decisions.prefix(normalizedLimit))
        }
        if let decisions = try await listRecentDecisionsFromSQLite(limit: normalizedLimit) {
            return Array(decisions.prefix(normalizedLimit))
        }
        if let decisions = try await listRecentDecisionsOverExec(limit: normalizedLimit) {
            return Array(decisions.prefix(normalizedLimit))
        }
        return []
    }

    private func listPendingApprovalsOverHTTP() async throws -> [Approval]? {
        guard resolvedHTTPTransportURL(path: "/approval/list") != nil else {
            return nil
        }
        guard let data = try? await httpRequestRaw(method: "GET", path: "/approval/list") else {
            return nil
        }
        return try decodeApprovalsTransportPayload(data, source: "http")
            .sorted { lhs, rhs in lhs.requestedAt > rhs.requestedAt }
    }

    private func listPendingApprovalsFromSQLite() async throws -> [Approval]? {
        guard let dbPath = resolvedSmithersDBPath() else {
            return nil
        }
        guard let data = try? await execSQLiteJSON(dbPath: dbPath, query: "SELECT * FROM _smithers_approvals") else {
            return nil
        }
        return try decodeApprovalsTransportPayload(data, source: "sqlite")
            .sorted { lhs, rhs in lhs.requestedAt > rhs.requestedAt }
    }

    private func listPendingApprovalsOverExec() async throws -> [Approval]? {
        for args in [
            ["approval", "list", "--format", "json"],
            ["approvals", "list", "--format", "json"],
        ] {
            guard let data = try? await execArgs(args) else {
                continue
            }
            return try decodeApprovalsTransportPayload(data, source: "exec")
                .sorted { lhs, rhs in lhs.requestedAt > rhs.requestedAt }
        }
        return nil
    }

    private func listPendingApprovalsSynthetic() async throws -> [Approval] {
        // Synthetic fallback for older setups that do not expose approval transport.
        // This path is clearly labeled via approval.source == "synthetic".
        let runs = try await listRuns()
        var approvals: [Approval] = []
        for run in runs where run.status == .waitingApproval {
            if let inspection = try? await inspectRun(run.runId) {
                for task in inspection.tasks where task.state == "blocked" || task.state == "waiting-approval" {
                    let approvalID = task.iteration.map { "\(run.runId):\(task.nodeId):\($0)" } ?? "\(run.runId):\(task.nodeId)"
                    approvals.append(
                        Approval(
                            id: approvalID,
                            runId: run.runId,
                            nodeId: task.nodeId,
                            iteration: task.iteration,
                            workflowPath: run.workflowPath,
                            gate: task.label,
                            status: "pending",
                            payload: nil,
                            requestedAt: run.startedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000),
                            resolvedAt: nil,
                            resolvedBy: nil,
                            source: "synthetic"
                        )
                    )
                }
            }
        }
        return approvals.sorted { lhs, rhs in lhs.requestedAt > rhs.requestedAt }
    }

    private func listRecentDecisionsOverHTTP(limit _: Int) async throws -> [ApprovalDecision]? {
        guard resolvedHTTPTransportURL(path: "/approval/decisions") != nil else {
            return nil
        }
        guard let data = try? await httpRequestRaw(method: "GET", path: "/approval/decisions") else {
            return nil
        }
        return try decodeApprovalDecisionsTransportPayload(data, source: "http")
            .sorted(by: Self.approvalDecisionSortOrder)
    }

    private func listRecentDecisionsFromSQLite(limit _: Int) async throws -> [ApprovalDecision]? {
        guard let dbPath = resolvedSmithersDBPath() else {
            return nil
        }
        guard let data = try? await execSQLiteJSON(dbPath: dbPath, query: "SELECT * FROM _smithers_approvals") else {
            return nil
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }
        let all = try decodeApprovalDecisionsTransportPayload(data, source: "sqlite")
        let resolved = all.filter { decision in
            let status = decision.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return status == "approved" || status == "denied"
        }
        return resolved.sorted(by: Self.approvalDecisionSortOrder)
    }

    private func listRecentDecisionsOverExec(limit: Int) async throws -> [ApprovalDecision]? {
        for args in [
            ["approval", "decisions", "--limit", "\(limit)", "--format", "json"],
            ["approval", "history", "--limit", "\(limit)", "--format", "json"],
        ] {
            guard let data = try? await execArgs(args) else {
                continue
            }
            let output = String(data: data, encoding: .utf8) ?? ""
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return []
            }
            return try decodeApprovalDecisionsTransportPayload(data, source: "exec")
                .sorted(by: Self.approvalDecisionSortOrder)
        }
        return nil
    }

    private func decodeApprovalsTransportPayload(_ data: Data, source: String) throws -> [Approval] {
        let decoded = try decodeApprovalPayloadCandidates(data) { payload in
            let unwrapped = try unwrapLegacyEnvelope(payload)

            if let direct = try? decoder.decode([Approval].self, from: unwrapped) {
                return direct.map { approval in
                    Approval(
                        id: approval.id,
                        runId: approval.runId,
                        nodeId: approval.nodeId,
                        iteration: approval.iteration,
                        workflowPath: approval.workflowPath,
                        gate: approval.gate,
                        status: Self.normalizedApprovalStatus(approval.status),
                        payload: approval.payload,
                        requestedAt: approval.requestedAt,
                        resolvedAt: approval.resolvedAt,
                        resolvedBy: approval.resolvedBy,
                        source: approval.source ?? source
                    )
                }
            }

            struct ApprovalListEnvelope: Decodable {
                let approvals: [Approval]?
                let items: [Approval]?
                let results: [Approval]?
                let data: [Approval]?
            }

            if let wrapped = try? decoder.decode(ApprovalListEnvelope.self, from: unwrapped) {
                let approvals = wrapped.approvals ?? wrapped.items ?? wrapped.results ?? wrapped.data ?? []
                return approvals.map { approval in
                    Approval(
                        id: approval.id,
                        runId: approval.runId,
                        nodeId: approval.nodeId,
                        iteration: approval.iteration,
                        workflowPath: approval.workflowPath,
                        gate: approval.gate,
                        status: Self.normalizedApprovalStatus(approval.status),
                        payload: approval.payload,
                        requestedAt: approval.requestedAt,
                        resolvedAt: approval.resolvedAt,
                        resolvedBy: approval.resolvedBy,
                        source: approval.source ?? source
                    )
                }
            }

            let rows = try approvalRowsFromJSONObjectData(unwrapped)
            return rows.enumerated().compactMap { index, row in
                approvalFromDictionary(row, source: source, fallbackIndex: index)
            }
        }
        return decoded
    }

    private func decodeApprovalDecisionsTransportPayload(_ data: Data, source: String) throws -> [ApprovalDecision] {
        let decoded = try decodeApprovalPayloadCandidates(data) { payload in
            let unwrapped = try unwrapLegacyEnvelope(payload)

            if let direct = try? decoder.decode([ApprovalDecision].self, from: unwrapped) {
                return direct.map { decision in
                    ApprovalDecision(
                        id: decision.id,
                        runId: decision.runId,
                        nodeId: decision.nodeId,
                        iteration: decision.iteration,
                        action: Self.normalizedApprovalStatus(decision.action),
                        note: decision.note,
                        reason: decision.reason,
                        resolvedAt: decision.resolvedAt,
                        resolvedBy: decision.resolvedBy,
                        workflowPath: decision.workflowPath,
                        gate: decision.gate,
                        payload: decision.payload,
                        requestedAt: decision.requestedAt,
                        source: decision.source ?? source
                    )
                }
            }

            struct ApprovalDecisionsEnvelope: Decodable {
                let decisions: [ApprovalDecision]?
                let approvals: [ApprovalDecision]?
                let items: [ApprovalDecision]?
                let results: [ApprovalDecision]?
                let data: [ApprovalDecision]?
            }

            if let wrapped = try? decoder.decode(ApprovalDecisionsEnvelope.self, from: unwrapped) {
                let decisions = wrapped.decisions ?? wrapped.approvals ?? wrapped.items ?? wrapped.results ?? wrapped.data ?? []
                return decisions.map { decision in
                    ApprovalDecision(
                        id: decision.id,
                        runId: decision.runId,
                        nodeId: decision.nodeId,
                        iteration: decision.iteration,
                        action: Self.normalizedApprovalStatus(decision.action),
                        note: decision.note,
                        reason: decision.reason,
                        resolvedAt: decision.resolvedAt,
                        resolvedBy: decision.resolvedBy,
                        workflowPath: decision.workflowPath,
                        gate: decision.gate,
                        payload: decision.payload,
                        requestedAt: decision.requestedAt,
                        source: decision.source ?? source
                    )
                }
            }

            let rows = try approvalRowsFromJSONObjectData(unwrapped)
            return rows.enumerated().compactMap { index, row in
                approvalDecisionFromDictionary(row, source: source, fallbackIndex: index)
            }
        }
        return decoded
    }

    private func decodeApprovalPayloadCandidates<T>(_ data: Data, decoder: (Data) throws -> [T]) throws -> [T] {
        let candidates = approvalJSONCandidates(from: data)
        var firstError: Error?

        for candidate in candidates {
            do {
                return try decoder(candidate)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        return try decoder(data)
    }

    private func approvalJSONCandidates(from data: Data) -> [Data] {
        let candidates = cliJSONPayloadCandidates(from: data)
        return candidates.isEmpty ? [data] : candidates
    }

    private func approvalRowsFromJSONObjectData(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let rows = approvalRows(from: object) {
            return rows
        }
        throw SmithersError.api("Unexpected approval response format")
    }

    private func approvalRows(from object: Any) -> [[String: Any]]? {
        if let rows = object as? [[String: Any]] {
            return rows
        }
        if let rows = object as? [Any] {
            let mapped = rows.compactMap { $0 as? [String: Any] }
            if mapped.count == rows.count {
                return mapped
            }
            return nil
        }
        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        if Self.isApprovalRowDictionary(dictionary) {
            return [dictionary]
        }

        for key in ["approvals", "decisions", "items", "results", "data"] {
            guard let nested = dictionary[key], !(nested is NSNull) else {
                continue
            }
            if let rows = approvalRows(from: nested) {
                return rows
            }
        }

        for (_, nested) in dictionary {
            if let rows = approvalRows(from: nested) {
                return rows
            }
        }

        return nil
    }

    private static func isApprovalRowDictionary(_ dictionary: [String: Any]) -> Bool {
        let keys = Set(dictionary.keys)
        let runKeyPresent = keys.contains("runId") || keys.contains("run_id")
        let nodeKeyPresent = keys.contains("nodeId") || keys.contains("node_id")
        return runKeyPresent && nodeKeyPresent
    }

    private func approvalFromDictionary(_ row: [String: Any], source: String, fallbackIndex: Int) -> Approval? {
        guard
            let runId = approvalString(from: row, keys: ["runId", "run_id"]),
            let nodeId = approvalString(from: row, keys: ["nodeId", "node_id"])
        else {
            return nil
        }

        let requestedAt = approvalInt64(from: row, keys: ["requestedAt", "requested_at", "requested_at_ms"])
            ?? Int64(Date().timeIntervalSince1970 * 1000)
        let resolvedAt = approvalInt64(from: row, keys: ["resolvedAt", "resolved_at", "decidedAt", "decided_at", "decided_at_ms"])
        let resolvedBy = approvalString(from: row, keys: ["resolvedBy", "resolved_by", "decidedBy", "decided_by"])
        let workflowPath = approvalString(from: row, keys: ["workflowPath", "workflow_path"])
        let gate = approvalString(from: row, keys: ["gate", "question", "label"])
        let iteration = approvalInt(from: row, keys: ["iteration", "attempt"])
        let status = Self.normalizedApprovalStatus(
            approvalString(from: row, keys: ["status", "decision", "action"])
        )
        let payload = approvalPayloadString(from: row, keys: ["payload", "context", "requestPayload"])
        let id = approvalString(from: row, keys: ["id"])
            ?? "\(runId):\(nodeId):\(fallbackIndex)"

        return Approval(
            id: id,
            runId: runId,
            nodeId: nodeId,
            iteration: iteration,
            workflowPath: workflowPath,
            gate: gate,
            status: status,
            payload: payload,
            requestedAt: requestedAt,
            resolvedAt: resolvedAt,
            resolvedBy: resolvedBy,
            source: source
        )
    }

    private func approvalDecisionFromDictionary(_ row: [String: Any], source: String, fallbackIndex: Int) -> ApprovalDecision? {
        guard
            let runId = approvalString(from: row, keys: ["runId", "run_id"]),
            let nodeId = approvalString(from: row, keys: ["nodeId", "node_id"])
        else {
            return nil
        }

        let action = Self.normalizedApprovalStatus(
            approvalString(from: row, keys: ["action", "decision", "status"])
        )
        let resolvedAt = approvalInt64(from: row, keys: ["resolvedAt", "resolved_at", "decidedAt", "decided_at", "decided_at_ms"])
        let requestedAt = approvalInt64(from: row, keys: ["requestedAt", "requested_at", "requested_at_ms"])
        let resolvedBy = approvalString(from: row, keys: ["resolvedBy", "resolved_by", "decidedBy", "decided_by"])
        let id = approvalString(from: row, keys: ["id"])
            ?? "decision-\(runId)-\(nodeId)-\(fallbackIndex)"
        let iteration = approvalInt(from: row, keys: ["iteration", "attempt"])

        return ApprovalDecision(
            id: id,
            runId: runId,
            nodeId: nodeId,
            iteration: iteration,
            action: action,
            note: approvalString(from: row, keys: ["note", "comment"]),
            reason: approvalString(from: row, keys: ["reason"]),
            resolvedAt: resolvedAt,
            resolvedBy: resolvedBy,
            workflowPath: approvalString(from: row, keys: ["workflowPath", "workflow_path"]),
            gate: approvalString(from: row, keys: ["gate", "question", "label"]),
            payload: approvalPayloadString(from: row, keys: ["payload", "context", "requestPayload"]),
            requestedAt: requestedAt,
            source: source
        )
    }

    private func approvalString(from row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else {
                continue
            }
            guard let parsed = Self.searchString(value)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !parsed.isEmpty else {
                continue
            }
            return parsed
        }
        return nil
    }

    private func approvalInt64(from row: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else {
                continue
            }
            if let parsed = int64Value(from: value) {
                return parsed
            }
        }
        return nil
    }

    private func approvalInt(from row: [String: Any], keys: [String]) -> Int? {
        guard let value = approvalInt64(from: row, keys: keys) else {
            return nil
        }
        return Int(exactly: value)
    }

    private func approvalPayloadString(from row: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else {
                continue
            }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                continue
            }
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: []),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            if let scalar = Self.searchString(value),
               !scalar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return scalar
            }
        }
        return nil
    }

    private nonisolated static func normalizedApprovalStatus(_ rawStatus: String?) -> String {
        let normalized = rawStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "pending"
        switch normalized {
        case "approve", "approved":
            return "approved"
        case "deny", "denied":
            return "denied"
        case "waiting-approval", "waiting", "blocked":
            return "pending"
        case "":
            return "pending"
        default:
            return normalized
        }
    }

    private nonisolated static func approvalDecisionSortOrder(lhs: ApprovalDecision, rhs: ApprovalDecision) -> Bool {
        let lhsResolved = lhs.resolvedAt ?? lhs.requestedAt ?? 0
        let rhsResolved = rhs.resolvedAt ?? rhs.requestedAt ?? 0
        if lhsResolved != rhsResolved {
            return lhsResolved > rhsResolved
        }
        return lhs.id < rhs.id
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
                createdAt: DateFormatters.iso8601InternetDateTime.string(from: Date()),
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
        if let wrapped = try? decoder.decode(DataEnvelope<IssueListResponse>.self, from: payload),
           let issues = wrapped.data.issues {
            return issues
        }
        if let wrapped = try? decoder.decode(IssueListResponse.self, from: payload),
           let issues = wrapped.issues {
            return issues
        }
        if let wrapped = try? decoder.decode(APIEnvelope<[SmithersIssue]>.self, from: payload),
           let issues = wrapped.data {
            return issues
        }
        if let wrapped = try? decoder.decode(APIEnvelope<IssueListResponse>.self, from: payload),
           let issues = wrapped.data?.issues {
            return issues
        }
        if let bare = try? decoder.decode([SmithersIssue].self, from: payload) {
            return bare
        }

        let snippet = String(decoding: payload.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse issues: unsupported JSON response \(snippet)")
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

    func closeIssue(number: Int, comment: String?) async throws -> SmithersIssue {
        if UITestSupport.isEnabled {
            guard let index = uiIssues.firstIndex(where: { $0.number == number }) else {
                throw SmithersError.notFound
            }
            let issue = uiIssues[index]
            let updated = SmithersIssue(id: issue.id, number: issue.number, title: issue.title, body: issue.body, state: "closed", labels: issue.labels, assignees: issue.assignees, commentCount: issue.commentCount)
            uiIssues[index] = updated
            return updated
        }

        var args = ["issue", "close", "\(number)"]
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["-c", comment]
        }
        let data = try await execJJHubJSONArgs(args)
        if let issue = try? decodeIssue(data) {
            return issue
        }
        return try await getIssue(number: number)
    }

    func reopenIssue(number: Int) async throws -> SmithersIssue {
        if UITestSupport.isEnabled {
            guard let index = uiIssues.firstIndex(where: { $0.number == number }) else {
                throw SmithersError.notFound
            }
            let issue = uiIssues[index]
            let updated = SmithersIssue(id: issue.id, number: issue.number, title: issue.title, body: issue.body, state: "open", labels: issue.labels, assignees: issue.assignees, commentCount: issue.commentCount)
            uiIssues[index] = updated
            return updated
        }

        let data = try await execJJHubJSONArgs(["issue", "reopen", "\(number)"])
        if let issue = try? decodeIssue(data) {
            return issue
        }
        return try await getIssue(number: number)
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
        let payload = try unwrapLegacyEnvelope(data)
        if let direct = try? decodeCLIJSON(Workspace.self, from: payload) {
            return direct
        }
        if let wrapped = try? decodeCLIJSON(WorkspaceResponse.self, from: payload),
           let workspace = wrapped.workspace ?? wrapped.item ?? wrapped.data {
            return workspace
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<Workspace>.self, from: payload),
           let workspace = envelope.data {
            return workspace
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<Workspace>.self, from: payload) {
            return envelope.data
        }
        let snippet = String(decoding: payload.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaces(from data: Data) throws -> [Workspace] {
        let payload = try unwrapLegacyEnvelope(data)
        if let direct = try? decodeCLIJSON([Workspace].self, from: payload) {
            return direct
        }
        if let wrapped = try? decodeCLIJSON(WorkspacesResponse.self, from: payload),
           let workspaces = wrapped.workspaces ?? wrapped.items ?? wrapped.results ?? wrapped.data {
            return workspaces
        }
        if let wrapped = try? decodeCLIJSON(WorkspaceResponse.self, from: payload),
           let workspace = wrapped.workspace ?? wrapped.item ?? wrapped.data {
            return [workspace]
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<[Workspace]>.self, from: payload),
           let workspaces = envelope.data {
            return workspaces
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<[Workspace]>.self, from: payload) {
            return envelope.data
        }
        let snippet = String(decoding: payload.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspaces: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaceSnapshot(from data: Data) throws -> WorkspaceSnapshot {
        let payload = try unwrapLegacyEnvelope(data)
        if let direct = try? decodeCLIJSON(WorkspaceSnapshot.self, from: payload) {
            return direct
        }
        if let wrapped = try? decodeCLIJSON(WorkspaceSnapshotResponse.self, from: payload),
           let snapshot = wrapped.snapshot ?? wrapped.item ?? wrapped.data {
            return snapshot
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<WorkspaceSnapshot>.self, from: payload),
           let snapshot = envelope.data {
            return snapshot
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<WorkspaceSnapshot>.self, from: payload) {
            return envelope.data
        }
        let snippet = String(decoding: payload.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace snapshot: unsupported JSON response \(snippet)")
    }

    private func decodeWorkspaceSnapshots(from data: Data) throws -> [WorkspaceSnapshot] {
        let payload = try unwrapLegacyEnvelope(data)
        if let direct = try? decodeCLIJSON([WorkspaceSnapshot].self, from: payload) {
            return direct
        }
        if let wrapped = try? decodeCLIJSON(WorkspaceSnapshotsResponse.self, from: payload),
           let snapshots = wrapped.snapshots ?? wrapped.items ?? wrapped.results ?? wrapped.data {
            return snapshots
        }
        if let wrapped = try? decodeCLIJSON(WorkspaceSnapshotResponse.self, from: payload),
           let snapshot = wrapped.snapshot ?? wrapped.item ?? wrapped.data {
            return [snapshot]
        }
        if let envelope = try? decodeCLIJSON(APIEnvelope<[WorkspaceSnapshot]>.self, from: payload),
           let snapshots = envelope.data {
            return snapshots
        }
        if let envelope = try? decodeCLIJSON(DataEnvelope<[WorkspaceSnapshot]>.self, from: payload) {
            return envelope.data
        }
        let snippet = String(decoding: payload.prefix(200), as: UTF8.self)
        throw SmithersError.api("parse workspace snapshots: unsupported JSON response \(snippet)")
    }

    func search(query: String, scope: SearchScope, issueState: String? = nil, limit: Int = 20) async throws -> [SearchResult] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw SmithersError.api("query must not be empty")
        }

        if UITestSupport.isEnabled {
            return try await uiSearchResults(query: trimmedQuery, scope: scope, issueState: issueState)
        }

        do {
            let cliData = try await executeJJHubSearchCLI(query: trimmedQuery, scope: scope, issueState: issueState, limit: limit)
            return try Self.decodeSearchResults(cliData, scope: scope)
        } catch {
            guard Self.shouldFallbackToJJHubSearchAPI(error) else {
                throw error
            }

            let apiData = try await executeJJHubSearchAPI(query: trimmedQuery, scope: scope, issueState: issueState, limit: limit)
            return try Self.decodeSearchResults(apiData, scope: scope)
        }
    }

    func searchCode(query: String, limit: Int = 20) async throws -> [SearchResult] {
        try await search(query: query, scope: .code, limit: limit)
    }

    func searchIssues(query: String, state: String? = nil, limit: Int = 20) async throws -> [SearchResult] {
        try await search(query: query, scope: .issues, issueState: state, limit: limit)
    }

    func searchRepos(query: String, limit: Int = 20) async throws -> [SearchResult] {
        try await search(query: query, scope: .repos, limit: limit)
    }

    private func uiSearchResults(query: String, scope: SearchScope, issueState: String?) async throws -> [SearchResult] {
        switch scope {
        case .code:
            return [
                SearchResult(
                    id: "code-1",
                    title: "ContentView.swift",
                    description: "SwiftUI root view",
                    snippet: "ContentView launches \(query)",
                    filePath: "ContentView.swift",
                    lineNumber: 1,
                    kind: SearchScope.code.resultKind
                )
            ]
        case .issues:
            return try await listIssues(state: issueState).map {
                SearchResult(
                    id: $0.id,
                    title: $0.title,
                    description: $0.body,
                    snippet: nil,
                    filePath: nil,
                    lineNumber: nil,
                    kind: SearchScope.issues.resultKind
                )
            }
        case .repos:
            return [
                SearchResult(
                    id: "repo-1",
                    title: "smithers/gui",
                    description: "Fixture repository for \(query)",
                    snippet: nil,
                    filePath: nil,
                    lineNumber: nil,
                    kind: SearchScope.repos.resultKind
                )
            ]
        }
    }

    private func executeJJHubSearchCLI(query: String, scope: SearchScope, issueState: String?, limit: Int) async throws -> Data {
        var args = ["search", scope.rawValue, query, "--limit", "\(limit)"]
        if scope == .issues, let issueState = normalizedIssueSearchState(issueState) {
            args += ["--state", issueState]
        }
        return try await execJJHubJSONArgs(args)
    }

    private func executeJJHubSearchAPI(query: String, scope: SearchScope, issueState: String?, limit: Int) async throws -> Data {
        var components = URLComponents()
        components.path = Self.jjhubSearchAPIPath(for: scope)
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        if scope == .issues, let issueState = normalizedIssueSearchState(issueState) {
            queryItems.append(URLQueryItem(name: "state", value: issueState))
        }
        components.queryItems = queryItems
        guard let endpoint = components.string else {
            throw SmithersError.api("failed to build search endpoint")
        }
        return try await execJJHubJSONArgs(["api", endpoint])
    }

    private func normalizedIssueSearchState(_ state: String?) -> String? {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines),
              !state.isEmpty,
              state.caseInsensitiveCompare("all") != .orderedSame else {
            return nil
        }
        return state
    }

    private static func jjhubSearchAPIPath(for scope: SearchScope) -> String {
        switch scope {
        case .code:
            return "/search/code"
        case .issues:
            return "/search/issues"
        case .repos:
            return "/search/repositories"
        }
    }

    private static func shouldFallbackToJJHubSearchAPI(_ error: Error) -> Bool {
        guard case let SmithersError.cli(message) = error else {
            return false
        }
        let lowercased = message.lowercased()
        return lowercased.contains("unknown command")
            || lowercased.contains("no such command")
            || lowercased.contains("unexpected command")
            || lowercased.contains("unrecognized")
    }

    private static func decodeSearchResults(_ data: Data, scope: SearchScope) throws -> [SearchResult] {
        switch scope {
        case .code:
            return try decodeCodeSearchResults(data)
        case .issues:
            return try decodeIssueSearchResults(data)
        case .repos:
            return try decodeRepositorySearchResults(data)
        }
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

            let snippetRanges = matches
                .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { SearchSnippetRange(content: $0.content, startLine: $0.lineNumber) }
            let snippet = snippetRanges
                .map(\.content)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
                .nilIfEmpty
            let lineNumber = snippetRanges.first { $0.startLine != nil }?.startLine
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
                kind: "code",
                snippetRanges: snippetRanges.isEmpty ? nil : snippetRanges
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
        let encoded = Self.encodedURLPathComponent(tableName)
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

        let operationID = Self.makeOperationID(prefix: "http")
        AppLogger.network.debug("HTTP \(method) \(path) start", metadata: [
            "operation_id": operationID,
            "url": url.absoluteString,
            "body_bytes": String(jsonBody?.count ?? 0)
        ])
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let jsonBody {
            request.httpBody = jsonBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let start = CFAbsoluteTimeGetCurrent()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            AppLogger.network.error("HTTP \(method) \(path) failed", metadata: [
                "operation_id": operationID,
                "error": error.localizedDescription,
                "duration_ms": String(ms)
            ])
            throw SmithersError.api(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            AppLogger.network.error("HTTP \(method) \(path) invalid response", metadata: [
                "operation_id": operationID,
                "duration_ms": String(ms),
                "bytes": String(data.count)
            ])
            throw SmithersError.api("Invalid HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let serverMessage = extractServerErrorMessage(data)
            AppLogger.network.warning("HTTP \(method) \(path) non-2xx", metadata: [
                "operation_id": operationID,
                "status": String(http.statusCode),
                "duration_ms": String(ms),
                "bytes": String(data.count),
                "server_error": serverMessage ?? ""
            ])
            switch http.statusCode {
            case 401:
                throw SmithersError.unauthorized
            case 404:
                throw SmithersError.notFound
            default:
                if let message = serverMessage, !message.isEmpty {
                    throw SmithersError.api(message)
                }
                throw SmithersError.httpError(http.statusCode)
            }
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        AppLogger.network.debug("HTTP \(method) \(path) ok", metadata: [
            "operation_id": operationID,
            "status": String(http.statusCode),
            "duration_ms": String(ms),
            "bytes": String(data.count)
        ])
        return data
    }

    private func unwrapLegacyEnvelope(_ data: Data) throws -> Data {
        let candidates = cliJSONPayloadCandidates(from: data)
        guard !candidates.isEmpty else {
            return data
        }

        let fallbackCandidate = candidates.first(where: { candidate in
            guard let text = String(data: candidate, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let first = text.first else {
                return false
            }
            return first == "{" || first == "["
        }) ?? data

        for candidate in candidates {
            guard
                let rootAny = try? JSONSerialization.jsonObject(with: candidate, options: [.fragmentsAllowed]),
                let root = rootAny as? [String: Any],
                root["ok"] != nil
            else {
                continue
            }

            let ok = (root["ok"] as? Bool) ?? false
            if !ok {
                let message = (root["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SmithersError.api((message?.isEmpty == false ? message : nil) ?? "Smithers API error")
            }

            let payload = root["data"] ?? NSNull()
            return try JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        }

        return fallbackCandidate
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

    private func doubleValue(from value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
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
        let encodedRunId = Self.encodedURLPathComponent(runId)
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

    private func getChatOutputCLI(_ args: [String], timeoutSeconds: Double = 30) async throws -> [ChatBlock] {
        let data = try await execBinaryArgs(bin: smithersBin, args: args, displayName: "smithers", timeoutSeconds: timeoutSeconds)
        return try decodeChatBlocks(from: data)
    }

    private func decodeChatBlocks(from data: Data) throws -> [ChatBlock] {
        let dataSize = data.count
        AppLogger.network.debug("decodeChatBlocks", metadata: ["bytes": "\(dataSize)"])

        if let direct = try? decoder.decode([ChatBlock].self, from: data) {
            AppLogger.network.debug("decodeChatBlocks matched: [ChatBlock]")
            return deduplicatedChatBlocks(direct)
        }
        if let wrapped = try? decoder.decode(ChatBlocksResponse.self, from: data) {
            AppLogger.network.debug("decodeChatBlocks matched: ChatBlocksResponse")
            return deduplicatedChatBlocks(wrapped.blocks)
        }
        if let envelope = try? decoder.decode(APIEnvelope<[ChatBlock]>.self, from: data),
           envelope.ok,
           let payload = envelope.data {
            AppLogger.network.debug("decodeChatBlocks matched: APIEnvelope")
            return deduplicatedChatBlocks(payload)
        }
        if let envelope = try? decoder.decode(DataEnvelope<[ChatBlock]>.self, from: data) {
            AppLogger.network.debug("decodeChatBlocks matched: DataEnvelope")
            return deduplicatedChatBlocks(envelope.data)
        }
        if let lineMap = try? decoder.decode([String: String].self, from: data) {
            AppLogger.network.debug("decodeChatBlocks matched: [String: String]", metadata: ["keys": "\(lineMap.count)"])
            let parsed = parseLegacyChatMap(lineMap)
            AppLogger.network.debug("decodeChatBlocks parseLegacyChatMap", metadata: ["blocks": "\(parsed.count)"])
            if !parsed.isEmpty {
                return deduplicatedChatBlocks(parsed)
            }
        }

        // Handle JSON array of strings (["line0", "line1", ...])
        if let lineArray = try? decoder.decode([String].self, from: data) {
            var lineMap: [String: String] = [:]
            for (i, line) in lineArray.enumerated() {
                lineMap[String(i)] = line
            }
            let parsed = parseLegacyChatMap(lineMap)
            if !parsed.isEmpty {
                return deduplicatedChatBlocks(parsed)
            }
        }

        // Fallback: use JSONSerialization for mixed-type dictionaries or arrays
        if let jsonObj = try? JSONSerialization.jsonObject(with: data) {
            var lineMap: [String: String] = [:]
            if let dict = jsonObj as? [String: Any] {
                for (key, value) in dict {
                    if let str = value as? String {
                        lineMap[key] = str
                    } else {
                        lineMap[key] = String(describing: value)
                    }
                }
            } else if let arr = jsonObj as? [Any] {
                for (i, value) in arr.enumerated() {
                    if let str = value as? String {
                        lineMap[String(i)] = str
                    } else {
                        lineMap[String(i)] = String(describing: value)
                    }
                }
            }
            let parsed = parseLegacyChatMap(lineMap)
            if !parsed.isEmpty {
                return deduplicatedChatBlocks(parsed)
            }
        }

        // Try regex-based extraction for JSON-like text that JSONSerialization couldn't parse
        // (handles encoding issues, trailing commas, BOM, or non-JSON preamble before the JSON body)
        let rawText = String(decoding: data, as: UTF8.self)
        let rawTrimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrimmed.hasPrefix("{") || rawTrimmed.hasPrefix("[") {
            let kvPattern = #"\"(\d+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""#
            if let kvRegex = try? NSRegularExpression(pattern: kvPattern, options: [.dotMatchesLineSeparators]) {
                let matches = kvRegex.matches(in: rawTrimmed, range: NSRange(location: 0, length: (rawTrimmed as NSString).length))
                if !matches.isEmpty {
                    var lineMap: [String: String] = [:]
                    let ns = rawTrimmed as NSString
                    for match in matches {
                        let key = ns.substring(with: match.range(at: 1))
                        let rawValue = ns.substring(with: match.range(at: 2))
                        lineMap[key] = Self.unescapeJSONStringValue(rawValue)
                    }
                    AppLogger.network.debug("decodeChatBlocks matched: regex JSON extraction", metadata: ["keys": "\(lineMap.count)"])
                    let parsed = parseLegacyChatMap(lineMap)
                    if !parsed.isEmpty {
                        return deduplicatedChatBlocks(parsed)
                    }
                }
            }
        }

        // Last resort: treat the raw data as newline-delimited text
        let rawLines = rawText.components(separatedBy: .newlines)
        if !rawLines.isEmpty {
            var lineMap: [String: String] = [:]
            for (i, line) in rawLines.enumerated() {
                lineMap[String(i)] = line
            }
            let parsed = parseLegacyChatMap(lineMap)
            if !parsed.isEmpty {
                return deduplicatedChatBlocks(parsed)
            }
        }

        // Absolute fallback: return raw text as a single system block
        if !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [ChatBlock(
                id: "raw-fallback",
                runId: nil,
                nodeId: nil,
                attempt: 0,
                role: "system",
                content: rawText,
                timestampMs: nil
            )]
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
        // Primary: nodeId may contain colons — use #\d+: as the boundary
        let rowWithAttemptPattern = #"^\[[^\]]+\]\s+(\S+)\s+(.+)#(\d+):\s*(.*)$"#
        // Fallback for lines without #attempt suffix
        let rowFallbackPattern = #"^\[[^\]]+\]\s+(\S+)\s+(.+?):\s*(.*)$"#
        let headerRegex = try? NSRegularExpression(pattern: headerPattern)
        let rowWithAttemptRegex = try? NSRegularExpression(pattern: rowWithAttemptPattern, options: [.dotMatchesLineSeparators])
        let rowFallbackRegex = try? NSRegularExpression(pattern: rowFallbackPattern, options: [.dotMatchesLineSeparators])

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

            // Try primary pattern first (handles nodeIds with colons like "ticket:implement#1: content")
            if let rowWithAttemptRegex,
               let match = rowWithAttemptRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let ns = line as NSString
                let rawRole = ns.substring(with: match.range(at: 1))
                let nodeToken = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let attemptText = ns.substring(with: match.range(at: 3))
                let message = ns.substring(with: match.range(at: 4))

                var attempt = currentAttempt
                if let oneBasedAttempt = Int(attemptText) {
                    attempt = max(0, oneBasedAttempt - 1)
                }

                blocks.append(
                    ChatBlock(
                        id: "legacy-\(index)",
                        runId: nil,
                        nodeId: nodeToken.isEmpty ? currentNodeId : nodeToken,
                        attempt: attempt,
                        role: normalizeChatRole(rawRole),
                        content: message.isEmpty ? line : message,
                        timestampMs: nil
                    )
                )
            } else if let rowFallbackRegex,
               let match = rowFallbackRegex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
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

    private static func unescapeJSONStringValue(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\\" {
                let next = s.index(after: i)
                if next < s.endIndex {
                    switch s[next] {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "r": result.append("\r")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    case "/": result.append("/")
                    default:
                        result.append(s[i])
                        result.append(s[next])
                    }
                    i = s.index(next, offsetBy: 1)
                } else {
                    result.append(s[i])
                    i = next
                }
            } else {
                result.append(s[i])
                i = s.index(after: i)
            }
        }
        return result
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
        let encodedRunId = Self.encodedURLPathComponent(runId)
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
            AppLogger.network.debug("SSE stream unavailable")
            continuation.finish()
        }
    }

    private struct ParsedSSEEvent {
        let event: String?
        let data: String
        let runId: String?
    }

    private struct SSECandidateURL {
        let url: URL
        let requireAttributedRunId: Bool
    }

    private struct SSEParser {
        private var eventType: String?
        private var dataLines: [String] = []
        private var runId: String?

        mutating func consume(_ rawLine: String) -> ParsedSSEEvent? {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine

            if line.isEmpty {
                return dispatch()
            }

            guard !line.hasPrefix(":") else {
                return nil
            }

            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0])
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.first == " " {
                value.removeFirst()
            }

            switch field {
            case "event":
                eventType = value
            case "data":
                dataLines.append(value)
            case "runId", "run_id", "workflowRunId", "workflow_run_id":
                runId = SSEEvent.normalizedRunId(value)
            case "id", "retry":
                break
            default:
                break
            }

            return nil
        }

        mutating func finish() -> ParsedSSEEvent? {
            dispatch()
        }

        private mutating func dispatch() -> ParsedSSEEvent? {
            defer {
                eventType = nil
                dataLines.removeAll(keepingCapacity: true)
                runId = nil
            }

            guard !dataLines.isEmpty else {
                return nil
            }

            let event = eventType?.isEmpty == true ? nil : eventType
            return ParsedSSEEvent(event: event, data: dataLines.joined(separator: "\n"), runId: runId)
        }
    }

    private func sseStream(url: URL, runId: String?, requireAttributedRunId: Bool = false) -> AsyncStream<SSEEvent> {
        let candidate = SSECandidateURL(url: url, requireAttributedRunId: requireAttributedRunId)
        return sseStream(candidates: [candidate], runId: runId)
    }

    private func sseStream(urls: [URL], runId: String?, requireAttributedRunId: Bool = false) -> AsyncStream<SSEEvent> {
        let candidates = urls.map { SSECandidateURL(url: $0, requireAttributedRunId: requireAttributedRunId) }
        return sseStream(candidates: candidates, runId: runId)
    }

    private func sseStream(candidates: [SSECandidateURL], runId: String?) -> AsyncStream<SSEEvent> {
        return AsyncStream { continuation in
            let streamID = Self.makeOperationID(prefix: "sse")
            let task = Task.detached { [streamSession] in
                guard !candidates.isEmpty else {
                    AppLogger.network.warning("SSE stream has no candidate URLs", metadata: [
                        "stream_id": streamID,
                        "run_id": runId ?? ""
                    ])
                    continuation.finish()
                    return
                }

                let streamStart = CFAbsoluteTimeGetCurrent()
                var yieldedEvents = 0
                var filteredEvents = 0

                for (index, candidate) in candidates.enumerated() {
                    if Task.isCancelled {
                        let ms = Int((CFAbsoluteTimeGetCurrent() - streamStart) * 1000)
                        AppLogger.network.debug("SSE stream cancelled", metadata: [
                            "stream_id": streamID,
                            "run_id": runId ?? "",
                            "events": String(yieldedEvents),
                            "filtered_events": String(filteredEvents),
                            "duration_ms": String(ms)
                        ])
                        continuation.finish()
                        return
                    }

                    let url = candidate.url
                    var request = URLRequest(url: url)
                    request.timeoutInterval = .infinity
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

                    let attemptStart = CFAbsoluteTimeGetCurrent()
                    AppLogger.network.info("SSE connect", metadata: [
                        "stream_id": streamID,
                        "run_id": runId ?? "",
                        "attempt": String(index + 1),
                        "attempts": String(candidates.count),
                        "url": url.absoluteString
                    ])

                    do {
                        let (bytes, response) = try await streamSession.bytes(for: request)
                        guard let http = response as? HTTPURLResponse else {
                            let ms = Int((CFAbsoluteTimeGetCurrent() - attemptStart) * 1000)
                            AppLogger.network.warning("SSE invalid response", metadata: [
                                "stream_id": streamID,
                                "run_id": runId ?? "",
                                "attempt": String(index + 1),
                                "duration_ms": String(ms)
                            ])
                            if index == candidates.count - 1 {
                                continuation.finish()
                            }
                            continue
                        }
                        guard http.statusCode == 200 else {
                            let ms = Int((CFAbsoluteTimeGetCurrent() - attemptStart) * 1000)
                            AppLogger.network.warning("SSE non-200", metadata: [
                                "stream_id": streamID,
                                "run_id": runId ?? "",
                                "attempt": String(index + 1),
                                "status": String(http.statusCode),
                                "duration_ms": String(ms)
                            ])
                            if index == candidates.count - 1 {
                                continuation.finish()
                            }
                            continue
                        }

                        AppLogger.network.info("SSE connected", metadata: [
                            "stream_id": streamID,
                            "run_id": runId ?? "",
                            "attempt": String(index + 1),
                            "status": String(http.statusCode)
                        ])

                        var parser = SSEParser()

                        func emit(_ parsed: ParsedSSEEvent) {
                            if let event = SSEEvent.filtered(
                                event: parsed.event,
                                data: parsed.data,
                                eventRunId: parsed.runId,
                                expectedRunId: runId,
                                requireAttributedRunId: candidate.requireAttributedRunId
                            ) {
                                yieldedEvents += 1
                                continuation.yield(event)
                            } else {
                                filteredEvents += 1
                            }
                        }

                        for try await line in bytes.lines {
                            if let parsed = parser.consume(line) {
                                emit(parsed)
                            }
                        }

                        if let parsed = parser.finish() {
                            emit(parsed)
                        }
                        let ms = Int((CFAbsoluteTimeGetCurrent() - streamStart) * 1000)
                        AppLogger.network.info("SSE finished", metadata: [
                            "stream_id": streamID,
                            "run_id": runId ?? "",
                            "events": String(yieldedEvents),
                            "filtered_events": String(filteredEvents),
                            "duration_ms": String(ms)
                        ])
                        continuation.finish()
                        return
                    } catch {
                        let ms = Int((CFAbsoluteTimeGetCurrent() - attemptStart) * 1000)
                        AppLogger.network.warning("SSE failed", metadata: [
                            "stream_id": streamID,
                            "run_id": runId ?? "",
                            "attempt": String(index + 1),
                            "error": error.localizedDescription,
                            "duration_ms": String(ms)
                        ])
                        if index == candidates.count - 1 {
                            let totalMs = Int((CFAbsoluteTimeGetCurrent() - streamStart) * 1000)
                            AppLogger.network.info("SSE exhausted candidates", metadata: [
                                "stream_id": streamID,
                                "run_id": runId ?? "",
                                "events": String(yieldedEvents),
                                "filtered_events": String(filteredEvents),
                                "duration_ms": String(totalMs)
                            ])
                            continuation.finish()
                        }
                    }
                }
            }
            continuation.onTermination = { termination in
                AppLogger.network.debug("SSE termination requested", metadata: [
                    "stream_id": streamID,
                    "run_id": runId ?? "",
                    "termination": "\(termination)"
                ])
                task.cancel()
            }
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

private struct ForkRunResponse: Decodable {
    let forkedRunId: String
    let parentRunId: String?
    let parentFrame: Int?
    let started: Bool?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case forkedRunId
        case forkedRunIdSnake = "forked_run_id"
        case runId
        case runIdSnake = "run_id"
        case parentRunId
        case parentRunIdSnake = "parent_run_id"
        case parentFrame
        case parentFrameSnake = "parent_frame"
        case started
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let forkedRunId = try container.decodeIfPresent(String.self, forKey: .forkedRunId)
            ?? container.decodeIfPresent(String.self, forKey: .forkedRunIdSnake)
            ?? container.decodeIfPresent(String.self, forKey: .runId)
            ?? container.decodeIfPresent(String.self, forKey: .runIdSnake) {
            self.forkedRunId = forkedRunId
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.forkedRunId,
                .init(codingPath: decoder.codingPath, debugDescription: "Missing forked run identifier")
            )
        }
        self.parentRunId = try container.decodeIfPresent(String.self, forKey: .parentRunId)
            ?? container.decodeIfPresent(String.self, forKey: .parentRunIdSnake)
        let parentFrameValue = try container.decodeIfPresent(Int.self, forKey: .parentFrame)
            ?? container.decodeIfPresent(Int.self, forKey: .parentFrameSnake)
        let parentFrameString = try container.decodeIfPresent(String.self, forKey: .parentFrame)
            ?? container.decodeIfPresent(String.self, forKey: .parentFrameSnake)
        self.parentFrame = parentFrameValue ?? parentFrameString.flatMap(Int.init)
        self.started = try container.decodeIfPresent(Bool.self, forKey: .started)
        self.status = try container.decodeIfPresent(String.self, forKey: .status)
    }

    func toRunSummary(workflowPath: String?) -> RunSummary {
        RunSummary(
            runId: forkedRunId,
            workflowName: nil,
            workflowPath: workflowPath,
            status: normalizeCLIRunStatus(status),
            startedAtMs: nil,
            finishedAtMs: nil,
            summary: nil,
            errorJson: nil
        )
    }
}

private struct ForkRunWrapper: Decodable {
    let fork: ForkRunResponse
}

private struct ReplayRunWrapper: Decodable {
    let replay: ForkRunResponse
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
        case startedAt
        case startedAtSnake = "started_at"
        case startedAtMs
        case startedAtMsSnake = "started_at_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.workflow = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .workflow))
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? RunStatus.unknown.rawValue
        self.step = normalizeCLIString(try container.decodeIfPresent(String.self, forKey: .step))
        self.started = try container.decodeIfPresent(String.self, forKey: .started)
            ?? container.decodeIfPresent(String.self, forKey: .startedAt)
            ?? container.decodeIfPresent(String.self, forKey: .startedAtSnake)
        self.startedAtMs = decodeCLIInt64(container, forKey: .startedAtMs)
            ?? decodeCLIInt64(container, forKey: .startedAtMsSnake)
            ?? decodeCLIInt64(container, forKey: .startedAt)
            ?? decodeCLIInt64(container, forKey: .startedAtSnake)
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

    if let date = DateFormatters.parseISO8601InternetDateTime(raw) {
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    if let relativeMs = DateFormatters.parseRelativeAgoTimestampMs(raw) {
        return relativeMs
    }

    return nil
}

private func normalizeCLIRunStatus(_ status: String?) -> RunStatus {
    RunStatus.normalized(status)
}

private func makeRunTaskSummary(_ tasks: [RunTask]) -> [String: Int] {
    var summary = ["total": tasks.count]
    for task in tasks {
        summary[task.state, default: 0] += 1
    }
    return summary
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
    let issuesList: [SmithersIssue]?
    let items: [SmithersIssue]?
    let results: [SmithersIssue]?
    let data: [SmithersIssue]?

    enum CodingKeys: String, CodingKey {
        case issuesList = "issues"
        case items
        case results
        case data
    }

    var issues: [SmithersIssue]? {
        issuesList ?? items ?? results ?? data
    }
}
private struct WorkspaceResponse: Decodable {
    let workspace: Workspace?
    let item: Workspace?
    let data: Workspace?
}
private struct WorkspacesResponse: Decodable {
    let workspaces: [Workspace]?
    let items: [Workspace]?
    let results: [Workspace]?
    let data: [Workspace]?
}
private struct WorkspaceSnapshotResponse: Decodable {
    let snapshot: WorkspaceSnapshot?
    let item: WorkspaceSnapshot?
    let data: WorkspaceSnapshot?
}
private struct WorkspaceSnapshotsResponse: Decodable {
    let snapshots: [WorkspaceSnapshot]?
    let items: [WorkspaceSnapshot]?
    let results: [WorkspaceSnapshot]?
    let data: [WorkspaceSnapshot]?
}
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

// MARK: - SmithersClient + DevTools providers

extension SmithersClient: @preconcurrency DevToolsStreamProvider, NodeOutputProvider {}
