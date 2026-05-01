import Foundation

struct ShareWorkspace: Identifiable, Equatable {
    let id: String
    let repoOwner: String?
    let repoName: String?
    let title: String
    let state: String
    let lastAccessedAt: Date?
    let lastActivityAt: Date?
    let createdAt: Date?

    var repoLabel: String {
        switch (repoOwner?.shareTrimmedNonEmpty, repoName?.shareTrimmedNonEmpty) {
        case let (owner?, name?): return "\(owner)/\(name)"
        case (nil, let name?): return name
        case (let owner?, nil): return owner
        default: return ""
        }
    }

    var canPostAgentMessage: Bool {
        repoOwner?.shareTrimmedNonEmpty != nil && repoName?.shareTrimmedNonEmpty != nil
    }

    var recencyKey: Date {
        lastAccessedAt ?? lastActivityAt ?? createdAt ?? .distantPast
    }
}

enum ShareExtensionAPIError: LocalizedError, Equatable {
    case notSignedIn
    case missingRepositoryContext
    case invalidResponse
    case http(status: Int, body: String)
    case backendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Smithers before sharing."
        case .missingRepositoryContext:
            return "This workspace is missing repository context."
        case .invalidResponse:
            return "Smithers returned an unexpected response."
        case .http(let status, let body):
            if let body = body.shareTrimmedNonEmpty {
                return "Smithers returned HTTP \(status): \(body)"
            }
            return "Smithers returned HTTP \(status)."
        case .backendUnavailable(let message):
            return message.shareTrimmedNonEmpty ?? "Smithers is unavailable."
        }
    }
}

struct ShareExtensionAPIClient {
    typealias BearerProvider = () -> String?

    let baseURL: URL
    let bearerProvider: BearerProvider
    let session: URLSession

    init(
        baseURL: URL,
        bearerProvider: @escaping BearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func fetchWorkspaces() async throws -> [ShareWorkspace] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/user/workspaces"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "100")]
        guard let url = components?.url else {
            throw ShareExtensionAPIError.invalidResponse
        }

        let data = try await request(url: url, method: "GET")
        return try Self.decodeWorkspaces(from: data)
    }

    func handoff(
        content: ShareExtensionContent,
        comment: String,
        workspace: ShareWorkspace
    ) async throws {
        guard let owner = workspace.repoOwner?.shareTrimmedNonEmpty,
              let repo = workspace.repoName?.shareTrimmedNonEmpty
        else {
            throw ShareExtensionAPIError.missingRepositoryContext
        }

        let text = Self.messageText(content: content, comment: comment)
        let sessionID = try await resolveAgentSessionID(
            owner: owner,
            repo: repo,
            workspace: workspace
        )
        try await postMessage(text: text, owner: owner, repo: repo, sessionID: sessionID)
    }

    private func resolveAgentSessionID(
        owner: String,
        repo: String,
        workspace: ShareWorkspace
    ) async throws -> String {
        let sessions = try await fetchAgentSessions(owner: owner, repo: repo)
        if let workspaceMatch = sessions.first(where: { $0.workspaceID == workspace.id })?.resolvedID {
            return workspaceMatch
        }
        if let first = sessions.first?.resolvedID {
            return first
        }
        return try await createAgentSession(owner: owner, repo: repo, workspace: workspace)
    }

    private func fetchAgentSessions(owner: String, repo: String) async throws -> [AgentSessionDTO] {
        let data = try await request(
            url: repoURL(owner: owner, repo: repo)
                .appendingPathComponent("agent")
                .appendingPathComponent("sessions"),
            method: "GET"
        )
        return try Self.decodeAgentSessions(from: data)
    }

    private func createAgentSession(
        owner: String,
        repo: String,
        workspace: ShareWorkspace
    ) async throws -> String {
        let title = "iOS share: \(workspace.title)"
        let url = repoURL(owner: owner, repo: repo)
            .appendingPathComponent("agent")
            .appendingPathComponent("sessions")

        do {
            let data = try await request(
                url: url,
                method: "POST",
                jsonBody: [
                    "title": title,
                    "workspace_id": workspace.id,
                ]
            )
            if let sessionID = try Self.decodeAgentSession(from: data).resolvedID {
                return sessionID
            }
            throw ShareExtensionAPIError.invalidResponse
        } catch let error as ShareExtensionAPIError {
            switch error {
            case .http(let status, _) where status == 400 || status == 422:
                let data = try await request(
                    url: url,
                    method: "POST",
                    jsonBody: ["title": title]
                )
                if let sessionID = try Self.decodeAgentSession(from: data).resolvedID {
                    return sessionID
                }
                throw ShareExtensionAPIError.invalidResponse
            default:
                throw error
            }
        }
    }

    private func postMessage(
        text: String,
        owner: String,
        repo: String,
        sessionID: String
    ) async throws {
        let url = repoURL(owner: owner, repo: repo)
            .appendingPathComponent("agent")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("messages")

        do {
            _ = try await request(url: url, method: "POST", jsonBody: ["text": text])
        } catch let error as ShareExtensionAPIError {
            switch error {
            case .http(let status, _) where status == 400 || status == 404 || status == 422:
                _ = try await request(
                    url: url,
                    method: "POST",
                    jsonBody: [
                        "role": "user",
                        "parts": [[
                            "type": "text",
                            "content": ["value": text],
                        ]],
                    ]
                )
            default:
                throw error
            }
        }
    }

