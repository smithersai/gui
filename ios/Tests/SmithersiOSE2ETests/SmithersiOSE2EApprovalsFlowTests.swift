#if os(iOS)
import Darwin
import Foundation
import XCTest

private struct ApprovalFlowHTTPResponse {
    let status: Int
    let headers: [AnyHashable: Any]
    let data: Data

    var body: String {
        String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    }

    func header(named name: String) -> String? {
        headers.first { element in
            String(describing: element.key).caseInsensitiveCompare(name) == .orderedSame
        }.map { String(describing: $0.value) }
    }
}

private final class ApprovalFlowHTTPClient {
    func get(
        _ url: URL,
        bearer: String? = nil,
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) throws -> ApprovalFlowHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try send(request, timeout: timeout)
    }

    func postJSON(
        _ url: URL,
        bearer: String? = nil,
        body: [String: Any],
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) throws -> ApprovalFlowHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return try send(request, timeout: timeout)
    }

    private func send(_ request: URLRequest, timeout: TimeInterval) throws -> ApprovalFlowHTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        let session = URLSession(configuration: config)

        var output: ApprovalFlowHTTPResponse?
        var outputError: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outputError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outputError = NSError(
                    domain: "approvals-flow-e2e.http",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "missing HTTPURLResponse for \(request.url?.absoluteString ?? "?")"]
                )
                return
            }
            output = ApprovalFlowHTTPResponse(
                status: http.statusCode,
                headers: http.allHeaderFields,
                data: data ?? Data()
            )
        }

        task.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 3)
        task.cancel()

        if let outputError {
            throw outputError
        }
        guard let output else {
            throw NSError(
                domain: "approvals-flow-e2e.http",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "timed out waiting for \(request.httpMethod ?? "?") \(request.url?.absoluteString ?? "?")"]
            )
        }
        return output
    }
}

private struct ApprovalFlowContext {
    private static let seededRepoIDEnv = "PLUE_E2E_REPO_ID"

    let bearer: String
    let baseURL: URL
    let owner: String
    let repoName: String
    let repoID: String
    let agentSessionID: String
    let seededApprovalID: String

    static func load() throws -> ApprovalFlowContext {
        let env = ProcessInfo.processInfo.environment
        guard env[E2ELaunchKey.seededData] == "1" else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_E2E_SEEDED=1"]
            )
        }
        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require SMITHERS_E2E_BEARER"]
            )
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL],
              let baseURL = URL(string: baseURLString) else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_BASE_URL"]
            )
        }
        guard let owner = env[E2ELaunchKey.seededRepoOwner], !owner.isEmpty,
              let repoName = env[E2ELaunchKey.seededRepoName], !repoName.isEmpty else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_E2E_REPO_OWNER + PLUE_E2E_REPO_NAME"]
            )
        }
        guard let repoID = env[Self.seededRepoIDEnv], !repoID.isEmpty else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_E2E_REPO_ID"]
            )
        }
        guard let agentSessionID = env[E2ELaunchKey.seededAgentSessionID], !agentSessionID.isEmpty else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_E2E_AGENT_SESSION_ID"]
            )
        }
        guard let approvalID = env[E2ELaunchKey.seededApprovalID], !approvalID.isEmpty else {
            throw NSError(
                domain: "approvals-flow-e2e.env",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "approvals flow scenarios require PLUE_E2E_APPROVAL_ID"]
            )
        }

        return ApprovalFlowContext(
            bearer: bearer,
            baseURL: baseURL,
            owner: owner,
            repoName: repoName,
            repoID: repoID,
            agentSessionID: agentSessionID,
            seededApprovalID: approvalID
        )
    }

    var approvalsListURL: URL {
        baseURL.appendingPathComponent("api/repos/\(owner)/\(repoName)/approvals")
    }

    func decideURL(
        approvalID: String,
        owner overrideOwner: String? = nil,
        repo overrideRepoName: String? = nil
    ) -> URL {
        baseURL.appendingPathComponent(
            "api/repos/\(overrideOwner ?? owner)/\(overrideRepoName ?? repoName)/approvals/\(approvalID)/decide"
        )
    }

    func shapeBaseCandidates() -> [URL] {
        var candidates: [URL] = []
        if let sameOrigin = replacing(path: "/v1/shape", queryItems: nil, port: baseURL.port) {
            candidates.append(sameOrigin)
        }
        if let proxyOrigin = replacing(path: "/v1/shape", queryItems: nil, port: 3001) {
            let proxyString = proxyOrigin.absoluteString
            if !candidates.contains(where: { $0.absoluteString == proxyString }) {
                candidates.append(proxyOrigin)
            }
        }
        return candidates
    }

    private func replacing(path: String, queryItems: [URLQueryItem]?, port: Int?) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = path
        components.queryItems = queryItems
        components.port = port
        return components.url
    }
}

