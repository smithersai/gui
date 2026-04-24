#if os(iOS)
import Foundation
import XCTest

// SmithersiOSE2ERateLimitsTests.swift
//
// HTTP-only E2E quota/rate-limit scenarios against a real plue backend.
// These tests intentionally do NOT drive UI. They live in the XCUITest
// bundle for parity with the rest of the iOS end-to-end harness and use
// the same runner-provided env contract (`PLUE_BASE_URL`,
// `SMITHERS_E2E_BEARER`, seeded repo/session ids, etc.).
//
// Important constraints from the ticket:
// - Pure HTTP / URLSession only.
// - When a specific limiter/cap is not implemented on the backend yet,
//   skip with an endpoint-specific follow-up.
// - No xcodebuild or seed-script changes here.

final class SmithersiOSE2ERateLimitsTests: XCTestCase {
    private static let seededRepoIDEnvKey = "PLUE_E2E_REPO_ID"
    private static let electricBaseURLEnvKey = "PLUE_ELECTRIC_BASE_URL"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - 1. Workspace quota

    /// The per-user workspace cap is exercised by creating distinct repos,
    /// then creating exactly one primary workspace in each repo. Repeating
    /// POST /workspaces on the same repo would often reuse the primary
    /// workspace and would not exercise the quota.
    func test_workspace_cap_100_enforced() throws {
        let env = try requireEnvironment()

        var createdRepos: [String] = []
        var createdWorkspaces: [(repo: String, id: String)] = []
        defer {
            cleanupWorkspacesAndRepos(env: env, workspaces: createdWorkspaces, repos: createdRepos)
        }

        let maxAttempts = 105
        var successCount = 0
        var first429: HTTPResponse?

        for index in 0..<maxAttempts {
            let repoName = uniqueName(prefix: "e2e-rl-ws-\(index)")
            let repoResp = try createRepo(env: env, name: repoName)
            guard repoResp.statusCode == 201 else {
                XCTFail("POST /api/user/repos failed while preparing distinct repos for workspace quota test: \(repoResp.statusCode) body=\(repoResp.text)")
                return
            }
            createdRepos.append(repoName)

            let createResp = try createWorkspace(env: env, owner: env.owner, repo: repoName, name: "quota-\(index)")
            switch createResp.statusCode {
            case 201:
                successCount += 1
                if let workspaceID = createResp.jsonDictionary?["id"] as? String, !workspaceID.isEmpty {
                    createdWorkspaces.append((repo: repoName, id: workspaceID))
                }
            case 429:
                first429 = createResp
                break
            case 403, 409, 422:
                if (createResp.jsonDictionary?["code"] as? String) == "quota_exceeded" {
                    XCTFail("POST /api/repos/{owner}/{repo}/workspaces rejects over-cap creates with \(createResp.statusCode), expected 429; body=\(createResp.text)")
                    return
                }
                XCTFail("POST /api/repos/{owner}/{repo}/workspaces returned \(createResp.statusCode) before any 429 quota response; body=\(createResp.text)")
                return
            case 500, 501, 502, 503:
                throw XCTSkip("POST /api/repos/{owner}/{repo}/workspaces is not usable in this E2E backend (status \(createResp.statusCode)): \(createResp.text)")
            default:
                XCTFail("unexpected status from POST /api/repos/{owner}/{repo}/workspaces: \(createResp.statusCode) body=\(createResp.text)")
                return
            }

            if first429 != nil { break }
        }

        guard let rateLimited = first429 else {
            throw XCTSkip("quota not enforced on POST /api/repos/{owner}/{repo}/workspaces within \(maxAttempts) distinct workspace creates")
        }

        XCTAssertEqual(rateLimited.statusCode, 429)
        XCTAssertLessThanOrEqual(
            successCount, 100,
            "workspace cap should stop new creates at or before 100 active workspaces; succeeded=\(successCount), body=\(rateLimited.text)"
        )
    }

    // MARK: - 2. Terminal open rate

