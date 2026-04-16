import XCTest
@testable import SmithersGUI

final class WorkspaceLayoutNodeTests: XCTestCase {
    func testRemovingLeafKeepsSplitIDWhenBranchStillHasTwoChildren() {
        let tree: WorkspaceLayoutNode = .split(
            id: "root",
            axis: .vertical,
            first: .split(
                id: "left",
                axis: .horizontal,
                first: .leaf("a"),
                second: .leaf("b")
            ),
            second: .leaf("c")
        )

        guard let result = tree.removingLeaf("a") else {
            XCTFail("Expected layout result")
            return
        }

        guard case .split(let id, let axis, let first, let second) = result else {
            XCTFail("Expected root to remain a split")
            return
        }
        XCTAssertEqual(id, "root")
        XCTAssertEqual(axis, .vertical)

        guard case .leaf(let remainingLeft) = first else {
            XCTFail("Expected left branch to collapse into a leaf")
            return
        }
        XCTAssertEqual(remainingLeft, "b")

        guard case .leaf(let remainingRight) = second else {
            XCTFail("Expected right branch to remain a leaf")
            return
        }
        XCTAssertEqual(remainingRight, "c")
    }

    func testRemovingMissingLeafPreservesExistingIDs() {
        let tree: WorkspaceLayoutNode = .split(
            id: "root",
            axis: .vertical,
            first: .leaf("a"),
            second: .leaf("b")
        )

        let result = tree.removingLeaf("missing")
        XCTAssertEqual(result, tree)
    }
}

final class BrowserURLResolverTests: XCTestCase {
    func testSearchFallbackUsesConfiguredEngine() {
        let suite = "BrowserURLResolverTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Expected isolated user defaults")
            return
        }
        defaults.set(BrowserSearchEngine.google.rawValue, forKey: AppPreferenceKeys.browserSearchEngine)
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let resolved = BrowserURLResolver.url(from: "swift ui", userDefaults: defaults)
        XCTAssertEqual(resolved?.host, "www.google.com")
        XCTAssertEqual(resolved?.path, "/search")
    }

    func testSearchFallbackDefaultsToDuckDuckGo() {
        let suite = "BrowserURLResolverTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Expected isolated user defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let resolved = BrowserURLResolver.url(from: "smithers workflow", userDefaults: defaults)
        XCTAssertEqual(resolved?.host, "duckduckgo.com")
    }
}

@MainActor
final class SurfaceNotificationStoreTests: XCTestCase {
    func testAddNotificationTracksCountAndLatestMessage() {
        let store = SurfaceNotificationStore.shared
        let workspaceId = "workspace-\(UUID().uuidString)"
        let surfaceId = "surface-\(UUID().uuidString)"

        store.register(surfaceId: surfaceId, workspaceId: workspaceId)
        store.setFocusedSurface(surfaceId, workspaceId: workspaceId)
        defer {
            store.unregister(surfaceId: surfaceId)
        }

        store.addNotification(surfaceId: surfaceId, title: "Build", body: "first")
        store.addNotification(surfaceId: surfaceId, title: "Build", body: "second")

        XCTAssertEqual(store.notificationCountBySurfaceId[surfaceId], 2)
        XCTAssertEqual(store.notificationsBySurfaceId[surfaceId]?.body, "second")

        store.markRead(surfaceId: surfaceId)
        XCTAssertEqual(store.notificationCountBySurfaceId[surfaceId], 0)
    }
}
