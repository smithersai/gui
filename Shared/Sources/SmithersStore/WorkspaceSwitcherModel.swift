// WorkspaceSwitcherModel.swift — enriched row + view-model for ticket 0138.
//
// Design notes:
//   - The 0124 `WorkspaceRow` is the bare shape-slice row. The switcher
//     needs a richer view type carrying repo owner/name, a human-friendly
//     workspace title (falling back to `name`), a `state`, a
//     `last_accessed_at` timestamp (0136), and a `source` kind so macOS
//     can keep Local separate from Remote in one list model if it wants.
//   - The remote list fetch is an HTTP GET of 0135's
//     `/api/user/workspaces?limit=100`. This view-model does NOT own
//     URLSession — callers inject a `RemoteFetcher` so tests can drive
//     ordering / empty-state / auth-expired deterministically without a
//     live stack.
//   - Live updates after initial load come from the 0116 workspaces
//     shape via `WorkspacesStore.workspaces`; when the shape is live we
//     `isLive()==true` and skip the background refetch on wake. When
//     it is NOT live (0120 fake transport today), the presenter can call
//     `refresh()` on foreground — we do NOT hide a polling loop in here.
//   - Delete routes through `ActionRequestFactory.workspaceDelete(...)` (0105 owns the
//     surface). Soft-delete → row disappears when the shape echoes.
//     Hard-delete → row is gone outright. Either way: single path.
//   - Ordering rule (MUST match 0135's server order):
//       COALESCE(last_accessed_at, last_activity_at, created_at) DESC,
//       id DESC
//     We preserve server order verbatim and only apply the `id DESC`
//     tiebreak locally when timestamps collide.

import Foundation
#if canImport(Combine)
import Combine
#endif
#if SWIFT_PACKAGE
import SmithersRuntime
#endif

// MARK: - Enriched row model

/// Source of a switcher row. Local rows come from the libsmithers SQLite
/// `recent_workspaces` table (macOS only today); Remote rows come from the
/// 0135 HTTP endpoint / 0116 shape.
public enum WorkspaceSource: String, Sendable, Codable, Equatable, Hashable {
    case local
    case remote
}

public struct SwitcherRepoRef: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public static func normalized(owner: String?, name: String?) -> SwitcherRepoRef? {
        guard
            let owner = owner?.switcherTrimmedNonEmpty,
            let name = name?.switcherTrimmedNonEmpty
        else { return nil }
        return SwitcherRepoRef(owner: owner, name: name)
    }

    public var id: String { "\(owner)/\(name)" }
    public var label: String { id }
    public var accessibilityKey: String { "\(owner)-\(name)" }
    public var actionRepoRef: ActionRepoRef { ActionRepoRef(owner: owner, name: name) }
}

/// The switcher's view-facing workspace row.
public struct SwitcherWorkspace: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: String
    public let repoOwner: String?
    public let repoName: String?
    public let title: String
    public let state: String
    public let lastAccessedAt: Date?
    public let lastActivityAt: Date?
    public let createdAt: Date?
    public let source: WorkspaceSource

    public init(
        id: String,
        repoOwner: String? = nil,
        repoName: String? = nil,
        title: String,
        state: String,
        lastAccessedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        createdAt: Date? = nil,
        source: WorkspaceSource = .remote
    ) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.title = title
        self.state = state
        self.lastAccessedAt = lastAccessedAt
        self.lastActivityAt = lastActivityAt
        self.createdAt = createdAt
        self.source = source
    }

    /// Renderable repo label: `owner/name`, falling back to one or the
    /// other if only one is present, or an empty string if neither is.
    public var repoLabel: String {
        switch (repoOwner, repoName) {
        case let (owner?, name?): return "\(owner)/\(name)"
        case (nil, let name?): return name
        case (let owner?, nil): return owner
        default: return ""
        }
    }

    public var repoRef: SwitcherRepoRef? {
        SwitcherRepoRef.normalized(owner: repoOwner, name: repoName)
    }

    public var actionRepoRef: ActionRepoRef? {
        repoRef?.actionRepoRef
    }

    /// The sortable recency key. Matches 0135's server expression:
    ///   COALESCE(last_accessed_at, last_activity_at, created_at)
    public var recencyKey: Date {
        lastAccessedAt ?? lastActivityAt ?? createdAt ?? .distantPast
    }
}

// MARK: - 0135 wire shape

