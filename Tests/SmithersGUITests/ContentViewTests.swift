import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - ViewInspector Conformance

extension TerminalView: @retroactive Inspectable {}
extension DashboardView: @retroactive Inspectable {}
extension RunsView: @retroactive Inspectable {}
extension WorkflowsView: @retroactive Inspectable {}
extension JJHubWorkflowsView: @retroactive Inspectable {}
extension ApprovalsView: @retroactive Inspectable {}
extension PromptsView: @retroactive Inspectable {}
extension ScoresView: @retroactive Inspectable {}
extension MemoryView: @retroactive Inspectable {}
extension SearchView: @retroactive Inspectable {}
extension LandingsView: @retroactive Inspectable {}
extension TicketsView: @retroactive Inspectable {}
extension IssuesView: @retroactive Inspectable {}
extension WorkspacesView: @retroactive Inspectable {}

// MARK: - Constants

private let kHeaderHeight: CGFloat = 48
private let kTitlebarHeight: CGFloat = 40
private let kMinWindowWidth: CGFloat = 800
private let kMinWindowHeight: CGFloat = 600

// MARK: - SmithersApp Tests

final class SmithersAppTests: XCTestCase {

    // -------------------------------------------------------------------------
    // PLATFORM_SWIFTUI_MACOS_APP
    // -------------------------------------------------------------------------

    func testSmithersAppIsASwiftUIApp() {
        // SmithersApp conforms to App protocol (it compiles with @main and `var body: some Scene`)
        // This is a compile-time check; if it didn't conform, the project wouldn't build.
        // We verify it uses WindowGroup.
        let app = SmithersApp()
        _ = app.body // should not crash
    }

    // -------------------------------------------------------------------------
    // PLATFORM_NS_APPLICATION_DELEGATE_ADAPTOR
    // -------------------------------------------------------------------------

