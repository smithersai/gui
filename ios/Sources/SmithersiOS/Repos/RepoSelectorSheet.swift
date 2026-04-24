#if os(iOS)
import Foundation
import SwiftUI

struct RepoSelectorSheet: View {
    @StateObject private var viewModel: RepoSelectorViewModel
    @State private var searchText = ""

    private let title: String
    private let allowsAllRepos: Bool
    private let selectedRepo: SwitcherRepoRef?
    private let onSelect: (SwitcherRepoRef?) -> Void
    private let onCancel: () -> Void

    init(
        title: String,
        client: any UserReposClient,
        allowsAllRepos: Bool,
        selectedRepo: SwitcherRepoRef?,
        onSelect: @escaping (SwitcherRepoRef?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.allowsAllRepos = allowsAllRepos
        self.selectedRepo = selectedRepo
        self.onSelect = onSelect
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: RepoSelectorViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField

                Group {
                    if viewModel.isLoading && viewModel.repos.isEmpty {
                        ProgressView("Loading repositories...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage = viewModel.errorMessage, viewModel.repos.isEmpty {
                        errorState(errorMessage)
                    } else if rows.isEmpty && !allowsAllRepos {
                        emptyState
                    } else {
                        repoList
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .primaryAction) {
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
        .accessibilityIdentifier("repo-selector.root")
    }

    private var searchField: some View {
        TextField("Search repositories", text: $searchText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("repo-selector.search")
    }

    private var repoList: some View {
        List {
            if allowsAllRepos {
                Button {
                    onSelect(nil)
                } label: {
                    repoRowLabel(title: "All repos", isSelected: selectedRepo == nil)
                }
                .accessibilityIdentifier("repo-selector.row.all")
            }

            ForEach(rows) { repo in
                Button {
                    onSelect(repo)
                } label: {
                    repoRowLabel(title: repo.label, isSelected: selectedRepo == repo)
                }
                .accessibilityIdentifier("repo-selector.row.\(repo.accessibilityKey)")
            }
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.reload()
        }
    }

    private var rows: [SwitcherRepoRef] {
        viewModel.filteredRepos(matching: searchText)
    }

    private func repoRowLabel(title: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .frame(width: 22)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Unable to load repositories")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                Task { await viewModel.reload() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No repositories found")
                .font(.headline)
            Text("Repositories with workspaces will appear here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

@MainActor
final class RepoSelectorViewModel: ObservableObject {
    @Published private(set) var repos: [SwitcherRepoRef] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let client: any UserReposClient
    private var hasLoaded = false

    init(client: any UserReposClient) {
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            repos = try await client.fetchRepos()
            hasLoaded = true
        } catch {
            errorMessage = error.localizedDescription
            if repos.isEmpty {
                hasLoaded = false
            }
        }
    }

    func filteredRepos(matching query: String) -> [SwitcherRepoRef] {
        guard let normalizedQuery = query.repoSelectorTrimmedNonEmpty?.lowercased() else {
            return repos
        }

        return repos.filter {
            $0.label.lowercased().contains(normalizedQuery) ||
            $0.owner.lowercased().contains(normalizedQuery) ||
            $0.name.lowercased().contains(normalizedQuery)
        }
    }
}

protocol UserReposClient {
    func fetchRepos() async throws -> [SwitcherRepoRef]
}

struct URLSessionUserReposClient: UserReposClient {
    private let baseURL: URL
    private let bearerProvider: () -> String?
    private let session: URLSession
    private let workspaceFetcher: URLSessionRemoteWorkspaceFetcher

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

    func fetchRepos() async throws -> [SwitcherRepoRef] {
        let token = try requireBearer()
        do {
            return try await fetchUserReposRoute(token: token)
        } catch UserReposError.routeUnavailable {
            return try await fetchReposFromWorkspaces()
        }
    }

    private func fetchUserReposRoute(token: String) async throws -> [SwitcherRepoRef] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/user/repos"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UserReposError.backendUnavailable("Missing HTTP response")
            }

            switch http.statusCode {
            case 200:
                return Self.uniqueSorted(try Self.decodeRepos(from: data))
            case 204:
                return []
            case 401, 403:
                throw UserReposError.authExpired
            case 404, 405, 501:
                throw UserReposError.routeUnavailable
            default:
                throw UserReposError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as UserReposError {
            throw error
        } catch {
            throw UserReposError.backendUnavailable(error.localizedDescription)
        }
    }

    private func fetchReposFromWorkspaces() async throws -> [SwitcherRepoRef] {
        do {
            let workspaces = try await workspaceFetcher.fetch(limit: 100)
            let repos = workspaces.compactMap {
                SwitcherRepoRef.normalized(owner: $0.repoOwner, name: $0.repoName)
            }
            return Self.uniqueSorted(repos)
        } catch let error as RemoteWorkspaceFetchError {
            throw UserReposError(error)
        } catch {
            throw UserReposError.backendUnavailable(error.localizedDescription)
        }
    }

    private func requireBearer() throws -> String {
        guard let token = bearerProvider()?.repoSelectorTrimmedNonEmpty else {
            throw UserReposError.authExpired
        }
        return token
    }

    private static func decodeRepos(from data: Data) throws -> [SwitcherRepoRef] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()

        if let rows = try? decoder.decode([UserRepoDTO].self, from: data) {
            return rows.compactMap(\.repoRef)
        }

        let envelope = try decoder.decode(UserReposEnvelope.self, from: data)
        let rows = envelope.repos
            ?? envelope.repositories
            ?? envelope.items
            ?? envelope.results
            ?? envelope.data
            ?? []
        return rows.compactMap(\.repoRef)
    }

    private static func decodeErrorMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(RepoSelectorAPIErrorPayload.self, from: data),
           let message = payload.message?.repoSelectorTrimmedNonEmpty {
            return message
        }
        if let body = String(data: data, encoding: .utf8)?.repoSelectorTrimmedNonEmpty {
            return body
        }
        return "HTTP \(status)"
    }

    private static func uniqueSorted(_ repos: [SwitcherRepoRef]) -> [SwitcherRepoRef] {
        var seen = Set<SwitcherRepoRef>()
        var unique: [SwitcherRepoRef] = []

        for repo in repos where seen.insert(repo).inserted {
            unique.append(repo)
        }

        return unique.sorted {
            if $0.owner == $1.owner {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending
        }
    }
}

private struct UserRepoDTO: Decodable {
    let owner: String?
    let name: String?
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case owner
        case repoOwner = "repo_owner"
        case repositoryOwner = "repository_owner"
        case namespace
        case organization
        case org
        case name
        case repoName = "repo_name"
        case repositoryName = "repository_name"
        case slug
        case fullName = "full_name"
        case fullNameCamel = "fullName"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owner = container.decodeFirstString([
            .owner,
            .repoOwner,
            .repositoryOwner,
            .namespace,
            .organization,
            .org,
        ])
        name = container.decodeFirstString([
            .name,
            .repoName,
            .repositoryName,
            .slug,
        ])
        fullName = container.decodeFirstString([.fullName, .fullNameCamel])
    }

    var repoRef: SwitcherRepoRef? {
        if let ref = SwitcherRepoRef.normalized(owner: owner, name: name) {
            return ref
        }

        guard let fullName = fullName?.repoSelectorTrimmedNonEmpty else {
            return nil
        }
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return SwitcherRepoRef.normalized(owner: parts[0], name: parts[1])
    }
}

private struct UserReposEnvelope: Decodable {
    let repos: [UserRepoDTO]?
    let repositories: [UserRepoDTO]?
    let items: [UserRepoDTO]?
    let results: [UserRepoDTO]?
    let data: [UserRepoDTO]?
}

private struct RepoSelectorAPIErrorPayload: Decodable {
    let message: String?
}

private enum UserReposError: LocalizedError {
    case authExpired
    case routeUnavailable
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
        case .routeUnavailable:
            return "Repository listing is not available."
        case .backendUnavailable(let message):
            return message.repoSelectorTrimmedNonEmpty ?? "Unable to load repositories."
        }
    }
}

private extension KeyedDecodingContainer where Key == UserRepoDTO.CodingKeys {
    func decodeFirstString(_ keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decodeIfPresent(String.self, forKey: key),
               let trimmed = value.repoSelectorTrimmedNonEmpty {
                return trimmed
            }
        }
        return nil
    }
}

private extension String {
    var repoSelectorTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
