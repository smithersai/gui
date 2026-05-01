#if os(iOS)
import Foundation
import XCTest

final class SmithersiOSE2EWorkflowRunsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_workflow_run_dispatch_returns_id_and_shape_streams() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()

        let dispatch = try harness.dispatchAndDiscoverRun(workflow: workflow)

        XCTAssertGreaterThan(dispatch.run.id, 0, "dispatch must result in a persisted workflow run id")
        XCTAssertNotEqual(dispatch.response.statusCode, 401, "authenticated dispatch must not be rejected as unauthorized")

        let rows = try harness.waitForShapeRows(
            table: "workflow_runs",
            whereClause: harness.workflowRunsWhere(runID: dispatch.run.id)
        ) { row in
            harness.int64(from: row["id"]) == dispatch.run.id
        }

        XCTAssertTrue(
            rows.contains { harness.int64(from: $0["id"]) == dispatch.run.id },
            "workflow_runs shape must include the dispatched run row"
        )
        XCTAssertFalse(
            rows.contains {
                harness.int64(from: $0["id"]) == dispatch.run.id &&
                harness.int64(from: $0["repository_id"]) != harness.env.repoID
            },
            "workflow_runs shape must not leak the dispatched run under the wrong repository_id"
        )
    }

    func test_workflow_run_cancel_transitions_status() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()
        let dispatched = try harness.dispatchAndDiscoverRun(workflow: workflow)

        let cancel = try harness.cancelRun(runID: dispatched.run.id)
        XCTAssertEqual(cancel.statusCode, 204, "cancel route should return 204 for an active run")

        let cancelled = try harness.waitForRun(runID: dispatched.run.id) { run in
            run.status == "cancelled" ? run : nil
        }

        XCTAssertEqual(cancelled.status, "cancelled", "cancelling a run must persist the terminal cancelled status")
        XCTAssertNotEqual(cancelled.status, "running", "cancelled run must not remain running")
    }

    func test_workflow_run_rerun_creates_new_run_same_workflow() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()
        let original = try harness.dispatchAndDiscoverRun(workflow: workflow).run

        let rerun = try harness.rerunRun(runID: original.id)
        XCTAssertEqual(rerun.statusCode, 201, "rerun route should create a new run")

        let rerunBody = try rerun.decode(WorkflowRunResultResponse.self)
        XCTAssertGreaterThan(rerunBody.workflowRunID, 0, "rerun response must include the new workflow_run_id")
        XCTAssertEqual(rerunBody.workflowDefinitionID, original.workflowDefinitionID, "rerun must stay on the same workflow definition")
        XCTAssertNotEqual(rerunBody.workflowRunID, original.id, "rerun must create a distinct workflow run id")
    }

    func test_workflow_run_resume_from_paused() throws {
        throw XCTSkip("real plue only resumes cancelled or failed runs; a paused workflow-run state is not exposed")
    }

    func test_workflow_run_tasks_shape_populated() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()
        let dispatched = try harness.dispatchAndDiscoverRun(workflow: workflow)

        let rows = try harness.waitForShapeRows(
            table: "workflow_tasks",
            whereClause: harness.runScopedWhere(runID: dispatched.run.id)
        ) { row in
            harness.int64(from: row["workflow_run_id"]) == dispatched.run.id
        }

        XCTAssertFalse(rows.isEmpty, "workflow_tasks shape must contain at least one row after dispatch")
        XCTAssertFalse(
            rows.contains { harness.int64(from: $0["workflow_run_id"]) != dispatched.run.id },
            "workflow_tasks slice must stay scoped to the dispatched workflow_run_id"
        )
    }

    func test_workflow_run_steps_shape_populated() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()
        let dispatched = try harness.dispatchAndDiscoverRun(workflow: workflow)

        let rows = try harness.waitForShapeRows(
            table: "workflow_steps",
            whereClause: harness.runScopedWhere(runID: dispatched.run.id)
        ) { row in
            harness.int64(from: row["workflow_run_id"]) == dispatched.run.id
        }

        XCTAssertFalse(rows.isEmpty, "workflow_steps shape must contain at least one row after dispatch")
        XCTAssertFalse(
            rows.contains { harness.int64(from: $0["workflow_run_id"]) != dispatched.run.id },
            "workflow_steps slice must stay scoped to the dispatched workflow_run_id"
        )

        let inspection = try harness.getRunInspection(runID: dispatched.run.id)
        XCTAssertFalse(inspection.nodes.isEmpty, "run inspection tree must include nodes for the dispatched run")
        XCTAssertTrue(inspection.planXml.contains("<workflow"), "run inspection plan_xml must describe a workflow tree")
        XCTAssertFalse(inspection.mermaid.isEmpty, "run inspection mermaid graph must not be empty")
    }

    func test_workflow_run_dispatch_requires_auth() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()

        let response = try harness.dispatchWorkflow(workflow: workflow, auth: .none)

        XCTAssertEqual(response.statusCode, 401, "dispatch without a bearer token must return 401")
        XCTAssertNotEqual(response.statusCode, 204, "unauthenticated dispatch must not be accepted")
        XCTAssertFalse(
            response.text.contains("workflow_run_id"),
            "unauthenticated dispatch response must not claim a created workflow_run_id"
        )
    }

    func test_workflow_run_dispatch_wrong_repo_scope_rejected() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()

        let response = try harness.dispatchWorkflow(
            workflowID: workflow.id,
            owner: harness.env.repoOwner,
            repo: "\(harness.env.repoName)-wrong-scope",
            auth: .bearer,
            inputs: harness.dispatchInputs(for: workflow)
        )

        XCTAssertTrue(
            response.statusCode == 403 || response.statusCode == 404,
            "dispatch against the wrong repo scope should be rejected with 403 or 404, got \(response.statusCode): \(response.text)"
        )
        XCTAssertFalse(
            [200, 201, 204].contains(response.statusCode),
            "dispatch against the wrong repo scope must not succeed"
        )
    }

    func test_workflow_run_rate_limit() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()

        guard try harness.resetGlobalRateLimitsIfAvailable() else {
            throw XCTSkip("rate-limit scenario requires /api/_test/auth-rate-limits to be enabled for safe isolation")
        }
        defer { _ = try? harness.resetGlobalRateLimitsIfAvailable() }

        var statuses: [Int] = []
        var lastResponseText = ""
        for _ in 0..<70 {
            let response = try harness.dispatchWorkflow(workflow: workflow, auth: .none)
            statuses.append(response.statusCode)
            lastResponseText = response.text
            if response.statusCode == 429 {
                break
            }
        }

        XCTAssertEqual(statuses.first, 401, "anonymous dispatch should hit auth before the rate-limit threshold is exhausted")
        XCTAssertTrue(statuses.contains(429), "rapid anonymous dispatch attempts should eventually trip the global API rate limit")
        XCTAssertFalse(statuses.contains { (200..<300).contains($0) }, "anonymous dispatch attempts must not succeed while rate-limiting is exercised")
        XCTAssertTrue(
            lastResponseText.lowercased().contains("rate limit") || statuses.last == 429,
            "final rate-limited response should describe the limit breach"
        )
    }

    func test_workflow_run_listed_for_user() throws {
        let harness = try WorkflowRunsHarness()
        let workflow = try harness.requireWorkflowDefinition()
        let dispatched = try harness.dispatchAndDiscoverRun(workflow: workflow).run

        let listed = try harness.waitForRunsListItem(runID: dispatched.id)

        XCTAssertEqual(listed.id, dispatched.id, "repo-scoped workflow runs listing must include the newly dispatched run")
        XCTAssertFalse(
            listed.workflowDefinitionID == 0,
            "listed workflow run must carry its workflow_definition_id"
        )
    }
}

