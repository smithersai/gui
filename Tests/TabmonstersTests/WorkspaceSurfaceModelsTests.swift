import XCTest
@testable import Tabmonsters
#if os(macOS)
import AppKit
#endif

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

    func testReplacingSurfaceIdsPreservesSplitShape() {
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

        let result = tree.replacingSurfaceIds(["a": "new-a", "c": "new-c"])

        guard case .split(let rootId, let rootAxis, let left, let right) = result else {
            XCTFail("Expected root split")
            return
        }
        XCTAssertEqual(rootId, "root")
        XCTAssertEqual(rootAxis, .vertical)
        XCTAssertEqual(right, .leaf("new-c"))

        guard case .split(let leftId, let leftAxis, let first, let second) = left else {
            XCTFail("Expected nested split")
            return
        }
        XCTAssertEqual(leftId, "left")
        XCTAssertEqual(leftAxis, .horizontal)
        XCTAssertEqual(first, .leaf("new-a"))
        XCTAssertEqual(second, .leaf("b"))
    }

    func testSplitAxisContainingSurfaceUsesNearestParentSplit() {
        let tree: WorkspaceLayoutNode = .split(
            id: "root-pane",
            axis: .horizontal,
            first: .leaf("root"),
            second: .split(
                id: "nested-pane",
                axis: .vertical,
                first: .leaf("left"),
                second: .split(
                    id: "deep-pane",
                    axis: .horizontal,
                    first: .leaf("right"),
                    second: .leaf("nested")
                )
            )
        )

        XCTAssertEqual(tree.splitAxis(containing: "root"), .horizontal)
        XCTAssertEqual(tree.splitAxis(containing: "left"), .vertical)
        XCTAssertEqual(tree.splitAxis(containing: "nested"), .horizontal)
        XCTAssertNil(tree.splitAxis(containing: "missing"))
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

    func testRestartingWorkspaceReplacesTerminalSurfaceIDsButKeepsNonTerminalSurfaces() throws {
        let workspace = TerminalWorkspace(
            id: WorkspaceID(),
            title: "Workspace",
            workingDirectory: "/tmp/project",
            command: "zsh",
            backend: .native
        )
        let firstTerminalId = try XCTUnwrap(workspace.layout.firstSurfaceId)
        let browserId = workspace.splitFocused(axis: .horizontal, kind: .browser)
        let secondTerminalId = workspace.splitFocused(axis: .vertical, kind: .terminal)
        workspace.focusSurface(secondTerminalId)

        XCTAssertTrue(workspace.restartTerminalSurfaces())

        let restartedSurfaceIds = Set(workspace.orderedSurfaces.map(\.id))
        XCTAssertFalse(restartedSurfaceIds.contains(firstTerminalId))
        XCTAssertFalse(restartedSurfaceIds.contains(secondTerminalId))
        XCTAssertTrue(restartedSurfaceIds.contains(browserId))
        XCTAssertEqual(workspace.orderedSurfaces.filter { $0.kind == .terminal }.count, 2)
        XCTAssertEqual(workspace.orderedSurfaces.filter { $0.kind == .browser }.map(\.id), [browserId])
        XCTAssertNotEqual(workspace.focusedSurfaceId, secondTerminalId)
        XCTAssertEqual(
            workspace.focusedSurfaceId.flatMap { workspace.surfaces[$0]?.kind },
            .terminal
        )
        for surface in workspace.orderedSurfaces where surface.kind == .terminal {
            XCTAssertNil(surface.sessionId)
            XCTAssertEqual(workspace.nativeTerminalState(surfaceId: surface.id), .pending)
        }
    }

    func testRestartingTerminalTabPreservesTabIdentityAndClearsSessionMetadata() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestartTerminalTabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let workspacePath = tmpDir.appendingPathComponent("workspace", isDirectory: true).path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: workspacePath, isDirectory: true),
            withIntermediateDirectories: true
        )

        let store = SessionStore(
            workingDirectory: workspacePath,
            app: Smithers.App(databasePath: tmpDir.appendingPathComponent("app.sqlite").path)
        )
        let terminalId = store.addTerminalTab(
            title: "Codex",
            workingDirectory: workspacePath,
            command: "codex"
        )
        let workspace = store.ensureTerminalWorkspace(terminalId)
        let originalSurfaceId = try XCTUnwrap(workspace.layout.firstSurfaceId)
        workspace.markNativeTerminalReady(surfaceId: originalSurfaceId, sessionId: "old-session")

        XCTAssertTrue(store.restartTerminalTab(terminalId))

        let tab = try XCTUnwrap(store.terminalTabs.first { $0.terminalId == terminalId })
        let restartedWorkspace = try XCTUnwrap(store.terminalWorkspaceIfAvailable(terminalId))
        let restartedSurfaceId = try XCTUnwrap(restartedWorkspace.layout.firstSurfaceId)

        XCTAssertEqual(store.terminalTabs.count, 1)
        XCTAssertEqual(tab.terminalId, terminalId)
        XCTAssertEqual(tab.title, "Codex")
        XCTAssertNil(tab.sessionId)
        XCTAssertNotEqual(restartedSurfaceId, originalSurfaceId)
        XCTAssertEqual(tab.rootSurfaceId, restartedSurfaceId.rawValue)
        XCTAssertFalse(tab.snapshot?.surfaces.contains { $0.id == originalSurfaceId } ?? true)
    }

    func testTerminalTabsPersistAcrossSessionStoreRelaunch() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStorePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let workspacePath = tmpDir.appendingPathComponent("workspace", isDirectory: true).path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: workspacePath, isDirectory: true),
            withIntermediateDirectories: true
        )
        let databasePath = tmpDir.appendingPathComponent("app.sqlite").path

        let firstStore = SessionStore(
            workingDirectory: workspacePath,
            app: Smithers.App(databasePath: databasePath)
        )
        let terminalId = firstStore.addTerminalTab(
            title: "Claude Code",
            workingDirectory: workspacePath,
            command: "claude"
        )

        firstStore.flushSessionPersistence()

        let reloadedStore = SessionStore(
            workingDirectory: workspacePath,
            app: Smithers.App(databasePath: databasePath)
        )

        XCTAssertEqual(reloadedStore.terminalTabs.count, 1)
        XCTAssertEqual(reloadedStore.terminalTabs.first?.terminalId, terminalId)
        XCTAssertEqual(reloadedStore.terminalTabs.first?.title, "Claude Code")
        XCTAssertEqual(reloadedStore.terminalTabs.first?.command, "claude")
        XCTAssertNil(reloadedStore.terminalTabs.first?.sessionId)
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
