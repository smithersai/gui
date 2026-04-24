// WorkspaceSwitcherModelTests.swift — ticket 0138.
//
// Covers the invariants called out in the acceptance criteria:
//   - Ordering: COALESCE(last_accessed, last_activity, created) DESC,
//     with id DESC as the deterministic tiebreak.
//   - Row rendering: repo label composition, recency key fallback.
//   - Empty states: signed-in-no-rows, signed-out (401), backend-unavailable.
//   - Delete is explicit + confirmed (not implicit).
//   - Auth-expired flips the state machine to `.signedOut` rather than
//     keeping the stale rows on screen.
//
// The live-stack round-trip is deferred (POC_ELECTRIC_STACK) in
// SmithersStoreTests.swift; this file is deterministic and synchronous.

import XCTest
@testable import SmithersStore

// MARK: - Test doubles

private final class FakeFetcher: RemoteWorkspaceFetcher, @unchecked Sendable {
    enum Outcome {
        case rows([UserWorkspaceDTO])
        case authExpired
        case backendUnavailable
    }
    private let lock = NSLock()
    private var _outcome: Outcome
    private var _calls: Int = 0

    init(outcome: Outcome) { self._outcome = outcome }

    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func set(_ o: Outcome) { lock.lock(); _outcome = o; lock.unlock() }

    func fetch(limit: Int) async throws -> [UserWorkspaceDTO] {
        let outcome: Outcome = {
            lock.lock(); defer { lock.unlock() }
            _calls += 1
            return _outcome
        }()
        switch outcome {
        case .rows(let r): return r
        case .authExpired: throw RemoteWorkspaceFetchError.authExpired
        case .backendUnavailable: throw RemoteWorkspaceFetchError.backendUnavailable("boom")
        }
    }
}

private final class FakeDeleter: WorkspaceDeleter, @unchecked Sendable {
    var deleted: [String] = []
    var shouldThrow: Error? = nil
    func deleteWorkspace(_ workspace: SwitcherWorkspace) async throws {
        if let e = shouldThrow { throw e }
        deleted.append(workspace.id)
    }
}

private final class FakeLiveProbe: WorkspacesShapeLiveProbe {
    var live: Bool = false
    func isLive() -> Bool { live }
}

private func ms(_ t: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(t) / 1000.0) }

private func dto(
    id: String,
    owner: String? = "acme",
    name: String? = "repo",
    title: String? = nil,
    state: String? = "active",
    last: Int64? = nil,
    activity: Int64? = nil,
    created: Int64? = nil
) -> UserWorkspaceDTO {
    UserWorkspaceDTO(
        workspaceId: id,
        repoOwner: owner,
        repoName: name,
        title: title ?? "ws-\(id)",
        name: "ws-\(id)",
        state: state,
        status: nil,
        lastAccessedAt: last.map(ms),
        lastActivityAt: activity.map(ms),
        createdAt: created.map(ms)
    )
}

// MARK: - Ordering

final class WorkspaceSwitcherOrderingTests: XCTestCase {
    func testSortsByLastAccessedDescending() {
        let items: [SwitcherWorkspace] = [
            dto(id: "a", last: 1_000).asSwitcherWorkspace(),
            dto(id: "b", last: 3_000).asSwitcherWorkspace(),
            dto(id: "c", last: 2_000).asSwitcherWorkspace(),
        ]
        let sorted = WorkspaceSwitcherViewModel.orderedWithTiebreak(items)
        XCTAssertEqual(sorted.map(\.id), ["b", "c", "a"])
    }

    func testFallsBackToActivityThenCreated() {
        let items: [SwitcherWorkspace] = [
            dto(id: "a", last: nil, activity: 5_000, created: 100).asSwitcherWorkspace(),
            dto(id: "b", last: nil, activity: nil, created: 9_000).asSwitcherWorkspace(),
            dto(id: "c", last: 1_000, activity: 100, created: 100).asSwitcherWorkspace(),
        ]
        // c has last_accessed=1s; a has activity=5s; b has created=9s.
        // Recency key: a=5000, b=9000, c=1000 → order b, a, c.
        let sorted = WorkspaceSwitcherViewModel.orderedWithTiebreak(items)
        XCTAssertEqual(sorted.map(\.id), ["b", "a", "c"])
    }

    func testTiebreakByIdDescendingWhenRecencyCollides() {
        let items: [SwitcherWorkspace] = [
            dto(id: "aaa", last: 5_000).asSwitcherWorkspace(),
            dto(id: "ccc", last: 5_000).asSwitcherWorkspace(),
            dto(id: "bbb", last: 5_000).asSwitcherWorkspace(),
        ]
        let sorted = WorkspaceSwitcherViewModel.orderedWithTiebreak(items)
        XCTAssertEqual(sorted.map(\.id), ["ccc", "bbb", "aaa"])
    }

