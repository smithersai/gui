import XCTest
@testable import SmithersGUI

/// Comprehensive tests for `SurfaceNotificationStore`.
///
/// Note: `SurfaceNotificationStore` exposes only a `.shared` singleton with a
/// `private init()`. Every test must defensively reset state for the surfaces
/// it touches (via `unregister`) rather than spinning up a fresh instance.
/// Side-effects on `AppNotifications.shared` are tolerated; we don't assert on
/// them here.
///
/// (Class is named `…CoverageTests` to avoid colliding with the small
/// pre-existing `SurfaceNotificationStoreTests` class in
/// `WorkspaceSurfaceModelsTests.swift`.)
@MainActor
final class SurfaceNotificationStoreCoverageTests: XCTestCase {
    private var store: SurfaceNotificationStore { SurfaceNotificationStore.shared }

    /// Surfaces touched in a given test, cleaned up in tearDown.
    private var touchedSurfaces: Set<String> = []

    private func makeSurfaceId(_ tag: String = "") -> String {
        let id = "test-\(tag)-\(UUID().uuidString)"
        touchedSurfaces.insert(id)
        return id
    }

    override func tearDown() async throws {
        await MainActor.run {
            for sid in touchedSurfaces {
                store.unregister(surfaceId: sid)
            }
            store.setFocusedSurface(nil, workspaceId: nil)
            touchedSurfaces.removeAll()
        }
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testRegisterAddsSurfaceWorkspaceMapping() {
        let sid = makeSurfaceId("init")
        store.register(surfaceId: sid, workspaceId: "ws-1")
        XCTAssertEqual(store.surfaceWorkspaceIds[sid], "ws-1")
        XCTAssertNil(store.notificationsBySurfaceId[sid])
        XCTAssertNil(store.notificationCountBySurfaceId[sid])
        XCTAssertFalse(store.unreadSurfaceIds.contains(sid))
        XCTAssertFalse(store.focusedIndicatorSurfaceIds.contains(sid))
        XCTAssertFalse(store.erroredSurfaceIds.contains(sid))
        XCTAssertFalse(store.hasError(surfaceId: sid))
        XCTAssertFalse(store.hasVisibleIndicator(surfaceId: sid))
    }

    func testHasErrorReturnsFalseForUnknownSurface() {
        XCTAssertFalse(store.hasError(surfaceId: "never-registered-\(UUID().uuidString)"))
    }

    func testHasVisibleIndicatorReturnsFalseForUnknownSurface() {
        XCTAssertFalse(store.hasVisibleIndicator(surfaceId: "never-registered-\(UUID().uuidString)"))
    }

    // MARK: - Single dispatch

    func testAddNotificationStoresSingleEntryAndIncrementsCount() {
        let sid = makeSurfaceId("single")
        store.register(surfaceId: sid, workspaceId: "ws-A")

        store.addNotification(surfaceId: sid, title: "Hello", body: "World")

        let n = store.notificationsBySurfaceId[sid]
        XCTAssertNotNil(n)
        XCTAssertEqual(n?.title, "Hello")
        XCTAssertEqual(n?.body, "World")
        XCTAssertEqual(n?.surfaceId, sid)
        XCTAssertEqual(n?.workspaceId, "ws-A")
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 1)
        XCTAssertTrue(store.unreadSurfaceIds.contains(sid))
        XCTAssertTrue(store.hasVisibleIndicator(surfaceId: sid))
    }