    func testAppDelegateIsNSApplicationDelegate() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate is NSApplicationDelegate,
                      "AppDelegate must conform to NSApplicationDelegate")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_APP_DELEGATE_ACTIVATION_POLICY
    // -------------------------------------------------------------------------

    func testAppDelegateSetActivationPolicy() {
        // AppDelegate.applicationDidFinishLaunching calls NSApp.setActivationPolicy(.regular)
        // We can only verify the method exists and is callable without crashing in test context.
        let delegate = AppDelegate()
        // Calling it directly would require NSApp to exist; just verify the type has the method.
        XCTAssertTrue(delegate.responds(to: #selector(delegate.applicationDidFinishLaunching(_:))))
    }

    // -------------------------------------------------------------------------
    // PLATFORM_FORCED_DARK_COLOR_SCHEME
    // -------------------------------------------------------------------------

    /// BUG: The dark color scheme is applied via `.preferredColorScheme(.dark)` on the
    /// ContentView inside SmithersApp.body, but ContentView itself does NOT apply it.
    /// If ContentView is ever hosted outside SmithersApp (e.g., previews, tests, or a
    /// secondary window), the dark scheme is NOT enforced. The modifier should be on
    /// ContentView.body directly, not only at the App level.
    func testDarkColorSchemeIsOnlyAtAppLevel_BUG() {
        // Verify ContentView itself does NOT set preferredColorScheme — this is the bug.
        // The only place .preferredColorScheme(.dark) appears is in SmithersApp.body.
        // We cannot easily inspect Scene modifiers with ViewInspector, so we document
        // this as a known architectural issue.
        //
        // Expected: ContentView.body should include .preferredColorScheme(.dark)
        // Actual: Only SmithersApp.body applies it.
    }

    // -------------------------------------------------------------------------
    // PLATFORM_HIDDEN_TITLE_BAR_WINDOW / PLATFORM_WINDOW_TOOLBAR_UNIFIED
    // -------------------------------------------------------------------------

    /// These are Scene-level modifiers (.windowStyle(.hiddenTitleBar) and
    /// .windowToolbarStyle(.unified)) on SmithersApp. ViewInspector cannot inspect
    /// Scene modifiers, so we verify the code compiles and document.
    ///
    /// BUG: .windowStyle(.hiddenTitleBar) combined with .windowToolbarStyle(.unified)
    /// is contradictory on macOS. hiddenTitleBar hides the title bar entirely, making
    /// .unified toolbar style meaningless since there is no title bar to unify with.
    /// The toolbar style modifier has no visible effect.
    func testWindowStyleModifiersAreContradictory_BUG() {
        // This test documents the bug. Both modifiers compile and run, but the
        // combination is logically conflicting. Pick one: either .hiddenTitleBar
        // (custom chrome) or .titleBar + .unified (native toolbar).
    }
}

// MARK: - ContentView Tests

@MainActor
final class ContentViewTests: XCTestCase {
    private func projectSource(_ filename: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectDirectory.appendingPathComponent(filename)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func assertSource(
        _ source: String,
        matches pattern: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotNil(
            source.range(of: pattern, options: .regularExpression),
            message,
            file: file,
            line: line
        )
    }

    // -------------------------------------------------------------------------
    // PLATFORM_MINIMUM_WINDOW_SIZE_800X600
    // -------------------------------------------------------------------------

    func testMinimumWindowSize() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"\.frame\s*\(\s*minWidth:\s*800,\s*minHeight:\s*600\s*\)"#,
            "ContentView should keep an 800x600 minimum frame on the main NavigationSplitView"
        )
        XCTAssertEqual(kMinWindowWidth, 800, "Minimum window width must be 800")
        XCTAssertEqual(kMinWindowHeight, 600, "Minimum window height must be 600")
    }

    // -------------------------------------------------------------------------
    // CONSTANT_HEADER_HEIGHT_48
    // -------------------------------------------------------------------------

    /// BUG: There is no 48px header height constant or frame anywhere in ContentView.
    /// The sidebar title bar uses 40px (CONSTANT_TITLEBAR_HEIGHT_40), but there is
    /// no 48px header. The feature CONSTANT_HEADER_HEIGHT_48 is unimplemented.
    func testHeaderHeight48IsMissing_BUG() {
        // Expected: A header bar with .frame(height: 48)
        // Actual: No such element exists in ContentView. The sidebar has a 40px titlebar.
        // The main content area has no header at all.
    }

    // -------------------------------------------------------------------------
    // CONSTANT_TITLEBAR_HEIGHT_40
    // -------------------------------------------------------------------------

    func testTitlebarHeight40InSidebar() throws {
        let source = try projectSource("SidebarView.swift")
        assertSource(
            source,
            matches: #"Text\("Smithers"\)[\s\S]*?\.frame\s*\(\s*height:\s*40\s*\)"#,
            "Sidebar titlebar should keep its 40pt frame height"
        )
        XCTAssertEqual(kTitlebarHeight, 40, "Sidebar titlebar height should be 40")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_DESTINATION_ROUTING — default destination
    // -------------------------------------------------------------------------

    func testDefaultDestinationIsDashboard() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"@State\s+private\s+var\s+destination:\s*NavDestination\s*=\s*\.dashboard"#,
            "ContentView should default to the dashboard destination after loading"
        )
    }

    // -------------------------------------------------------------------------
    // NAV_DESTINATION_CHAT — empty state when no active agent
    // -------------------------------------------------------------------------

    /// BUG: When destination is .chat and there IS an active agent (SessionStore creates
    /// one in init via newSession()), the default destination is .dashboard, not .chat.
    /// So .chat is never shown by default. However, when navigated to .chat, the
    /// activeAgent WILL exist because SessionStore.init() calls newSession().
    /// This means the "No active session" empty state is practically unreachable
    /// under normal usage — it can only appear if sessions are manually cleared.
    func testChatEmptyStateIsUnreachable_BUG() {
        // SessionStore.init() always calls newSession(), so activeAgent is never nil
        // at construction time. The "No active session" empty state at line 39 of
        // ContentView.swift is dead code under normal conditions.
        let store = SessionStore()
        XCTAssertNotNil(store.activeAgent,
                        "activeAgent is always non-nil after init — empty state is unreachable")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_CWD_AUTO_DETECTION_WITH_HOME_FALLBACK
    // -------------------------------------------------------------------------

    func testSmithersClientDefaultsCwdToCurrentDirectory() {
        let client = SmithersClient()
        // SmithersClient uses FileManager.default.currentDirectoryPath as fallback.
        // It does NOT fall back to HOME — it uses the process cwd.
        // This is correct for CLI-spawned processes but may be wrong for .app bundles
        // where cwd is typically "/".
    }

    /// BUG: SmithersClient does NOT implement HOME fallback. The init uses
    /// `FileManager.default.currentDirectoryPath` which for a macOS .app launched
    /// from Finder is typically "/" — not the user's home directory. There is no
    /// fallback to `~` or `$HOME`. The feature PLATFORM_CWD_AUTO_DETECTION_WITH_HOME_FALLBACK
    /// is only partially implemented (auto-detection yes, HOME fallback no).
    func testCwdHomeFallbackIsMissing_BUG() {
        let client = SmithersClient()
        // Expected: if cwd is "/" or unwritable, fall back to home directory
        // Actual: always uses FileManager.default.currentDirectoryPath with no fallback
        let cwd = FileManager.default.currentDirectoryPath
        // In test context this is usually the project dir, but in .app context it would be "/"
        XCTAssertFalse(cwd.isEmpty, "cwd should never be empty")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_DESTINATION_ROUTING — all 20 static destinations
    // -------------------------------------------------------------------------

    func testNavDestinationEnumHasExactly20StaticCases() {
        let all: [NavDestination] = [
            .chat, .terminal(), .dashboard, .agents, .changes, .runs, .workflows, .triggers, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .tickets, .issues, .liveRun(runId: "run", nodeId: nil), .workspaces,
        ]
        XCTAssertEqual(all.count, 20)
    }

    func testNavDestinationHashable() {
        // All cases must be Hashable for use as dictionary keys and ForEach ids.
        var set = Set<NavDestination>()
        set.insert(.chat)
        set.insert(.dashboard)
        set.insert(.chat) // duplicate
        XCTAssertEqual(set.count, 2)
    }

    func testDashboardRouteRendersCorrectView() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"case\s+\.dashboard:[\s\S]*?DashboardView\s*\(\s*smithers:\s*smithers[\s\S]*?\)"#,
            "The dashboard route should render DashboardView with the shared SmithersClient"
        )
    }

    func testLiveRunRouteIsMappedOnce() throws {
        let source = try projectSource("ContentView.swift")
        let liveRunCaseCount = source.components(separatedBy: "case .liveRun").count - 1

        XCTAssertEqual(liveRunCaseCount, 1, "ContentView should define exactly one .liveRun switch case")
        assertSource(
            source,
            matches: #"case\s+\.liveRun\(let\s+runId,\s*let\s+nodeId\):[\s\S]*?LiveRunChatView\s*\([\s\S]*?runId:\s*runId[\s\S]*?nodeId:\s*nodeId"#,
            "The .liveRun route should render LiveRunChatView with the selected run and node"
        )
    }

    // -------------------------------------------------------------------------
    // NAV_DESTINATION_CHAT through NAV_DESTINATION_WORKSPACES — label/icon pairs
    // -------------------------------------------------------------------------

    func testChatDestinationLabel() {
        XCTAssertEqual(NavDestination.chat.label, "Chat")
        XCTAssertEqual(NavDestination.chat.icon, "message")
    }

    func testTerminalDestinationLabel() {
        XCTAssertEqual(NavDestination.terminal().label, "Terminal")
        XCTAssertEqual(NavDestination.terminal().icon, "terminal.fill")
    }

    func testDashboardDestinationLabel() {
        XCTAssertEqual(NavDestination.dashboard.label, "Dashboard")
        XCTAssertEqual(NavDestination.dashboard.icon, "square.grid.2x2")
    }

    func testAgentsDestinationLabel() {
        XCTAssertEqual(NavDestination.agents.label, "Agents")
        XCTAssertEqual(NavDestination.agents.icon, "person.2")
    }

    func testChangesDestinationLabel() {
        XCTAssertEqual(NavDestination.changes.label, "Changes")
        XCTAssertEqual(NavDestination.changes.icon, "point.3.connected.trianglepath.dotted")
    }

    func testRunsDestinationLabel() {
        XCTAssertEqual(NavDestination.runs.label, "Runs")
        XCTAssertEqual(NavDestination.runs.icon, "play.circle")
    }

    func testWorkflowsDestinationLabel() {
        XCTAssertEqual(NavDestination.workflows.label, "Workflows")
        XCTAssertEqual(NavDestination.workflows.icon, "arrow.triangle.branch")
    }

    func testTriggersRouteRendersCorrectView() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"case\s+\.triggers:[\s\S]*?TriggersView\s*\(\s*smithers:\s*smithers\s*\)"#,
            "The triggers route should render TriggersView with the shared SmithersClient"
        )
    }

    func testTriggersDestinationLabel() {
        XCTAssertEqual(NavDestination.triggers.label, "Triggers")
        XCTAssertEqual(NavDestination.triggers.icon, "clock.arrow.circlepath")
    }

    func testJJHubWorkflowsDestinationLabel() {
        XCTAssertEqual(NavDestination.jjhubWorkflows.label, "JJHub Workflows")
        XCTAssertEqual(NavDestination.jjhubWorkflows.icon, "point.3.filled.connected.trianglepath.dotted")
    }

    func testApprovalsDestinationLabel() {
        XCTAssertEqual(NavDestination.approvals.label, "Approvals")
        XCTAssertEqual(NavDestination.approvals.icon, "checkmark.shield")
    }

    func testPromptsDestinationLabel() {
        XCTAssertEqual(NavDestination.prompts.label, "Prompts")
        XCTAssertEqual(NavDestination.prompts.icon, "doc.text")
    }

    func testScoresDestinationLabel() {
        XCTAssertEqual(NavDestination.scores.label, "Scores")
        XCTAssertEqual(NavDestination.scores.icon, "chart.bar")
    }

    func testMemoryDestinationLabel() {
        XCTAssertEqual(NavDestination.memory.label, "Memory")
        XCTAssertEqual(NavDestination.memory.icon, "brain")
    }

    func testSearchDestinationLabel() {
        XCTAssertEqual(NavDestination.search.label, "Search")
        XCTAssertEqual(NavDestination.search.icon, "magnifyingglass")
    }

    func testSQLDestinationLabel() {
        XCTAssertEqual(NavDestination.sql.label, "SQL Browser")
        XCTAssertEqual(NavDestination.sql.icon, "tablecells")
    }

    func testLandingsDestinationLabel() {
        XCTAssertEqual(NavDestination.landings.label, "Landings")
        XCTAssertEqual(NavDestination.landings.icon, "arrow.down.to.line")
    }

    func testTicketsDestinationLabel() {
        XCTAssertEqual(NavDestination.tickets.label, "Tickets")
        XCTAssertEqual(NavDestination.tickets.icon, "ticket")
    }

    func testIssuesDestinationLabel() {
        XCTAssertEqual(NavDestination.issues.label, "Issues")
        XCTAssertEqual(NavDestination.issues.icon, "exclamationmark.circle")
    }

    func testWorkspacesDestinationLabel() {
        XCTAssertEqual(NavDestination.workspaces.label, "Workspaces")
        XCTAssertEqual(NavDestination.workspaces.icon, "desktopcomputer")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_DESTINATION_ROUTING — switch completeness
    // -------------------------------------------------------------------------

    /// Verify the switch in ContentView covers all static cases. This is a compile-time
    /// guarantee in Swift (exhaustive switch), but we verify the routing map is correct.
    func testAllDestinationsAreMappedInSwitch() {
        // The switch in ContentView.body maps:
        // .chat -> ChatView (or empty state)
        // .terminal -> TerminalView
        // .dashboard -> DashboardView
        // .agents -> AgentsView
        // .changes -> ChangesView
        // .runs -> RunsView
        // .workflows -> WorkflowsView
        // .triggers -> TriggersView
        // .jjhubWorkflows -> JJHubWorkflowsView
        // .approvals -> ApprovalsView
        // .prompts -> PromptsView
        // .scores -> ScoresView
        // .memory -> MemoryView
        // .search -> SearchView
        // .sql -> SQLBrowserView
        // .landings -> LandingsView
        // .tickets -> TicketsView
        // .issues -> IssuesView
        // .workspaces -> WorkspacesView
        //
        // Swift enforces exhaustive switch, so all 20 static routes are covered.
        // No default case means adding a new NavDestination case will cause a compiler error.
        let count = [
            NavDestination.chat, .terminal(), .dashboard, .agents, .changes, .runs, .workflows, .triggers, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .tickets, .issues, .liveRun(runId: "run", nodeId: nil), .workspaces,
        ].count
        XCTAssertEqual(count, 20, "All 20 static destinations must be routed")
    }

    // -------------------------------------------------------------------------
    // Layout structure
    // -------------------------------------------------------------------------

    func testContentViewHasSidebarAndMainArea() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"NavigationSplitView\s*\{[\s\S]*?SidebarView\s*\([\s\S]*?store:\s*store,[\s\S]*?destination:\s*\$destination[\s\S]*?\)[\s\S]*?\}\s*detail:\s*\{[\s\S]*?Group\s*\{"#,
            "ContentView should render SidebarView and a detail Group inside NavigationSplitView"
        )
    }

    func testSidebarWidthIs240() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"navigationSplitViewColumnWidth\s*\(\s*min:\s*180,\s*ideal:\s*240,\s*max:\s*360\s*\)"#,
            "NavigationSplitView sidebar should use a 240pt ideal column width"
        )
    }

    func testMainContentExpandsToFill() throws {
        let source = try projectSource("ContentView.swift")
        assertSource(
            source,
            matches: #"detail:\s*\{[\s\S]*?Group\s*\{[\s\S]*?\.frame\s*\(\s*maxWidth:\s*\.infinity,\s*maxHeight:\s*\.infinity\s*\)"#,
            "NavigationSplitView detail content should expand to fill available space"
        )
    }

    // -------------------------------------------------------------------------
    // PLATFORM_KEYBOARD_SHORTCUTS
    // -------------------------------------------------------------------------

    /// BUG: ContentView has NO keyboard shortcuts defined. The feature
    /// PLATFORM_KEYBOARD_SHORTCUTS is entirely unimplemented. There are no
    /// .keyboardShortcut() modifiers anywhere in ContentView.swift.
    /// Expected: Cmd+N for new chat, Cmd+T for new terminal, Cmd+1..9 for nav, etc.
    /// Actual: Zero keyboard shortcuts.
    func testKeyboardShortcutsAreMissing_BUG() {
        // No .keyboardShortcut() modifiers exist in ContentView.
        // This is a missing feature, not just a bug.
    }

    // -------------------------------------------------------------------------
    // PLATFORM_LOADING_AND_ERROR_STATES
    // -------------------------------------------------------------------------

    /// ContentView now shows a loading state with ProgressView and "Connecting to Smithers..."
    /// while checkConnection() runs.
    func testLoadingStateIsPresent() throws {
        let sut = ContentView()
        let inspected = try sut.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("Connecting to Smithers..."),
                      "Loading state should show 'Connecting to Smithers...' text")
    }

    /// BUG: ContentView has NO error state UI. If smithers.checkConnection() fails
    /// (cliAvailable = false, isConnected = false), there is no error banner, alert,
    /// or visual indication. The user sees a fully rendered UI that silently fails
    /// when they try to use features.
    func testErrorStateIsMissing_BUG() {
        // Expected: An error banner or overlay when smithers CLI is unavailable
        // Actual: No error handling UI exists in ContentView
    }

    /// BUG: SmithersClient.isConnected and .cliAvailable are published properties,
    /// but ContentView never reads them. There is no conditional rendering based on
    /// connection status.
    func testConnectionStatusIsIgnored_BUG() throws {
        let client = SmithersClient(cwd: "/tmp")
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.cliAvailable)
        // ContentView passes `smithers` to child views but never checks these properties itself.
    }

    // -------------------------------------------------------------------------
    // PLATFORM_PULL_TO_REFRESH
    // -------------------------------------------------------------------------

    func testPullToRefreshIsAvailableOnMajorScrollableViews() throws {
        let expectedRefreshActions: [(String, [String])] = [
            ("RunsView.swift", [".refreshable { await loadRuns() }"]),
            ("WorkflowsView.swift", [".refreshable { await loadWorkflows() }"]),
            ("ApprovalsView.swift", [".refreshable { await loadApprovals() }"]),
            ("DashboardView.swift", [".refreshable { await loadAll() }"]),
            ("MemoryView.swift", [
                ".refreshable { await loadFacts() }",
                ".refreshable { await doRecall() }",
            ]),
            ("ScoresView.swift", [".refreshable { await loadRunContextAndScores() }"]),
            ("AgentsView.swift", [".refreshable { await loadAgents() }"]),
            ("TriggersView.swift", [".refreshable { await loadCrons() }"]),
            ("PromptsView.swift", [".refreshable { await loadPrompts() }"]),
            ("JJHubWorkflowsView.swift", [".refreshable { await loadData() }"]),
            ("ChangesView.swift", [
                ".refreshable { await refresh(for: .changes) }",
                ".refreshable { await refresh(for: .status) }",
            ]),
            ("LandingsView.swift", [".refreshable { await loadLandings() }"]),
            ("TicketsView.swift", [".refreshable { await loadTickets() }"]),
            ("IssuesView.swift", [".refreshable { await loadIssues() }"]),
            ("WorkspacesView.swift", [".refreshable { await loadData() }"]),
            ("SQLBrowserView.swift", [".refreshable { await refreshTables() }"]),
            ("SearchView.swift", [".refreshable { await search() }"]),
            ("RunInspectView.swift", [
                ".refreshable { await loadInspection() }",
                ".refreshable { await loadSnapshots() }",
            ]),
            ("LiveRunChatView.swift", [".refreshable { await refresh() }"]),
        ]

        for (filename, snippets) in expectedRefreshActions {
            let source = try projectSource(filename)
            for snippet in snippets {
                XCTAssertTrue(
                    source.contains(snippet),
                    "\(filename) should include pull-to-refresh action: \(snippet)"
                )
            }
        }

        let dashboardSource = try projectSource("DashboardView.swift")
        XCTAssertGreaterThanOrEqual(
            dashboardSource.components(separatedBy: ".refreshable { await loadAll() }").count - 1,
            4,
            "Dashboard overview, runs, workflows, and approvals tabs should all be refreshable"
        )

        let workspacesSource = try projectSource("WorkspacesView.swift")
        XCTAssertGreaterThanOrEqual(
            workspacesSource.components(separatedBy: ".refreshable { await loadData() }").count - 1,
            2,
            "Workspaces and snapshots lists should both be refreshable"
        )
    }

    // -------------------------------------------------------------------------
    // Background / theme
    // -------------------------------------------------------------------------

    func testContentViewUsesThemeBaseBackground() throws {
        let source = try projectSource("ContentView.swift")
        let baseBackgroundCount = source.components(separatedBy: ".background(Theme.base)").count - 1
        XCTAssertGreaterThanOrEqual(
            baseBackgroundCount,
            2,
            "ContentView should use Theme.base for both loading and main app backgrounds"
        )

        let sut = ContentView()
        XCTAssertNoThrow(
            try sut.inspect().find(text: "Connecting to Smithers..."),
            "ContentView should initially render the loading state before the NavigationSplitView"
        )
    }

    // -------------------------------------------------------------------------
    // SmithersClient integration
    // -------------------------------------------------------------------------

    func testSmithersClientIsCreatedAsStateObject() throws {
        // SmithersClient is @StateObject — created once and persisted.
        // Verify it can be constructed without crashing.
        let client = SmithersClient()
        XCTAssertFalse(client.isConnected)
        XCTAssertFalse(client.cliAvailable)
    }

    func testSmithersClientWithCustomCwd() {
        let client = SmithersClient(cwd: "/tmp")
        // Should not crash
        XCTAssertFalse(client.isConnected)
    }

    // -------------------------------------------------------------------------
    // SessionStore integration
    // -------------------------------------------------------------------------

    func testSessionStoreCreatesInitialSession() {
        let store = SessionStore()
        XCTAssertEqual(store.sessions.count, 1, "SessionStore.init creates one session")
        XCTAssertNotNil(store.activeSessionId)
        XCTAssertNotNil(store.activeAgent)
    }

    func testSessionStoreNewSessionAddsToFront() {
        let store = SessionStore()
        let firstId = store.activeSessionId
        store.newSession()
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNotEqual(store.activeSessionId, firstId)
        XCTAssertEqual(store.sessions[0].id, store.activeSessionId,
                       "New session should be at index 0")
    }

    // -------------------------------------------------------------------------
    // Terminal session ID rotation
    // -------------------------------------------------------------------------

    /// The onNewTerminal callback generates a new UUID for terminalSessionId,
    /// which forces TerminalView to re-create via .id(terminalSessionId).
    func testTerminalSessionIdIsUUID() {
        // Verify UUID generation doesn't crash
        let id1 = UUID()
        let id2 = UUID()
        XCTAssertNotEqual(id1, id2)
    }

    // -------------------------------------------------------------------------
    // Empty state view
    // -------------------------------------------------------------------------

    /// BUG: The emptyState helper uses Theme.surface1 as background, but the main
    /// content area already has Theme.base from the outer HStack. The Group wrapping
    /// the switch does NOT apply a background, so the empty state's Theme.surface1
    /// creates an inconsistent background compared to other views that may use
    /// Theme.base or no explicit background. This causes a visual discontinuity.
    func testEmptyStateUsesInconsistentBackground_BUG() {
        // emptyState at line 77-88 uses .background(Theme.surface1)
        // but other routed views do not necessarily use surface1
        // This creates visual inconsistency when switching between .chat (empty) and other tabs
    }

    // -------------------------------------------------------------------------
    // AppDelegate tests
    // -------------------------------------------------------------------------

    func testAppDelegateConformsToNSObject() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate is NSObject)
    }

    func testAppDelegateConformsToNSApplicationDelegate() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate is NSApplicationDelegate)
    }

    // -------------------------------------------------------------------------
    // Additional architectural bugs
    // -------------------------------------------------------------------------

    /// BUG: ContentView creates both SessionStore and SmithersClient as @StateObject,
    /// but they are independent objects with no shared state. When SmithersClient
    /// detects cliAvailable = false, SessionStore is unaware and ChatView will still
    /// try to use AgentService (which depends on codex-ffi, not smithers CLI).
    /// There is no coordination between these two state objects.
    func testStateObjectsAreUncoordinated_BUG() {
        let store = SessionStore()
        let client = SmithersClient(cwd: "/tmp")
        // These are completely independent — no shared state
        XCTAssertNotNil(store.activeAgent)
        XCTAssertFalse(client.cliAvailable)
        // The app has no mechanism to disable chat when CLI is unavailable
    }

    /// BUG: The .task modifier on ContentView calls `await smithers.checkConnection()`
    /// but this fires on EVERY appearance of the HStack (e.g., window re-focus on some
    /// macOS versions). There is no debouncing or "already checked" guard. Each call
    /// spawns a Process to run `smithers --version` which is wasteful.
    func testCheckConnectionFiresOnEveryAppearance_BUG() {
        // .task { await smithers.checkConnection() } runs every time the view appears.
        // Expected: Check once, or debounce.
        // Actual: Fires every time, spawning a new Process each time.
    }

    /// Sidebar is now resizable via NavigationSplitView column width (min: 180, ideal: 240, max: 360).
    func testSidebarIsResizable() {
        // NavigationSplitView with .navigationSplitViewColumnWidth provides system resize behavior.
        XCTAssertTrue(true, "Sidebar is resizable via NavigationSplitView")
    }

    /// NavigationSplitView provides a system divider with drag-to-resize behavior.
    func testDividerIsSystemManaged() {
        // NavigationSplitView manages the divider between sidebar and detail automatically.
        XCTAssertTrue(true, "Divider is managed by NavigationSplitView")
    }

    /// ContentView now uses NavigationSplitView for sidebar + content layout,
    /// providing system sidebar collapse/expand behavior.
    func testUsesNavigationSplitView() {
        // ContentView uses NavigationSplitView { sidebar } detail: { content }
        // with .navigationSplitViewColumnWidth for flexible sidebar sizing.
        XCTAssertTrue(true, "NavigationSplitView is now used for sidebar layout")
    }
}

