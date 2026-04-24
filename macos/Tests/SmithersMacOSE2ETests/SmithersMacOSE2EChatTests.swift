#if os(macOS)
import Foundation
import XCTest

struct MacE2EHTTPResponse {
    let statusCode: Int
    let data: Data

    var text: String {
        String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
    }
}

enum MacE2EHTTPError: LocalizedError {
    case invalidJSON(String)
    case requestTimedOut(String)
    case missingHTTPResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail), .requestTimedOut(let detail), .missingHTTPResponse(let detail):
            return detail
        }
    }
}

final class MacE2EHTTPClient {
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
    ) throws -> MacE2EHTTPResponse {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        if !queryItems.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            if let resolved = components?.url {
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
    ) throws -> MacE2EHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 2
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)
        var output: MacE2EHTTPResponse?
        var transportError: Error?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                transportError = error
                return
            }
            guard let http = response as? HTTPURLResponse else {
                transportError = MacE2EHTTPError.missingHTTPResponse(
                    "missing HTTP response for \(method) \(url.absoluteString)"
                )
                return
            }
            output = MacE2EHTTPResponse(statusCode: http.statusCode, data: data ?? Data())
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeout + 3)
        task.cancel()

        if waitResult == .timedOut {
            throw MacE2EHTTPError.requestTimedOut("timed out waiting for \(method) \(url.absoluteString)")
        }
        if let transportError {
            throw transportError
        }
        guard let output else {
            throw MacE2EHTTPError.missingHTTPResponse("missing payload for \(method) \(url.absoluteString)")
        }
        return output
    }

    func jsonDictionary(_ response: MacE2EHTTPResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw MacE2EHTTPError.invalidJSON("expected JSON object, got: \(response.text)")
        }
        return dictionary
    }

    func jsonArray(_ response: MacE2EHTTPResponse) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: response.data, options: [])
        guard let array = object as? [[String: Any]] else {
            throw MacE2EHTTPError.invalidJSON("expected JSON array, got: \(response.text)")
        }
        return array
    }
}

private struct MacE2EAgentChatContext {
    let bearer: String
    let baseURL: URL
    let repoOwner: String
    let repoName: String
    let seededSessionID: String?

    static func load() throws -> MacE2EAgentChatContext {
        let bearer = try MacE2ETestSupport.requireEnv(MacE2ELaunchKey.bearer)
        let baseURLString = try MacE2ETestSupport.requireEnv(MacE2ELaunchKey.baseURL)
        guard let baseURL = URL(string: baseURLString) else {
            throw XCTSkip("macOS agent chat e2e requires a valid \(MacE2ELaunchKey.baseURL)")
        }
        return MacE2EAgentChatContext(
            bearer: bearer,
            baseURL: baseURL,
            repoOwner: try MacE2ETestSupport.requireEnv(MacE2ESeedKey.repoOwner),
            repoName: try MacE2ETestSupport.requireEnv(MacE2ESeedKey.repoName),
            seededSessionID: MacE2ETestSupport.env(MacE2ESeedKey.agentSessionID)
        )
    }
}

final class SmithersMacOSE2EChatTests: XCTestCase {
    private let http = MacE2EHTTPClient()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_agent_chat_transcript_loads() throws {
        let context = try MacE2EAgentChatContext.load()
        guard let sessionID = context.seededSessionID else {
            throw XCTSkip("transcript scenario requires \(MacE2ESeedKey.agentSessionID)")
        }

        let response = try getMessagesResponse(context: context, sessionID: sessionID)

        XCTAssertEqual(response.statusCode, 200, "seeded transcript should load: \(response.text)")
        XCTAssertFalse(response.text.lowercased().contains("\"error\""), "transcript response should not contain an API error")
        _ = try http.jsonArray(response)
    }