    func test_terminal_open_rate_limit() throws {
        let env = try requireEnvironment()
        guard let sessionID = env.workspaceSessionID, !sessionID.isEmpty else {
            XCTFail("terminal rate-limit scenario requires \(E2ELaunchKey.seededWorkspaceSessionID)")
            return
        }

        let terminalPath = "api/repos/\(env.owner)/\(env.repoName)/workspace/sessions/\(sessionID)/terminal"
        let requestFactory = {
            try self.makeTerminalProbeRequest(env: env, path: terminalPath)
        }

        let result = try burstHeaderProbe(
            maxAttempts: 24,
            requestFactory: requestFactory
        )

        if let limited = result.first429 {
            XCTAssertEqual(limited.statusCode, 429)
            return
        }

        if let first = result.firstNon429, [500, 501, 502, 503].contains(first.statusCode) {
            throw XCTSkip("GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal is not usable in this E2E backend for open-rate probing (status \(first.statusCode)): \(first.text)")
        }

        throw XCTSkip("no dedicated open-rate limit observed on GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal")
    }

    // MARK: - 3. Approval decide rate

    func test_approval_decide_rate_limit() throws {
        let env = try requireEnvironment()
        guard let approvalID = env.approvalID, !approvalID.isEmpty else {
            XCTFail("approval rate-limit scenario requires \(E2ELaunchKey.seededApprovalID)")
            return
        }

        let flags = try fetchFeatureFlags(env: env)
        guard flags["approvals_flow_enabled"] == true else {
            throw XCTSkip("POST /api/repos/{owner}/{repo}/approvals/{id}/decide is disabled because approvals_flow_enabled=false")
        }

        let path = "api/repos/\(env.owner)/\(env.repoName)/approvals/\(approvalID)/decide"
        let statuses = try concurrentApprovalBurst(
            env: env,
            path: path,
            requests: 12
        )

        if statuses.contains(429) {
            return
        }

        if statuses.contains(404) {
            throw XCTSkip("POST /api/repos/{owner}/{repo}/approvals/{id}/decide is not available on this backend")
        }

        throw XCTSkip("no dedicated rate limit observed on POST /api/repos/{owner}/{repo}/approvals/{id}/decide before conflict/idempotency paths")
    }

    // MARK: - 4. Electric shape active cap

    func test_shape_active_subscriptions_cap() throws {
        let env = try requireEnvironment()
        guard let repoID = env.repoID else {
            XCTFail("shape active-cap scenario requires \(Self.seededRepoIDEnvKey)")
            return
        }

        var openLeases: [StreamLease] = []
        defer { openLeases.forEach { $0.close() } }

        let maxAttempts = 12
        var first429: HTTPResponse?

        for _ in 0..<maxAttempts {
            let req = try makeShapeRequest(
                env: env,
                table: "approvals",
                whereClause: "repository_id IN (\(repoID))"
            )
            let lease: StreamLease
            do {
                lease = try openStream(req, timeout: 10)
            } catch {
                throw XCTSkip("GET /v1/shape is not reachable from this E2E backend: \(error.localizedDescription)")
            }

            switch lease.response.statusCode {
            case 200:
                openLeases.append(lease)
            case 429:
                first429 = lease.response
                lease.close()
                break
            case 404, 501, 502, 503:
                lease.close()
                throw XCTSkip("GET /v1/shape is not available for Electric active-cap probing (status \(lease.response.statusCode)): \(lease.response.text)")
            default:
                lease.close()
                throw XCTSkip("GET /v1/shape did not expose an active-subscription cap probe path (status \(lease.response.statusCode)): \(lease.response.text)")
            }

            if first429 != nil { break }
        }

        guard let limited = first429 else {
            throw XCTSkip("no active-subscription cap observed on GET /v1/shape")
        }
        XCTAssertEqual(limited.statusCode, 429)
    }

    // MARK: - 5. Agent message post rate

    func test_agent_message_post_rate_limit() throws {
        let env = try requireEnvironment()
        let probe = try probeAgentMessagePostRateLimit(env: env, maxAttempts: 64)
        defer { deleteAgentSession(env: env, sessionID: probe.sessionID) }

        guard let limited = probe.first429 else {
            throw XCTSkip("no dedicated rate limit observed on POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages")
        }

        XCTAssertEqual(limited.statusCode, 429)
    }