    func testMissingTimestampsGoToTheBottom() {
        let items: [SwitcherWorkspace] = [
            dto(id: "a", last: nil, activity: nil, created: nil).asSwitcherWorkspace(),
            dto(id: "b", last: 1_000).asSwitcherWorkspace(),
        ]
        let sorted = WorkspaceSwitcherViewModel.orderedWithTiebreak(items)
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
    }
}

// MARK: - Row rendering

final class WorkspaceSwitcherRowModelTests: XCTestCase {
    func testRepoLabelComposesOwnerAndName() {
        let ws = dto(id: "1", owner: "acme", name: "repo").asSwitcherWorkspace()
        XCTAssertEqual(ws.repoLabel, "acme/repo")
    }

    func testRepoLabelFallsBackWhenOnePartMissing() {
        XCTAssertEqual(dto(id: "1", owner: nil, name: "repo").asSwitcherWorkspace().repoLabel, "repo")
        XCTAssertEqual(dto(id: "1", owner: "acme", name: nil).asSwitcherWorkspace().repoLabel, "acme")
        XCTAssertEqual(dto(id: "1", owner: nil, name: nil).asSwitcherWorkspace().repoLabel, "")
    }

    func testTitleFallsBackToNameThenId() {
        let titled = UserWorkspaceDTO(
            workspaceId: "x", repoOwner: nil, repoName: nil,
            title: "My WS", name: nil, state: "a", status: nil,
            lastAccessedAt: nil, lastActivityAt: nil, createdAt: nil
        ).asSwitcherWorkspace()
        let named = UserWorkspaceDTO(
            workspaceId: "x", repoOwner: nil, repoName: nil,
            title: nil, name: "named", state: "a", status: nil,
            lastAccessedAt: nil, lastActivityAt: nil, createdAt: nil
        ).asSwitcherWorkspace()
        let bare = UserWorkspaceDTO(
            workspaceId: "x", repoOwner: nil, repoName: nil,
            title: nil, name: nil, state: "a", status: nil,
            lastAccessedAt: nil, lastActivityAt: nil, createdAt: nil
        ).asSwitcherWorkspace()
        XCTAssertEqual(titled.title, "My WS")
        XCTAssertEqual(named.title, "named")
        XCTAssertEqual(bare.title, "x")
    }

    func testStateDefaultsToUnknown() {
        let ws = UserWorkspaceDTO(
            workspaceId: "x", repoOwner: nil, repoName: nil,
            title: "t", name: "n", state: nil, status: nil,
            lastAccessedAt: nil, lastActivityAt: nil, createdAt: nil
        ).asSwitcherWorkspace()
        XCTAssertEqual(ws.state, "unknown")
    }

    func testUniqueReposAreSortedAndDeduped() {
        let repos = WorkspaceSwitcherViewModel.uniqueRepos(from: [
            dto(id: "1", owner: "zed", name: "api").asSwitcherWorkspace(),
            dto(id: "2", owner: "acme", name: "widgets").asSwitcherWorkspace(),
            dto(id: "3", owner: "acme", name: "widgets").asSwitcherWorkspace(),
            dto(id: "4", owner: nil, name: "missing-owner").asSwitcherWorkspace(),
        ])

        XCTAssertEqual(repos.map(\.label), ["acme/widgets", "zed/api"])
    }
}

// MARK: - Empty / error states

@MainActor
final class WorkspaceSwitcherStateMachineTests: XCTestCase {
    func testLoadedWhenRowsReturned() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "a", last: 1)]))
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()
        guard case .loaded(let items) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "a")
    }

    func testEmptySignedInWhenZeroRows() async {
        let fetcher = FakeFetcher(outcome: .rows([]))
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()
        XCTAssertEqual(vm.state, .emptySignedIn)
    }

    func testSignedOutOn401() async {
        let fetcher = FakeFetcher(outcome: .authExpired)
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()
        XCTAssertEqual(vm.state, .signedOut)
    }

    func testBackendUnavailableOn5xx() async {
        let fetcher = FakeFetcher(outcome: .backendUnavailable)
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()
        if case .backendUnavailable = vm.state { /* ok */ } else {
            XCTFail("expected .backendUnavailable, got \(vm.state)")
        }
    }

    func testAuthExpiredDropsStaleRows() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "a", last: 1)]))
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()
        guard case .loaded = vm.state else { return XCTFail("precondition") }
        fetcher.set(.authExpired)
        await vm.refresh()
        XCTAssertEqual(vm.state, .signedOut, "stale rows must not remain visible after auth expiry")
    }

    func testRepoFilterRestrictsVisibleRowsAndCanClear() async {
        let fetcher = FakeFetcher(outcome: .rows([
            dto(id: "a", owner: "acme", name: "widgets", last: 3_000),
            dto(id: "b", owner: "zed", name: "api", last: 2_000),
            dto(id: "c", owner: "acme", name: "widgets", last: 1_000),
        ]))
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher)
        await vm.refresh()

        vm.setRepoFilter(SwitcherRepoRef(owner: "acme", name: "widgets"))
        guard case .loaded(let filtered) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(filtered.map(\.id), ["a", "c"])
        XCTAssertEqual(vm.repoFilterLabel, "acme/widgets")

        vm.clearRepoFilter()
        guard case .loaded(let all) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(all.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(vm.repoFilterLabel, "All repos")
    }
}

