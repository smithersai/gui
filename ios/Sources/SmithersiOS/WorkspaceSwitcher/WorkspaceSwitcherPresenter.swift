// WorkspaceSwitcherPresenter.swift — iOS full-screen modal host for the
// shared workspace switcher (ticket 0138).
//
// On iOS the switcher is a dedicated surface (per spec: full-screen
// modal). Remote-only — Local recents are a desktop-only construct and
// are intentionally absent here.
//
// Composition:
//   - Caller passes in a `WorkspaceSwitcherViewModel` already wired to
//     a `RemoteWorkspaceFetcher` and (optionally) a `WorkspaceDeleter`.
//   - This wrapper provides the `.sheet` modifier plumbing so the iOS
//     shell can present the switcher without knowing about its inner
//     state.
//   - `.task` on present drives the initial load. On foreground (app
//     becoming active), the caller should call `refresh()` if the
//     shape isn't live — we surface a `refresh()` button in the
//     navigation bar for the explicit-refresh fallback path.

#if os(iOS)
import SwiftUI
#if SWIFT_PACKAGE
import SmithersStore
#endif

public struct WorkspaceSwitcherPresenter: View {
    @ObservedObject public var viewModel: WorkspaceSwitcherViewModel
    public let onOpen: (SwitcherWorkspace) -> Void
    public let onSignIn: () -> Void
    public let onDismiss: () -> Void
    public let baseURL: URL
    public let bearerProvider: () -> String?
    public let focusedWorkspaceID: String?
    public let autoOpenFocusedWorkspace: Bool

    @State private var activeSheet: WorkspaceSwitcherActiveSheet?
    @State private var createWorkspaceTitle = ""
    @State private var createWorkspaceError: String?
    @State private var isCreatingWorkspace = false
    @State private var autoOpenedWorkspaceID: String?

    public init(
        viewModel: WorkspaceSwitcherViewModel,
        baseURL: URL,
        bearerProvider: @escaping () -> String?,
        focusedWorkspaceID: String? = nil,
        autoOpenFocusedWorkspace: Bool = false,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.onOpen = onOpen
        self.onSignIn = onSignIn
        self.onDismiss = onDismiss
        self.focusedWorkspaceID = focusedWorkspaceID
        self.autoOpenFocusedWorkspace = autoOpenFocusedWorkspace
    }

    public var body: some View {
        NavigationStack {
            WorkspaceSwitcherView(
                viewModel: viewModel,
                onOpen: { workspace in
                    onOpen(workspace)
                    onDismiss()
                },
                onSignIn: onSignIn,
                onRetry: { Task { await viewModel.refresh() } },
                onSelectRepoFilter: {
                    activeSheet = .repoSelector(.filter)
                },
                onClearRepoFilter: {
                    viewModel.clearRepoFilter()
                },
                focusedWorkspaceID: focusedWorkspaceID,
                onFocusedWorkspaceResolved: { workspace in
                    scheduleFocusedWorkspaceOpen(workspace)
                }
            )
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onDismiss)
                        .accessibilityIdentifier("switcher.ios.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginCreateWorkspace()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("switcher.ios.create")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(viewModel.isRefreshing)
                    .accessibilityIdentifier("switcher.ios.refresh")
                }
            }
        }
        .task { await viewModel.refresh() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .repoSelector(let purpose):
                RepoSelectorSheet(
                    title: purpose.title,
                    client: URLSessionUserReposClient(
                        baseURL: baseURL,
                        bearerProvider: bearerProvider
                    ),
                    allowsAllRepos: purpose == .filter,
                    selectedRepo: purpose == .filter ? viewModel.selectedRepoFilter : nil,
                    onSelect: { repo in
                        handleRepoSelection(repo, purpose: purpose)
                    },
                    onCancel: {
                        activeSheet = nil
                    }
                )
            case .createTitle(let repo):
                CreateWorkspaceTitleSheet(
                    repo: repo,
                    title: $createWorkspaceTitle,
                    errorMessage: createWorkspaceError,
                    isCreating: isCreatingWorkspace,
                    onCancel: {
                        guard !isCreatingWorkspace else { return }
                        activeSheet = nil
                    },
                    onSubmit: {
                        Task { await createWorkspace(in: repo) }
                    }
                )
            }
        }
        .accessibilityIdentifier("switcher.ios.root")
    }

    private func beginCreateWorkspace() {
        createWorkspaceTitle = ""
        createWorkspaceError = nil
        activeSheet = .repoSelector(.create)
    }

    private func handleRepoSelection(_ repo: SwitcherRepoRef?, purpose: RepoSelectorPurpose) {
        switch purpose {
        case .filter:
            viewModel.setRepoFilter(repo)
            activeSheet = nil
        case .create:
            guard let repo else { return }
            createWorkspaceTitle = ""
            createWorkspaceError = nil
            activeSheet = .createTitle(repo)
        }
    }

    private func createWorkspace(in repo: SwitcherRepoRef) async {
        guard let title = createWorkspaceTitle.workspaceSwitcherTrimmedNonEmpty else {
            return
        }

        isCreatingWorkspace = true
        createWorkspaceError = nil
        defer { isCreatingWorkspace = false }

        do {
            _ = try await URLSessionWorkspaceCreateClient(
                baseURL: baseURL,
                bearerProvider: bearerProvider
            )
            .createWorkspace(repo: repo, title: title)
            activeSheet = nil
            createWorkspaceTitle = ""
            await viewModel.refresh()
        } catch {
            createWorkspaceError = error.localizedDescription
        }
    }

    private func scheduleFocusedWorkspaceOpen(_ workspace: SwitcherWorkspace) {
        guard autoOpenFocusedWorkspace,
              focusedWorkspaceID == workspace.id,
              autoOpenedWorkspaceID != workspace.id
        else {
            return
        }

        autoOpenedWorkspaceID = workspace.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            onOpen(workspace)
            onDismiss()
        }
    }
}

