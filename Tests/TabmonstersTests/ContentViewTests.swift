import XCTest
@testable import Tabmonsters

final class NavDestinationMetadataTests: XCTestCase {
    private let destinations: [NavDestination] = [
        .dashboard,
        .vcsDashboard,
        .agents,
        .changes,
        .runs,
        .snapshots,
        .workflows,
        .triggers,
        .jjhubWorkflows,
        .approvals,
        .prompts,
        .scores,
        .memory,
        .search,
        .sql,
        .landings,
        .tickets,
        .issues,
        .terminal(),
        .terminalCommand(binary: "codex", workingDirectory: "/tmp", name: "Codex"),
        .liveRun(runId: "run-1", nodeId: nil),
        .runInspect(runId: "run-1", workflowName: "wf"),
        .workspaces,
        .logs,
        .settings,
    ]

    func testEveryDestinationProvidesNonEmptyLabelAndIcon() {
        for destination in destinations {
            XCTAssertFalse(destination.label.isEmpty, "Expected non-empty label for \(destination)")
            XCTAssertFalse(destination.icon.isEmpty, "Expected non-empty icon for \(destination)")
        }
    }

    func testTerminalDestinationsAreClassifiedAsTerminal() {
        XCTAssertTrue(NavDestination.terminal().isTerminal)
        XCTAssertTrue(NavDestination.terminalCommand(binary: "codex", workingDirectory: "/tmp", name: "Codex").isTerminal)

        XCTAssertFalse(NavDestination.dashboard.isTerminal)
        XCTAssertFalse(NavDestination.liveRun(runId: "run-1", nodeId: nil).isTerminal)
    }

    func testTerminalCommandUsesProvidedNameAsLabel() {
        let destination = NavDestination.terminalCommand(binary: "smithers", workingDirectory: "/tmp", name: "Smithers CLI")
        XCTAssertEqual(destination.label, "Smithers CLI")
        XCTAssertEqual(destination.icon, "terminal.fill")
    }

    func testAssociatedValuesAffectHashAndEquality() {
        let first = NavDestination.liveRun(runId: "run-1", nodeId: nil)
        let second = NavDestination.liveRun(runId: "run-2", nodeId: nil)
        let third = NavDestination.liveRun(runId: "run-1", nodeId: "node-1")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first, third)

        let set: Set<NavDestination> = [first, second, third]
        XCTAssertEqual(set.count, 3)
    }

    func testRouteLabelsRemainStableForInspectorViews() {
        XCTAssertEqual(NavDestination.liveRun(runId: "run", nodeId: nil).label, "Live Run")
        XCTAssertEqual(NavDestination.runInspect(runId: "run", workflowName: "wf").label, "Run Inspector")
        XCTAssertEqual(NavDestination.runInspect(runId: "run", workflowName: "wf").icon, "sidebar.right")
    }
}

final class AppPreferenceKeysTests: XCTestCase {
    func testPreferenceKeysAreDistinctAndNamespaced() {
        let keys = [
            AppPreferenceKeys.vimModeEnabled,
            AppPreferenceKeys.developerToolsEnabled,
            AppPreferenceKeys.tabmonstersControlSidebarEnabled,
            AppPreferenceKeys.externalAgentUnsafeFlagsEnabled,
            AppPreferenceKeys.browserSearchEngine,
            AppPreferenceKeys.shortcutCheatSheetFooterEnabled,
            AppPreferenceKeys.defaultShellPath,
        ]

        XCTAssertEqual(Set(keys).count, keys.count)
        for key in keys {
            XCTAssertTrue(key.hasPrefix("settings."), "Expected settings namespace for key: \(key)")
        }
    }

    func testBrowserSearchEngineCasesAreStable() {
        XCTAssertEqual(BrowserSearchEngine.allCases.map(\.rawValue), ["duckduckgo", "google", "bing"])
        XCTAssertEqual(BrowserSearchEngine.duckDuckGo.label, "DuckDuckGo")
        XCTAssertEqual(BrowserSearchEngine.google.label, "Google")
        XCTAssertEqual(BrowserSearchEngine.bing.label, "Bing")
    }
}

final class ContentViewRoutingSourceTests: XCTestCase {
    func testDetailContentSwitchContainsSingleLiveRunCase() throws {
        let source = try detailRouterSource()
        let liveRunCaseCount = source.components(separatedBy: "case .liveRun").count - 1
        XCTAssertEqual(liveRunCaseCount, 1, "Expected exactly one `.liveRun` case in detailContent switch")
    }

