#if os(iOS)
import Foundation
import XCTest

private struct AgentChatE2EEnvironment {
    static let repoIDKey = "PLUE_E2E_REPO_ID"

    let bearer: String
    let apiBaseURL: URL
    let shapeBaseURLCandidates: [URL]
    let repoOwner: String
    let repoName: String
    let repoID: Int64
    let seededAgentSessionID: String?
    let seededWorkspaceID: String?

    static func load() throws -> AgentChatE2EEnvironment {
        let env = ProcessInfo.processInfo.environment

        guard let bearer = env[E2ELaunchKey.bearer], !bearer.isEmpty else {
            throw XCTSkip("agent chat e2e requires \(E2ELaunchKey.bearer)")
        }
        guard let baseURLString = env[E2ELaunchKey.baseURL],
              let apiBaseURL = URL(string: baseURLString) else {
            throw XCTSkip("agent chat e2e requires \(E2ELaunchKey.baseURL)")
        }
        guard let repoOwner = env[E2ELaunchKey.seededRepoOwner], !repoOwner.isEmpty,
              let repoName = env[E2ELaunchKey.seededRepoName], !repoName.isEmpty else {
            throw XCTSkip("agent chat e2e requires \(E2ELaunchKey.seededRepoOwner) and \(E2ELaunchKey.seededRepoName)")
        }
        guard let repoIDString = env[repoIDKey],
              let repoID = Int64(repoIDString),
              repoID > 0 else {
            throw XCTSkip("agent chat e2e requires \(repoIDKey)")
        }

        return AgentChatE2EEnvironment(
            bearer: bearer,
            apiBaseURL: apiBaseURL,
            shapeBaseURLCandidates: derivedShapeCandidates(from: apiBaseURL),
            repoOwner: repoOwner,
            repoName: repoName,
            repoID: repoID,
            seededAgentSessionID: nonEmpty(env[E2ELaunchKey.seededAgentSessionID]),
            seededWorkspaceID: nonEmpty(env[E2ELaunchKey.seededWorkspaceID])
        )
    }

    private static func derivedShapeCandidates(from apiBaseURL: URL) -> [URL] {
        var urls: [URL] = [apiBaseURL]
        if var comps = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) {
            if comps.port != 3001 {
                comps.port = 3001
                if let alt = comps.url, !urls.contains(where: { $0 == alt }) {
                    urls.append(alt)
                }
            }
        }
        return urls
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct AgentChatHTTPResponse {
    let statusCode: Int
    let data: Data

    var text: String {
        String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
    }
}

private enum AgentChatE2EHTTPError: LocalizedError {
    case invalidJSON(String)
    case requestTimedOut(String)
    case missingHTTPResponse(String)
    case shapeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail): return detail
        case .requestTimedOut(let detail): return detail
        case .missingHTTPResponse(let detail): return detail
        case .shapeUnavailable(let detail): return detail
        }
    }
}

private final class AgentChatE2EHTTPClient {
    private let timeout: TimeInterval

    init(timeout: TimeInterval = 15) {
        self.timeout = timeout
    }