    private func request(
        url: URL,
        method: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        guard let token = bearerProvider()?.shareTrimmedNonEmpty else {
            throw ShareExtensionAPIError.notSignedIn
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ShareExtensionAPIError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw ShareExtensionAPIError.http(
                    status: http.statusCode,
                    body: String(data: data, encoding: .utf8) ?? ""
                )
            }
            return data
        } catch let error as ShareExtensionAPIError {
            throw error
        } catch {
            throw ShareExtensionAPIError.backendUnavailable(error.localizedDescription)
        }
    }

    private func repoURL(owner: String, repo: String) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)
    }

    private static func messageText(
        content: ShareExtensionContent,
        comment: String
    ) -> String {
        [
            comment.shareTrimmedNonEmpty,
            content.text.shareTrimmedNonEmpty,
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")
    }

    private static func decodeWorkspaces(from data: Data) throws -> [ShareWorkspace] {
        if let envelope = try? shareDecoder.decode(UserWorkspacesEnvelope.self, from: data) {
            return ordered(envelope.workspaces.map(\.shareWorkspace))
        }
        if let rows = try? shareDecoder.decode([UserWorkspaceDTO].self, from: data) {
            return ordered(rows.map(\.shareWorkspace))
        }
        throw ShareExtensionAPIError.invalidResponse
    }

    private static func decodeAgentSessions(from data: Data) throws -> [AgentSessionDTO] {
        if data.isEmpty {
            return []
        }
        if let rows = try? shareDecoder.decode([AgentSessionDTO].self, from: data) {
            return rows.filter { $0.resolvedID != nil }
        }
        if let envelope = try? shareDecoder.decode(AgentSessionsEnvelope.self, from: data) {
            return envelope.rows.filter { $0.resolvedID != nil }
        }
        throw ShareExtensionAPIError.invalidResponse
    }

    private static func decodeAgentSession(from data: Data) throws -> AgentSessionDTO {
        if let row = try? shareDecoder.decode(AgentSessionDTO.self, from: data) {
            return row
        }
        if let envelope = try? shareDecoder.decode(AgentSessionEnvelope.self, from: data),
           let row = envelope.session ?? envelope.data {
            return row
        }
        throw ShareExtensionAPIError.invalidResponse
    }

    private static func ordered(_ rows: [ShareWorkspace]) -> [ShareWorkspace] {
        rows.sorted {
            if $0.recencyKey == $1.recencyKey {
                return $0.id > $1.id
            }
            return $0.recencyKey > $1.recencyKey
        }
    }
}

private struct UserWorkspacesEnvelope: Decodable {
    let workspaces: [UserWorkspaceDTO]
}

private struct UserWorkspaceDTO: Decodable {
    let workspaceId: String
    let repoOwner: String?
    let repoName: String?
    let title: String?
    let name: String?
    let state: String?
    let status: String?
    let lastAccessedAt: Date?
    let lastActivityAt: Date?
    let createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case repoOwner = "repo_owner"
        case repoName = "repo_name"
        case title
        case name
        case state
        case status
        case lastAccessedAt = "last_accessed_at"
        case lastActivityAt = "last_activity_at"
        case createdAt = "created_at"
    }

    var shareWorkspace: ShareWorkspace {
        ShareWorkspace(
            id: workspaceId,
            repoOwner: repoOwner,
            repoName: repoName,
            title: title?.shareTrimmedNonEmpty ?? name?.shareTrimmedNonEmpty ?? workspaceId,
            state: state?.shareTrimmedNonEmpty ?? status?.shareTrimmedNonEmpty ?? "unknown",
            lastAccessedAt: lastAccessedAt,
            lastActivityAt: lastActivityAt,
            createdAt: createdAt
        )
    }
}

private struct AgentSessionsEnvelope: Decodable {
    let sessions: [AgentSessionDTO]?
    let data: [AgentSessionDTO]?
    let items: [AgentSessionDTO]?
    let results: [AgentSessionDTO]?

    var rows: [AgentSessionDTO] {
        sessions ?? data ?? items ?? results ?? []
    }
}

private struct AgentSessionEnvelope: Decodable {
    let session: AgentSessionDTO?
    let data: AgentSessionDTO?
}

private struct AgentSessionDTO: Decodable {
    let id: String?
    let sessionID: String?
    let workspaceID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case workspaceID = "workspace_id"
    }

    var resolvedID: String? {
        id?.shareTrimmedNonEmpty ?? sessionID?.shareTrimmedNonEmpty
    }
}

private let shareDecoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        if let milliseconds = try? container.decode(Int64.self) {
            return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        }
        if let double = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: double / 1000)
        }
        if let string = try? container.decode(String.self) {
            if let milliseconds = Double(string), milliseconds > 0 {
                return Date(timeIntervalSince1970: milliseconds / 1000)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) {
                return date
            }
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "expected unix-millis or ISO-8601 date"
        )
    }
    return decoder
}()

enum ShareExtensionEndpoint {
    static let baseURLInfoKey = "SmithersPlueBaseURL"
    static let previewURLInfoKey = "SmithersPreviewURL"

    static func resolvedBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL {
        if let configured = configuredBaseURL(environment: environment, bundle: bundle) {
            return configured
        }
        if let dev = parsedURL(environment["SMITHERS_PLUE_URL"]) {
            return dev
        }
        #if DEBUG
        return URL(string: "http://localhost:4000")!
        #else
        return URL(string: "https://app.smithers.sh")!
        #endif
    }

    static func configuredBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let url = parsedURL(environment["PLUE_BASE_URL"]) {
            return url
        }
        if let url = parsedURL(environment["PLUE_PREVIEW_URL"]) {
            return url
        }
        if let url = parsedURL(bundle.object(forInfoDictionaryKey: baseURLInfoKey)) {
            return url
        }
        if let url = parsedURL(bundle.object(forInfoDictionaryKey: previewURLInfoKey)) {
            return url
        }
        return nil
    }

    static func parsedURL(_ rawValue: Any?) -> URL? {
        guard let raw = rawValue as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        if components.path == "/api" {
            components.path = ""
        }
        return components.url
    }
}
