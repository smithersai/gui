#if os(iOS)
import Foundation
import SwiftUI
import UIKit

struct ApprovalsInboxView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ApprovalsInboxViewModel
    private let focusedApprovalID: String?

    init(
        baseURL: URL,
        bearerProvider: @escaping () -> String?,
        focusedApprovalID: String? = nil
    ) {
        self.focusedApprovalID = focusedApprovalID
        _viewModel = StateObject(
            wrappedValue: ApprovalsInboxViewModel(
                client: URLSessionApprovalsInboxClient(
                    baseURL: baseURL,
                    bearerProvider: bearerProvider
                )
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let loadError = viewModel.loadError, !loadError.isEmpty {
                    ApprovalsErrorBanner(message: loadError) {
                        Task { await viewModel.reload() }
                    }
                }

                Group {
                    if viewModel.isLoading && viewModel.rows.isEmpty {
                        ProgressView("Loading approvals...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("approvals.loading")
                    } else if viewModel.rows.isEmpty {
                        if viewModel.loadError == nil {
                            emptyState
                        } else {
                            failedState
                        }
                    } else {
                        inboxList
                    }
                }
            }
            .navigationTitle("Approvals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.reload() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoading)
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .accessibilityIdentifier("approvals.inbox.root")
    }

    private var inboxList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.rows) { row in
                    ApprovalInboxRow(
                        row: row,
                        inlineError: viewModel.inlineError(for: row.id),
                        isWorking: viewModel.isWorking(on: row.id),
                        onApprove: {
                            Task { await viewModel.decide(row, decision: .approved) }
                        },
                        onDeny: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task { await viewModel.decide(row, decision: .rejected) }
                        }
                    )
                    .id(row.id)
                    .accessibilityIdentifier(approvalRowAccessibilityID(for: row.id))
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                }
            }
            .listStyle(.plain)
            .refreshable {
                await viewModel.reload()
            }
            .onAppear {
                scrollToFocusedApproval(in: proxy)
            }
            .onChange(of: focusedApprovalScrollKey) { _, _ in
                scrollToFocusedApproval(in: proxy)
            }
        }
    }

    private var focusedApprovalScrollKey: String {
        "\(focusedApprovalID ?? "")|\(viewModel.rows.map(\.id).joined(separator: ","))"
    }

    private func approvalRowAccessibilityID(for rowID: String) -> String {
        rowID == focusedApprovalID ? "deeplink.focused.\(rowID)" : "approvals.row.\(rowID)"
    }

    private func scrollToFocusedApproval(in proxy: ScrollViewProxy) {
        guard let focusedApprovalID,
              viewModel.rows.contains(where: { $0.id == focusedApprovalID })
        else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(focusedApprovalID, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(viewModel.loadError == nil ? "No pending approvals" : "Unable to load approvals")
                .font(.headline)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("approvals.empty")
    }

    private var failedState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Unable to load approvals")
                .font(.headline)

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

private struct ApprovalsErrorBanner: View {
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
                .accessibilityIdentifier("approvals.error.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approvals.error")
    }
}

