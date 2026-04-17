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

final class HandleResolverTests: XCTestCase {
    func testShortRefsAreMonotonicAndStablePerResolver() {
        let resolver = HandleResolver()
        let windowID = WindowID()
        let workspaceID = WorkspaceID()
        let paneID = PaneID()
        let surfaceID = SurfaceID()

        XCTAssertEqual(resolver.ref(for: windowID).rawValue, "window:1")
        XCTAssertEqual(resolver.ref(for: workspaceID).rawValue, "workspace:2")
        XCTAssertEqual(resolver.ref(for: paneID).rawValue, "pane:3")
        XCTAssertEqual(resolver.ref(for: surfaceID).rawValue, "surface:4")

        XCTAssertEqual(resolver.ref(for: workspaceID).rawValue, "workspace:2")
        XCTAssertEqual(resolver.ref(for: SurfaceID()).rawValue, "surface:5")
    }

    func testResolverRoundTripsRefsToUUIDs() {
        let resolver = HandleResolver()
        let windowID = WindowID()
        let workspaceID = WorkspaceID()
        let paneID = PaneID()
        let surfaceID = SurfaceID()

        let windowRef = resolver.ref(for: windowID)
        let workspaceRef = resolver.ref(for: workspaceID)
        let paneRef = resolver.ref(for: paneID)
        let surfaceRef = resolver.ref(for: surfaceID)

        XCTAssertEqual(resolver.resolveWindow(windowRef), windowID)
        XCTAssertEqual(resolver.resolveWorkspace(workspaceRef.rawValue), workspaceID)
        XCTAssertEqual(resolver.resolvePane(paneRef), paneID)
        XCTAssertEqual(resolver.resolveSurface(surfaceRef.rawValue), surfaceID)
        XCTAssertNil(resolver.resolveSurface(windowRef))
    }
}

@MainActor
final class WorkspaceSurfaceIdentityTests: XCTestCase {
    func testMovingSurfaceAcrossWorkspaceAndWindowKeepsSurfaceID() throws {
        let store = SessionStore()
        let sourceWorkspaceId = store.addTerminalTab(title: "Source")
        let targetWorkspaceId = store.addTerminalTab(title: "Target")
        let source = store.ensureTerminalWorkspace(sourceWorkspaceId)
        let target = store.ensureTerminalWorkspace(targetWorkspaceId)
        let targetWindowID = WindowID()

        let movedSurfaceID = source.splitFocused(axis: .horizontal, kind: .browser)
        let targetPaneID = try XCTUnwrap(target.paneIDs.first)

        let workspaceMove = store.moveWorkspace(
            target.id,
            toWindow: targetWindowID,
            placement: .end
        )
        guard case .success(let workspaceResult) = workspaceMove else {
            XCTFail("Expected workspace move to succeed")
            return
        }
        XCTAssertEqual(workspaceResult.workspaceID, target.id)
        XCTAssertEqual(workspaceResult.windowID, targetWindowID)

        let surfaceMove = store.moveSurface(movedSurfaceID, toPane: targetPaneID, placement: .end)
        guard case .success(let surfaceResult) = surfaceMove else {
            XCTFail("Expected surface move to succeed")
            return
        }

        XCTAssertEqual(surfaceResult.surfaceID, movedSurfaceID)
        XCTAssertEqual(surfaceResult.workspaceID, target.id)
        XCTAssertEqual(surfaceResult.windowID, targetWindowID)
        XCTAssertEqual(surfaceResult.paneID, targetPaneID)
        XCTAssertNil(source.surfaces[movedSurfaceID])
        XCTAssertEqual(target.surfaces[movedSurfaceID]?.id, movedSurfaceID)
    }

    func testReorderingSurfacesKeepsAllSurfaceIDs() throws {
        let store = SessionStore()
        let workspaceId = store.addTerminalTab(title: "Reorder")
        let workspace = store.ensureTerminalWorkspace(workspaceId)
        let originalSurfaceID = try XCTUnwrap(workspace.orderedSurfaces.first?.id)
        let secondSurfaceID = workspace.splitFocused(axis: .horizontal, kind: .browser)
        let thirdSurfaceID = workspace.splitFocused(axis: .horizontal, kind: .terminal)
        let idsBefore = Set(workspace.orderedSurfaces.map(\.id))

        let result = workspace.reorderSurface(thirdSurfaceID, anchor: .beforeSurface(originalSurfaceID))
        guard case .success(let reorderResult) = result else {
            XCTFail("Expected surface reorder to succeed")
            return
        }

        XCTAssertEqual(reorderResult.surfaceID, thirdSurfaceID)
        XCTAssertEqual(reorderResult.paneID, try XCTUnwrap(workspace.paneID(containing: thirdSurfaceID)))
        XCTAssertEqual(Set(workspace.orderedSurfaces.map(\.id)), idsBefore)
        XCTAssertEqual(workspace.orderedSurfaces.map(\.id).first, thirdSurfaceID)
        XCTAssertTrue(workspace.orderedSurfaces.contains { $0.id == secondSurfaceID })
    }

    func testMovingWorkspaceAcrossWindowsKeepsWorkspaceID() {
        let store = SessionStore()
        let workspaceId = WorkspaceID(store.addTerminalTab(title: "Movable"))
        let targetWindowID = WindowID()

        let result = store.moveWorkspace(workspaceId, toWindow: targetWindowID, placement: .start)
        guard case .success(let moveResult) = result else {
            XCTFail("Expected workspace move to succeed")
            return
        }

        XCTAssertEqual(moveResult.workspaceID, workspaceId)
        XCTAssertEqual(moveResult.windowID, targetWindowID)
    }

    func testReorderingWorkspacesKeepsWorkspaceIDs() {
        let store = SessionStore()
        let firstWorkspaceId = store.addTerminalTab(title: "First")
        let secondWorkspaceId = store.addTerminalTab(title: "Second")
        let firstID = WorkspaceID(firstWorkspaceId)
        let secondID = WorkspaceID(secondWorkspaceId)

        let result = store.reorderWorkspace(firstID, anchor: .beforeWorkspace(secondID))
        guard case .success(let reorderResult) = result else {
            XCTFail("Expected workspace reorder to succeed")
            return
        }

        XCTAssertEqual(reorderResult.workspaceID, firstID)
        XCTAssertEqual(store.terminalTabs.map(\.terminalId).prefix(2), [firstWorkspaceId, secondWorkspaceId])
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