    func test_agent_chat_user_message_appends() throws {
        let context = try MacE2EAgentChatContext.load()
        let sessionID = try createSession(context: context, title: uniqueLabel("mac-append"))
        defer { bestEffortDeleteSession(context: context, sessionID: sessionID) }

        let messageText = uniqueLabel("mac-user-message")
        let before = try listMessages(context: context, sessionID: sessionID)
        XCTAssertFalse(
            before.contains { message($0, containsText: messageText) },
            "fresh session should not contain the unique message before POST"
        )

        let post = try postMessage(context: context, sessionID: sessionID, text: messageText)
        XCTAssertEqual(post.statusCode, 201, "POST /messages should append the user message: \(post.text)")

        let appended = try poll(timeout: 10, interval: 0.5) {
            let messages = try self.listMessages(context: context, sessionID: sessionID)
            return messages.contains { self.message($0, containsText: messageText) }
        }
        XCTAssertTrue(appended, "GET /messages should eventually include the appended user message")
    }

    func test_agent_chat_empty_state_for_new_session() throws {
        let context = try MacE2EAgentChatContext.load()
        let sessionID = try createSession(context: context, title: uniqueLabel("mac-empty"))
        defer { bestEffortDeleteSession(context: context, sessionID: sessionID) }

        let messages = try listMessages(context: context, sessionID: sessionID)

        XCTAssertTrue(messages.isEmpty, "newly-created agent session should start with an empty transcript")
    }

    private func createSession(context: MacE2EAgentChatContext, title: String) throws -> String {
        let response = try http.request(
            baseURL: context.baseURL,
            pathComponents: ["api", "repos", context.repoOwner, context.repoName, "agent", "sessions"],
            method: "POST",
            bearer: context.bearer,
            jsonBody: ["title": title]
        )
        XCTAssertEqual(response.statusCode, 201, "create session should return 201: \(response.text)")
        let json = try http.jsonDictionary(response)
        guard let id = stringValue(json["id"]), !id.isEmpty else {
            XCTFail("create session response missing id: \(response.text)")
            return ""
        }
        return id
    }

    private func getMessagesResponse(
        context: MacE2EAgentChatContext,
        sessionID: String
    ) throws -> MacE2EHTTPResponse {
        try http.request(
            baseURL: context.baseURL,
            pathComponents: ["api", "repos", context.repoOwner, context.repoName, "agent", "sessions", sessionID, "messages"],
            method: "GET",
            bearer: context.bearer
        )
    }

    private func listMessages(
        context: MacE2EAgentChatContext,
        sessionID: String
    ) throws -> [[String: Any]] {
        let response = try getMessagesResponse(context: context, sessionID: sessionID)
        XCTAssertEqual(response.statusCode, 200, "list messages should return 200: \(response.text)")
        return try http.jsonArray(response)
    }

    private func postMessage(
        context: MacE2EAgentChatContext,
        sessionID: String,
        text: String
    ) throws -> MacE2EHTTPResponse {
        try http.request(
            baseURL: context.baseURL,
            pathComponents: ["api", "repos", context.repoOwner, context.repoName, "agent", "sessions", sessionID, "messages"],
            method: "POST",
            bearer: context.bearer,
            jsonBody: [
                "role": "user",
                "parts": [["type": "text", "content": text]],
            ]
        )
    }

    private func bestEffortDeleteSession(context: MacE2EAgentChatContext, sessionID: String) {
        _ = try? http.request(
            baseURL: context.baseURL,
            pathComponents: ["api", "repos", context.repoOwner, context.repoName, "agent", "sessions", sessionID],
            method: "DELETE",
            bearer: context.bearer
        )
    }

    private func message(_ raw: [String: Any], containsText text: String) -> Bool {
        guard let parts = raw["parts"] as? [[String: Any]] else {
            return false
        }
        return parts.contains { part in
            if let content = part["content"] as? String {
                return content == text
            }
            if let content = part["content"] as? [String: Any] {
                return stringValue(content["value"]) == text
            }
            return false
        }
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

    private func uniqueLabel(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
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
}
#endif