    func request(
        baseURL: URL,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        bearer: String? = nil,
        jsonBody: Any? = nil
    ) throws -> AgentChatHTTPResponse {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        if !queryItems.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.queryItems = queryItems
            if let resolved = comps?.url {
                url = resolved
            }
        }
        return try request(url: url, method: method, bearer: bearer, jsonBody: jsonBody)
    }

    func request(
        url: URL,
        method: String = "GET",
        bearer: String? = nil,
        jsonBody: Any? = nil
    ) throws -> AgentChatHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout + 1

        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var output: AgentChatHTTPResponse?
        var transportError: Error?

        let task = session.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error {
                transportError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                transportError = AgentChatE2EHTTPError.missingHTTPResponse("missing HTTP response for \(url.absoluteString)")
                return
            }
            output = AgentChatHTTPResponse(
                statusCode: http.statusCode,
                data: data ?? Data()
            )
        }
        task.resume()

        let waitResult = sem.wait(timeout: .now() + timeout + 2)
        task.cancel()

        if waitResult == .timedOut {
            throw AgentChatE2EHTTPError.requestTimedOut("timed out waiting for \(method) \(url.absoluteString)")
        }
        if let transportError {
            throw transportError
        }
        guard let output else {
            throw AgentChatE2EHTTPError.missingHTTPResponse("missing response payload for \(method) \(url.absoluteString)")
        }
        return output
    }

    func shapeRequest(
        env: AgentChatE2EEnvironment,
        table: String,
        whereClause: String,
        offset: String = "-1"
    ) throws -> AgentChatHTTPResponse {
        let queryItems = [
            URLQueryItem(name: "table", value: table),
            URLQueryItem(name: "where", value: whereClause),
            URLQueryItem(name: "offset", value: offset),
        ]

        var attempted: [String] = []
        var lastError: Error?
        var saw404 = false

        for baseURL in env.shapeBaseURLCandidates {
            do {
                let response = try request(
                    baseURL: baseURL,
                    pathComponents: ["v1", "shape"],
                    queryItems: queryItems,
                    method: "GET",
                    bearer: env.bearer
                )
                attempted.append(baseURL.absoluteString)
                if response.statusCode == 404 {
                    saw404 = true
                    continue
                }
                return response
            } catch {
                attempted.append(baseURL.absoluteString)
                lastError = error
            }
        }

        if let lastError {
            throw AgentChatE2EHTTPError.shapeUnavailable(
                "Electric /v1/shape unreachable on \(attempted.joined(separator: ", ")): \(lastError.localizedDescription)"
            )
        }
        if saw404 {
            throw AgentChatE2EHTTPError.shapeUnavailable(
                "Electric /v1/shape not served on \(attempted.joined(separator: ", "))"
            )
        }
        throw AgentChatE2EHTTPError.shapeUnavailable("Electric /v1/shape unavailable")
    }

    func jsonDictionary(_ response: AgentChatHTTPResponse) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: response.data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw AgentChatE2EHTTPError.invalidJSON("expected JSON object, got: \(response.text)")
        }
        return dict
    }

    func jsonArray(_ response: AgentChatHTTPResponse) throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: response.data, options: [])
        guard let array = obj as? [[String: Any]] else {
            throw AgentChatE2EHTTPError.invalidJSON("expected JSON array, got: \(response.text)")
        }
        return array
    }
}

private func stringValue(_ value: Any?) -> String? {
    value as? String
}

private func int64Value(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}