private struct WorkflowRunsEnvironment {
    let baseURL: URL
    let bearer: String
    let repoID: Int64
    let repoOwner: String
    let repoName: String
    let workflowIDOverride: Int64?
    let dispatchRef: String

    init(process: ProcessInfo = .processInfo) throws {
        let env = process.environment

        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            throw WorkflowRunsError.missingEnv(E2ELaunchKey.bearer)
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL], let baseURL = URL(string: baseURLString) else {
            throw WorkflowRunsError.missingEnv(E2ELaunchKey.baseURL)
        }
        guard let repoIDString = env["PLUE_E2E_REPO_ID"], let repoID = Int64(repoIDString) else {
            throw WorkflowRunsError.missingEnv("PLUE_E2E_REPO_ID")
        }
        guard let repoOwner = env[E2ELaunchKey.seededRepoOwner], !repoOwner.isEmpty else {
            throw WorkflowRunsError.missingEnv(E2ELaunchKey.seededRepoOwner)
        }
        guard let repoName = env[E2ELaunchKey.seededRepoName], !repoName.isEmpty else {
            throw WorkflowRunsError.missingEnv(E2ELaunchKey.seededRepoName)
        }

        self.baseURL = baseURL
        self.bearer = bearer
        self.repoID = repoID
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.workflowIDOverride = env["PLUE_E2E_WORKFLOW_ID"].flatMap(Int64.init)
        self.dispatchRef = env["PLUE_E2E_WORKFLOW_REF"] ?? "main"
    }
}

