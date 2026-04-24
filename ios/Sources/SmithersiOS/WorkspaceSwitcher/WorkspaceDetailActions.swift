#if os(iOS)
import Foundation
#if SWIFT_PACKAGE
import SmithersStore
#endif

enum WorkspaceDetailMutationAction: Equatable {
    case suspend
    case resume
    case fork

    var successMessage: String {
        switch self {
        case .suspend:
            return "Workspace suspended."
        case .resume:
            return "Workspace resumed."
        case .fork:
            return "Workspace fork created."
        }
    }
}

struct WorkspaceDetailBanner: Equatable {
    enum Style: Equatable {
        case success
        case warning
        case error
    }

    let message: String
    let style: Style
    let autoDismiss: Bool
}

struct WorkspaceDetailMutationResponse: Equatable {
    let workspace: SwitcherWorkspace?
    let createdWorkspaceID: String?
}

enum WorkspaceDetailMutationError: LocalizedError, Equatable {
    case authExpired
    case missingRepoContext
    case invalidResponse
    case rateLimited(retryAfter: Int?, message: String)
    case backendUnavailable(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Sign in again to manage this workspace."
        case .missingRepoContext:
            return "This workspace is missing repository context."
        case .invalidResponse:
            return "The server returned an invalid workspace response."
        case let .rateLimited(retryAfter, message):
            return WorkspaceDetailActionModel.rateLimitMessage(base: message, retryAfter: retryAfter)
        case let .backendUnavailable(message), let .decode(message):
            return message.trimmedNonEmpty ?? "Workspace action failed."
        }
    }
}

protocol WorkspaceDetailMutationClient {
    func perform(
        _ action: WorkspaceDetailMutationAction,
        workspace: SwitcherWorkspace
    ) async throws -> WorkspaceDetailMutationResponse
}

struct URLSessionWorkspaceDetailMutationClient: WorkspaceDetailMutationClient {
    typealias BearerProvider = () -> String?

    private let baseURL: URL
    private let bearerProvider: BearerProvider
    private let session: URLSession

    init(
        baseURL: URL,
        bearerProvider: @escaping BearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func perform(
        _ action: WorkspaceDetailMutationAction,
        workspace: SwitcherWorkspace
    ) async throws -> WorkspaceDetailMutationResponse {
        guard
            let repoOwner = workspace.repoOwner?.trimmedNonEmpty,
            let repoName = workspace.repoName?.trimmedNonEmpty
        else {
            throw WorkspaceDetailMutationError.missingRepoContext
        }
        guard let bearer = bearerProvider()?.trimmedNonEmpty else {
            throw WorkspaceDetailMutationError.authExpired
        }

        var request = URLRequest(url: endpointURL(
            action: action,
            repoOwner: repoOwner,
            repoName: repoName,
            workspaceID: workspace.id
        ))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        if action == .fork {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["title": Self.forkTitle(for: workspace)],
                options: []
            )
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WorkspaceDetailMutationError.backendUnavailable("Missing HTTP response")
            }

            switch http.statusCode {
            case 200...299:
                if data.isEmpty {
                    return Self.emptySuccessResponse(for: action, workspace: workspace)
                }
                let record = try Self.decodeMutationRecord(from: data)
                switch action {
                case .fork:
                    return WorkspaceDetailMutationResponse(
                        workspace: nil,
                        createdWorkspaceID: record.id
                    )
                case .suspend, .resume:
                    return WorkspaceDetailMutationResponse(
                        workspace: record.asSwitcherWorkspace(basedOn: workspace),
                        createdWorkspaceID: nil
                    )
                }
            case 401, 403:
                throw WorkspaceDetailMutationError.authExpired
            case 429:
                throw WorkspaceDetailMutationError.rateLimited(
                    retryAfter: Self.retryAfterSeconds(from: http),
                    message: Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            default:
                throw WorkspaceDetailMutationError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as WorkspaceDetailMutationError {
            throw error
        } catch {
            throw WorkspaceDetailMutationError.backendUnavailable(error.localizedDescription)
        }
    }

    static func forkTitle(for workspace: SwitcherWorkspace) -> String {
        let baseTitle = workspace.title.trimmedNonEmpty ?? workspace.id
        return "\(baseTitle) (fork)"
    }

    static func retryAfterSeconds(
        from response: HTTPURLResponse,
        now: Date = Date()
    ) -> Int? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?.trimmedNonEmpty else {
            return nil
        }
        if let seconds = Int(rawValue), seconds > 0 {
            return seconds
        }
        if let retryDate = Self.retryAfterDateFormatter.date(from: rawValue) {
            let delta = Int(ceil(retryDate.timeIntervalSince(now)))
            return delta > 0 ? delta : nil
        }
        return nil
    }

    private static func emptySuccessResponse(
        for action: WorkspaceDetailMutationAction,
        workspace: SwitcherWorkspace
    ) -> WorkspaceDetailMutationResponse {
        switch action {
        case .fork:
            return WorkspaceDetailMutationResponse(
                workspace: nil,
                createdWorkspaceID: nil
            )
        case .suspend:
            return WorkspaceDetailMutationResponse(
                workspace: workspace.settingState("suspended"),
                createdWorkspaceID: nil
            )
        case .resume:
            return WorkspaceDetailMutationResponse(
                workspace: workspace.settingState("running"),
                createdWorkspaceID: nil
            )
        }
    }

    private func endpointURL(
        action: WorkspaceDetailMutationAction,
        repoOwner: String,
        repoName: String,
        workspaceID: String
    ) -> URL {
        var url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(repoOwner)
            .appendingPathComponent(repoName)
            .appendingPathComponent("workspaces")
            .appendingPathComponent(workspaceID)
        switch action {
        case .suspend:
            url.appendPathComponent("suspend")
        case .resume:
            url.appendPathComponent("resume")
        case .fork:
            url.appendPathComponent("fork")
        }
        return url
    }

    private static func decodeMutationRecord(from data: Data) throws -> WorkspaceDetailMutationRecord {
        guard !data.isEmpty else {
            throw WorkspaceDetailMutationError.invalidResponse
        }
        do {
            return try StoreDecoder.shared.decode(WorkspaceDetailMutationRecord.self, from: data)
        } catch {
            throw WorkspaceDetailMutationError.decode(
                "Could not decode workspace action response: \(error.localizedDescription)"
            )
        }
    }

    private static func decodeErrorMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data),
           let message = payload.message?.trimmedNonEmpty {
            return message
        }
        if let body = String(data: data, encoding: .utf8)?.trimmedNonEmpty {
            return body
        }
        return "HTTP \(status)"
    }

    private static let retryAfterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter
    }()
}