/// Convenience `.sheet` style modifier: `.workspaceSwitcherSheet(...)`
/// from the iOS shell presents the switcher full-screen when `isPresented`
/// becomes true.
public extension View {
    func workspaceSwitcherSheet(
        isPresented: Binding<Bool>,
        viewModel: WorkspaceSwitcherViewModel,
        baseURL: URL,
        bearerProvider: @escaping () -> String?,
        focusedWorkspaceID: String? = nil,
        autoOpenFocusedWorkspace: Bool = false,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            WorkspaceSwitcherPresenter(
                viewModel: viewModel,
                baseURL: baseURL,
                bearerProvider: bearerProvider,
                focusedWorkspaceID: focusedWorkspaceID,
                autoOpenFocusedWorkspace: autoOpenFocusedWorkspace,
                onOpen: onOpen,
                onSignIn: onSignIn,
                onDismiss: { isPresented.wrappedValue = false }
            )
        }
    }
}

private enum RepoSelectorPurpose: Hashable {
    case create
    case filter

    var title: String {
        switch self {
        case .create:
            return "Choose Repository"
        case .filter:
            return "Filter by Repository"
        }
    }
}

private enum WorkspaceSwitcherActiveSheet: Identifiable, Hashable {
    case repoSelector(RepoSelectorPurpose)
    case createTitle(SwitcherRepoRef)

    var id: String {
        switch self {
        case .repoSelector(let purpose):
            return "repo-selector-\(purpose)"
        case .createTitle(let repo):
            return "create-title-\(repo.id)"
        }
    }
}

private struct CreateWorkspaceTitleSheet: View {
    let repo: SwitcherRepoRef
    @Binding var title: String
    let errorMessage: String?
    let isCreating: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Repository") {
                        Text(repo.label)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Workspace title", text: $title)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("switcher.create.title")
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("switcher.create.error")
                    }
                }
            }
            .navigationTitle("New Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(isCreating)
                        .accessibilityIdentifier("switcher.create.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onSubmit()
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(title.workspaceSwitcherTrimmedNonEmpty == nil || isCreating)
                    .accessibilityIdentifier("switcher.create.submit")
                }
            }
        }
        .interactiveDismissDisabled(isCreating)
    }
}

private struct URLSessionWorkspaceCreateClient {
    private let baseURL: URL
    private let bearerProvider: () -> String?
    private let session: URLSession