private struct ApprovalInboxRow: View {
    let row: ApprovalInboxRowModel
    let inlineError: String?
    let isWorking: Bool
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                if let description = row.normalizedDescription {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text(row.repoLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("approvals.row.\(row.id).approve")

                Button("Deny", role: .destructive, action: onDeny)
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                    .accessibilityIdentifier("approvals.row.\(row.id).deny")

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let inlineError, !inlineError.isEmpty {
                Text(inlineError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
final class ApprovalsInboxViewModel: ObservableObject {
    @Published private(set) var rows: [ApprovalInboxRowModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private var rowErrors: [String: String] = [:]
    @Published private var inFlightIDs: Set<String> = []

    private var hasLoaded = false
    private let client: any ApprovalsInboxClient

    init(client: any ApprovalsInboxClient) {
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        let hadRows = !rows.isEmpty
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let loaded = try await client.fetchPendingApprovals()
            rows = loaded.sorted(by: ApprovalInboxRowModel.sortDescending)
            hasLoaded = true
        } catch {
            loadError = error.localizedDescription
            if !hadRows {
                rows = []
            }
        }
    }

    func decide(_ row: ApprovalInboxRowModel, decision: ApprovalInboxDecision) async {
        rowErrors[row.id] = nil
        inFlightIDs.insert(row.id)
        defer { inFlightIDs.remove(row.id) }

        do {
            try await client.decide(
                approvalID: row.id,
                repo: row.repo,
                decision: decision
            )
            rowErrors[row.id] = nil
            rows.removeAll { $0.id == row.id }
        } catch {
            rowErrors[row.id] = error.localizedDescription
        }
    }

    func inlineError(for approvalID: String) -> String? {
        rowErrors[approvalID]
    }

    func isWorking(on approvalID: String) -> Bool {
        inFlightIDs.contains(approvalID)
    }
}

protocol ApprovalsInboxClient {
    func fetchPendingApprovals() async throws -> [ApprovalInboxRowModel]
    func decide(
        approvalID: String,
        repo: ApprovalRepoRef,
        decision: ApprovalInboxDecision
    ) async throws
}

struct URLSessionApprovalsInboxClient: ApprovalsInboxClient {
    private let baseURL: URL
    private let bearerProvider: () -> String?
    private let workspaceFetcher: URLSessionRemoteWorkspaceFetcher
    private let session: URLSession

    init(
        baseURL: URL,
        bearerProvider: @escaping () -> String?,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.session = session
        self.workspaceFetcher = URLSessionRemoteWorkspaceFetcher(
            baseURL: baseURL,
            bearer: bearerProvider,
            session: session
        )
    }

    func fetchPendingApprovals() async throws -> [ApprovalInboxRowModel] {
        let repos = try await discoverRepos()
        guard !repos.isEmpty else { return [] }

        var rows: [ApprovalInboxRowModel] = []
        var seenIDs: Set<String> = []

        for repo in repos {
            let approvals = try await listApprovals(in: repo)
            for approval in approvals where approval.isPending {
                let row = approval.asRowModel(repo: repo)
                if seenIDs.insert(row.id).inserted {
                    rows.append(row)
                }
            }
        }

        return rows
    }

    func decide(
        approvalID: String,
        repo: ApprovalRepoRef,
        decision: ApprovalInboxDecision
    ) async throws {
        var request = URLRequest(url: repo.decideURL(baseURL: baseURL, approvalID: approvalID))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try requireBearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(DecisionRequest(decision: decision.rawValue))

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApprovalsInboxError.backendUnavailable("Missing HTTP response")
            }

            switch http.statusCode {
            case 200:
                return
            case 401, 403:
                throw ApprovalsInboxError.authExpired
            default:
                throw ApprovalsInboxError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as ApprovalsInboxError {
            throw error
        } catch {
            throw ApprovalsInboxError.backendUnavailable(error.localizedDescription)
        }
    }

    private func discoverRepos() async throws -> [ApprovalRepoRef] {
        let workspaces: [UserWorkspaceDTO]
        do {
            workspaces = try await workspaceFetcher.fetch(limit: 100)
        } catch let error as RemoteWorkspaceFetchError {
            if let fallback = Self.seededRepoFromEnvironment() {
                return [fallback]
            }
            throw ApprovalsInboxError(error)
        } catch {
            if let fallback = Self.seededRepoFromEnvironment() {
                return [fallback]
            }
            throw ApprovalsInboxError.backendUnavailable(error.localizedDescription)
        }

        var repos: Set<ApprovalRepoRef> = []
        for workspace in workspaces {
            guard
                let owner = workspace.repoOwner?.trimmedNonEmpty,
                let name = workspace.repoName?.trimmedNonEmpty
            else {
                continue
            }
            repos.insert(ApprovalRepoRef(owner: owner, name: name))
        }

        if repos.isEmpty, let fallback = Self.seededRepoFromEnvironment() {
            repos.insert(fallback)
        }

        return repos.sorted {
            if $0.owner == $1.owner {
                return $0.name < $1.name
            }
            return $0.owner < $1.owner
        }
    }

    private func listApprovals(in repo: ApprovalRepoRef) async throws -> [ApprovalInboxDTO] {
        var components = URLComponents(
            url: repo.approvalsURL(baseURL: baseURL),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "state", value: "pending")]

        guard let url = components?.url else {
            throw ApprovalsInboxError.backendUnavailable("Invalid approvals URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try requireBearer())", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApprovalsInboxError.backendUnavailable("Missing HTTP response")
            }

            switch http.statusCode {
            case 200:
                return try Self.decodeApprovals(from: data)
            case 401, 403:
                throw ApprovalsInboxError.authExpired
            default:
                throw ApprovalsInboxError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as ApprovalsInboxError {
            throw error
        } catch {
            throw ApprovalsInboxError.backendUnavailable(error.localizedDescription)
        }
    }

    private func requireBearer() throws -> String {
        guard let token = bearerProvider()?.trimmedNonEmpty else {
            throw ApprovalsInboxError.authExpired
        }
        return token
    }

    private static func decodeApprovals(from data: Data) throws -> [ApprovalInboxDTO] {
        if data.isEmpty {
            return []
        }
        if let rows = try? StoreDecoder.shared.decode([ApprovalInboxDTO].self, from: data) {
            return rows
        }

        let envelope = try StoreDecoder.shared.decode(ApprovalInboxEnvelope.self, from: data)
        if let approvals = envelope.approvals {
            return approvals
        }
        if let items = envelope.items {
            return items
        }
        if let results = envelope.results {
            return results
        }
        if let dataRows = envelope.data {
            return dataRows
        }
        return []
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

    private static func seededRepoFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ApprovalRepoRef? {
        guard
            let owner = environment["PLUE_E2E_REPO_OWNER"]?.trimmedNonEmpty,
            let name = environment["PLUE_E2E_REPO_NAME"]?.trimmedNonEmpty
        else {
            return nil
        }
        return ApprovalRepoRef(owner: owner, name: name)
    }
}

struct ApprovalRepoRef: Hashable {
    let owner: String
    let name: String

    var repoLabel: String {
        "\(owner)/\(name)"
    }

    func approvalsURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(owner)
            .appendingPathComponent(name)
            .appendingPathComponent("approvals")
    }

    func decideURL(baseURL: URL, approvalID: String) -> URL {
        approvalsURL(baseURL: baseURL)
            .appendingPathComponent(approvalID)
            .appendingPathComponent("decide")
    }
}

enum ApprovalInboxDecision: String {
    case approved
    case rejected
}

struct ApprovalInboxRowModel: Identifiable {
    let id: String
    let repo: ApprovalRepoRef
    let title: String
    let description: String?
    let createdAt: Date?

    var repoLabel: String {
        repo.repoLabel
    }

    var normalizedDescription: String? {
        description?.trimmedNonEmpty
    }

    static func sortDescending(lhs: ApprovalInboxRowModel, rhs: ApprovalInboxRowModel) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
            if left != right {
                return left > right
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private struct ApprovalInboxDTO: Decodable {
    let id: String
    let approvalID: String?
    let status: String?
    let state: String?
    let title: String
    let description: String?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case approvalID = "approval_id"
        case status
        case state
        case title
        case description
        case createdAt = "created_at"
    }

    var isPending: Bool {
        switch (status ?? state ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "", "pending", "waiting", "waiting-approval", "blocked", "paused":
            return true
        default:
            return false
        }
    }

    func asRowModel(repo: ApprovalRepoRef) -> ApprovalInboxRowModel {
        ApprovalInboxRowModel(
            id: approvalID ?? id,
            repo: repo,
            title: title,
            description: description,
            createdAt: createdAt
        )
    }
}

private struct ApprovalInboxEnvelope: Decodable {
    let approvals: [ApprovalInboxDTO]?
    let items: [ApprovalInboxDTO]?
    let results: [ApprovalInboxDTO]?
    let data: [ApprovalInboxDTO]?
}

private struct DecisionRequest: Encodable {
    let decision: String
}

private struct APIErrorPayload: Decodable {
    let message: String?
}

private enum ApprovalsInboxError: LocalizedError {
    case authExpired
    case backendUnavailable(String)

    init(_ error: RemoteWorkspaceFetchError) {
        switch error {
        case .authExpired:
            self = .authExpired
        case .backendUnavailable(let message), .decode(let message):
            self = .backendUnavailable(message)
        }
    }

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Your session expired. Sign in again."
        case .backendUnavailable(let message):
            return message.trimmedNonEmpty ?? "Unable to reach approvals."
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