// MARK: - Delete

@MainActor
final class WorkspaceSwitcherDeleteTests: XCTestCase {
    func testDeleteRequiresExplicitConfirm() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "a", last: 1)]))
        let deleter = FakeDeleter()
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher, deleter: deleter)
        await vm.refresh()

        vm.requestDelete(id: "a")
        XCTAssertEqual(vm.pendingDeleteID, "a", "requestDelete must park the id for confirmation")
        XCTAssertTrue(deleter.deleted.isEmpty, "delete must not dispatch until confirmed")

        vm.cancelDelete()
        XCTAssertNil(vm.pendingDeleteID)
        XCTAssertTrue(deleter.deleted.isEmpty)
    }

    func testConfirmDeleteDispatches() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "a", last: 1)]))
        let deleter = FakeDeleter()
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher, deleter: deleter)
        await vm.refresh()
        vm.requestDelete(id: "a")
        await vm.confirmDelete(id: "a")
        XCTAssertEqual(deleter.deleted, ["a"])
        XCTAssertNil(vm.pendingDeleteID)
    }

    func testConfirmOnlyAppliesToPendingID() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "a"), dto(id: "b")]))
        let deleter = FakeDeleter()
        let vm = WorkspaceSwitcherViewModel(fetcher: fetcher, deleter: deleter)
        await vm.refresh()
        vm.requestDelete(id: "a")
        // Someone calls confirm with a DIFFERENT id → no-op.
        await vm.confirmDelete(id: "b")
        XCTAssertTrue(deleter.deleted.isEmpty)
        XCTAssertEqual(vm.pendingDeleteID, "a")
    }
}

// MARK: - Shape liveness fast-path

@MainActor
final class WorkspaceSwitcherShapeFastPathTests: XCTestCase {
    func testLiveShapeSkipsHTTPFetch() async {
        let fetcher = FakeFetcher(outcome: .rows([dto(id: "http", last: 9_999_999)]))
        let probe = FakeLiveProbe()
        probe.live = true
        let snapshot: [WorkspaceRow] = [
            WorkspaceRow(
                workspaceId: "shape",
                name: "live-ws",
                status: "active",
                engineId: nil,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 5),
                suspendedAt: nil
            )
        ]
        let vm = WorkspaceSwitcherViewModel(
            fetcher: fetcher,
            liveProbe: probe,
            shapeSnapshot: { snapshot }
        )
        await vm.refresh()
        guard case .loaded(let items) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(items.first?.id, "shape", "shape path must win when live")
        XCTAssertEqual(fetcher.calls, 0, "fetcher must not be called when shape is live")
    }

    func testApplyShapePreservesServerOrderWithTiebreak() {
        let vm = WorkspaceSwitcherViewModel(fetcher: FakeFetcher(outcome: .rows([])))
        let rows: [WorkspaceRow] = [
            WorkspaceRow(workspaceId: "aaa", name: "a", status: "s", engineId: nil, createdAt: nil, updatedAt: ms(5_000), suspendedAt: nil),
            WorkspaceRow(workspaceId: "ccc", name: "c", status: "s", engineId: nil, createdAt: nil, updatedAt: ms(5_000), suspendedAt: nil),
            WorkspaceRow(workspaceId: "bbb", name: "b", status: "s", engineId: nil, createdAt: nil, updatedAt: ms(9_000), suspendedAt: nil),
        ]
        vm.applyShape(rows)
        guard case .loaded(let items) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(items.map(\.id), ["bbb", "ccc", "aaa"])
    }

    func testApplyShapeEmptyMapsToEmptyState() {
        let vm = WorkspaceSwitcherViewModel(fetcher: FakeFetcher(outcome: .rows([])))
        vm.applyShape([])
        XCTAssertEqual(vm.state, .emptySignedIn)
    }
}