private final class WorkflowRunsHarness {
    let env: WorkflowRunsEnvironment
    private let session: URLSession

    init() throws {
        self.env = try WorkflowRunsEnvironment()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: config)
    }

    func requireWorkflowDefinition() throws -> WorkflowDefinition {
        if let overrideID = env.workflowIDOverride {
            let response = try request(
                path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows/\(overrideID)"
            )
            guard response.statusCode == 200 else {
                throw WorkflowRunsError.server("workflow override \(overrideID) lookup failed: HTTP \(response.statusCode) \(response.text)")
            }
            return try response.decode(WorkflowDefinition.self)
        }

        let response = try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        guard response.statusCode == 200 else {
            throw WorkflowRunsError.server("list workflows failed: HTTP \(response.statusCode) \(response.text)")
        }

        let workflows = try response.decode(WorkflowListResponse.self).workflows
        guard let workflow = workflows.first(where: { $0.isActive }) ?? workflows.first else {
            throw XCTSkip("seeded repo has no persisted workflow definitions; dispatch scenarios need a real workflow_definitions row")
        }
        return workflow
    }

    func dispatchWorkflow(workflow: WorkflowDefinition, auth: AuthMode) throws -> HTTPResponse {
        try dispatchWorkflow(
            workflowID: workflow.id,
            owner: env.repoOwner,
            repo: env.repoName,
            auth: auth,
            inputs: dispatchInputs(for: workflow)
        )
    }

    func dispatchWorkflow(
        workflowID: Int64,
        owner: String,
        repo: String,
        auth: AuthMode,
        inputs: [String: Any]
    ) throws -> HTTPResponse {
        var body: [String: Any] = ["ref": env.dispatchRef]
        if !inputs.isEmpty {
            body["inputs"] = inputs
        }
        return try request(
            path: "/api/repos/\(owner)/\(repo)/workflows/\(workflowID)/dispatches",
            method: "POST",
            auth: auth,
            jsonObject: body
        )
    }

    func dispatchAndDiscoverRun(workflow: WorkflowDefinition) throws -> DispatchResult {
        let before = try listRuns()
        let beforeIDs = Set(before.map(\.id))
        let response = try dispatchWorkflow(workflow: workflow, auth: .bearer)

        guard response.statusCode == 204 || response.statusCode == 201 else {
            throw WorkflowRunsError.server("dispatch failed: HTTP \(response.statusCode) \(response.text)")
        }

        if response.statusCode == 201, !response.data.isEmpty,
           let direct = try? response.decode(WorkflowRunResultResponse.self) {
            let run = try waitForRun(runID: direct.workflowRunID) { $0 }
            return DispatchResult(response: response, run: run)
        }

        let discovered = try waitFor(timeout: 20, pollInterval: 0.5) {
            let runs = try self.listRuns()
            return runs.first(where: {
                !beforeIDs.contains($0.id) && $0.workflowDefinitionID == workflow.id
            })
        }

        return DispatchResult(response: response, run: discovered)
    }

    func cancelRun(runID: Int64) throws -> HTTPResponse {
        try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows/runs/\(runID)/cancel",
            method: "POST",
            auth: .bearer,
            jsonObject: [:]
        )
    }

    func rerunRun(runID: Int64) throws -> HTTPResponse {
        try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows/runs/\(runID)/rerun",
            method: "POST",
            auth: .bearer,
            jsonObject: [:]
        )
    }

    func getActionRun(runID: Int64) throws -> WorkflowRunListItem {
        let response = try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/actions/runs/\(runID)"
        )
        guard response.statusCode == 200 else {
            throw WorkflowRunsError.server("get run \(runID) failed: HTTP \(response.statusCode) \(response.text)")
        }
        return try response.decode(WorkflowRunListItem.self)
    }

    func getRunInspection(runID: Int64) throws -> WorkflowInspectionResponse {
        let response = try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows/runs/\(runID)"
        )
        guard response.statusCode == 200 else {
            throw WorkflowRunsError.server("get run inspection \(runID) failed: HTTP \(response.statusCode) \(response.text)")
        }
        return try response.decode(WorkflowInspectionResponse.self)
    }

    func listRuns() throws -> [WorkflowRunListItem] {
        let response = try request(
            path: "/api/repos/\(env.repoOwner)/\(env.repoName)/workflows/runs",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        guard response.statusCode == 200 else {
            throw WorkflowRunsError.server("list workflow runs failed: HTTP \(response.statusCode) \(response.text)")
        }
        return try response.decode(WorkflowRunsListResponse.self).runs
    }

    func waitForRunsListItem(runID: Int64) throws -> WorkflowRunListItem {
        try waitFor(timeout: 20, pollInterval: 0.5) {
            try self.listRuns().first(where: { $0.id == runID })
        }
    }

    func waitForRun(
        runID: Int64,
        timeout: TimeInterval = 20,
        predicate: @escaping (WorkflowRunListItem) -> WorkflowRunListItem?
    ) throws -> WorkflowRunListItem {
        try waitFor(timeout: timeout, pollInterval: 0.5) {
            let run = try self.getActionRun(runID: runID)
            return predicate(run)
        }
    }

    func waitForShapeRows(
        table: String,
        whereClause: String,
        timeout: TimeInterval = 20,
        rowFilter: @escaping ([String: Any]) -> Bool
    ) throws -> [[String: Any]] {
        try waitFor(timeout: timeout, pollInterval: 0.5) {
            let response = try self.request(
                path: "/v1/shape",
                auth: .bearer,
                query: [
                    URLQueryItem(name: "table", value: table),
                    URLQueryItem(name: "where", value: whereClause),
                    URLQueryItem(name: "offset", value: "-1"),
                ]
            )
            guard response.statusCode == 200 else {
                throw WorkflowRunsError.server("shape \(table) failed: HTTP \(response.statusCode) \(response.text)")
            }

            let rows = try self.shapeRows(from: response.data)
            return rows.contains(where: rowFilter) ? rows : nil
        }
    }

    func resetGlobalRateLimitsIfAvailable() throws -> Bool {
        let response = try request(
            path: "/api/_test/auth-rate-limits",
            method: "DELETE",
            auth: .none
        )
        switch response.statusCode {
        case 200, 204:
            return true
        case 404:
            return false
        default:
            throw WorkflowRunsError.server("rate-limit reset failed: HTTP \(response.statusCode) \(response.text)")
        }
    }

    func workflowRunsWhere(runID: Int64) -> String {
        "repository_id IN (\(env.repoID)) AND id = \(runID)"
    }

    func runScopedWhere(runID: Int64) -> String {
        "repository_id IN (\(env.repoID)) AND workflow_run_id = \(runID)"
    }

    func dispatchInputs(for workflow: WorkflowDefinition) -> [String: Any] {
        guard
            let on = workflow.config?["on"]?.objectValue,
            let workflowDispatch = on["workflow_dispatch"]?.objectValue,
            let inputs = workflowDispatch["inputs"]?.objectValue
        else {
            return [:]
        }

        var resolved: [String: Any] = [:]
        for (key, specValue) in inputs {
            guard let spec = specValue.objectValue else { continue }
            if spec["default"] != nil {
                continue
            }
            guard spec["required"]?.boolValue == true else { continue }
            resolved[key] = stubDispatchValue(for: spec, key: key)
        }
        return resolved
    }

    func int64(from value: Any?) -> Int64? {
        switch value {
        case let int as Int:
            return Int64(int)
        case let int64 as Int64:
            return int64
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private func stubDispatchValue(for spec: [String: JSONValue], key: String) -> Any {
        if let options = spec["options"]?.arrayValue, let first = options.first {
            return first.foundationValue
        }
        if let choices = spec["choices"]?.arrayValue, let first = choices.first {
            return first.foundationValue
        }
        switch spec["type"]?.stringValue?.lowercased() {
        case "boolean":
            return true
        case "number", "integer":
            return 1
        case "array":
            return ["e2e-\(key)"]
        case "object":
            return ["value": "e2e-\(key)"]
        default:
            return "e2e-\(key)"
        }
    }

    private func request(
        path: String,
        method: String = "GET",
        auth: AuthMode = .bearer,
        query: [URLQueryItem] = [],
        jsonObject: Any? = nil
    ) throws -> HTTPResponse {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if auth == .bearer {
            request.setValue("Bearer \(env.bearer)", forHTTPHeaderField: "Authorization")
        }
        if let jsonObject {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        var captured: HTTPResponse?
        var capturedError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                capturedError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                capturedError = WorkflowRunsError.server("missing HTTPURLResponse for \(method) \(path)")
                return
            }
            captured = HTTPResponse(
                statusCode: http.statusCode,
                data: data ?? Data()
            )
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            task.cancel()
            throw WorkflowRunsError.server("timed out waiting for \(method) \(path)")
        }
        if let capturedError {
            throw capturedError
        }
        guard let captured else {
            throw WorkflowRunsError.server("request completed without a response for \(method) \(path)")
        }
        return captured
    }

    private func url(path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: env.baseURL, resolvingAgainstBaseURL: false) else {
            throw WorkflowRunsError.server("failed to parse PLUE_BASE_URL \(env.baseURL)")
        }
        let basePath = components.path
        if path.hasPrefix("/") {
            components.path = basePath + path
        } else {
            components.path = basePath + "/" + path
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw WorkflowRunsError.server("failed to build URL for path \(path)")
        }
        return url
    }

    private func shapeRows(from data: Data) throws -> [[String: Any]] {
        let json = try JSONSerialization.jsonObject(with: data, options: [])
        guard let messages = json as? [[String: Any]] else {
            throw WorkflowRunsError.server("shape response was not a JSON array")
        }

        var rows: [[String: Any]] = []
        for message in messages {
            guard
                let headers = message["headers"] as? [String: Any],
                let operation = headers["operation"] as? String,
                operation == "insert" || operation == "update" || operation == "delete",
                let value = message["value"] as? [String: Any]
            else {
                continue
            }
            rows.append(value)
        }
        return rows
    }

    private func waitFor<T>(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        operation: () throws -> T?
    ) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if let value = try operation() {
                    return value
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        if let lastError {
            throw lastError
        }
        throw WorkflowRunsError.server("timed out after \(timeout)s")
    }
}