@MainActor
final class WorkspaceDetailActionModel: ObservableObject {
    @Published private(set) var workspace: SwitcherWorkspace
    @Published private(set) var banner: WorkspaceDetailBanner?
    @Published private(set) var isPerformingAction = false

    private let client: any WorkspaceDetailMutationClient
    private let onRefreshSwitcher: @MainActor () async -> Void
    private var bannerDismissTask: Task<Void, Never>?

    init(
        workspace: SwitcherWorkspace,
        client: any WorkspaceDetailMutationClient,
        onRefreshSwitcher: @escaping @MainActor () async -> Void
    ) {
        self.workspace = workspace
        self.client = client
        self.onRefreshSwitcher = onRefreshSwitcher
    }

    var showsSuspendAction: Bool {
        workspace.state.normalizedWorkspaceDetailStatus == "running"
    }

    var showsResumeAction: Bool {
        workspace.state.normalizedWorkspaceDetailStatus == "suspended"
    }

    func perform(_ action: WorkspaceDetailMutationAction) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        bannerDismissTask?.cancel()
        defer { isPerformingAction = false }

        do {
            let response = try await client.perform(action, workspace: workspace)
            if let updatedWorkspace = response.workspace {
                workspace = updatedWorkspace
            }
            presentBanner(
                WorkspaceDetailBanner(
                    message: action.successMessage,
                    style: .success,
                    autoDismiss: true
                )
            )
            await onRefreshSwitcher()
        } catch let error as WorkspaceDetailMutationError {
            presentBanner(
                WorkspaceDetailBanner(
                    message: error.errorDescription ?? "Workspace action failed.",
                    style: Self.bannerStyle(for: error),
                    autoDismiss: false
                )
            )
        } catch {
            presentBanner(
                WorkspaceDetailBanner(
                    message: error.localizedDescription,
                    style: .error,
                    autoDismiss: false
                )
            )
        }
    }

    nonisolated static func rateLimitMessage(base: String, retryAfter: Int?) -> String {
        let prefix: String
        let normalizedBase = base.trimmedNonEmpty
        if normalizedBase == nil || normalizedBase == "HTTP 429" {
            prefix = "Rate limit reached."
        } else if normalizedBase?.hasSuffix(".") == true {
            prefix = normalizedBase ?? "Rate limit reached."
        } else {
            prefix = "\(normalizedBase ?? "Rate limit reached")."
        }

        guard let retryAfter, retryAfter > 0 else {
            return prefix
        }
        return "\(prefix) Try again in \(Self.retryAfterLabel(seconds: retryAfter))."
    }

    private func presentBanner(_ nextBanner: WorkspaceDetailBanner) {
        banner = nextBanner
        guard nextBanner.autoDismiss else { return }

        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.banner = nil
            }
        }
    }

    private static func bannerStyle(for error: WorkspaceDetailMutationError) -> WorkspaceDetailBanner.Style {
        switch error {
        case .rateLimited:
            return .warning
        case .authExpired, .missingRepoContext, .invalidResponse, .backendUnavailable, .decode:
            return .error
        }
    }

    nonisolated private static func retryAfterLabel(seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }
}

private struct WorkspaceDetailMutationRecord: Decodable {
    let id: String
    let title: String?
    let name: String?
    let status: String?
    let state: String?
    let createdAt: Date?
    let lastAccessedAt: Date?
    let lastActivityAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case status
        case state
        case createdAt = "created_at"
        case lastAccessedAt = "last_accessed_at"
        case lastActivityAt = "last_activity_at"
    }

    func asSwitcherWorkspace(basedOn existing: SwitcherWorkspace) -> SwitcherWorkspace {
        SwitcherWorkspace(
            id: id,
            repoOwner: existing.repoOwner,
            repoName: existing.repoName,
            title: title?.trimmedNonEmpty ?? name?.trimmedNonEmpty ?? existing.title,
            state: status?.trimmedNonEmpty ?? state?.trimmedNonEmpty ?? existing.state,
            lastAccessedAt: lastAccessedAt ?? existing.lastAccessedAt,
            lastActivityAt: lastActivityAt ?? existing.lastActivityAt,
            createdAt: createdAt ?? existing.createdAt,
            source: existing.source
        )
    }
}

private struct APIErrorPayload: Decodable {
    let message: String?
}

private extension String {
    var normalizedWorkspaceDetailStatus: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension SwitcherWorkspace {
    func settingState(_ nextState: String) -> SwitcherWorkspace {
        SwitcherWorkspace(
            id: id,
            repoOwner: repoOwner,
            repoName: repoName,
            title: title,
            state: nextState,
            lastAccessedAt: lastAccessedAt,
            lastActivityAt: lastActivityAt,
            createdAt: createdAt,
            source: source
        )
    }
}
#endif