/// JSON payload shape emitted by plue's `GET /api/user/workspaces?limit=100`.
/// Field names are the 0135 contract; decoder uses the same millisecond /
/// ISO-8601 strategy as `StoreDecoder`.
public struct UserWorkspaceDTO: Sendable, Codable, Equatable, Hashable {
    public let workspaceId: String
    public let repoOwner: String?
    public let repoName: String?
    public let title: String?
    public let name: String?
    public let state: String?
    public let status: String?
    public let lastAccessedAt: Date?
    public let lastActivityAt: Date?
    public let createdAt: Date?

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

    /// Project a wire DTO into a switcher row. `title` wins, falling back
    /// to `name` (the 0116 workspaces-shape column) then the bare id.
    public func asSwitcherWorkspace() -> SwitcherWorkspace {
        SwitcherWorkspace(
            id: workspaceId,
            repoOwner: repoOwner,
            repoName: repoName,
            title: title ?? name ?? workspaceId,
            state: state ?? status ?? "unknown",
            lastAccessedAt: lastAccessedAt,
            lastActivityAt: lastActivityAt,
            createdAt: createdAt,
            source: .remote
        )
    }
}

public struct UserWorkspacesListResponse: Sendable, Codable, Equatable {
    public let workspaces: [UserWorkspaceDTO]

    public init(workspaces: [UserWorkspaceDTO]) { self.workspaces = workspaces }
}

// MARK: - Fetcher abstraction

/// Thin abstraction over 0135's HTTP call so the view-model is testable
/// without URLSession. Production wires this to a closure that calls the
/// plue API with the current bearer token.
public protocol RemoteWorkspaceFetcher: Sendable {
    /// Fetch up to `limit` workspaces in server-recency order. Throws on
    /// network/HTTP failure; throws `.authExpired` on 401.
    func fetch(limit: Int) async throws -> [UserWorkspaceDTO]
}

public enum RemoteWorkspaceFetchError: Error, Equatable {
    case authExpired
    case backendUnavailable(String)
    case decode(String)
}

/// A concrete URLSession-backed fetcher. Callers provide a base URL and a
/// closure that returns a bearer token (or nil, which triggers authExpired).
public final class URLSessionRemoteWorkspaceFetcher: RemoteWorkspaceFetcher, @unchecked Sendable {
    public typealias BearerProvider = @Sendable () -> String?

    private let baseURL: URL
    private let bearer: BearerProvider
    private let session: URLSession

    public init(baseURL: URL, bearer: @escaping BearerProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.bearer = bearer
        self.session = session
    }

    public func fetch(limit: Int) async throws -> [UserWorkspaceDTO] {
        guard let token = bearer() else { throw RemoteWorkspaceFetchError.authExpired }
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/user/workspaces"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            switch http?.statusCode {
            case 200:
                if let list = try? StoreDecoder.shared.decode(UserWorkspacesListResponse.self, from: data) {
                    return list.workspaces
                }
                if let arr = try? StoreDecoder.shared.decode([UserWorkspaceDTO].self, from: data) {
                    return arr
                }
                throw RemoteWorkspaceFetchError.decode("unexpected payload shape")
            case 401, 403:
                throw RemoteWorkspaceFetchError.authExpired
            default:
                throw RemoteWorkspaceFetchError.backendUnavailable("HTTP \(http?.statusCode ?? -1)")
            }
        } catch let e as RemoteWorkspaceFetchError {
            throw e
        } catch {
            throw RemoteWorkspaceFetchError.backendUnavailable("\(error)")
        }
    }
}

// MARK: - Shape-live probe

/// Adapter so the view-model can ask the 0124 store "is the shape
/// actually pushing live deltas?" without a hard dependency on the
/// concrete `WorkspacesStore` type.
public protocol WorkspacesShapeLiveProbe: AnyObject {
    /// True if the 0116 workspaces shape is subscribed and has emitted
    /// at least one delta (or is otherwise known-live). False means the
    /// view-model falls back to explicit refresh.
    func isLive() -> Bool
}

extension WorkspacesStore: WorkspacesShapeLiveProbe {
    /// A non-zero subscription handle indicates the baseline subscribe
    /// succeeded; `lastRefreshedAt` proves the cache has been queried at
    /// least once. This is a pragmatic "live-ish" signal for 0138 until
    /// the runtime exposes a direct liveness probe.
    public func isLive() -> Bool {
        subscriptionHandle != 0 && lastRefreshedAt != nil
    }
}

// MARK: - Empty / error states

public enum WorkspaceSwitcherState: Equatable {
    case loading
    case loaded(items: [SwitcherWorkspace])
    case emptySignedIn
    case signedOut
    case backendUnavailable(message: String)
}

// MARK: - Delete action protocol