    func testAddNotificationOnUnregisteredSurfaceLeavesWorkspaceNil() {
        let sid = makeSurfaceId("no-ws")
        // Intentionally not registered.
        store.addNotification(surfaceId: sid, title: "T", body: "B")

        let n = store.notificationsBySurfaceId[sid]
        XCTAssertNotNil(n)
        XCTAssertNil(n?.workspaceId)
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 1)
    }

    // MARK: - "Dedup" / replacement semantics

    func testRepeatedNotificationsReplaceLatestAndIncrementCount() {
        let sid = makeSurfaceId("replace")
        store.register(surfaceId: sid, workspaceId: "ws")

        store.addNotification(surfaceId: sid, title: "First", body: "1")
        let first = store.notificationsBySurfaceId[sid]
        store.addNotification(surfaceId: sid, title: "Second", body: "2")
        let second = store.notificationsBySurfaceId[sid]

        // Only the latest survives in the slot; new UUID each time.
        XCTAssertEqual(second?.title, "Second")
        XCTAssertEqual(second?.body, "2")
        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 2)
    }

    func testIdenticalNotificationsStillIncrementCount() {
        let sid = makeSurfaceId("identical")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "X", body: "Y")
        store.addNotification(surfaceId: sid, title: "X", body: "Y")
        store.addNotification(surfaceId: sid, title: "X", body: "Y")
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 3)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, "X")
    }

    func testNearIdenticalNotificationsAreNotMerged() {
        let sid = makeSurfaceId("near")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "Hello", body: "World")
        store.addNotification(surfaceId: sid, title: "Hello!", body: "World")
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 2)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, "Hello!")
    }

    func testTimestampsAdvanceAcrossDispatches() async {
        let sid = makeSurfaceId("ts")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "A", body: "1")
        let t1 = store.notificationsBySurfaceId[sid]?.timestamp
        try? await Task.sleep(nanoseconds: 5_000_000)
        store.addNotification(surfaceId: sid, title: "B", body: "2")
        let t2 = store.notificationsBySurfaceId[sid]?.timestamp
        XCTAssertNotNil(t1)
        XCTAssertNotNil(t2)
        if let t1, let t2 {
            XCTAssertGreaterThanOrEqual(t2, t1)
        }
    }

    // MARK: - Surface registration / lifecycle

    func testUnregisterClearsAllPerSurfaceState() {
        let sid = makeSurfaceId("lifecycle")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "T", body: "B")
        XCTAssertNotNil(store.notificationsBySurfaceId[sid])

        store.unregister(surfaceId: sid)

        XCTAssertNil(store.surfaceWorkspaceIds[sid])
        XCTAssertNil(store.notificationsBySurfaceId[sid])
        XCTAssertNil(store.notificationCountBySurfaceId[sid])
        XCTAssertFalse(store.unreadSurfaceIds.contains(sid))
        XCTAssertFalse(store.focusedIndicatorSurfaceIds.contains(sid))
        XCTAssertFalse(store.erroredSurfaceIds.contains(sid))
    }

    func testUnregisterClearsFocusedSurfaceWhenItMatches() {
        let sid = makeSurfaceId("focus-clear")
        store.register(surfaceId: sid, workspaceId: "ws-fc")
        store.setFocusedSurface(sid, workspaceId: "ws-fc")
        XCTAssertEqual(store.focusedSurfaceId, sid)

        store.unregister(surfaceId: sid)
        XCTAssertNil(store.focusedSurfaceId)
        // focusedWorkspaceId is intentionally NOT cleared by unregister.
        XCTAssertEqual(store.focusedWorkspaceId, "ws-fc")
    }

    func testUnregisterDoesNotClearFocusedSurfaceWhenDifferent() {
        let kept = makeSurfaceId("kept")
        let removed = makeSurfaceId("removed")
        store.register(surfaceId: kept, workspaceId: "ws")
        store.register(surfaceId: removed, workspaceId: "ws")
        store.setFocusedSurface(kept, workspaceId: "ws")
        store.unregister(surfaceId: removed)
        XCTAssertEqual(store.focusedSurfaceId, kept)
    }

    func testReregisterAfterUnregisterStartsClean() {
        let sid = makeSurfaceId("re-reg")
        store.register(surfaceId: sid, workspaceId: "ws-1")
        store.addNotification(surfaceId: sid, title: "T", body: "B")
        store.unregister(surfaceId: sid)

        store.register(surfaceId: sid, workspaceId: "ws-2")
        XCTAssertEqual(store.surfaceWorkspaceIds[sid], "ws-2")
        XCTAssertNil(store.notificationsBySurfaceId[sid])
        XCTAssertNil(store.notificationCountBySurfaceId[sid])
    }

    // MARK: - Multiple surfaces / isolation

    func testMultipleSurfacesAreIsolated() {
        let a = makeSurfaceId("iso-a")
        let b = makeSurfaceId("iso-b")
        store.register(surfaceId: a, workspaceId: "ws-1")
        store.register(surfaceId: b, workspaceId: "ws-2")

        store.addNotification(surfaceId: a, title: "A", body: "")
        store.addNotification(surfaceId: a, title: "A2", body: "")
        store.addNotification(surfaceId: b, title: "B", body: "")

        XCTAssertEqual(store.notificationCountBySurfaceId[a], 2)
        XCTAssertEqual(store.notificationCountBySurfaceId[b], 1)
        XCTAssertEqual(store.notificationsBySurfaceId[a]?.title, "A2")
        XCTAssertEqual(store.notificationsBySurfaceId[b]?.title, "B")
        XCTAssertEqual(store.notificationsBySurfaceId[a]?.workspaceId, "ws-1")
        XCTAssertEqual(store.notificationsBySurfaceId[b]?.workspaceId, "ws-2")

        store.markRead(surfaceId: a)
        XCTAssertFalse(store.unreadSurfaceIds.contains(a))
        XCTAssertTrue(store.unreadSurfaceIds.contains(b))
    }

    func testWorkspaceHasIndicatorOnlyForMatchingWorkspace() {
        let a = makeSurfaceId("ws-a")
        let b = makeSurfaceId("ws-b")
        let workspaceA = "ws-cov-1-\(UUID().uuidString)"
        let workspaceB = "ws-cov-2-\(UUID().uuidString)"
        store.register(surfaceId: a, workspaceId: workspaceA)
        store.register(surfaceId: b, workspaceId: workspaceB)

        store.addNotification(surfaceId: a, title: "x", body: "")

        XCTAssertTrue(store.workspaceHasIndicator(workspaceA))
        XCTAssertFalse(store.workspaceHasIndicator(workspaceB))
        XCTAssertFalse(store.workspaceHasIndicator("ws-other-\(UUID().uuidString)"))
    }

    // MARK: - Ordering / latestUnread

    func testLatestUnreadSurfaceReturnsMostRecent() async {
        let a = makeSurfaceId("ord-a")
        let b = makeSurfaceId("ord-b")
        let c = makeSurfaceId("ord-c")
        let workspace = "ws-ord-\(UUID().uuidString)"
        for sid in [a, b, c] {
            store.register(surfaceId: sid, workspaceId: workspace)
        }

        store.addNotification(surfaceId: a, title: "a", body: "")
        try? await Task.sleep(nanoseconds: 5_000_000)
        store.addNotification(surfaceId: b, title: "b", body: "")
        try? await Task.sleep(nanoseconds: 5_000_000)
        store.addNotification(surfaceId: c, title: "c", body: "")

        XCTAssertEqual(store.latestUnreadSurface(in: workspace), c)

        store.markRead(surfaceId: c)
        XCTAssertEqual(store.latestUnreadSurface(in: workspace), b)
    }

    func testLatestUnreadSurfaceFiltersByWorkspace() {
        let a = makeSurfaceId("wsf-a")
        let b = makeSurfaceId("wsf-b")
        let workspaceA = "ws-cov-A-\(UUID().uuidString)"
        let workspaceB = "ws-cov-B-\(UUID().uuidString)"
        store.register(surfaceId: a, workspaceId: workspaceA)
        store.register(surfaceId: b, workspaceId: workspaceB)
        store.addNotification(surfaceId: a, title: "a", body: "")
        store.addNotification(surfaceId: b, title: "b", body: "")

        XCTAssertEqual(store.latestUnreadSurface(in: workspaceA), a)
        XCTAssertEqual(store.latestUnreadSurface(in: workspaceB), b)
        XCTAssertNil(store.latestUnreadSurface(in: "ws-missing-\(UUID().uuidString)"))
    }

    func testLatestUnreadSurfaceNilWhenNoneUnread() {
        let a = makeSurfaceId("no-unread")
        let workspace = "ws-nu-\(UUID().uuidString)"
        store.register(surfaceId: a, workspaceId: workspace)
        store.addNotification(surfaceId: a, title: "a", body: "")
        store.markRead(surfaceId: a)
        XCTAssertNil(store.latestUnreadSurface(in: workspace))
    }

    // MARK: - Focus behaviour (focused vs unread routing)

    func testNotificationOnFocusedSurfaceGoesToFocusedIndicator() {
        let sid = makeSurfaceId("focused-add")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.setFocusedSurface(sid, workspaceId: "ws")

        store.addNotification(surfaceId: sid, title: "Heads up", body: "")

        XCTAssertTrue(store.focusedIndicatorSurfaceIds.contains(sid))
        XCTAssertFalse(store.unreadSurfaceIds.contains(sid))
        XCTAssertTrue(store.hasVisibleIndicator(surfaceId: sid))
    }

    func testNotificationOnUnfocusedSurfaceGoesToUnread() {
        let focused = makeSurfaceId("f")
        let other = makeSurfaceId("o")
        store.register(surfaceId: focused, workspaceId: "ws")
        store.register(surfaceId: other, workspaceId: "ws")
        store.setFocusedSurface(focused, workspaceId: "ws")

        store.addNotification(surfaceId: other, title: "Hi", body: "")

        XCTAssertTrue(store.unreadSurfaceIds.contains(other))
        XCTAssertFalse(store.focusedIndicatorSurfaceIds.contains(other))
    }

    func testMarkReadClearsAllIndicatorsAndZeroesCount() {
        let sid = makeSurfaceId("mark-read")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "x", body: "")
        store.addNotification(surfaceId: sid, title: "y", body: "")
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 2)

        store.markRead(surfaceId: sid)
        XCTAssertEqual(store.notificationCountBySurfaceId[sid], 0)
        XCTAssertFalse(store.unreadSurfaceIds.contains(sid))
        XCTAssertFalse(store.focusedIndicatorSurfaceIds.contains(sid))
        XCTAssertFalse(store.hasVisibleIndicator(surfaceId: sid))
    }

    func testFlashFocusedSurfaceWithNoFocusIsNoOp() {
        store.setFocusedSurface(nil, workspaceId: nil)
        // Just verifies it does not crash and does not insert anything.
        store.flashFocusedSurface(duration: 0.01)
        XCTAssertNil(store.focusedSurfaceId)
    }

    func testFlashFocusedSurfaceInsertsThenClearsIndicator() async {
        let sid = makeSurfaceId("flash")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.setFocusedSurface(sid, workspaceId: "ws")

        store.flashFocusedSurface(duration: 0.05)
        XCTAssertTrue(store.focusedIndicatorSurfaceIds.contains(sid))

        try? await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(store.focusedIndicatorSurfaceIds.contains(sid))
    }

    func testSetFocusedSurfaceUpdatesBothIds() {
        store.setFocusedSurface("s-1", workspaceId: "w-1")
        XCTAssertEqual(store.focusedSurfaceId, "s-1")
        XCTAssertEqual(store.focusedWorkspaceId, "w-1")
        store.setFocusedSurface(nil, workspaceId: nil)
        XCTAssertNil(store.focusedSurfaceId)
        XCTAssertNil(store.focusedWorkspaceId)
    }

    // MARK: - Edge fields

    func testEmptyTitleFallsBackToTerminal() {
        let sid = makeSurfaceId("empty-title")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "", body: "Body")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, "Terminal")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body, "Body")
    }

    func testWhitespaceOnlyTitleAndBodyAreTrimmedThenTitleFallsBack() {
        let sid = makeSurfaceId("ws-only")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "   \n\t  ", body: "  \n  ")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, "Terminal")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body, "")
    }

    func testTitleAndBodyAreTrimmed() {
        let sid = makeSurfaceId("trim")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "  Title  ", body: "\n Body \t")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, "Title")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body, "Body")
    }

    func testEmptyBodyAllowed() {
        let sid = makeSurfaceId("empty-body")
        store.register(surfaceId: sid, workspaceId: "ws")
        store.addNotification(surfaceId: sid, title: "Hi", body: "")
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body, "")
    }

    func testUnicodePayload() {
        let sid = makeSurfaceId("unicode")
        store.register(surfaceId: sid, workspaceId: "ws")
        let title = "Hello world Test"
        let body = "Multi-line\nBody with quotes \"\""
        store.addNotification(surfaceId: sid, title: title, body: body)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title, title)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body, body)
    }

    func testVeryLargePayloadStoredVerbatim() {
        let sid = makeSurfaceId("large")
        store.register(surfaceId: sid, workspaceId: "ws")
        let bigTitle = String(repeating: "T", count: 10_000)
        let bigBody = String(repeating: "B", count: 100_000)
        store.addNotification(surfaceId: sid, title: bigTitle, body: bigBody)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.title.count, 10_000)
        XCTAssertEqual(store.notificationsBySurfaceId[sid]?.body.count, 100_000)
    }

    // MARK: - Concurrency

    func testConcurrentDispatchesAccumulateCountCorrectly() async {
        let sid = makeSurfaceId("concurrent")
        store.register(surfaceId: sid, workspaceId: "ws")

        let total = 50
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask { @MainActor in
                    self.store.addNotification(surfaceId: sid, title: "n-\(i)", body: "")
                }
            }
        }

        XCTAssertEqual(store.notificationCountBySurfaceId[sid], total)
        XCTAssertNotNil(store.notificationsBySurfaceId[sid])
        XCTAssertTrue(store.unreadSurfaceIds.contains(sid))
    }

    func testConcurrentDispatchesAcrossManySurfaces() async {
        let surfaces = (0..<10).map { i in makeSurfaceId("many-\(i)") }
        for sid in surfaces {
            store.register(surfaceId: sid, workspaceId: "ws-many")
        }

        await withTaskGroup(of: Void.self) { group in
            for sid in surfaces {
                for _ in 0..<5 {
                    let captured = sid
                    group.addTask { @MainActor in
                        self.store.addNotification(surfaceId: captured, title: "x", body: "y")
                    }
                }
            }
        }

        for sid in surfaces {
            XCTAssertEqual(store.notificationCountBySurfaceId[sid], 5, "surface \(sid) count")
            XCTAssertTrue(store.unreadSurfaceIds.contains(sid))
        }
    }

    // MARK: - Identifiable / Hashable contract

    func testSurfaceNotificationEqualityByAllFields() {
        let now = Date()
        let n1 = SurfaceNotification(id: "id", workspaceId: "w", surfaceId: "s", title: "t", body: "b", timestamp: now)
        let n2 = SurfaceNotification(id: "id", workspaceId: "w", surfaceId: "s", title: "t", body: "b", timestamp: now)
        let n3 = SurfaceNotification(id: "other", workspaceId: "w", surfaceId: "s", title: "t", body: "b", timestamp: now)
        XCTAssertEqual(n1, n2)
        XCTAssertEqual(n1.hashValue, n2.hashValue)
        XCTAssertNotEqual(n1, n3)
    }
}