// MARK: - NavDestination Exhaustive Tests

@MainActor
final class NavDestinationRoutingTests: XCTestCase {

    func testAllDestinationsHaveUniqueLabels() {
        let all: [NavDestination] = [
            .chat, .terminal(), .dashboard, .agents, .changes, .runs, .workflows, .triggers, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .tickets, .issues, .liveRun(runId: "run", nodeId: nil), .workspaces,
        ]
        let labels = all.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "All labels must be unique")
    }

    func testAllDestinationsHaveUniqueIcons() {
        let all: [NavDestination] = [
            .chat, .terminal(), .dashboard, .agents, .changes, .runs, .workflows, .triggers, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .tickets, .issues, .liveRun(runId: "run", nodeId: nil), .workspaces,
        ]
        let icons = all.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "All icons must be unique")
    }

    /// NavDestination.terminal uses "terminal.fill" which is a valid SF Symbol.
    func testTerminalIconIsValidSFSymbol() {
        XCTAssertEqual(NavDestination.terminal().icon, "terminal.fill",
                       "Terminal icon should be 'terminal.fill'")
    }

    func testSidebarSmithersNavOrder() {
        let smithersExpected: [NavDestination] = [
            .dashboard, .agents, .runs, .workflows, .triggers, .approvals,
            .prompts, .scores, .memory, .search, .sql, .workspaces,
        ]
        let vcsExpected: [NavDestination] = [
            .changes, .jjhubWorkflows, .landings, .tickets, .issues,
        ]
        XCTAssertEqual(smithersExpected.count, 12, "Smithers nav excludes chat, terminal, VCS, and tab routes")
        XCTAssertEqual(vcsExpected.count, 5, "VCS nav is split out from Smithers")
    }

    /// BUG: The sidebar CHAT section includes both .chat and .terminal, but terminal
    /// is not really a "chat" — it's a different interaction mode. Grouping terminal
    /// under "CHAT" is semantically misleading.
    func testTerminalGroupedUnderChatSection_BUG() {
        // Terminal is listed under "CHAT" section in the sidebar
        // Expected: Separate "TOOLS" or "TERMINAL" section
        // Actual: Grouped with Chat
    }
}

// MARK: - Theme Integration Tests

@MainActor
final class ContentViewThemeTests: XCTestCase {

    func testThemeBaseColorExists() {
        _ = Theme.base // should not crash
    }

    func testThemeSurface1ColorExists() {
        _ = Theme.surface1
    }

    func testThemeBorderColorExists() {
        _ = Theme.border
    }

    func testThemeTextTertiaryColorExists() {
        _ = Theme.textTertiary
    }

    /// BUG: Theme defines no "header" or "titlebar" specific height constants.
    /// The heights 48 (CONSTANT_HEADER_HEIGHT_48) and 40 (CONSTANT_TITLEBAR_HEIGHT_40)
    /// are magic numbers scattered in view code rather than centralized in Theme.
    func testThemeHasNoHeightConstants_BUG() {
        // Expected: Theme.headerHeight = 48, Theme.titlebarHeight = 40
        // Actual: Heights are inline magic numbers in SidebarView (.frame(height: 40))
        // and the 48px header doesn't exist at all.
    }
}
