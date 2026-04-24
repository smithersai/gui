#if os(iOS)
import Foundation
import SwiftUI

struct AgentChatView: View {
    @StateObject private var model: AgentChatViewModel

    init(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String,
        bearerProvider: @escaping AgentChatAPIClient.BearerProvider
    ) {
        _model = StateObject(
            wrappedValue: AgentChatViewModel(
                client: AgentChatAPIClient(
                    baseURL: baseURL,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    sessionID: sessionID,
                    bearerProvider: bearerProvider
                )
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                AgentChatErrorBanner(message: error) {
                    Task { await model.reload() }
                }
            }

            ScrollViewReader { proxy in
                Group {
                    if model.showsLoadingState {
                        ProgressView("Loading chat…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("chat.loading")
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                if model.showsEmptyState {
                                    ContentUnavailableView(
                                        "No messages yet",
                                        systemImage: "bubble.left",
                                        description: Text("Start the session with a message below.")
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                    .accessibilityIdentifier("chat.empty")
                                } else if model.messages.isEmpty {
                                    ContentUnavailableView(
                                        "Unable to load chat",
                                        systemImage: "exclamationmark.bubble",
                                        description: Text("Pull to refresh or retry above.")
                                    )
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 24)
                                } else {
                                    ForEach(model.messages) { message in
                                        AgentChatMessageRow(message: message)
                                            .id(message.id)
                                    }
                                }
                            }
                            .padding(12)
                        }
                        .refreshable {
                            await model.reload()
                        }
                        .onChange(of: model.scrollTargetID) { _, target in
                            guard let target else { return }
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .bottom)
                            }
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .accessibilityIdentifier("chat.transcript")
            }

            Divider()

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("chat.compose.input")
                    .onSubmit { model.send() }

                Button("Send") {
                    model.send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSend)
                .accessibilityIdentifier("chat.compose.send")
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .task { await model.loadIfNeeded() }
        .onDisappear { model.stopPolling() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("content.ios.workspace-detail.chat")
    }
}

private struct AgentChatErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("chat.error.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.error")
    }
}

private struct AgentChatMessageRow: View {
    let message: AgentChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.roleLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(message.roleTint)

                Spacer(minLength: 8)

                Text(message.timestampText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(message.text.isEmpty ? " " : message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(message.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.message.\(message.id)")
    }
}

@MainActor
final class AgentChatViewModel: ObservableObject {
    @Published var draft: String = ""
    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoadedOnce = false
    @Published private(set) var isLoading = false
    @Published private(set) var scrollTargetID: String?

    private let client: AgentChatAPIClient
    private var didLoad = false
    private var serverMessages: [AgentChatMessage] = []
    private var pendingMessages: [AgentChatMessage] = []
    private var pollingTask: Task<Void, Never>?

    init(client: AgentChatAPIClient) {
        self.client = client
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsLoadingState: Bool {
        let awaitingFirstResponse = messages.isEmpty && !hasLoadedOnce && errorMessage == nil
        return awaitingFirstResponse || (messages.isEmpty && isLoading)
    }

    var showsEmptyState: Bool {
        hasLoadedOnce && messages.isEmpty && errorMessage == nil && !isLoading
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await reload()
    }

    func reload() async {
        await refreshMessages()
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let optimistic = AgentChatMessage(
            id: UUID().uuidString.lowercased(),
            role: "user",
            text: text,
            createdAt: Date(),
            isPending: true
        )

        draft = ""
        errorMessage = nil
        pendingMessages.append(optimistic)
        publishMessages(scrollTo: optimistic.id)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendMessage(text: text)
                await self.refreshMessages()
                self.startPolling()
            } catch {
                self.pendingMessages.removeAll { $0.id == optimistic.id }
                self.publishMessages(scrollTo: self.messages.last?.id)
                self.errorMessage = AgentChatAPIClient.describe(error)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await self.refreshMessages()
            }
        }
    }

    private func refreshMessages() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            let loaded = try await client.fetchMessages()
            errorMessage = nil
            serverMessages = loaded
            publishMessages(scrollTo: loaded.last?.id)
        } catch {
            errorMessage = AgentChatAPIClient.describe(error)
        }
    }

    private func publishMessages(scrollTo explicitTarget: String?) {
        prunePendingMessages()

        let combined = (serverMessages + pendingMessages).sorted(by: AgentChatMessage.sort)
        messages = combined
        scrollTargetID = explicitTarget ?? combined.last?.id
    }

    private func prunePendingMessages() {
        let now = Date()
        pendingMessages.removeAll { pending in
            if now.timeIntervalSince(pending.createdAt ?? now) > 60 {
                return true
            }
            return serverMessages.contains { server in
                server.matchesPending(pending)
            }
        }
    }
}