/// The actual delete dispatch. In production this is a thin wrapper over
/// `SmithersStore.dispatch(ActionRequestFactory.workspaceDelete(...))` —
/// which routes to 0105's soft-delete surface. In tests it's a recorder.
public protocol WorkspaceDeleter: AnyObject {
    func deleteWorkspace(_ workspace: SwitcherWorkspace) async throws
}

// MARK: - View-model

/// Drives the iOS + macOS switcher. `@MainActor` so callers can bind
/// `state` directly from SwiftUI without dispatching.
@MainActor
public final class WorkspaceSwitcherViewModel: ObservableObject {
    @Published public private(set) var state: WorkspaceSwitcherState = .loading
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var selectedRepoFilter: SwitcherRepoRef?
    /// Row currently awaiting delete-confirmation. The UI MUST present an
    /// explicit confirm step — setting `pendingDeleteID` is NOT the same
    /// as actually deleting.
    @Published public var pendingDeleteID: String? = nil

    private let fetcher: RemoteWorkspaceFetcher
    private let deleter: WorkspaceDeleter?
    private let liveProbe: WorkspacesShapeLiveProbe?
    private let limit: Int
    // When a live shape is available we mirror its rows into the state.
    // This closure reads the current shape snapshot lazily so the view-
    // model doesn't keep a strong Combine dependency just for that.
    private let shapeSnapshot: (() -> [WorkspaceRow])?
    private var unfilteredItems: [SwitcherWorkspace] = []

    public init(
        fetcher: RemoteWorkspaceFetcher,
        deleter: WorkspaceDeleter? = nil,
        liveProbe: WorkspacesShapeLiveProbe? = nil,
        shapeSnapshot: (() -> [WorkspaceRow])? = nil,
        limit: Int = 100
    ) {
        self.fetcher = fetcher
        self.deleter = deleter
        self.liveProbe = liveProbe
        self.shapeSnapshot = shapeSnapshot
        self.limit = limit
    }

    /// Call on open / foreground. If the shape is live and already
    /// populated, we use it directly. Otherwise we fetch from 0135.
    public func refresh() async {
        let previousState = state
        let shouldPreserveVisibleState = previousState.supportsInlineErrorRecovery
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        if let probe = liveProbe, probe.isLive(), let snapshot = shapeSnapshot?() {
            applyShape(snapshot)
            return
        }
        if !shouldPreserveVisibleState {
            state = .loading
        }
        do {
            let remote = try await fetcher.fetch(limit: limit)
            errorMessage = nil
            if remote.isEmpty {
                unfilteredItems = []
                state = .emptySignedIn
                return
            }
            let rows = remote.map { $0.asSwitcherWorkspace() }
            applyLoadedItems(rows)
        } catch RemoteWorkspaceFetchError.authExpired {
            errorMessage = nil
            unfilteredItems = []
            state = .signedOut
        } catch let RemoteWorkspaceFetchError.backendUnavailable(msg) {
            applyRefreshFailure(message: msg, previousState: previousState)
        } catch let RemoteWorkspaceFetchError.decode(msg) {
            applyRefreshFailure(message: "decode: \(msg)", previousState: previousState)
        } catch {
            applyRefreshFailure(message: "\(error)", previousState: previousState)
        }
    }

    /// Called when the 0116 shape emits new rows (via the parent
    /// subscribing to `WorkspacesStore.$workspaces` and forwarding).
    public func applyShape(_ rows: [WorkspaceRow]) {
        errorMessage = nil
        if rows.isEmpty {
            unfilteredItems = []
            state = .emptySignedIn
            return
        }
        let existingByID: [String: SwitcherWorkspace]
        if case .loaded(let items) = state {
            existingByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        } else {
            existingByID = [:]
        }
        let mapped: [SwitcherWorkspace] = rows.map {
            let existing = existingByID[$0.workspaceId]
            return SwitcherWorkspace(
                id: $0.workspaceId,
                repoOwner: $0.repoOwner ?? existing?.repoOwner,
                repoName: $0.repoName ?? existing?.repoName,
                title: $0.name,
                state: $0.status,
                lastAccessedAt: $0.updatedAt,
                lastActivityAt: $0.updatedAt,
                createdAt: $0.createdAt,
                source: .remote
            )
        }
        applyLoadedItems(mapped)
    }

    public var repoFilterLabel: String {
        selectedRepoFilter?.label ?? "All repos"
    }