    init(
        baseURL: URL,
        bearerProvider: @escaping () -> String?,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.session = session
    }

    func createWorkspace(repo: SwitcherRepoRef, title: String) async throws -> SwitcherWorkspace {
        var request = URLRequest(url: workspaceCreateURL(repo: repo))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try requireBearer())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(CreateWorkspaceRequest(name: title))

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WorkspaceCreateError.backendUnavailable("Missing HTTP response")
            }

            switch http.statusCode {
            case 200, 201:
                return try Self.decodeWorkspace(from: data, repo: repo, fallbackTitle: title)
            case 401, 403:
                throw WorkspaceCreateError.authExpired
            default:
                throw WorkspaceCreateError.backendUnavailable(
                    Self.decodeErrorMessage(from: data, status: http.statusCode)
                )
            }
        } catch let error as WorkspaceCreateError {
            throw error
        } catch {
            throw WorkspaceCreateError.backendUnavailable(error.localizedDescription)
        }
    }

    private func workspaceCreateURL(repo: SwitcherRepoRef) -> URL {
        baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("repos")
            .appendingPathComponent(repo.owner)
            .appendingPathComponent(repo.name)
            .appendingPathComponent("workspaces")
    }

    private func requireBearer() throws -> String {
        guard let token = bearerProvider()?.workspaceSwitcherTrimmedNonEmpty else {
            throw WorkspaceCreateError.authExpired
        }
        return token
    }

    private static func decodeWorkspace(
        from data: Data,
        repo: SwitcherRepoRef,
        fallbackTitle: String
    ) throws -> SwitcherWorkspace {
        let record = try StoreDecoder.shared.decode(CreateWorkspaceRecord.self, from: data)
        guard let id = record.resolvedID else {
            throw WorkspaceCreateError.invalidResponse
        }
        return SwitcherWorkspace(
            id: id,
            repoOwner: repo.owner,
            repoName: repo.name,
            title: record.title.workspaceSwitcherTrimmedNonEmpty
                ?? record.name.workspaceSwitcherTrimmedNonEmpty
                ?? fallbackTitle,
            state: record.status.workspaceSwitcherTrimmedNonEmpty
                ?? record.state.workspaceSwitcherTrimmedNonEmpty
                ?? "unknown",
            lastAccessedAt: record.lastAccessedAt,
            lastActivityAt: record.lastActivityAt,
            createdAt: record.createdAt,
            source: .remote
        )
    }

    private static func decodeErrorMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONDecoder().decode(WorkspaceCreateAPIErrorPayload.self, from: data),
           let message = payload.message?.workspaceSwitcherTrimmedNonEmpty {
            return message
        }
        if let body = String(data: data, encoding: .utf8)?.workspaceSwitcherTrimmedNonEmpty {
            return body
        }
        return "HTTP \(status)"
    }
}

private struct CreateWorkspaceRequest: Encodable {
    let name: String
}

private struct CreateWorkspaceRecord: Decodable {
    let id: String?
    let workspaceID: String?
    let title: String?
    let name: String?
    let status: String?
    let state: String?
    let lastAccessedAt: Date?
    let lastActivityAt: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case title
        case name
        case status
        case state
        case lastAccessedAt = "last_accessed_at"
        case lastActivityAt = "last_activity_at"
        case createdAt = "created_at"
    }

    var resolvedID: String? {
        id.workspaceSwitcherTrimmedNonEmpty ?? workspaceID.workspaceSwitcherTrimmedNonEmpty
    }
}

private struct WorkspaceCreateAPIErrorPayload: Decodable {
    let message: String?
}

private enum WorkspaceCreateError: LocalizedError {
    case authExpired
    case invalidResponse
    case backendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .authExpired:
            return "Your session expired. Sign in again."
        case .invalidResponse:
            return "Workspace create returned an invalid response."
        case .backendUnavailable(let message):
            return message.workspaceSwitcherTrimmedNonEmpty ?? "Unable to create workspace."
        }
    }
}

private extension Optional where Wrapped == String {
    var workspaceSwitcherTrimmedNonEmpty: String? {
        flatMap { $0.workspaceSwitcherTrimmedNonEmpty }
    }
}

private extension String {
    var workspaceSwitcherTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