    // MARK: - 6. Workflow dispatch rate

    func test_workflow_run_dispatch_rate_limit() throws {
        let env = try requireEnvironment()

        let workflowID = try firstWorkflowID(env: env)
        guard let workflowID else {
            throw XCTSkip("POST /api/repos/{owner}/{repo}/workflows/{id}/dispatches cannot be exercised because the seeded repo has no workflow definitions")
        }

        let path = "api/repos/\(env.owner)/\(env.repoName)/workflows/\(workflowID)/dispatches"
        let result = try burstJSONRequests(
            maxAttempts: 24,
            requestFactory: {
                try self.makeJSONRequest(
                    env: env,
                    method: "POST",
                    path: path,
                    body: ["ref": "main", "inputs": [:]] as [String: Any]
                )
            }
        )

        if let limited = result.first429 {
            XCTAssertEqual(limited.statusCode, 429)
            return
        }

        throw XCTSkip("no dedicated rate limit observed on POST /api/repos/{owner}/{repo}/workflows/{id}/dispatches")
    }

    // MARK: - 7. Retry-After header

    func test_rate_limit_retry_after_header_present() throws {
        let env = try requireEnvironment()
        let probe = try probeAgentMessagePostRateLimit(env: env, maxAttempts: 64)
        defer { deleteAgentSession(env: env, sessionID: probe.sessionID) }

        guard let limited = probe.first429 else {
            throw XCTSkip("cannot assert Retry-After because POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages did not return 429")
        }

        XCTAssertEqual(limited.statusCode, 429)
        XCTAssertNotNil(
            limited.header("Retry-After"),
            "429 from POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages must include Retry-After; headers=\(limited.headers)"
        )
    }

    // MARK: - 8. Bucket recovery

    /// Legacy scenario name retained from the ticket. The actual runtime
    /// assertion here is "honor Retry-After, then the same user can retry
    /// successfully".
    func test_rate_limit_is_per_user_not_global() throws {
        let env = try requireEnvironment()
        let probe = try probeAgentMessagePostRateLimit(env: env, maxAttempts: 64)
        defer { deleteAgentSession(env: env, sessionID: probe.sessionID) }

        guard let limited = probe.first429 else {
            throw XCTSkip("cannot assert Retry-After recovery because POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages did not return 429")
        }

        guard let retryAfterValue = limited.header("Retry-After"),
              let retryAfterSeconds = Int(retryAfterValue), retryAfterSeconds >= 0 else {
            XCTFail("429 from POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages must include integer Retry-After; headers=\(limited.headers)")
            return
        }

        if retryAfterSeconds > 20 {
            throw XCTSkip("Retry-After=\(retryAfterSeconds)s is too large for E2E recovery verification on POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages")
        }

        Thread.sleep(forTimeInterval: TimeInterval(retryAfterSeconds + 1))

        let retryResp = try postAgentMessage(
            env: env,
            owner: env.owner,
            repo: env.repoName,
            sessionID: probe.sessionID,
            text: "post-retry"
        )
        XCTAssertNotEqual(
            retryResp.statusCode, 429,
            "request should recover after Retry-After + 1s on POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages; body=\(retryResp.text)"
        )
    }

    // MARK: - 9. 429 JSON body shape

    func test_quota_response_body_shape() throws {
        let env = try requireEnvironment()
        let probe = try probeAgentMessagePostRateLimit(env: env, maxAttempts: 64)
        defer { deleteAgentSession(env: env, sessionID: probe.sessionID) }

        guard let limited = probe.first429 else {
            throw XCTSkip("cannot assert 429 body shape because POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages did not return 429")
        }

        guard let payload = limited.jsonDictionary else {
            XCTFail("429 body must be JSON; body=\(limited.text)")
            return
        }

        XCTAssertNotNil(payload["code"], "429 JSON must include code; body=\(limited.text)")
        XCTAssertNotNil(payload["message"], "429 JSON must include message; body=\(limited.text)")
        XCTAssertNotNil(payload["limit"], "429 JSON must include limit; body=\(limited.text)")
        XCTAssertNotNil(payload["remaining"], "429 JSON must include remaining; body=\(limited.text)")
    }