private enum AuthMode {
    case bearer
    case none
}

private struct DispatchResult {
    let response: HTTPResponse
    let run: WorkflowRunListItem
}

private struct HTTPResponse {
    let statusCode: Int
    let data: Data

    var text: String {
        String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

private enum WorkflowRunsError: LocalizedError {
    case missingEnv(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case let .missingEnv(key):
            return "missing environment variable \(key)"
        case let .server(message):
            return message
        }
    }
}

private struct WorkflowListResponse: Decodable {
    let workflows: [WorkflowDefinition]
}

private struct WorkflowDefinition: Decodable {
    let id: Int64
    let repositoryId: Int64
    let name: String
    let path: String
    let config: JSONValue?
    let isActive: Bool
}

private struct WorkflowRunsListResponse: Decodable {
    let runs: [WorkflowRunListItem]
}

private struct WorkflowRunListItem: Decodable {
    let id: Int64
    let repositoryId: Int64
    let workflowDefinitionID: Int64
    let status: String
    let workflowName: String?
    let workflowPath: String?
}

private struct WorkflowRunResultResponse: Decodable {
    let workflowDefinitionID: Int64
    let workflowRunID: Int64
}

private struct WorkflowInspectionResponse: Decodable {
    let run: WorkflowRunListItem
    let nodes: [WorkflowInspectionNode]
    let mermaid: String
    let planXml: String
}

private struct WorkflowInspectionNode: Decodable {
    let id: String
    let stepId: Int64
    let name: String
    let position: Int64
    let status: String
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
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
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    var foundationValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case let .object(value):
            return value.mapValues { $0.foundationValue }
        case let .array(values):
            return values.map(\.foundationValue)
        case .null:
            return NSNull()
        }
    }
}
#endif