    public func setRepoFilter(_ repo: SwitcherRepoRef?) {
        selectedRepoFilter = repo
        switch state {
        case .loaded, .emptySignedIn:
            applyCurrentFilterToState()
        case .loading, .signedOut, .backendUnavailable:
            break
        }
    }

    public func clearRepoFilter() {
        setRepoFilter(nil)
    }

    /// Ask for confirmation. This does NOT delete — the caller must
    /// present a confirm UI and then call `confirmDelete`.
    public func requestDelete(id: String) {
        pendingDeleteID = id
    }

    public func cancelDelete() {
        pendingDeleteID = nil
    }

    /// Confirmed delete. Dispatches through 0105's action surface. If the
    /// shape is live the row disappears via `applyShape` on the next
    /// delta; otherwise we fire another refresh.
    public func confirmDelete(id: String) async {
        guard pendingDeleteID == id else { return }
        pendingDeleteID = nil
        guard let deleter else { return }
        guard case .loaded(let items) = state, let workspace = items.first(where: { $0.id == id }) else {
            errorMessage = "Delete failed: missing workspace context."
            return
        }
        do {
            try await deleter.deleteWorkspace(workspace)
            if liveProbe?.isLive() != true {
                await refresh()
            }
        } catch RemoteWorkspaceFetchError.authExpired {
            errorMessage = nil
            state = .signedOut
        } catch {
            errorMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func applyRefreshFailure(message: String, previousState: WorkspaceSwitcherState) {
        if previousState.supportsInlineErrorRecovery {
            errorMessage = message
            state = previousState
        } else {
            unfilteredItems = []
            errorMessage = nil
            state = .backendUnavailable(message: message)
        }
    }

    private func applyLoadedItems(_ items: [SwitcherWorkspace]) {
        unfilteredItems = Self.orderedWithTiebreak(items)
        applyCurrentFilterToState()
    }

    private func applyCurrentFilterToState() {
        guard !unfilteredItems.isEmpty else {
            state = .emptySignedIn
            return
        }

        state = .loaded(items: Self.filteredItems(unfilteredItems, by: selectedRepoFilter))
    }

    public nonisolated static func filteredItems(
        _ items: [SwitcherWorkspace],
        by repo: SwitcherRepoRef?
    ) -> [SwitcherWorkspace] {
        guard let repo else { return items }
        return items.filter { $0.repoRef == repo }
    }

    public nonisolated static func uniqueRepos(from items: [SwitcherWorkspace]) -> [SwitcherRepoRef] {
        var seen = Set<SwitcherRepoRef>()
        var repos: [SwitcherRepoRef] = []

        for item in items {
            guard let repo = item.repoRef, seen.insert(repo).inserted else {
                continue
            }
            repos.append(repo)
        }

        return repos.sorted {
            if $0.owner == $1.owner {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.owner.localizedCaseInsensitiveCompare($1.owner) == .orderedAscending
        }
    }

    /// Tiebreak by id DESC, matching the 0135 server-side ordering. We
    /// do NOT re-sort by client-side fields beyond this — the server
    /// owns recency.
    nonisolated static func orderedWithTiebreak(_ items: [SwitcherWorkspace]) -> [SwitcherWorkspace] {
        items.sorted { lhs, rhs in
            if lhs.recencyKey != rhs.recencyKey {
                return lhs.recencyKey > rhs.recencyKey
            }
            return lhs.id > rhs.id
        }
    }
}

private extension WorkspaceSwitcherState {
    var supportsInlineErrorRecovery: Bool {
        switch self {
        case .loaded, .emptySignedIn:
            return true
        case .loading, .signedOut, .backendUnavailable:
            return false
        }
    }
}

private extension String {
    var switcherTrimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - SmithersStore adapter

/// Thin adapter: wires `SmithersStore.dispatch` to the `WorkspaceDeleter`
/// protocol the view-model consumes. Keeps the view-model dep graph
/// free of the full store type.
public final class StoreWorkspaceDeleter: WorkspaceDeleter, @unchecked Sendable {
    private let store: SmithersStoreProtocol

    public init(store: SmithersStoreProtocol) { self.store = store }

    public func deleteWorkspace(_ workspace: SwitcherWorkspace) async throws {
        // 0105 owns this surface: `workspaces.delete` is the canonical
        // soft-delete dispatch. We wait for the shape echo so the row
        // actually disappears before we return.
        guard let repo = workspace.actionRepoRef else {
            throw ActionContractError.missingRepoContext
        }
        _ = try await store.dispatch(
            ActionRequestFactory.workspaceDelete(repo: repo, workspaceID: workspace.id),
            echoTable: StoreTable.workspaces
        )
    }
}