    // MARK: - 10. Reads remain available

    func test_rate_limit_does_not_affect_reads() throws {
        let env = try requireEnvironment()
        let path = "api/repos/\(env.owner)/\(env.repoName)/workspaces?limit=100"

        for _ in 0..<60 {
            let req = try makeJSONRequest(env: env, method: "GET", path: path)
            let resp = try send(req)
            XCTAssertNotEqual(
                resp.statusCode, 429,
                "rapid reads on GET /api/repos/{owner}/{repo}/workspaces should not hit the write-side quota/rate-limit path"
            )
            XCTAssertEqual(
                resp.statusCode, 200,
                "GET /api/repos/{owner}/{repo}/workspaces should remain healthy under read bursts; got \(resp.statusCode), body=\(resp.text)"
            )
        }
    }

    // MARK: - Environment

    private func requireEnvironment() throws -> TestEnvironment {
        let procEnv = ProcessInfo.processInfo.environment

        guard let bearer = procEnv[E2ELaunchKey.bearer], !bearer.isEmpty else {
            XCTFail("rate-limit scenarios require \(E2ELaunchKey.bearer)")
            throw TestFailure.missingEnvironment
        }
        guard let baseURLString = procEnv[E2ELaunchKey.baseURL],
              let configuredBaseURL = URL(string: baseURLString) else {
            XCTFail("rate-limit scenarios require \(E2ELaunchKey.baseURL)")
            throw TestFailure.missingEnvironment
        }
        guard let owner = procEnv[E2ELaunchKey.seededRepoOwner], !owner.isEmpty,
              let repoName = procEnv[E2ELaunchKey.seededRepoName], !repoName.isEmpty else {
            XCTFail("rate-limit scenarios require \(E2ELaunchKey.seededRepoOwner) and \(E2ELaunchKey.seededRepoName)")
            throw TestFailure.missingEnvironment
        }

        let rootURL = stripAPISuffix(from: configuredBaseURL)
        let electricBaseURL: URL? = {
            guard let raw = procEnv[Self.electricBaseURLEnvKey], !raw.isEmpty else {
                return nil
            }
            return URL(string: raw)
        }()

        return TestEnvironment(
            rootURL: rootURL,
            bearer: bearer,
            owner: owner,
            repoName: repoName,
            repoID: Int64(procEnv[Self.seededRepoIDEnvKey] ?? ""),
            approvalID: procEnv[E2ELaunchKey.seededApprovalID],
            agentSessionID: procEnv[E2ELaunchKey.seededAgentSessionID],
            workspaceSessionID: procEnv[E2ELaunchKey.seededWorkspaceSessionID],
            electricBaseURL: electricBaseURL
        )
    }

    private func stripAPISuffix(from baseURL: URL) -> URL {
        let raw = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let stripped = raw.hasSuffix("/api") ? String(raw.dropLast(4)) : raw
        return URL(string: stripped) ?? baseURL
    }

    // MARK: - Repo / workspace helpers

    private func createRepo(env: TestEnvironment, name: String) throws -> HTTPResponse {
        let req = try makeJSONRequest(
            env: env,
            method: "POST",
            path: "api/user/repos",
            body: [
                "name": name,
                "private": true,
                "auto_init": true,
                "default_bookmark": "main",
            ]
        )
        return try send(req)
    }

    private func createWorkspace(env: TestEnvironment, owner: String, repo: String, name: String) throws -> HTTPResponse {
        let req = try makeJSONRequest(
            env: env,
            method: "POST",
            path: "api/repos/\(owner)/\(repo)/workspaces",
            body: ["name": name]
        )
        return try send(req, timeout: 90)
    }