struct AgentChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let createdAt: Date?
    let isPending: Bool

    var roleLabel: String {
        switch role.lowercased() {
        case "user":
            return "User"
        case "assistant":
            return "Assistant"
        default:
            return role.capitalized
        }
    }

    var roleTint: Color {
        switch role.lowercased() {
        case "user":
            return .accentColor
        case "assistant":
            return .secondary
        default:
            return .secondary
        }
    }

    var backgroundColor: Color {
        isPending ? Color.accentColor.opacity(0.08) : Color(uiColor: .systemBackground)
    }

    var timestampText: String {
        guard let createdAt else { return isPending ? "Pending" : "" }
        return Self.timestampFormatter.string(from: createdAt)
    }

    fileprivate func matchesPending(_ pending: AgentChatMessage) -> Bool {
        guard role == pending.role, text == pending.text else { return false }
        guard let pendingCreatedAt = pending.createdAt else { return false }
        if let createdAt {
            return abs(createdAt.timeIntervalSince(pendingCreatedAt)) < 30
        }
        return true
    }

    fileprivate static func sort(_ lhs: AgentChatMessage, _ rhs: AgentChatMessage) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
            if left != right { return left < right }
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            break
        }
        return lhs.id < rhs.id
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

enum AgentChatSessionDiscovery {
    enum DiscoveryResult: Equatable {
        case found(String)
        case empty
        case failure(String)
    }

    static func discoverFirstSessionID(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        bearerProvider: @escaping AgentChatAPIClient.BearerProvider
    ) async -> DiscoveryResult {
        do {
            let client = AgentChatAPIClient(
                baseURL: baseURL,
                repoOwner: repoOwner,
                repoName: repoName,
                sessionID: nil,
                bearerProvider: bearerProvider
            )
            if let sessionID = try await client.fetchSessionIDs().first {
                return .found(sessionID)
            }
            return .empty
        } catch {
            return .failure(AgentChatAPIClient.describe(error))
        }
    }
}

struct AgentChatAPIClient {
    typealias BearerProvider = () -> String?

    enum Error: Swift.Error {
        case notSignedIn
        case invalidResponse
        case http(status: Int, body: String)
        case invalidPayload
    }

    let baseURL: URL
    let repoOwner: String
    let repoName: String
    let sessionID: String?
    let bearerProvider: BearerProvider
    let session: URLSession

