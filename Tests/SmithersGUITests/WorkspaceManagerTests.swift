import XCTest
@testable import SmithersGUI

@MainActor
final class WorkspaceManagerTests: XCTestCase {

    // MARK: - Launch behaviour
    //
    // Bug: double-clicking the app jumped straight into the previously
    // opened workspace, never showing the welcome / picker screen, and
    // ContentView was wired up with SmithersClient(cwd: launchDir) so
    // smithers data always reflected the launch directory regardless of
    // which workspace had been selected.

    /// Plain double-click must land on the welcome screen even if a path
    /// was previously opened. Auto-restore was the source of the "always
    /// opens gui/" complaint.
    func test_launchWithoutExplicitWorkspace_landsOnWelcome() {
        let suite = makeIsolatedDefaults()
        let store = makeIsolatedStore()

        let manager = WorkspaceManager(
            store: store,
            userDefaults: suite,
            launchArguments: ["/Applications/SmithersGUI.app/Contents/MacOS/SmithersGUI"],
            environment: [:]
        )

        XCTAssertNil(
            manager.activeWorkspacePath,
            "Plain launch must show the welcome screen, not auto-restore a workspace."
        )
    }

    /// Even when a previous session persisted a path under the legacy
    /// activeWorkspacePath key, a plain double-click should ignore it.
    func test_launchIgnoresLegacyPersistedActivePath() {
        let suite = makeIsolatedDefaults()
        suite.set("/tmp", forKey: "com.smithers.gui.activeWorkspacePath")

        let manager = WorkspaceManager(
            store: makeIsolatedStore(),
            userDefaults: suite,
            launchArguments: ["SmithersGUI"],
            environment: [:]
        )

        XCTAssertNil(manager.activeWorkspacePath)
    }

    /// CLI launches like `SmithersGUI /path/to/repo` must open the supplied
    /// workspace directly — that's the `smithers .` use case.
    func test_launchWithPathArg_opensThatWorkspace() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manager = WorkspaceManager(
            store: makeIsolatedStore(),
            userDefaults: makeIsolatedDefaults(),
            launchArguments: ["SmithersGUI", tmp.path],
            environment: [:]
        )

        XCTAssertEqual(manager.activeWorkspacePath, tmp.path)
    }

    /// AppKit injects flags like `-NSDocumentRevisionsDebugMode YES` — these
    /// must not be mistaken for a workspace path.
    func test_launchSkipsAppKitDebugFlags() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manager = WorkspaceManager(
            store: makeIsolatedStore(),
            userDefaults: makeIsolatedDefaults(),
            launchArguments: [
                "SmithersGUI",
                "-NSDocumentRevisionsDebugMode", "YES",
                "-AppleLanguages", "(en)",
                tmp.path,
            ],
            environment: [:]
        )

        XCTAssertEqual(manager.activeWorkspacePath, tmp.path)
    }

    func test_launchHonoursSmithersOpenWorkspaceEnv() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manager = WorkspaceManager(
            store: makeIsolatedStore(),
            userDefaults: makeIsolatedDefaults(),
            launchArguments: ["SmithersGUI"],
            environment: ["SMITHERS_OPEN_WORKSPACE": tmp.path]
        )

        XCTAssertEqual(manager.activeWorkspacePath, tmp.path)
    }

    /// Argv parsing in isolation: the helper used by the init.
    func test_workspaceFromLaunch_parsing() {
        XCTAssertNil(WorkspaceManager.workspaceFromLaunch(arguments: ["SmithersGUI"], environment: [:]))
        XCTAssertEqual(
            WorkspaceManager.workspaceFromLaunch(
                arguments: ["SmithersGUI", "/tmp/foo"],
                environment: [:]
            ),
            "/tmp/foo"
        )
        XCTAssertEqual(
            WorkspaceManager.workspaceFromLaunch(
                arguments: ["SmithersGUI", "-NSDocumentRevisionsDebugMode", "YES", "/tmp/foo"],
                environment: [:]
            ),
            "/tmp/foo"
        )
        XCTAssertEqual(
            WorkspaceManager.workspaceFromLaunch(
                arguments: ["SmithersGUI"],
                environment: ["SMITHERS_OPEN_WORKSPACE": "/tmp/bar"]
            ),
            "/tmp/bar"
        )
    }

    // MARK: - Helpers

    private func makeIsolatedDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
        let suiteName = "WorkspaceManagerTests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults", file: file, line: line)
            return .standard
        }
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    private func makeIsolatedStore() -> RecentWorkspaceStore {
        let suiteName = "WorkspaceManagerTests.recents.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return RecentWorkspaceStore(userDefaults: suite)
    }

    private func makeTempDir() throws -> URL {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("WorkspaceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - SmithersClient cwd wiring (the "loads forever / crashes when I
// pick a folder" symptom). Originally ContentView did:
//
//     @StateObject private var smithers = SmithersClient()
//
// which ignored the workspacePath argument and ran every smithers CLI call
// against the launch directory. Picking a folder that wasn't gui/ broke
// the SwiftUI graph (SIGABRT in AG::Graph::value_set) and looked like a
// hang because `await smithers.checkConnection()` was probing the wrong
// cwd. The fix is to pass the resolved workspacePath into SmithersClient.

@MainActor
final class SmithersClientCWDWiringTests: XCTestCase {

    func test_smithersClientHonoursExplicitCWD() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let client = SmithersClient(cwd: tmp.path)
        XCTAssertEqual(client.workingDirectory, tmp.path)
    }

    /// The contract ContentView relies on: nil cwd falls back to the
    /// launch directory. This is *exactly* the behaviour that produced
    /// the bug — documented here so a future change to make it fall back
    /// to e.g. `nil` (welcome) doesn't silently regress ContentView.
    func test_smithersClientWithoutCWD_fallsBackToLaunchDirectory() {
        let client = SmithersClient()
        let expected = (FileManager.default.currentDirectoryPath as NSString).standardizingPath
        XCTAssertEqual(client.workingDirectory, expected)
    }

    /// Source-level regression check that ContentView wires its @StateObject
    /// `smithers` from the workspacePath. We assert on the source string
    /// because StateObject's wrappedValue is only legal to read inside a
    /// view body.
    func test_contentViewWiresSmithersClientFromWorkspacePath() throws {
        let source = try contentViewSource()

        XCTAssertFalse(
            source.contains("@StateObject private var smithers = SmithersClient()"),
            """
            ContentView is initialising `smithers` with no cwd. That makes \
            every SmithersClient call run against the launch directory, \
            which is the root cause of the "loads forever / crashes when I \
            pick a folder" bug. Pass the resolved workspacePath instead.
            """
        )
        XCTAssertTrue(
            source.contains("_smithers = StateObject(wrappedValue: SmithersClient(cwd: resolved))"),
            "ContentView.init must wire SmithersClient with the resolved workspacePath."
        )
    }

    private func makeTempDir() throws -> URL {
        let url = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("SmithersClientCWDWiringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contentViewSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent("ContentView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