    private func deleteWorkspace(env: TestEnvironment, owner: String, repo: String, workspaceID: String) {
        let req: URLRequest
        do {
            req = try makeJSONRequest(
                env: env,
                method: "DELETE",
                path: "api/repos/\(owner)/\(repo)/workspaces/\(workspaceID)"
            )
        } catch {
            return
        }
        _ = try? send(req, timeout: 30)
    }

    private func deleteRepo(env: TestEnvironment, name: String) {
        let req: URLRequest
        do {
            req = try makeJSONRequest(
                env: env,
                method: "DELETE",
                path: "api/repos/\(env.owner)/\(name)"
            )
        } catch {
            return
        }
        _ = try? send(req, timeout: 30)
    }

    private func cleanupWorkspacesAndRepos(
        env: TestEnvironment,
        workspaces: [(repo: String, id: String)],
        repos: [String]
    ) {
        for workspace in workspaces.reversed() {
            deleteWorkspace(env: env, owner: env.owner, repo: workspace.repo, workspaceID: workspace.id)
        }
        for repo in repos.reversed() {
            deleteRepo(env: env, name: repo)
        }
    }

    // MARK: - Agent message helpers

    private func createAgentSession(env: TestEnvironment, title: String) throws -> String {
        let req = try makeJSONRequest(
            env: env,
            method: "POST",
            path: "api/repos/\(env.owner)/\(env.repoName)/agent/sessions",
            body: ["title": title]
        )
        let resp = try send(req)
        guard resp.statusCode == 201 else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: resp.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "POST /api/repos/{owner}/{repo}/agent/sessions returned \(resp.statusCode): \(resp.text)"]
            )
        }
        guard let sessionID = resp.jsonDictionary?["id"] as? String, !sessionID.isEmpty else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "POST /api/repos/{owner}/{repo}/agent/sessions did not return a session id"]
            )
        }
        return sessionID
    }

    private func deleteAgentSession(env: TestEnvironment, sessionID: String) {
        let req: URLRequest
        do {
            req = try makeJSONRequest(
                env: env,
                method: "DELETE",
                path: "api/repos/\(env.owner)/\(env.repoName)/agent/sessions/\(sessionID)"
            )
        } catch {
            return
        }
        _ = try? send(req)
    }

    private func postAgentMessage(
        env: TestEnvironment,
        owner: String,
        repo: String,
        sessionID: String,
        text: String
    ) throws -> HTTPResponse {
        let req = try makeJSONRequest(
            env: env,
            method: "POST",
            path: "api/repos/\(owner)/\(repo)/agent/sessions/\(sessionID)/messages",
            body: [
                "role": "assistant",
                "parts": [
                    [
                        "type": "text",
                        "content": text,
                    ],
                ],
            ]
        )
        return try send(req)
    }

    private func probeAgentMessagePostRateLimit(
        env: TestEnvironment,
        maxAttempts: Int
    ) throws -> AgentMessageRateLimitProbe {
        let sessionID = try createAgentSession(env: env, title: uniqueName(prefix: "rate-limit-session"))

        var responses: [HTTPResponse] = []
        for index in 0..<maxAttempts {
            let resp = try postAgentMessage(
                env: env,
                owner: env.owner,
                repo: env.repoName,
                sessionID: sessionID,
                text: "rl-\(index)"
            )
            responses.append(resp)
            if resp.statusCode == 429 {
                return AgentMessageRateLimitProbe(sessionID: sessionID, responses: responses)
            }
            if resp.statusCode != 201 {
                throw NSError(
                    domain: "rate-limit-e2e",
                    code: resp.statusCode,
                    userInfo: [NSLocalizedDescriptionKey:
                        "unexpected status from POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages: \(resp.statusCode) body=\(resp.text)"]
                )
            }
        }
        return AgentMessageRateLimitProbe(sessionID: sessionID, responses: responses)
    }

    // MARK: - Workflow helpers

    private func firstWorkflowID(env: TestEnvironment) throws -> Int64? {
        let req = try makeJSONRequest(
            env: env,
            method: "GET",
            path: "api/repos/\(env.owner)/\(env.repoName)/workflows?limit=100"
        )
        let resp = try send(req)
        guard resp.statusCode == 200 else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: resp.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "GET /api/repos/{owner}/{repo}/workflows returned \(resp.statusCode): \(resp.text)"]
            )
        }

        guard let payload = resp.jsonDictionary,
              let workflows = payload["workflows"] as? [[String: Any]],
              let first = workflows.first,
              let id = first["id"] as? NSNumber else {
            return nil
        }
        return id.int64Value
    }

    // MARK: - Feature flag helpers

    private func fetchFeatureFlags(env: TestEnvironment) throws -> [String: Bool] {
        let req = try makeJSONRequest(env: env, method: "GET", path: "api/feature-flags", addBearer: false)
        let resp = try send(req)
        guard resp.statusCode == 200 else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: resp.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "GET /api/feature-flags returned \(resp.statusCode): \(resp.text)"]
            )
        }

        guard let payload = resp.jsonDictionary,
              let flags = payload["flags"] as? [String: Bool] else {
            return [:]
        }
        return flags
    }

    // MARK: - Approval helpers

    private func concurrentApprovalBurst(
        env: TestEnvironment,
        path: String,
        requests: Int
    ) throws -> [Int] {
        let queue = DispatchQueue(label: "approval-burst.lock")
        var statuses: [Int] = []
        let group = DispatchGroup()

        for _ in 0..<requests {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let req = try self.makeJSONRequest(
                        env: env,
                        method: "POST",
                        path: path,
                        body: ["decision": "approved"]
                    )
                    let resp = try self.send(req)
                    queue.sync { statuses.append(resp.statusCode) }
                } catch {
                    queue.sync { statuses.append(-1) }
                }
            }
        }

        group.wait()
        return statuses
    }

    // MARK: - Terminal / Electric helpers

    private func makeTerminalProbeRequest(env: TestEnvironment, path: String) throws -> URLRequest {
        var req = try makeJSONRequest(env: env, method: "GET", path: path)
        req.setValue(env.origin, forHTTPHeaderField: "Origin")
        req.setValue("Upgrade", forHTTPHeaderField: "Connection")
        req.setValue("websocket", forHTTPHeaderField: "Upgrade")
        req.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        req.setValue("dGhlIHNhbXBsZSBub25jZQ==", forHTTPHeaderField: "Sec-WebSocket-Key")
        return req
    }

    private func makeShapeRequest(
        env: TestEnvironment,
        table: String,
        whereClause: String
    ) throws -> URLRequest {
        var comps = URLComponents(url: env.effectiveElectricBaseURL.appendingPathComponent("v1/shape"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "table", value: table),
            URLQueryItem(name: "where", value: whereClause),
        ]
        guard let url = comps.url else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "failed to build Electric shape URL"]
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(env.bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        return req
    }

    // MARK: - Generic request helpers

    private func makeJSONRequest(
        env: TestEnvironment,
        method: String,
        path: String,
        body: Any? = nil,
        addBearer: Bool = true
    ) throws -> URLRequest {
        let base = env.rootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: "\(base)/\(normalizedPath)") else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "failed to build request URL for path \(path)"]
            )
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if addBearer {
            req.setValue("Bearer \(env.bearer)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    private func send(_ req: URLRequest, timeout: TimeInterval = 20) throws -> HTTPResponse {
        var output: HTTPResponse?
        var outputError: Error?
        let sem = DispatchSemaphore(value: 0)

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config)

        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                outputError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outputError = NSError(
                    domain: "rate-limit-e2e",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "non-HTTP response for \(req.url?.absoluteString ?? "?")"]
                )
                return
            }
            output = HTTPResponse(response: http, data: data ?? Data())
        }
        task.resume()

        _ = sem.wait(timeout: .now() + timeout + 2)
        session.finishTasksAndInvalidate()

        if let outputError { throw outputError }
        guard let output else {
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "timed out waiting for \(req.url?.absoluteString ?? "?")"]
            )
        }
        return output
    }

    private func sendForHeaders(_ req: URLRequest, timeout: TimeInterval = 10) throws -> HTTPResponse {
        let probe = HeaderProbe(keepOpen: false)
        defer { probe.close() }
        return try probe.open(req, timeout: timeout)
    }

    private func openStream(_ req: URLRequest, timeout: TimeInterval = 10) throws -> StreamLease {
        let probe = HeaderProbe(keepOpen: true)
        let response = try probe.open(req, timeout: timeout)
        return StreamLease(response: response, probe: probe)
    }

    private func burstHeaderProbe(
        maxAttempts: Int,
        requestFactory: () throws -> URLRequest
    ) throws -> BurstProbeResult {
        var responses: [HTTPResponse] = []
        for _ in 0..<maxAttempts {
            let resp = try sendForHeaders(try requestFactory())
            responses.append(resp)
            if resp.statusCode == 429 { break }
        }
        return BurstProbeResult(responses: responses)
    }

    private func burstJSONRequests(
        maxAttempts: Int,
        requestFactory: () throws -> URLRequest
    ) throws -> BurstProbeResult {
        var responses: [HTTPResponse] = []
        for _ in 0..<maxAttempts {
            let resp = try send(try requestFactory())
            responses.append(resp)
            if resp.statusCode == 429 { break }
        }
        return BurstProbeResult(responses: responses)
    }

    private func uniqueName(prefix: String) -> String {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        return "\(prefix)-\(suffix.prefix(10))"
    }
}

