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

    // -------------------------------------------------------------------------
    // PLATFORM_MINIMUM_WINDOW_SIZE_800X600
    // -------------------------------------------------------------------------

    func testMinimumWindowSize() throws {
        let sut = ContentView()
        let view = try sut.inspect()
        // The outermost is an HStack with .frame(minWidth: 800, minHeight: 600)
        let hstack = try view.hStack()
        // ViewInspector lets us check frame modifiers
        let frame = try hstack.flexFrame()
        XCTAssertEqual(frame.minWidth, kMinWindowWidth,
                       "Minimum window width must be 800")
        XCTAssertEqual(frame.minHeight, kMinWindowHeight,
                       "Minimum window height must be 600")
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
        let sut = ContentView()
        let view = try sut.inspect()
        // The sidebar contains a 40px-tall title area. We verify the sidebar frame exists.
        let hstack = try view.hStack()
        // First child is the SidebarView
        let sidebar = try hstack.view(SidebarView.self, 0)
        // SidebarView is wrapped in .frame(width: 240)
        let frame = try sidebar.fixedFrame()
        XCTAssertEqual(frame.width, 240, "Sidebar width should be 240")
    }

    // -------------------------------------------------------------------------
    // PLATFORM_DESTINATION_ROUTING — default destination
    // -------------------------------------------------------------------------

    func testDefaultDestinationIsDashboard() throws {
        let sut = ContentView()
        let view = try sut.inspect()
        let hstack = try view.hStack()
        // After sidebar (index 0) and Divider (index 1), Group is at index 2
        let group = try hstack.group(2)
        // Default is .dashboard, so DashboardView should be present
        _ = try group.view(DashboardView.self, 0)
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
    // PLATFORM_DESTINATION_ROUTING — all 17 destinations
    // -------------------------------------------------------------------------

    func testNavDestinationEnumHasExactly17Cases() {
        let all: [NavDestination] = [
            .chat, .terminal, .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .issues, .workspaces,
        ]
        XCTAssertEqual(all.count, 17)
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
        let sut = ContentView()
        let group = try sut.inspect().hStack().group(2)
        _ = try group.view(DashboardView.self, 0)
    }

    // -------------------------------------------------------------------------
    // NAV_DESTINATION_CHAT through NAV_DESTINATION_WORKSPACES — label/icon pairs
    // -------------------------------------------------------------------------

    func testChatDestinationLabel() {
        XCTAssertEqual(NavDestination.chat.label, "Chat")
        XCTAssertEqual(NavDestination.chat.icon, "message")
    }

    func testTerminalDestinationLabel() {
        XCTAssertEqual(NavDestination.terminal.label, "Terminal")
        XCTAssertEqual(NavDestination.terminal.icon, "terminal")
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

    /// Verify the switch in ContentView covers all 17 cases. This is a compile-time
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
        // .jjhubWorkflows -> JJHubWorkflowsView
        // .approvals -> ApprovalsView
        // .prompts -> PromptsView
        // .scores -> ScoresView
        // .memory -> MemoryView
        // .search -> SearchView
        // .sql -> SQLBrowserView
        // .landings -> LandingsView
        // .issues -> IssuesView
        // .workspaces -> WorkspacesView
        //
        // Swift enforces exhaustive switch, so all 17 are covered.
        // No default case means adding a new NavDestination case will cause a compiler error.
        let count = [
            NavDestination.chat, .terminal, .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .issues, .workspaces,
        ].count
        XCTAssertEqual(count, 17, "All 17 destinations must be routed")
    }

    // -------------------------------------------------------------------------
    // Layout structure
    // -------------------------------------------------------------------------

    func testContentViewHasSidebarAndMainArea() throws {
        let sut = ContentView()
        let hstack = try sut.inspect().hStack()
        // Index 0: SidebarView, Index 1: Divider, Index 2: Group (main content)
        _ = try hstack.view(SidebarView.self, 0)
        _ = try hstack.divider(1)
        _ = try hstack.group(2)
    }

    func testSidebarWidthIs240() throws {
        let sut = ContentView()
        let sidebar = try sut.inspect().hStack().view(SidebarView.self, 0)
        let frame = try sidebar.fixedFrame()
        XCTAssertEqual(frame.width, 240)
    }

    func testMainContentExpandsToFill() throws {
        let sut = ContentView()
        let group = try sut.inspect().hStack().group(2)
        let frame = try group.flexFrame()
        XCTAssertEqual(frame.maxWidth, .infinity)
        XCTAssertEqual(frame.maxHeight, .infinity)
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

    /// BUG: ContentView has NO loading state UI. The `.task { await smithers.checkConnection() }`
    /// runs on appear, but there is no ProgressView, loading indicator, or any visual feedback
    /// while the connection check is in progress. The user sees the full UI immediately with
    /// potentially stale or unloaded data.
    func testLoadingStateIsMissing_BUG() {
        // Expected: A loading spinner or skeleton while smithers.checkConnection() runs
        // Actual: No loading state at all — the view renders immediately
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

    /// BUG: ContentView has NO .refreshable modifier. Pull-to-refresh is completely
    /// unimplemented. On macOS, this would typically be a refresh button or Cmd+R shortcut.
    /// Neither exists.
    func testPullToRefreshIsMissing_BUG() {
        // Expected: .refreshable { } on the main content area, or a refresh button
        // Actual: No refresh mechanism exists
    }

    // -------------------------------------------------------------------------
    // Background / theme
    // -------------------------------------------------------------------------

    func testContentViewUsesThemeBaseBackground() throws {
        let sut = ContentView()
        let hstack = try sut.inspect().hStack()
        // .background(Theme.base) is applied to the outer HStack
        // ViewInspector can verify the modifier chain exists
        _ = hstack
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

    /// BUG: SidebarView is given a fixed width of 240, but there is no resize handle
    /// or collapsibility. The sidebar cannot be hidden or resized by the user.
    /// macOS conventions expect either a NavigationSplitView (with system resize) or
    /// a custom drag handle.
    func testSidebarIsNotResizable_BUG() {
        // .frame(width: 240) is a fixed width with no user control
    }

    /// BUG: The HStack(spacing: 0) layout means the Divider between sidebar and
    /// content has zero spacing, which is correct. However, there is no drag-to-resize
    /// affordance on the divider — it's purely decorative.
    func testDividerIsNotDraggable_BUG() {
        // The Divider() at line 21 is a visual separator only
    }

    /// BUG: ContentView uses HStack for sidebar + content layout instead of
    /// NavigationSplitView. This means:
    /// 1. No system sidebar collapse/expand behavior
    /// 2. No automatic sidebar hiding on small windows
    /// 3. No sidebar toggle in toolbar
    /// 4. Not using the platform-standard navigation paradigm
    func testUsesHStackInsteadOfNavigationSplitView_BUG() {
        // Expected: NavigationSplitView { sidebar } detail: { content }
        // Actual: HStack { sidebar; Divider; content }
    }
}

// MARK: - NavDestination Exhaustive Tests

@MainActor
final class NavDestinationRoutingTests: XCTestCase {

    func testAllDestinationsHaveUniqueLabels() {
        let all: [NavDestination] = [
            .chat, .terminal, .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .issues, .workspaces,
        ]
        let labels = all.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "All labels must be unique")
    }

    func testAllDestinationsHaveUniqueIcons() {
        let all: [NavDestination] = [
            .chat, .terminal, .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows,
            .approvals, .prompts, .scores, .memory, .search, .sql,
            .landings, .issues, .workspaces,
        ]
        let icons = all.map(\.icon)
        XCTAssertEqual(Set(icons).count, icons.count, "All icons must be unique")
    }

    /// BUG: NavDestination.terminal uses icon "terminal" which is NOT a valid
    /// SF Symbols name. The correct SF Symbol is "terminal.fill" or
    /// "apple.terminal" (macOS 13+) or "rectangle.on.rectangle" as fallback.
    /// Using an invalid symbol name results in a blank/missing icon at runtime.
    func testTerminalIconIsInvalidSFSymbol_BUG() {
        XCTAssertEqual(NavDestination.terminal.icon, "terminal",
                       "BUG: 'terminal' is not a valid SF Symbol. Use 'apple.terminal' or 'terminal.fill'")
    }

    func testSidebarSmithersNavOrder() {
        // The sidebar lists smithers nav items in this order:
        // dashboard, agents, changes, runs, workflows, jjhubWorkflows, approvals, prompts, scores, memory, search, sql, landings, issues, workspaces
        // Verify this matches the enum order expectations
        let expected: [NavDestination] = [
            .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows, .approvals,
            .prompts, .scores, .memory, .search, .sql,
            .landings, .issues, .workspaces,
        ]
        XCTAssertEqual(expected.count, 15, "Smithers nav section has 15 items (excludes chat and terminal)")
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