private struct ApprovalRow {
    let id: String
    let rawStatus: String

    var normalizedStatus: String {
        Self.normalize(rawStatus)
    }

    static func normalize(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "approve", "approved":
            return "approved"
        case "deny", "denied", "reject", "rejected":
            return "denied"
        case "pending":
            return "pending"
        default:
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}

private struct ShapeCursor {
    let baseURL: URL
    let handle: String
    let offset: String
    let body: String
}

private struct SeedSnapshot {
    let approvalID: String
}

final class SmithersiOSE2EApprovalsFlowTests: XCTestCase {
    private let http = ApprovalFlowHTTPClient()
    private static let seedScriptPath = "/Users/williamcory/gui/ios/scripts/seed-e2e-data.sh"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_approval_seeded_row_visible_via_http() throws {
        let ctx = try readyContext()
        _ = try reseedPrimaryApproval(ctx)

        let response = try http.get(ctx.approvalsListURL, bearer: ctx.bearer)
        XCTAssertEqual(response.status, 200, "GET approvals should return 200; body=\(response.body)")
        XCTAssertNotEqual(response.status, 401, "GET approvals must not require re-auth when bearer is present")

        let rows = try approvalRows(from: response)
        let row = try findApproval(id: ctx.seededApprovalID, in: rows, responseBody: response.body)
        XCTAssertEqual(row.normalizedStatus, "pending", "seeded approval must start pending")
        XCTAssertNotEqual(row.normalizedStatus, "approved", "seeded approval must not already be approved")
        XCTAssertNotEqual(row.normalizedStatus, "denied", "seeded approval must not already be denied")
    }

    func test_approval_approve_transitions_to_approved() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID
        try assertApprovalStatus(id: seeded, expected: "pending", context: ctx)

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(decide.status, 200, "first approve should succeed; body=\(decide.body)")
        XCTAssertNotEqual(decide.status, 409, "first approve must not conflict")

        try assertApprovalStatus(id: seeded, expected: "approved", context: ctx)
        let rows = try fetchApprovals(context: ctx)
        let row = try findApproval(id: seeded, in: rows, responseBody: "missing row after approve")
        XCTAssertNotEqual(row.normalizedStatus, "pending", "approved row must leave pending state")
        XCTAssertNotEqual(row.normalizedStatus, "denied", "approve must not flip the row to denied")
    }