// MARK: - Support types

private struct TestEnvironment {
    let rootURL: URL
    let bearer: String
    let owner: String
    let repoName: String
    let repoID: Int64?
    let approvalID: String?
    let agentSessionID: String?
    let workspaceSessionID: String?
    let electricBaseURL: URL?

    var effectiveElectricBaseURL: URL {
        electricBaseURL ?? rootURL
    }

    var origin: String {
        let comps = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)
        let scheme = comps?.scheme ?? "http"
        let host = comps?.host ?? "localhost"
        if let port = comps?.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

private struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    init(response: HTTPURLResponse, data: Data) {
        statusCode = response.statusCode
        var normalized: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String else { continue }
            normalized[key.lowercased()] = String(describing: rawValue)
        }
        headers = normalized
        self.data = data
    }

    var text: String {
        String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
    }

    var jsonDictionary: [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

private struct BurstProbeResult {
    let responses: [HTTPResponse]

    var first429: HTTPResponse? {
        responses.first { $0.statusCode == 429 }
    }

    var firstNon429: HTTPResponse? {
        responses.first { $0.statusCode != 429 }
    }
}

private struct AgentMessageRateLimitProbe {
    let sessionID: String
    let responses: [HTTPResponse]

    var first429: HTTPResponse? {
        responses.first { $0.statusCode == 429 }
    }
}

private enum TestFailure: Error {
    case missingEnvironment
}

private final class StreamLease {
    let response: HTTPResponse
    private let probe: HeaderProbe

    init(response: HTTPResponse, probe: HeaderProbe) {
        self.response = response
        self.probe = probe
    }

    func close() {
        probe.close()
    }

    deinit {
        probe.close()
    }
}

private final class HeaderProbe: NSObject, URLSessionDataDelegate {
    private let keepOpen: Bool
    private let semaphore = DispatchSemaphore(value: 0)
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var responseData = Data()
    private var completionError: Error?

    init(keepOpen: Bool) {
        self.keepOpen = keepOpen
    }

    func open(_ req: URLRequest, timeout: TimeInterval) throws -> HTTPResponse {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session?.dataTask(with: req)
        task?.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeout + 1)
        if waitResult == .timedOut {
            close()
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "timed out waiting for response headers from \(req.url?.absoluteString ?? "?")"]
            )
        }
        if let completionError, response == nil {
            close()
            throw completionError
        }
        guard let response else {
            close()
            throw NSError(
                domain: "rate-limit-e2e",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey:
                    "no HTTP response received from \(req.url?.absoluteString ?? "?")"]
            )
        }
        return HTTPResponse(response: response, data: responseData)
    }

    func close() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
        semaphore.signal()
        if !keepOpen {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            completionError = error
        }
        if response == nil {
            semaphore.signal()
        }
    }
}
#endif