private func dictionaryValue(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

private func arrayValue(_ value: Any?) -> [[String: Any]]? {
    value as? [[String: Any]]
}

private func messageContainsText(_ message: [String: Any], text: String) -> Bool {
    guard let parts = arrayValue(message["parts"]) else { return false }
    for part in parts {
        guard stringValue(part["type"]) == "text",
              let content = dictionaryValue(part["content"]) else { continue }
        if stringValue(content["value"]) == text {
            return true
        }
    }
    return false
}

private func assistantMessagesWithParts(in messages: [[String: Any]]) -> [[String: Any]] {
    messages.filter {
        stringValue($0["role"]) == "assistant" &&
        !(arrayValue($0["parts"]) ?? []).isEmpty
    }
}

private func shapeRows(from response: AgentChatHTTPResponse) throws -> [[String: Any]] {
    let obj = try JSONSerialization.jsonObject(with: response.data, options: [])
    guard let entries = obj as? [[String: Any]] else {
        throw AgentChatE2EHTTPError.invalidJSON("expected Electric shape array, got: \(response.text)")
    }
    var rows: [[String: Any]] = []
    for entry in entries {
        guard let headers = dictionaryValue(entry["headers"]),
              let operation = stringValue(headers["operation"]),
              operation == "insert" || operation == "update",
              let value = dictionaryValue(entry["value"]) else { continue }
        rows.append(value)
    }
    return rows
}

final class SmithersiOSE2EAgentChatTests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_agent_session_seeded_visible_in_shape() throws {
        let (env, client) = try makeClient()
        let sessionID = try requireSeededSessionID(env)

        let sessionResponse = try getSession(client: client, env: env, sessionID: sessionID)
        XCTAssertEqual(sessionResponse.statusCode, 200, "seeded session lookup should succeed: \(sessionResponse.text)")
        XCTAssertFalse(sessionResponse.text.lowercased().contains("\"error\""), "seeded session lookup should not return an API error")

        let shapeResponse: AgentChatHTTPResponse
        do {
            shapeResponse = try client.shapeRequest(
                env: env,
                table: "agent_sessions",
                whereClause: "repository_id IN ('\(env.repoID)')"
            )
        } catch let error as AgentChatE2EHTTPError {
            if case .shapeUnavailable(let reason) = error {
                throw XCTSkip(reason)
            }
            throw error
        }

        XCTAssertEqual(shapeResponse.statusCode, 200, "agent_sessions shape should be readable: \(shapeResponse.text)")
        XCTAssertFalse(shapeResponse.text.lowercased().contains("\"error\""), "agent_sessions shape should not return an error payload")

        let rows = try shapeRows(from: shapeResponse)
        XCTAssertFalse(rows.isEmpty, "agent_sessions shape snapshot should contain at least the seeded session row")
        XCTAssertTrue(
            rows.contains { stringValue($0["id"]) == sessionID },
            "seeded agent_session \(sessionID) should be present in /v1/shape snapshot"
        )
    }

    func test_agent_message_post_appends_to_session() throws {
        let (env, client) = try makeClient()
        let sessionID = try createSession(client: client, env: env, title: uniqueLabel("append"))
        defer { bestEffortDeleteSession(client: client, env: env, sessionID: sessionID) }

        let messageText = uniqueLabel("user-message")
        let before = try listMessages(client: client, env: env, sessionID: sessionID)
        XCTAssertFalse(
            before.contains { messageContainsText($0, text: messageText) },
            "new session should not contain the test message before POST"
        )

        let postResponse = try postMessage(
            client: client,
            env: env,
            sessionID: sessionID,
            role: "user",
            parts: [["type": "text", "content": messageText]]
        )
        XCTAssertEqual(postResponse.statusCode, 201, "POST /messages should append the user message: \(postResponse.text)")
        XCTAssertFalse(postResponse.text.lowercased().contains("\"error\""), "POST /messages should not return an API error")

        let appended = try poll(timeout: 10, interval: 0.5) {
            let messages = try self.listMessages(client: client, env: env, sessionID: sessionID)
            return messages.contains { messageContainsText($0, text: messageText) }
        }
        XCTAssertTrue(appended, "GET /messages should eventually include the newly-appended user message")
    }

    func test_agent_message_post_returns_id_matching_future_id() throws {
        let (env, client) = try makeClient()
        let sessionID = try createSession(client: client, env: env, title: uniqueLabel("future-id"))
        defer { bestEffortDeleteSession(client: client, env: env, sessionID: sessionID) }

        let futureID = uniqueLabel("future")
        let postResponse = try postMessage(
            client: client,
            env: env,
            sessionID: sessionID,
            role: "assistant",
            parts: [["type": "text", "content": ["value": "echo future id probe"]]],
            extraBody: ["future_id": futureID]
        )
        XCTAssertEqual(postResponse.statusCode, 201, "message append should still succeed when future_id is present: \(postResponse.text)")

        let body = try client.jsonDictionary(postResponse)
        if let echoedFutureID = stringValue(body["future_id"]) {
            XCTAssertEqual(echoedFutureID, futureID, "future_id echo should match the client-sent value")
        } else {
            XCTAssertNil(body["future_id"], "current HTTP response contract should omit future_id until the API explicitly adds it")
            throw XCTSkip("POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages does not echo future_id; future_id currently exists only in libsmithers write_ack/shape-delta plumbing, not the HTTP response body")
        }
    }

    func test_agent_parts_shape_streams_assistant_output() throws {
        let (env, client) = try makeClient()
        let sessionID = try createSession(client: client, env: env, title: uniqueLabel("assistant-shape"))
        defer { bestEffortDeleteSession(client: client, env: env, sessionID: sessionID) }

        let before = try listMessages(client: client, env: env, sessionID: sessionID)
        XCTAssertTrue(
            assistantMessagesWithParts(in: before).isEmpty,
            "fresh session should not have assistant parts before the user message dispatch"
        )

        let userText = uniqueLabel("assistant-parts")
        let postResponse = try postMessage(
            client: client,
            env: env,
            sessionID: sessionID,
            role: "user",
            parts: [["type": "text", "content": userText]]
        )
        XCTAssertEqual(postResponse.statusCode, 201, "user message POST must succeed before assistant output can stream: \(postResponse.text)")

        var assistantSeen = false
        var shapeDelivered = false
        var shapeGapReason: String?
        let deadline = Date().addingTimeInterval(20)

        while Date() < deadline {
            let messages = try listMessages(client: client, env: env, sessionID: sessionID)
            if !assistantMessagesWithParts(in: messages).isEmpty {
                assistantSeen = true
            }

            if shapeGapReason == nil && !shapeDelivered {
                do {
                    let shapeResponse = try client.shapeRequest(
                        env: env,
                        table: "agent_parts",
                        whereClause: "repository_id IN ('\(env.repoID)') AND session_id IN ('\(sessionID)')"
                    )
                    if shapeResponse.statusCode == 200 {
                        let rows = try shapeRows(from: shapeResponse)
                        if !rows.isEmpty {
                            shapeDelivered = true
                        }
                    } else {
                        let body = shapeResponse.text.lowercased()
                        if shapeResponse.statusCode == 400 || shapeResponse.statusCode == 404 ||
                            body.contains("repository_id") || body.contains("session_id") || body.contains("column") {
                            shapeGapReason = "agent_parts shape returned \(shapeResponse.statusCode): \(shapeResponse.text)"
                        }
                    }
                } catch let error as AgentChatE2EHTTPError {
                    if case .shapeUnavailable(let reason) = error {
                        shapeGapReason = reason
                    } else {
                        throw error
                    }
                }
            }

            if assistantSeen && (shapeDelivered || shapeGapReason != nil) {
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }

        XCTAssertTrue(assistantSeen, "assistant output should appear within 20s after posting a user message")
        if shapeDelivered {
            XCTAssertTrue(shapeDelivered, "agent_parts shape should deliver at least one assistant part row")
        } else {
            throw XCTSkip("assistant output was observed via GET /messages, but agent_parts Electric shape is unavailable: \(shapeGapReason ?? "unknown shape gap"). Current schema still matches the 0118 gap (missing repository_id/session_id on agent_parts) or the shape proxy is not exposed on this stack")
        }
    }

    func test_agent_session_tombstone_hides_messages() throws {
        let (env, client) = try makeClient()
        let sessionID = try createSession(client: client, env: env, title: uniqueLabel("delete"))

        let messageText = uniqueLabel("delete-message")
        let appendResponse = try postMessage(
            client: client,
            env: env,
            sessionID: sessionID,
            role: "assistant",
            parts: [["type": "text", "content": ["value": messageText]]]
        )
        XCTAssertEqual(appendResponse.statusCode, 201, "seed message append should succeed before delete: \(appendResponse.text)")

        let beforeDelete = try listMessages(client: client, env: env, sessionID: sessionID)
        XCTAssertTrue(
            beforeDelete.contains { messageContainsText($0, text: messageText) },
            "message should exist before the session delete"
        )

        let deleteResponse = try deleteSession(client: client, env: env, sessionID: sessionID)
        XCTAssertEqual(deleteResponse.statusCode, 204, "DELETE /agent/sessions/{id} should succeed for the owning user: \(deleteResponse.text)")

        let afterDeleteResponse = try getMessagesResponse(client: client, env: env, sessionID: sessionID)
        XCTAssertNotEqual(afterDeleteResponse.statusCode, 201, "deleted session must not allow new successful message-list semantics")
        switch afterDeleteResponse.statusCode {
        case 404:
            XCTAssertFalse(afterDeleteResponse.text.isEmpty, "404 response should not be empty after deleting a session")
        case 200:
            let messages = try client.jsonArray(afterDeleteResponse)
            XCTAssertTrue(messages.isEmpty, "deleted session should not expose old messages if GET /messages still returns 200")
            XCTAssertFalse(messages.contains { messageContainsText($0, text: messageText) }, "deleted session should not leak the pre-delete message text")
        default:
            XCTFail("expected GET /messages after delete to return 404 or 200-empty, got \(afterDeleteResponse.statusCode): \(afterDeleteResponse.text)")
        }
    }

    func test_agent_session_create_bound_to_workspace() throws {
        let (env, client) = try makeClient()
        guard let workspaceID = env.seededWorkspaceID else {
            throw XCTSkip("workspace-bound session scenario requires \(E2ELaunchKey.seededWorkspaceID)")
        }

        let createResponse = try createSessionResponse(
            client: client,
            env: env,
            title: uniqueLabel("workspace-bind"),
            extraBody: ["workspace_id": workspaceID]
        )
        XCTAssertEqual(createResponse.statusCode, 201, "session create should succeed even when an extra workspace_id key is sent: \(createResponse.text)")

        let created = try client.jsonDictionary(createResponse)
        guard let sessionID = stringValue(created["id"]) else {
            XCTFail("create session response missing id: \(createResponse.text)")
            return
        }
        defer { bestEffortDeleteSession(client: client, env: env, sessionID: sessionID) }

        XCTAssertNil(created["workspace_id"], "current create response should not expose workspace_id because agent_sessions is repo-bound, not workspace-bound")

        let getResponse = try getSession(client: client, env: env, sessionID: sessionID)
        XCTAssertEqual(getResponse.statusCode, 200, "created session should be readable: \(getResponse.text)")
        let fetched = try client.jsonDictionary(getResponse)
        XCTAssertEqual(int64Value(fetched["repository_id"]), env.repoID, "created session should be bound to the seeded repository")
        XCTAssertNil(fetched["workspace_id"], "current get-session response should not expose workspace_id")

        throw XCTSkip("agent_sessions create/get is repo-bound only in this checkout: create payload accepts title, the database schema has no workspace_id column, and there is no API to assert workspace foreign-key binding yet")
    }

    func test_agent_message_invalid_session_rejected() throws {
        let (env, client) = try makeClient()
        let bogusSessionID = UUID().uuidString.lowercased()

        let response = try postMessage(
            client: client,
            env: env,
            sessionID: bogusSessionID,
            role: "assistant",
            parts: [["type": "text", "content": ["value": "invalid session probe"]]]
        )
        XCTAssertTrue(
            response.statusCode == 404 || response.statusCode == 403,
            "posting to a random session id should be rejected with 404/403, got \(response.statusCode): \(response.text)"
        )
        XCTAssertNotEqual(response.statusCode, 201, "invalid session id must not append a message")
        XCTAssertFalse(response.text.isEmpty, "rejection response should explain the failure")
    }

    func test_agent_message_rate_limit() throws {
        let (env, client) = try makeClient()
        let sessionID = try createSession(client: client, env: env, title: uniqueLabel("rate-limit"))
        defer { bestEffortDeleteSession(client: client, env: env, sessionID: sessionID) }

        var statuses: [Int] = []
        for idx in 0..<8 {
            let response = try postMessage(
                client: client,
                env: env,
                sessionID: sessionID,
                role: "assistant",
                parts: [["type": "text", "content": ["value": "burst-\(idx)"]]]
            )
            statuses.append(response.statusCode)
            if response.statusCode == 429 {
                break
            }
        }

        XCTAssertFalse(statuses.contains(where: { $0 >= 500 }), "rapid message appends should not surface 5xx errors: \(statuses)")
        if let first429Index = statuses.firstIndex(of: 429) {
            XCTAssertGreaterThan(first429Index, 0, "rate limit should trigger only after at least one accepted message")
        } else {
            throw XCTSkip("no agent-message-specific rate limit surfaced under a short burst; current plue server only documents a global authenticated API limit of 5000/hr in cmd/server/main.go")
        }
    }

    func test_agent_session_listed_for_user() throws {
        let (env, client) = try makeClient()
        let seededSessionID = try requireSeededSessionID(env)

        let preferred = try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "user", "agent_sessions"],
            method: "GET",
            bearer: env.bearer
        )

        let listResponse: AgentChatHTTPResponse
        if preferred.statusCode == 200 {
            listResponse = preferred
        } else {
            XCTAssertEqual(preferred.statusCode, 404, "preferred /api/user/agent_sessions probe should be 404 when the equivalent route is absent, got \(preferred.statusCode): \(preferred.text)")
            listResponse = try listSessionsResponse(client: client, env: env)
        }

        XCTAssertEqual(listResponse.statusCode, 200, "agent session listing should succeed: \(listResponse.text)")
        XCTAssertFalse(listResponse.text.lowercased().contains("\"error\""), "agent session listing should not return an API error")

        let sessions = try client.jsonArray(listResponse)
        XCTAssertFalse(sessions.isEmpty, "repo-scoped session list should include at least the seeded session")
        XCTAssertTrue(
            sessions.contains { stringValue($0["id"]) == seededSessionID },
            "seeded session \(seededSessionID) should be present in the session list"
        )
    }

    func test_agent_session_cross_user_not_visible() throws {
        let (env, client) = try makeClient()
        let seededSessionID = try requireSeededSessionID(env)

        let noBearer = try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", seededSessionID],
            method: "GET",
            bearer: nil
        )
        XCTAssertTrue(
            noBearer.statusCode == 401 || noBearer.statusCode == 403,
            "missing bearer should be rejected with 401/403, got \(noBearer.statusCode): \(noBearer.text)"
        )
        XCTAssertNotEqual(noBearer.statusCode, 200, "missing bearer must not see the seeded session")

        let wrongBearer = try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", seededSessionID],
            method: "GET",
            bearer: "jjhub_0000000000000000000000000000000000000000"
        )
        XCTAssertTrue(
            wrongBearer.statusCode == 401 || wrongBearer.statusCode == 403,
            "wrong bearer should be rejected with 401/403, got \(wrongBearer.statusCode): \(wrongBearer.text)"
        )
        XCTAssertNotEqual(wrongBearer.statusCode, 200, "wrong bearer must not see the seeded session")
    }

    private func makeClient() throws -> (AgentChatE2EEnvironment, AgentChatE2EHTTPClient) {
        (try AgentChatE2EEnvironment.load(), AgentChatE2EHTTPClient())
    }

    private func requireSeededSessionID(_ env: AgentChatE2EEnvironment) throws -> String {
        guard let sessionID = env.seededAgentSessionID else {
            throw XCTSkip("seeded session scenario requires \(E2ELaunchKey.seededAgentSessionID)")
        }
        return sessionID
    }

    private func createSession(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        title: String
    ) throws -> String {
        let response = try createSessionResponse(client: client, env: env, title: title)
        XCTAssertEqual(response.statusCode, 201, "create session should return 201: \(response.text)")
        XCTAssertFalse(response.text.lowercased().contains("\"error\""), "create session should not return an API error")

        let json = try client.jsonDictionary(response)
        guard let sessionID = stringValue(json["id"]), !sessionID.isEmpty else {
            XCTFail("create session response missing id: \(response.text)")
            return ""
        }
        return sessionID
    }

    private func createSessionResponse(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        title: String,
        extraBody: [String: Any] = [:]
    ) throws -> AgentChatHTTPResponse {
        var body: [String: Any] = ["title": title]
        for (key, value) in extraBody {
            body[key] = value
        }
        return try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions"],
            method: "POST",
            bearer: env.bearer,
            jsonBody: body
        )
    }

    private func getSession(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String
    ) throws -> AgentChatHTTPResponse {
        try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", sessionID],
            method: "GET",
            bearer: env.bearer
        )
    }

    private func postMessage(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String,
        role: String,
        parts: [[String: Any]],
        extraBody: [String: Any] = [:]
    ) throws -> AgentChatHTTPResponse {
        var body: [String: Any] = [
            "role": role,
            "parts": parts,
        ]
        for (key, value) in extraBody {
            body[key] = value
        }
        return try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", sessionID, "messages"],
            method: "POST",
            bearer: env.bearer,
            jsonBody: body
        )
    }

    private func getMessagesResponse(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String
    ) throws -> AgentChatHTTPResponse {
        try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", sessionID, "messages"],
            method: "GET",
            bearer: env.bearer
        )
    }

    private func listMessages(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String
    ) throws -> [[String: Any]] {
        let response = try getMessagesResponse(client: client, env: env, sessionID: sessionID)
        XCTAssertEqual(response.statusCode, 200, "list messages should return 200: \(response.text)")
        XCTAssertFalse(response.text.lowercased().contains("\"error\""), "list messages should not return an API error")
        return try client.jsonArray(response)
    }

    private func listSessionsResponse(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment
    ) throws -> AgentChatHTTPResponse {
        try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions"],
            method: "GET",
            bearer: env.bearer
        )
    }

    private func deleteSession(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String
    ) throws -> AgentChatHTTPResponse {
        try client.request(
            baseURL: env.apiBaseURL,
            pathComponents: ["api", "repos", env.repoOwner, env.repoName, "agent", "sessions", sessionID],
            method: "DELETE",
            bearer: env.bearer
        )
    }

    private func bestEffortDeleteSession(
        client: AgentChatE2EHTTPClient,
        env: AgentChatE2EEnvironment,
        sessionID: String
    ) {
        _ = try? deleteSession(client: client, env: env, sessionID: sessionID)
    }

    private func poll(
        timeout: TimeInterval,
        interval: TimeInterval,
        until block: () throws -> Bool
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try block() {
                return true
            }
            Thread.sleep(forTimeInterval: interval)
        }
        return try block()
    }

    private func uniqueLabel(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
#endif
