#if os(iOS)
import Foundation
import SwiftUI

typealias WorkflowRunsBearerProvider = @Sendable () -> String?

struct WorkflowRunsListView: View {
    @StateObject private var viewModel: WorkflowRunsListViewModel

    private let client: URLSessionWorkflowRunsClient
    private let repo: WorkflowRunsRepoRef?

    init(
        baseURL: URL,
        bearerProvider: @escaping WorkflowRunsBearerProvider
    ) {
        let client = URLSessionWorkflowRunsClient(
            baseURL: baseURL,
            bearerProvider: bearerProvider
        )
        let repo = WorkflowRunsRepoRef.seeded()
        self.init(client: client, repo: repo)
    }

    init(
        baseURL: URL,
        bearerProvider: @escaping WorkflowRunsBearerProvider,
        session: URLSession,
        repoEnvironment: [String: String]
    ) {
        let client = URLSessionWorkflowRunsClient(
            baseURL: baseURL,
            bearerProvider: bearerProvider,
            session: session
        )
        let repo = WorkflowRunsRepoRef.seeded(environment: repoEnvironment)
        self.init(client: client, repo: repo)
    }

    init(
        client: URLSessionWorkflowRunsClient,
        repo: WorkflowRunsRepoRef?,
        viewModel: WorkflowRunsListViewModel? = nil
    ) {
        self.client = client
        self.repo = repo
        _viewModel = StateObject(
            wrappedValue: viewModel ?? WorkflowRunsListViewModel(
                client: client,
                repo: repo
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = viewModel.loadError, !loadError.isEmpty {
                WorkflowRunsErrorBanner(message: loadError) {
                    Task { await viewModel.reload() }
                }
            }

            Group {
                if viewModel.showsLoadingState {
                    ProgressView("Loading runs...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("workflow-runs.loading")
                } else if viewModel.runs.isEmpty {
                    if viewModel.loadError == nil {
                        emptyState
                    } else {
                        failedState
                    }
                } else {
                    runsList
                }
            }
        }
        .navigationTitle("Runs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await viewModel.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .navigationDestination(for: WorkflowRunListItem.self) { run in
            if let repo {
                WorkflowRunDetailView(
                    client: client,
                    repo: repo,
                    runID: run.id,
                    initialRun: run,
                    onCancelled: {
                        await viewModel.reload()
                    }
                )
            } else {
                Text("No repository context is available.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("workflow-runs.list.root")
    }

    private var runsList: some View {
        List {
            ForEach(viewModel.runs) { run in
                NavigationLink(value: run) {
                    WorkflowRunsListRow(run: run)
                }
                .accessibilityIdentifier("workflow-runs.row.\(run.id)")
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.reload()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.square.stack")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(viewModel.loadError == nil ? "No workflow runs" : "Unable to load runs")
                .font(.headline)

            if let repo {
                Text(repo.repoLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let loadError = viewModel.loadError, !loadError.isEmpty {
                Text(loadError)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("workflow-runs.empty")
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Unable to load runs")
                .font(.headline)

            if let repo {
                Text(repo.repoLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Pull to refresh or retry above.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct WorkflowRunsErrorBanner: View {
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
                .accessibilityIdentifier("workflow-runs.error.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-runs.error")
    }
}

private struct WorkflowRunsListRow: View {
    let run: WorkflowRunListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(run.displayWorkflowName)
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 12) {
                Text(run.statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(run.statusColor)
                    .accessibilityIdentifier("workflow-runs.row.\(run.id).status")

                Text(run.createdAtText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

struct WorkflowRunDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: WorkflowRunDetailViewModel

    private let onCancelled: @Sendable () async -> Void

    init(
        client: URLSessionWorkflowRunsClient,
        repo: WorkflowRunsRepoRef,
        runID: Int64,
        initialRun: WorkflowRunListItem,
        onCancelled: @escaping @Sendable () async -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: WorkflowRunDetailViewModel(
                client: client,
                repo: repo,
                runID: runID,
                initialDetail: WorkflowRunDetail(from: initialRun)
            )
        )
        self.onCancelled = onCancelled
    }

    var body: some View {
        List {
            if let loadError = viewModel.loadError, !loadError.isEmpty {
                Section {
                    Text(loadError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Run") {
                LabeledContent("workflow_id", value: viewModel.detail.workflowIDText)
                LabeledContent("status") {
                    Text(viewModel.detail.statusLabel)
                        .foregroundStyle(viewModel.detail.statusColor)
                }
                LabeledContent("dispatch time", value: viewModel.detail.dispatchTimeText)
            }

            if viewModel.detail.canCancel {
                Section {
                    Button(role: .destructive) {
                        Task {
                            let cancelled = await viewModel.cancel()
                            guard cancelled else { return }
                            await onCancelled()
                            await MainActor.run {
                                dismiss()
                            }
                        }
                    } label: {
                        if viewModel.isCancelling {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Cancel run")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(viewModel.isCancelling)
                    .accessibilityIdentifier("workflow-run.detail.cancel")
                }
            }
        }
        .navigationTitle(viewModel.detail.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
    }
}

@MainActor
final class WorkflowRunsListViewModel: ObservableObject {
    @Published private(set) var runs: [WorkflowRunListItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var hasLoadedOnce = false

    private var hasLoaded = false
    private let client: URLSessionWorkflowRunsClient
    private let repo: WorkflowRunsRepoRef?

    init(
        client: URLSessionWorkflowRunsClient,
        repo: WorkflowRunsRepoRef?
    ) {
        self.client = client
        self.repo = repo
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    var showsLoadingState: Bool {
        let awaitingFirstResponse = runs.isEmpty && !hasLoadedOnce && loadError == nil
        return awaitingFirstResponse || (runs.isEmpty && isLoading)
    }

    func reload() async {
        let hadRuns = !runs.isEmpty
        guard let repo else {
            loadError = "No seeded repository context is available."
            if !hadRuns {
                runs = []
            }
            hasLoadedOnce = true
            return
        }

        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        do {
            let loaded = try await client.listRuns(in: repo)
            runs = loaded.sorted(by: WorkflowRunListItem.sortDescending)
            hasLoaded = true
        } catch {
            loadError = error.localizedDescription
            if !hadRuns {
                runs = []
            }
        }
    }
}

@MainActor
final class WorkflowRunDetailViewModel: ObservableObject {
    @Published private(set) var detail: WorkflowRunDetail
    @Published private(set) var loadError: String?
    @Published private(set) var isCancelling = false

    private var hasLoaded = false
    private let client: URLSessionWorkflowRunsClient
    private let repo: WorkflowRunsRepoRef
    private let runID: Int64

    init(
        client: URLSessionWorkflowRunsClient,
        repo: WorkflowRunsRepoRef,
        runID: Int64,
        initialDetail: WorkflowRunDetail
    ) {
        self.client = client
        self.repo = repo
        self.runID = runID
        self.detail = initialDetail
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            detail = try await client.fetchRunDetail(in: repo, runID: runID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func cancel() async -> Bool {
        isCancelling = true
        loadError = nil
        defer { isCancelling = false }

        do {
            try await client.cancelRun(in: repo, runID: runID)
            if let refreshed = try? await client.fetchRunDetail(in: repo, runID: runID) {
                detail = refreshed
            }
            return true
        } catch {
            loadError = error.localizedDescription
            return false
        }
    }
}

struct URLSessionWorkflowRunsClient {
    private let baseURL: URL
    private let bearerProvider: WorkflowRunsBearerProvider
    private let session: URLSession

    init(
        baseURL: URL,
        bearerProvider: @escaping WorkflowRunsBearerProvider,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func listRuns(in repo: WorkflowRunsRepoRef) async throws -> [WorkflowRunListItem] {
        var components = URLComponents(
            url: repo.workflowRunsListURL(baseURL: baseURL),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]

        guard let url = components?.url else {
            throw WorkflowRunsError.backendUnavailable("Invalid runs URL")
        }

        let (data, _) = try await send(request: try makeRequest(url: url, method: "GET"))
        return try Self.decodeRuns(from: data)
    }

    func fetchRunDetail(in repo: WorkflowRunsRepoRef, runID: Int64) async throws -> WorkflowRunDetail {
        for url in repo.runDetailURLs(baseURL: baseURL, runID: runID) {
            do {
                let (data, _) = try await send(
                    request: try makeRequest(url: url, method: "GET")
                )
                return try Self.decodeRunDetail(from: data)
            } catch let error as WorkflowRunsError {
                if case .notFound = error {
                    continue
                }
                throw error
            }
        }

        throw WorkflowRunsError.notFound
    }

    func cancelRun(in repo: WorkflowRunsRepoRef, runID: Int64) async throws {
        let urls = repo.cancelRunURLs(baseURL: baseURL, runID: runID)

        for (index, url) in urls.enumerated() {
            do {
                _ = try await send(
                    request: try makeRequest(
                        url: url,
                        method: "POST",
                        body: Data("{}".utf8)
                    ),
                    acceptedStatus: [200, 202, 204]
                )
                return
            } catch let error as WorkflowRunsError {
                if case .notFound = error, index < urls.count - 1 {
                    continue
                }
                throw error
            }
        }

        throw WorkflowRunsError.notFound
    }

    private func makeRequest(
        url: URL,
        method: String,
        body: Data? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try requireBearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return request
    }

    private func send(
        request: URLRequest,
        acceptedStatus: Set<Int> = [200]
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WorkflowRunsError.backendUnavailable("Missing HTTP response")
            }

            if acceptedStatus.contains(http.statusCode) {
                return (data, http)
            }

            switch http.statusCode {
            case 401, 403:
                throw WorkflowRunsError.authExpired
            case 404:
                throw WorkflowRunsError.notFound
            default:
                throw WorkflowRunsError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as WorkflowRunsError {
            throw error
        } catch {
            throw WorkflowRunsError.backendUnavailable(error.localizedDescription)
        }
    }

    private func requireBearer() throws -> String {
        guard let token = bearerProvider()?.trimmedNonEmpty else {
            throw WorkflowRunsError.authExpired
        }
        return token
    }

    private static func decodeRuns(from data: Data) throws -> [WorkflowRunListItem] {
        if data.isEmpty {
            return []
        }
        if let direct = try? StoreDecoder.shared.decode([WorkflowRunListItem].self, from: data) {
            return direct
        }
        if let envelope = try? StoreDecoder.shared.decode(WorkflowRunsEnvelope.self, from: data) {
            if let runs = envelope.runs {
                return runs
            }
            if let items = envelope.items {
                return items
            }
            if let dataItems = envelope.data {
                return dataItems
            }
        }
        throw WorkflowRunsError.invalidResponse
    }

    private static func decodeRunDetail(from data: Data) throws -> WorkflowRunDetail {
        if let direct = try? StoreDecoder.shared.decode(WorkflowRunDetail.self, from: data) {
            return direct
        }
        if let envelope = try? StoreDecoder.shared.decode(WorkflowRunInspectionEnvelope.self, from: data) {
            return envelope.run
        }
        if let run = try? StoreDecoder.shared.decode(WorkflowRunListItem.self, from: data) {
            return WorkflowRunDetail(from: run)
        }
        throw WorkflowRunsError.invalidResponse
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
}

struct WorkflowRunListItem: Identifiable, Hashable, Decodable {
    let id: Int64
    let workflowDefinitionID: Int64?
    let workflowID: String?
    let status: String
    let workflowName: String?
    let createdAt: Date?
    let startedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case workflowDefinitionID = "workflow_definition_id"
        case workflowID = "workflow_id"
        case status
        case workflowName = "workflow_name"
        case workflowNameCamel = "workflowName"
        case name
        case createdAt = "created_at"
        case startedAt = "started_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.decodeLossyInt64(forKey: .id)
        guard let id else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected workflow run id"
                )
            )
        }

        self.id = id
        self.workflowDefinitionID = container.decodeLossyInt64(forKey: .workflowDefinitionID)
        self.workflowID = container.decodeLossyString(forKey: .workflowID)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        let workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        let workflowNameCamel = try container.decodeIfPresent(String.self, forKey: .workflowNameCamel)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedWorkflowName = workflowName ?? workflowNameCamel ?? name
        self.workflowName = decodedWorkflowName?.trimmedNonEmpty
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    }

    var displayWorkflowName: String {
        workflowName ?? "Unnamed workflow"
    }

    var statusToken: String {
        status.normalizedWorkflowRunStatus
    }

    var statusLabel: String {
        statusToken.isEmpty ? "Unknown" : statusToken.replacingOccurrences(of: "-", with: " ").capitalized
    }

    var statusColor: Color {
        switch statusToken {
        case "running":
            return .blue
        case "succeeded", "success", "finished", "completed":
            return .green
        case "failed", "error", "errored":
            return .red
        case "cancelled", "canceled":
            return .gray
        default:
            return .secondary
        }
    }

    var createdAtText: String {
        Self.format(date: createdAt ?? startedAt)
    }

    static func sortDescending(lhs: WorkflowRunListItem, rhs: WorkflowRunListItem) -> Bool {
        switch (lhs.createdAt ?? lhs.startedAt, rhs.createdAt ?? rhs.startedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id > rhs.id
        }
    }

    private static func format(date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct WorkflowRunDetail: Decodable {
    let id: Int64
    let workflowDefinitionID: Int64?
    let workflowID: String?
    let status: String
    let workflowName: String?
    let createdAt: Date?
    let startedAt: Date?
    let dispatchedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case workflowDefinitionID = "workflow_definition_id"
        case workflowID = "workflow_id"
        case status
        case workflowName = "workflow_name"
        case workflowNameCamel = "workflowName"
        case name
        case createdAt = "created_at"
        case startedAt = "started_at"
        case dispatchedAt = "dispatched_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = container.decodeLossyInt64(forKey: .id)
        guard let id else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected workflow run id"
                )
            )
        }

        self.id = id
        self.workflowDefinitionID = container.decodeLossyInt64(forKey: .workflowDefinitionID)
        self.workflowID = container.decodeLossyString(forKey: .workflowID)
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        let workflowName = try container.decodeIfPresent(String.self, forKey: .workflowName)
        let workflowNameCamel = try container.decodeIfPresent(String.self, forKey: .workflowNameCamel)
        let name = try container.decodeIfPresent(String.self, forKey: .name)
        let decodedWorkflowName = workflowName ?? workflowNameCamel ?? name
        self.workflowName = decodedWorkflowName?.trimmedNonEmpty
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.dispatchedAt = try container.decodeIfPresent(Date.self, forKey: .dispatchedAt)
    }

    init(from run: WorkflowRunListItem) {
        self.id = run.id
        self.workflowDefinitionID = run.workflowDefinitionID
        self.workflowID = run.workflowID
        self.status = run.status
        self.workflowName = run.workflowName
        self.createdAt = run.createdAt
        self.startedAt = run.startedAt
        self.dispatchedAt = nil
    }

    var workflowIDText: String {
        workflowID ?? workflowDefinitionID.map(String.init) ?? "Unknown"
    }

    var statusLabel: String {
        let token = status.normalizedWorkflowRunStatus
        return token.isEmpty ? "Unknown" : token.replacingOccurrences(of: "-", with: " ").capitalized
    }

    var statusColor: Color {
        switch status.normalizedWorkflowRunStatus {
        case "running":
            return .blue
        case "succeeded", "success", "finished", "completed":
            return .green
        case "failed", "error", "errored":
            return .red
        case "cancelled", "canceled":
            return .gray
        default:
            return .secondary
        }
    }

    var dispatchTimeText: String {
        let date = dispatchedAt ?? createdAt ?? startedAt
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var navigationTitle: String {
        workflowName ?? "Run \(id)"
    }

    var canCancel: Bool {
        status.normalizedWorkflowRunStatus == "running"
    }
}

private struct WorkflowRunsEnvelope: Decodable {
    let runs: [WorkflowRunListItem]?
    let items: [WorkflowRunListItem]?
    let data: [WorkflowRunListItem]?
}

private struct WorkflowRunInspectionEnvelope: Decodable {
    let run: WorkflowRunDetail
}

struct WorkflowRunsRepoRef: Hashable {
    let owner: String
    let name: String

    var repoLabel: String {
        "\(owner)/\(name)"
    }

    static func seeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WorkflowRunsRepoRef? {
        guard
            let owner = environment["PLUE_E2E_REPO_OWNER"]?.trimmedNonEmpty,
            let name = environment["PLUE_E2E_REPO_NAME"]?.trimmedNonEmpty
        else {
            return nil
        }
        return WorkflowRunsRepoRef(owner: owner, name: name)
    }

    func workflowRunsListURL(baseURL: URL) -> URL {
        repoBaseURL(baseURL: baseURL)
            .appendingPathComponent("workflows")
            .appendingPathComponent("runs")
    }

    func runDetailURLs(baseURL: URL, runID: Int64) -> [URL] {
        [
            repoBaseURL(baseURL: baseURL)
                .appendingPathComponent("runs")
                .appendingPathComponent(String(runID)),
            workflowRunsListURL(baseURL: baseURL)
                .appendingPathComponent(String(runID)),
            repoBaseURL(baseURL: baseURL)
                .appendingPathComponent("actions")
                .appendingPathComponent("runs")
                .appendingPathComponent(String(runID)),
        ]
    }

    func cancelRunURLs(baseURL: URL, runID: Int64) -> [URL] {
        [
            repoBaseURL(baseURL: baseURL)
                .appendingPathComponent("runs")
                .appendingPathComponent(String(runID))
                .appendingPathComponent("cancel"),
            workflowRunsListURL(baseURL: baseURL)
                .appendingPathComponent(String(runID))
                .appendingPathComponent("cancel"),
            repoBaseURL(baseURL: baseURL)
                .appendingPathComponent("actions")
                .appendingPathComponent("runs")
                .appendingPathComponent(String(runID))
                .appendingPathComponent("cancel"),
        ]
    }

    private func repoBaseURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(name)
    }
}

private enum WorkflowRunsError: LocalizedError {
    case authExpired
    case backendUnavailable(String)
    case invalidResponse
    case notFound

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Your session expired. Sign in again."
        case .backendUnavailable(let message):
            return message.trimmedNonEmpty ?? "Unable to load workflow runs."
        case .invalidResponse:
            return "Server returned an unexpected workflow-runs payload."
        case .notFound:
            return "Workflow run not found."
        }
    }
}

private struct APIErrorPayload: Decodable {
    let message: String?
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var normalizedWorkflowRunStatus: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    func decodeLossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.trimmedNonEmpty
        }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}
#endif