    init(
        baseURL: URL,
        repoOwner: String,
        repoName: String,
        sessionID: String?,
        bearerProvider: @escaping BearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.sessionID = sessionID
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func fetchSessionIDs() async throws -> [String] {
        let data = try await request(pathComponents: [
            "api", "repos", repoOwner, repoName, "agent", "sessions",
        ])
        let payload = try Self.jsonArray(from: data)
        return payload.compactMap { row in
            Self.string(row["id"]) ?? Self.string(row["session_id"])
        }
    }

    func fetchMessages() async throws -> [AgentChatMessage] {
        guard let sessionID else { throw Error.invalidPayload }
        let data = try await request(pathComponents: [
            "api", "repos", repoOwner, repoName, "agent", "sessions", sessionID, "messages",
        ])
        let payload = try Self.jsonArray(from: data)
        return payload.compactMap(Self.message(from:)).sorted(by: AgentChatMessage.sort)
    }

    func sendMessage(text: String) async throws {
        guard let sessionID else { throw Error.invalidPayload }
        do {
            _ = try await request(
                pathComponents: ["api", "repos", repoOwner, repoName, "agent", "sessions", sessionID, "messages"],
                method: "POST",
                jsonBody: ["text": text]
            )
        } catch let error as Error {
            switch error {
            case .http(let status, _) where status == 400 || status == 404 || status == 422:
                _ = try await request(
                    pathComponents: ["api", "repos", repoOwner, repoName, "agent", "sessions", sessionID, "messages"],
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

    static func describe(_ error: Swift.Error) -> String {
        guard let error = error as? Error else {
            return error.localizedDescription
        }
        switch error {
        case .notSignedIn:
            return "Sign in again to load agent chat."
        case .invalidResponse:
            return "The server returned an invalid chat response."
        case .invalidPayload:
            return "The chat response payload was not in the expected format."
        case .http(let status, let body):
            if body.isEmpty {
                return "Chat request failed with HTTP \(status)."
            }
            return "Chat request failed with HTTP \(status): \(body)"
        }
    }

    private func request(
        pathComponents: [String],
        method: String = "GET",
        jsonBody: [String: Any]? = nil
    ) async throws -> Data {
        guard let bearer = bearerProvider(), !bearer.isEmpty else {
            throw Error.notSignedIn
        }

        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: http.statusCode, body: body)
        }
        return data
    }

    private static func message(from raw: [String: Any]) -> AgentChatMessage? {
        guard let id = string(raw["id"]) ?? string(raw["message_id"]) else { return nil }
        let role = string(raw["role"]) ?? "assistant"
        let parts = array(raw["parts"]) ?? []
        let partsText = parts
            .compactMap(textValue(from:))
            .joined(separator: "\n")
        let text = partsText.isEmpty ? (string(raw["text"]) ?? "") : partsText

        return AgentChatMessage(
            id: id,
            role: role,
            text: text,
            createdAt: date(raw["created_at"]),
            isPending: false
        )
    }

    private static func textValue(from raw: [String: Any]) -> String? {
        guard (string(raw["type"]) ?? "text") == "text" else { return nil }

        if let content = raw["content"] as? String {
            return content
        }
        if let content = raw["content"] as? [String: Any] {
            return string(content["value"]) ?? string(content["text"])
        }
        return nil
    }

    private static func jsonArray(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        if let array = object as? [[String: Any]] {
            return array
        }
        if let dict = object as? [String: Any] {
            if let rows = dict["messages"] as? [[String: Any]] {
                return rows
            }
            if let rows = dict["sessions"] as? [[String: Any]] {
                return rows
            }
        }
        throw Error.invalidPayload
    }

    private static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let milliseconds = value as? NSNumber {
            return Date(timeIntervalSince1970: normalizeUnixTimestamp(milliseconds.doubleValue))
        }
        if let double = value as? Double {
            return Date(timeIntervalSince1970: normalizeUnixTimestamp(double))
        }
        if let integer = value as? Int64 {
            return Date(timeIntervalSince1970: normalizeUnixTimestamp(Double(integer)))
        }
        if let string = value as? String {
            if let seconds = Double(string), seconds > 0 {
                return Date(timeIntervalSince1970: normalizeUnixTimestamp(seconds))
            }
            if let date = fractionalISO8601.date(from: string) {
                return date
            }
            return plainISO8601.date(from: string)
        }
        return nil
    }

    private static func normalizeUnixTimestamp(_ raw: Double) -> Double {
        raw > 10_000_000_000 ? raw / 1000 : raw
    }

    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO8601 = ISO8601DateFormatter()
}
#endif
