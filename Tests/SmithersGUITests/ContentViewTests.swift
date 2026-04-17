import XCTest
@testable import SmithersGUI

final class NavDestinationMetadataTests: XCTestCase {
    private let destinations: [NavDestination] = [
        .chat,
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

        XCTAssertFalse(NavDestination.chat.isTerminal)
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
            AppPreferenceKeys.externalAgentUnsafeFlagsEnabled,
            AppPreferenceKeys.browserSearchEngine,
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
        let detailContent = try detailContentSource()
        let liveRunCaseCount = detailContent.components(separatedBy: "case .liveRun").count - 1
        XCTAssertEqual(liveRunCaseCount, 1, "Expected exactly one `.liveRun` case in detailContent switch")
    }

    func testLiveRunCaseRoutesToLiveRunView() throws {
        let detailContent = try detailContentSource()
        let casePattern = #"case \.liveRun\(let runId, let nodeId\):[\s\S]*?LiveRunView\("#

        XCTAssertNotNil(
            detailContent.range(of: casePattern, options: .regularExpression),
            "Expected `.liveRun` case to route to LiveRunView"
        )
        XCTAssertTrue(
            detailContent.contains(".accessibilityIdentifier(\"view.liveRun\")"),
            "Expected live run route to expose stable accessibility identifier"
        )
    }

    func testTerminalRouteRequestsConfirmationBeforeClose() throws {
        let detailContent = try detailContentSource()
        let casePattern = #"case \.terminal\(let id\):[\s\S]*?onClose:\s*\{\s*requestTerminalClose\(id\)\s*\}"#

        XCTAssertNotNil(
            detailContent.range(of: casePattern, options: .regularExpression),
            "Expected terminal route close action to request confirmation."
        )
    }

    func testTerminalCloseConfirmationDialogExists() throws {
        let source = try contentViewSource()

        XCTAssertTrue(
            source.contains("confirmationDialog(\n                \"Terminate Terminal?\""),
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

    private func detailContentSource() throws -> String {
        let source = try contentViewSource()

        guard let start = source.range(of: "private var detailContent: some View {"),
              let end = source.range(
                of: "\n\n    var body: some View",
                range: start.upperBound..<source.endIndex
              )
        else {
            XCTFail("Unable to locate detailContent source block in ContentView.swift")
            return source
        }

        return String(source[start.lowerBound..<end.lowerBound])
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
}