    func test_approval_deny_transitions_to_denied() throws {
        let ctx = try readyContext()
        let secondApprovalID = try insertPendingApproval(context: ctx, titleSeed: "deny")
        try assertApprovalStatus(id: secondApprovalID, expected: "pending", context: ctx)

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: secondApprovalID),
            bearer: ctx.bearer,
            body: ["decision": "rejected"]
        )
        XCTAssertEqual(decide.status, 200, "deny/reject should succeed for a fresh approval; body=\(decide.body)")
        XCTAssertNotEqual(decide.status, 409, "first reject must not conflict")

        try assertApprovalStatus(id: secondApprovalID, expected: "denied", context: ctx)
        let rows = try fetchApprovals(context: ctx)
        let row = try findApproval(id: secondApprovalID, in: rows, responseBody: "missing row after reject")
        XCTAssertNotEqual(row.normalizedStatus, "pending", "rejected row must leave pending state")
        XCTAssertNotEqual(row.normalizedStatus, "approved", "reject must not flip the row to approved")
    }

    func test_approval_decide_idempotent() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID

        let first = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(first.status, 200, "first approve should succeed; body=\(first.body)")

        let second = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertTrue([200, 409].contains(second.status), "second identical decision should be idempotent or conflict-cleanly; body=\(second.body)")
        XCTAssertNotEqual(second.status, 500, "second identical decision must not corrupt the route into a server error")

        try assertApprovalStatus(id: seeded, expected: "approved", context: ctx)
        let rows = try fetchApprovals(context: ctx)
        let row = try findApproval(id: seeded, in: rows, responseBody: "missing row after idempotent retry")
        XCTAssertNotEqual(row.normalizedStatus, "pending", "row must stay decided after idempotent retry")
        XCTAssertNotEqual(row.normalizedStatus, "denied", "identical approve retry must not change the final state")
    }

    func test_approval_decide_conflicting_decision_rejected() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID

        let first = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(first.status, 200, "first approve should succeed before the conflicting retry; body=\(first.body)")

        let second = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "rejected"]
        )
        XCTAssertEqual(second.status, 409, "conflicting second decision must be rejected; body=\(second.body)")
        XCTAssertNotEqual(second.status, 200, "conflicting second decision must not succeed")

        let rows = try fetchApprovals(context: ctx)
        let row = try findApproval(id: seeded, in: rows, responseBody: "missing row after conflicting retry")
        XCTAssertEqual(row.normalizedStatus, "approved", "conflicting retry must leave the original approval intact")
        XCTAssertNotEqual(row.normalizedStatus, "denied", "conflicting retry must not overwrite approved state")
    }

    func test_approval_decide_requires_auth() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID
        try assertApprovalStatus(id: seeded, expected: "pending", context: ctx)

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: nil,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(decide.status, 401, "decide without bearer must be unauthorized; body=\(decide.body)")
        XCTAssertNotEqual(decide.status, 200, "decide without bearer must not succeed")

        try assertApprovalStatus(id: seeded, expected: "pending", context: ctx)
    }

    func test_approval_decide_wrong_repo_scope_rejected() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID
        try assertApprovalStatus(id: seeded, expected: "pending", context: ctx)

        let wrongRepo = try http.postJSON(
            ctx.decideURL(approvalID: seeded, owner: "other", repo: "other"),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertTrue([403, 404].contains(wrongRepo.status), "wrong repo scope should be rejected; body=\(wrongRepo.body)")
        XCTAssertNotEqual(wrongRepo.status, 200, "wrong repo scope must not succeed")

        try assertApprovalStatus(id: seeded, expected: "pending", context: ctx)
    }

    func test_approval_audit_row_written() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(decide.status, 200, "approval decide should succeed before audit verification; body=\(decide.body)")

        let audit = try queryAuditLog(context: ctx, approvalID: seeded)
        XCTAssertEqual(audit.status, 200, "audit query should succeed once an endpoint is exposed; body=\(audit.body)")
        XCTAssertTrue(audit.body.lowercased().contains(seeded.lowercased()), "audit payload should mention the approval id; body=\(audit.body)")
        XCTAssertFalse(audit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "audit payload must not be empty")
    }

    func test_approval_rate_limit() throws {
        let ctx = try readyContext()
        let limitedBearer = try createRateLimitedBearer()

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: ctx.seededApprovalID),
            bearer: limitedBearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(decide.status, 429, "pre-exhausted API budget should force decide to return 429; body=\(decide.body)")
        XCTAssertNotEqual(decide.status, 200, "rate-limited decide must not succeed")
        XCTAssertEqual(decide.header(named: "X-RateLimit-Remaining"), "0", "429 response should clamp remaining budget to 0")
    }

    func test_approval_shape_updates_after_decide() throws {
        let ctx = try readyContext()
        let seeded = try reseedPrimaryApproval(ctx).approvalID

        let initialShape = try openInitialShape(context: ctx)
        let initialLower = initialShape.body.lowercased()
        XCTAssertTrue(initialLower.contains(seeded.lowercased()), "initial approvals shape should contain the seeded approval")
        XCTAssertTrue(initialLower.contains("pending"), "initial approvals shape should show the pending seeded row")
        XCTAssertFalse(initialLower.contains("approved"), "initial approvals shape must not already show the seeded row as approved")

        let decide = try http.postJSON(
            ctx.decideURL(approvalID: seeded),
            bearer: ctx.bearer,
            body: ["decision": "approved"]
        )
        XCTAssertEqual(decide.status, 200, "shape scenario needs a successful decide before polling the stream; body=\(decide.body)")

        let updatedBody = try awaitShapeUpdate(
            context: ctx,
            approvalID: seeded,
            expectedState: "approved",
            startingFrom: initialShape,
            timeout: 5
        )
        let updatedLower = updatedBody.lowercased()
        XCTAssertTrue(updatedLower.contains("approved"), "shape update should stream the approved state within 5s")
        XCTAssertFalse(updatedLower.contains("rejected"), "approve path must not stream a rejected state for the same row")
    }

    private func readyContext() throws -> ApprovalFlowContext {
        let context = try ApprovalFlowContext.load()
        let flags = try fetchFeatureFlags(context: context)
        guard flags["approvals_flow_enabled"] == true else {
            throw XCTSkip(
                "approvals_flow_enabled=false on \(context.baseURL.absoluteString); deeper approvals flow scenarios complement the existing flag-off coverage"
            )
        }
        return context
    }

    private func fetchFeatureFlags(context: ApprovalFlowContext) throws -> [String: Bool] {
        let url = context.baseURL.appendingPathComponent("api/feature-flags")
        let response = try http.get(url, timeout: 10)
        guard response.status == 200 else {
            throw NSError(
                domain: "approvals-flow-e2e.flags",
                code: response.status,
                userInfo: [NSLocalizedDescriptionKey: "GET /api/feature-flags returned \(response.status); body=\(response.body)"]
            )
        }
        struct FlagsResponse: Decodable { let flags: [String: Bool] }
        return try JSONDecoder().decode(FlagsResponse.self, from: response.data).flags
    }

    private func fetchApprovals(context: ApprovalFlowContext) throws -> [ApprovalRow] {
        let response = try http.get(context.approvalsListURL, bearer: context.bearer)
        XCTAssertEqual(response.status, 200, "GET approvals should return 200; body=\(response.body)")
        XCTAssertNotEqual(response.status, 401, "GET approvals must not fail auth with the seeded bearer")
        return try approvalRows(from: response)
    }

    private func approvalRows(from response: ApprovalFlowHTTPResponse) throws -> [ApprovalRow] {
        guard !response.data.isEmpty else {
            return []
        }
        let json = try JSONSerialization.jsonObject(with: response.data, options: [])
        let rows = flattenApprovalRows(json)
        if rows.isEmpty {
            throw NSError(
                domain: "approvals-flow-e2e.decode",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "unable to decode approvals payload: \(response.body)"]
            )
        }
        return rows
    }

    private func flattenApprovalRows(_ value: Any) -> [ApprovalRow] {
        if let array = value as? [Any] {
            return array.compactMap { element in
                guard let object = element as? [String: Any] else { return nil }
                return approvalRow(from: object)
            }
        }
        if let object = value as? [String: Any] {
            if let direct = approvalRow(from: object) {
                return [direct]
            }
            for key in ["approvals", "items", "results", "data"] {
                if let nested = object[key] {
                    let rows = flattenApprovalRows(nested)
                    if !rows.isEmpty {
                        return rows
                    }
                }
            }
        }
        return []
    }

    private func approvalRow(from object: [String: Any]) -> ApprovalRow? {
        guard let id = stringValue(object["id"]) ?? stringValue(object["approval_id"]) else {
            return nil
        }
        guard let status = stringValue(object["status"]) ?? stringValue(object["state"]) else {
            return nil
        }
        return ApprovalRow(id: id, rawStatus: status)
    }

    private func findApproval(
        id: String,
        in rows: [ApprovalRow],
        responseBody: String
    ) throws -> ApprovalRow {
        if let row = rows.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
            return row
        }
        throw NSError(
            domain: "approvals-flow-e2e.lookup",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey:
                "approval \(id) missing from approvals payload; body=\(responseBody)"]
        )
    }

    private func assertApprovalStatus(
        id: String,
        expected: String,
        context: ApprovalFlowContext
    ) throws {
        let response = try http.get(context.approvalsListURL, bearer: context.bearer)
        XCTAssertEqual(response.status, 200, "GET approvals should return 200 while checking \(id); body=\(response.body)")
        let rows = try approvalRows(from: response)
        let row = try findApproval(id: id, in: rows, responseBody: response.body)
        XCTAssertEqual(row.normalizedStatus, expected, "approval \(id) should be \(expected), got raw status \(row.rawStatus)")
    }

    private func reseedPrimaryApproval(_ context: ApprovalFlowContext) throws -> SeedSnapshot {
        var env: [String: String] = [:]
        env[E2ELaunchKey.bearer] = context.bearer
        let output = try runHostShell(Self.seedScriptPath, extraEnvironment: env)
        let values = parseKeyValueOutput(output)
        let approvalID = values[E2ELaunchKey.seededApprovalID] ?? context.seededApprovalID
        XCTAssertEqual(approvalID.lowercased(), context.seededApprovalID.lowercased(), "reseed should preserve the stable seeded approval id")
        return SeedSnapshot(approvalID: approvalID)
    }

    private func insertPendingApproval(context: ApprovalFlowContext, titleSeed: String) throws -> String {
        let approvalID = UUID().uuidString.lowercased()
        let title = "e2e_\(titleSeed)_\(randomHex(count: 10))"
        let description = "ios_e2e_\(titleSeed)_\(randomHex(count: 8))"
        let command = """
        psql -h "${PGHOST:-127.0.0.1}" -p "${PGPORT:-5432}" -U "${PGUSER:-jjhub}" -d "${PGDATABASE:-jjhub}" -v ON_ERROR_STOP=1 <<SQL
        INSERT INTO approvals (
            id, session_id, repository_id, state, kind, title, description, expires_at, payload
        ) VALUES (
            '\(approvalID)'::uuid,
            '\(context.agentSessionID)'::uuid,
            \(context.repoID),
            'pending',
            'shell_command',
            '\(title)',
            '\(description)',
            NOW() + INTERVAL '1 hour',
            '{"command":"echo inserted"}'::jsonb
        );
        SQL
        """
        _ = try runHostShell(command)
        return approvalID
    }

    private func createRateLimitedBearer() throws -> String {
        let userID = 900_000 + Int.random(in: 1...90_000)
        let username = "e2e_rl_\(randomHex(count: 10))"
        let email = "\(username)@smithers.local"
        let token = "jjhub_\(randomHex(count: 40))"

        let command = """
        psql -h "${PGHOST:-127.0.0.1}" -p "${PGPORT:-5432}" -U "${PGUSER:-jjhub}" -d "${PGDATABASE:-jjhub}" -v ON_ERROR_STOP=1 <<SQL
        INSERT INTO users (
            id, username, lower_username, email, lower_email, display_name, is_active, is_admin, created_at, updated_at
        ) VALUES (
            \(userID),
            '\(username)',
            '\(username)',
            '\(email)',
            '\(email)',
            'E2E Rate Limit User',
            TRUE,
            FALSE,
            NOW(),
            NOW()
        );

        INSERT INTO access_tokens (
            user_id, name, token_hash, token_last_eight, scopes, created_at, updated_at
        ) VALUES (
            \(userID),
            'e2e-rate-limit',
            encode(digest('\(token)', 'sha256'), 'hex'),
            RIGHT('\(token)', 8),
            'read:user',
            NOW(),
            NOW()
        );

        INSERT INTO search_rate_limits (
            scope, principal_key, tokens, last_refill_at, created_at, updated_at
        ) VALUES (
            'api',
            'user:\(userID)',
            0,
            NOW(),
            NOW(),
            NOW()
        )
        ON CONFLICT (scope, principal_key) DO UPDATE
            SET tokens = 0,
                last_refill_at = NOW(),
                updated_at = NOW();
        SQL
        """
        _ = try runHostShell(command)
        return token
    }

    private func queryAuditLog(
        context: ApprovalFlowContext,
        approvalID: String
    ) throws -> ApprovalFlowHTTPResponse {
        let since = iso8601String(for: Date().addingTimeInterval(-300))
        let publicCandidates = [
            "api/audit_log",
            "api/audit-log",
            "api/repos/\(context.owner)/\(context.repoName)/audit_log",
            "api/repos/\(context.owner)/\(context.repoName)/audit-log",
        ]

        for path in publicCandidates {
            let url = buildURL(
                base: context.baseURL,
                path: path,
                queryItems: [
                    URLQueryItem(name: "since", value: since),
                    URLQueryItem(name: "target_type", value: "approval"),
                    URLQueryItem(name: "target_name", value: approvalID),
                ]
            )
            let response = try http.get(url, bearer: context.bearer)
            if [404, 405].contains(response.status) {
                continue
            }
            if [401, 403].contains(response.status) {
                throw XCTSkip("audit endpoint exists at \(url.path) but is not accessible to the seeded E2E bearer (\(response.status))")
            }
            return response
        }

        let adminURL = buildURL(
            base: context.baseURL,
            path: "api/admin/audit-logs",
            queryItems: [URLQueryItem(name: "since", value: since)]
        )
        let adminResponse = try http.get(adminURL, bearer: context.bearer)
        if [401, 403].contains(adminResponse.status) {
            throw XCTSkip("missing repo-scoped /api/audit_log exposure; only admin-only /api/admin/audit-logs is visible to this harness")
        }

        throw XCTSkip("missing HTTP audit_log exposure for approvals verification")
    }

    private func openInitialShape(context: ApprovalFlowContext) throws -> ShapeCursor {
        var lastError: Error?
        for base in context.shapeBaseCandidates() {
            do {
                let url = buildShapeURL(
                    base: base,
                    repoID: context.repoID,
                    offset: "-1",
                    handle: nil,
                    live: false
                )
                let response = try http.get(url, bearer: context.bearer, timeout: 8)
                guard [200, 204].contains(response.status) else {
                    lastError = NSError(
                        domain: "approvals-flow-e2e.shape",
                        code: response.status,
                        userInfo: [NSLocalizedDescriptionKey: "shape probe at \(base.absoluteString) returned \(response.status); body=\(response.body)"]
                    )
                    continue
                }
                guard let handle = response.header(named: "electric-handle"),
                      let offset = response.header(named: "electric-offset") else {
                    lastError = NSError(
                        domain: "approvals-flow-e2e.shape",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "shape probe at \(base.absoluteString) missing electric headers; body=\(response.body)"]
                    )
                    continue
                }
                return ShapeCursor(
                    baseURL: base,
                    handle: handle,
                    offset: offset,
                    body: response.body
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NSError(
            domain: "approvals-flow-e2e.shape",
            code: -4,
            userInfo: [NSLocalizedDescriptionKey: "unable to reach approvals shape endpoint on any candidate origin"]
        )
    }

    private func awaitShapeUpdate(
        context: ApprovalFlowContext,
        approvalID: String,
        expectedState: String,
        startingFrom initial: ShapeCursor,
        timeout: TimeInterval
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var currentHandle = initial.handle
        var currentOffset = initial.offset

        while Date() < deadline {
            let remaining = max(1, deadline.timeIntervalSinceNow)
            let url = buildShapeURL(
                base: initial.baseURL,
                repoID: context.repoID,
                offset: currentOffset,
                handle: currentHandle,
                live: true
            )
            let response = try http.get(url, bearer: context.bearer, timeout: min(remaining, 5))
            XCTAssertNotEqual(response.status, 401, "shape request must stay authenticated")
            guard [200, 204].contains(response.status) else {
                throw NSError(
                    domain: "approvals-flow-e2e.shape",
                    code: response.status,
                    userInfo: [NSLocalizedDescriptionKey: "shape live poll failed with \(response.status); body=\(response.body)"]
                )
            }

            if let handle = response.header(named: "electric-handle"), !handle.isEmpty {
                currentHandle = handle
            }
            if let offset = response.header(named: "electric-offset"), !offset.isEmpty {
                currentOffset = offset
            }

            let body = response.body.lowercased()
            if body.contains(approvalID.lowercased()) && body.contains(expectedState.lowercased()) {
                return response.body
            }
        }

        throw NSError(
            domain: "approvals-flow-e2e.shape",
            code: -5,
            userInfo: [NSLocalizedDescriptionKey:
                "shape did not stream approval \(approvalID) with state \(expectedState) within \(timeout)s"]
        )
    }

    private func buildShapeURL(
        base: URL,
        repoID: String,
        offset: String,
        handle: String?,
        live: Bool
    ) -> URL {
        var items = [
            URLQueryItem(name: "table", value: "approvals"),
            URLQueryItem(name: "where", value: "repository_id IN ('\(repoID)')"),
            URLQueryItem(name: "offset", value: offset),
        ]
        if let handle {
            items.append(URLQueryItem(name: "handle", value: handle))
        }
        if live {
            items.append(URLQueryItem(name: "live", value: "true"))
        }
        return buildURL(base: base, path: "v1/shape", queryItems: items)
    }

    private func buildURL(base: URL, path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = queryItems
        return components.url!
    }

    private func runHostShell(
        _ command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        let basePath = environment["PATH"] ?? ""
        environment["PATH"] = "/opt/homebrew/opt/libpq/bin:/opt/homebrew/bin:/usr/local/bin:\(basePath)"
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        let shell = "/bin/bash"
        let fileManager = FileManager.default
        let stdoutURL = fileManager.temporaryDirectory.appendingPathComponent("smithers-approvals-stdout-\(UUID().uuidString)")
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("smithers-approvals-stderr-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: stdoutURL)
            try? fileManager.removeItem(at: stderrURL)
        }

        let wrappedCommand = """
        cd \(shellQuote("/Users/williamcory/gui")) && (\(command)) > \(shellQuote(stdoutURL.path)) 2> \(shellQuote(stderrURL.path))
        """
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(shell),
            strdup("-lc"),
            strdup(wrappedCommand),
            nil,
        ]
        defer {
            for case let ptr? in argv {
                free(ptr)
            }
        }

        var envp: [UnsafeMutablePointer<CChar>?] = environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for case let ptr? in envp {
                free(ptr)
            }
        }

        var pid: pid_t = 0
        let spawnStatus = shell.withCString { shellPtr in
            posix_spawn(&pid, shellPtr, nil, nil, &argv, &envp)
        }
        if spawnStatus != 0 {
            let message = String(cString: strerror(spawnStatus))
            throw NSError(
                domain: "approvals-flow-e2e.shell",
                code: Int(spawnStatus),
                userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed: \(message)"]
            )
        }

        var status: Int32 = 0
        if waitpid(pid, &status, 0) == -1 {
            throw NSError(
                domain: "approvals-flow-e2e.shell",
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "waitpid failed with errno \(errno)"]
            )
        }

        let out = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let exitCode = Int((status >> 8) & 0xff)
        let signalBits = Int(status & 0x7f)

        guard signalBits == 0, exitCode == 0 else {
            throw NSError(
                domain: "approvals-flow-e2e.shell",
                code: exitCode == 0 ? signalBits : exitCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "host shell failed (exit=\(exitCode), signalBits=\(signalBits))\ncommand: \(command)\nstdout:\n\(out)\nstderr:\n\(err)"]
            )
        }
        return out
    }

    private func parseKeyValueOutput(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let idx = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<idx])
            let value = String(line[line.index(after: idx)...])
            values[key] = value
        }
        return values
    }

    private func iso8601String(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private func randomHex(count: Int) -> String {
        var output = ""
        while output.count < count {
            output += UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return String(output.prefix(count))
    }

    private func shellQuote(_ string: String) -> String {
        let escaped = string.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}
#endif