    func testLiveRunCaseRoutesToRunInspectorView() throws {
        let source = try detailRouterSource()
        let casePattern = #"case \.liveRun\(let runId, let nodeId\):[\s\S]*?RunInspectorView\("#

        XCTAssertNotNil(
            source.range(of: casePattern, options: .regularExpression),
            "Expected `.liveRun` case to route to RunInspectorView"
        )
        XCTAssertTrue(
            source.contains(".accessibilityIdentifier(\"view.liveRun\")"),
            "Expected live run route to expose stable accessibility identifier"
        )
    }

    func testTerminalRouteRequestsConfirmationBeforeClose() throws {
        let source = try detailRouterSource()
        let casePattern = #"case \.terminal\(let id\):[\s\S]*?onClose:\s*\{\s*actions\.requestTerminalClose\(id\)\s*\}"#

        XCTAssertNotNil(
            source.range(of: casePattern, options: .regularExpression),
            "Expected terminal route close action to request confirmation."
        )
    }

    func testTerminalCloseConfirmationDialogExists() throws {
        let source = try contentViewSource() + "\n" + contentShellSource()

        XCTAssertNotNil(
            source.range(of: #"confirmationDialog\(\s*"Terminate Terminal\?""#, options: .regularExpression),
            "Expected ContentView to present a terminal termination confirmation dialog."
        )
        XCTAssertTrue(
            source.contains("Button(\"Terminate Terminal\", role: .destructive)"),
            "Expected destructive terminal termination confirmation action."
        )
        XCTAssertTrue(
            source.contains("store.removeTerminalTab(terminalId)"),
            "Expected confirmed terminal close to remove the terminal workspace."
        )
    }

    func testShortcutCheatSheetFooterSettingIsWiredThroughShell() throws {
        let contentSource = try contentViewSource()
        let shellSource = try contentShellSource()

        XCTAssertTrue(
            contentSource.contains("AppPreferenceKeys.shortcutCheatSheetFooterEnabled"),
            "Expected Settings and ContentView to read the shortcut footer preference."
        )
        XCTAssertTrue(
            contentSource.contains("settings.shortcuts.footer.toggle"),
            "Expected Settings to expose a stable toggle for the shortcut footer."
        )
        XCTAssertTrue(
            shellSource.contains("shortcutCheatSheetFooterEnabled"),
            "Expected the macOS shell to receive the shortcut footer preference."
        )
        XCTAssertTrue(
            shellSource.contains("ShortcutCheatSheetFooter("),
            "Expected the macOS shell to render the shortcut cheat sheet footer."
        )
        XCTAssertTrue(
            shellSource.contains("shortcutFooter.item.\\(action.rawValue)"),
            "Expected footer shortcut items to expose stable accessibility identifiers."
        )
    }

    func testDefaultShellSettingIsExposedInSettings() throws {
        let contentSource = try contentViewSource()
        let sessionStoreSource = try sessionStoreSource()

        XCTAssertTrue(
            contentSource.contains("AppPreferenceKeys.defaultShellPath"),
            "Expected Settings to read the default shell preference."
        )
        XCTAssertTrue(
            contentSource.contains("settings.defaultShell.picker"),
            "Expected Settings to expose a stable default shell picker."
        )
        XCTAssertTrue(
            contentSource.contains("settings.defaultShell.customPath"),
            "Expected Settings to expose a custom shell path field."
        )
        XCTAssertTrue(
            sessionStoreSource.contains("TerminalShellPreference.resolvedShellPath(userDefaults: userDefaults)"),
            "Expected new native sessions to use the configured default shell."
        )
    }

    private func detailRouterSource() throws -> String {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DetailRouter.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    private func contentViewSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let contentViewURL = repoRoot.appendingPathComponent("ContentView.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: contentViewURL.path),
            "Missing expected source file at \(contentViewURL.path)"
        )
        return try String(contentsOf: contentViewURL, encoding: .utf8)
    }

    private func contentShellSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let shellURL = repoRoot
            .appendingPathComponent("macos")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Smithers")
            .appendingPathComponent("Smithers.ContentShell.macOS.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: shellURL.path),
            "Missing expected source file at \(shellURL.path)"
        )
        return try String(contentsOf: shellURL, encoding: .utf8)
    }

    private func sessionStoreSource() throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let sessionStoreURL = repoRoot
            .appendingPathComponent("macos")
            .appendingPathComponent("Sources")
            .appendingPathComponent("Smithers")
            .appendingPathComponent("Smithers.SessionStore.swift")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sessionStoreURL.path),
            "Missing expected source file at \(sessionStoreURL.path)"
        )
        return try String(contentsOf: sessionStoreURL, encoding: .utf8)
    }
}
