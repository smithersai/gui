// ContentView.swift
//
// Ticket 0122 decomposed this file. Compared to pre-refactor, ContentView
// no longer owns:
//   - the app entry point (`@main SmithersApp`) → `macos/Sources/Smithers/Smithers.AppDelegate.swift`
//   - the app delegate (`AppDelegate`)          → `macos/Sources/Smithers/Smithers.AppDelegate.swift`
//   - the route/state model (`NavDestination`)  → `SharedNavigation.swift`
//   - the detail route switch (`detailContent`) → `DetailRouter.swift`
//   - the loading/bootstrap stage                → `BootstrapStage.swift`
//   - the macOS `NavigationSplitView` shell       → `macos/Sources/Smithers/Smithers.ContentShell.macOS.swift`
//   - AppKit-only actions (open-panel / workspace-open / app-terminate /
//     pasteboard-write)                             → `macos/Sources/Smithers/Smithers.PlatformAdapters.swift`
//
// What stays here is the composition root: `ContentView` wires the shared
// navigation store, palette state, keyboard shortcut controller, and
// per-destination callbacks into the macOS shell via `MacOSContentShell`.
// The iOS shell is a separate composition in `ios/Sources/SmithersiOS/`.

import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.vimModeEnabled) private var vimModeEnabled = false
    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @AppStorage(AppPreferenceKeys.guiControlSidebarEnabled) private var guiControlSidebarEnabled = false
    @AppStorage(AppPreferenceKeys.externalAgentUnsafeFlagsEnabled) private var externalAgentUnsafeFlagsEnabled = false
    @AppStorage(AppPreferenceKeys.browserSearchEngine) private var browserSearchEngine = BrowserSearchEngine.duckDuckGo.rawValue
    @StateObject private var shortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var neovimPath: String? = NeovimDetector.executablePath()

    private var neovimAvailable: Bool {
        neovimPath != nil
    }

    private var neovimToggle: Binding<Bool> {
        Binding(
            get: { vimModeEnabled && neovimAvailable },
            set: { enabled in
                vimModeEnabled = enabled && neovimAvailable
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    developerToolsSection
                    operatorFeatureSection
                    externalAgentSafetySection
                    browserSearchSection
                    neovimSection
                    shortcutsSection
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface1)
        .onAppear {
            refreshNeovimPath()
        }
        .accessibilityIdentifier("settings.root")
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .border(Theme.border, edges: [.bottom])
    }

    private var developerToolsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer tools")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Show the developer debug panel and related diagnostics.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $developerToolsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.developerTools.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.developerTools.section")
    }

    private var operatorFeatureSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Smithers operator")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Work in progress: let an agent control the Smithers UI itself for you.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $guiControlSidebarEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.guiControlSidebar.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.guiControlSidebar.section")
    }

    private var neovimSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vim mode")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Open files in Neovim instead of the built-in editor.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: neovimToggle)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!neovimAvailable)
                    .accessibilityIdentifier("settings.neovim.toggle")
            }

            Divider().background(Theme.border)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(neovimAvailable ? "Detected" : "Not detected")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(neovimAvailable ? Theme.success : Theme.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((neovimAvailable ? Theme.success : Theme.warning).opacity(0.14))
                    .cornerRadius(5)

                Text(neovimPath ?? "Install nvim or add it to PATH.")
                    .font(.system(size: 11, design: neovimAvailable ? .monospaced : .default))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(2)

                Spacer()

                Button("Refresh") {
                    refreshNeovimPath()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("settings.neovim.refresh")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.neovim.section")
    }

    private var externalAgentSafetySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.warning)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("External agent unsafe flags")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Opt in to append --dangerously-skip-permissions / --yolo when launching external agent CLIs (Claude, Codex, Gemini, Kimi).")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Toggle("", isOn: $externalAgentUnsafeFlagsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.externalAgentUnsafeFlags.toggle")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.externalAgentUnsafeFlags.section")
    }

    private var browserSearchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Browser search engine")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Choose the search fallback used by browser surfaces when the address is plain text.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Picker("Search engine", selection: $browserSearchEngine) {
                    ForEach(BrowserSearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                .accessibilityIdentifier("settings.browserSearchEngine.picker")
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.browserSearchEngine.section")
    }

    private var shortcutsSection: some View {
        let _ = shortcutSettingsObserver.revision
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "keyboard")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard shortcuts")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text("Rebind app shortcuts or manage them in settings.json.")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }

                Spacer()

                Button("Open settings.json") {
                    openShortcutSettingsFile()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("settings.shortcuts.openSettingsFile")
            }

            Divider().background(Theme.border)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutSettingsRow(action: action)
                    if action != ShortcutAction.allCases.last {
                        Divider().background(Theme.border.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface2)
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        .accessibilityIdentifier("settings.shortcuts.section")
    }

    private func refreshNeovimPath() {
        let detectedPath = NeovimDetector.executablePath()
        neovimPath = detectedPath
        if detectedPath == nil {
            vimModeEnabled = false
        }
    }

    private func openShortcutSettingsFile() {
        let fileURL = KeyboardShortcutSettings.settingsFileURLForEditing()
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let template = """
            {
              "shortcuts": {
              }
            }
            """
            try? template.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        #if os(macOS)
        PlatformAdapters.open(fileURL)
        #endif
    }
}

#if os(macOS)
private struct ShortcutSettingsRow: View {
    let action: ShortcutAction
    @State private var shortcut: StoredShortcut

    init(action: ShortcutAction) {
        self.action = action
        _shortcut = State(initialValue: KeyboardShortcutSettings.current(for: action))
    }

    private var managedByFile: Bool {
        KeyboardShortcutSettings.isManagedBySettingsFile(action)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                if let subtitle = KeyboardShortcutSettings.settingsFileManagedSubtitle(for: action) {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }
            }

            Spacer(minLength: 16)

            KeyboardShortcutRecorder(
                shortcut: $shortcut,
                displayString: { action.displayedShortcutString(for: $0) },
                allowsModifierlessShortcut: action.isPrefixOnly,
                isDisabled: managedByFile
            )
            .frame(width: 150, height: 24)

            Button("Reset") {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(managedByFile ? Theme.textTertiary : Theme.accent)
            .disabled(managedByFile)
        }
        .padding(.vertical, 9)
        .onChange(of: shortcut) { _, newValue in
            KeyboardShortcutSettings.setShortcut(newValue, for: action)
        }
        .onReceive(NotificationCenter.default.publisher(for: KeyboardShortcutSettings.didChangeNotification)) { _ in
            let latest = KeyboardShortcutSettings.current(for: action)
            if latest != shortcut {
                shortcut = latest
            }
        }
        .accessibilityIdentifier("settings.shortcuts.\(action.rawValue)")
    }
}
#endif

// MARK: - ContentView

/// macOS composition root. ContentView wires the shared navigation store,
/// the palette state, and per-destination callbacks into `MacOSContentShell`.
/// The iOS target composes `IOSContentShell` directly from `SmithersApp.swift`.
struct ContentView: View {
    @StateObject private var store: SessionStore
    @StateObject private var smithers: SmithersClient
    @StateObject private var fileSearchIndex: WorkspaceFileSearchIndex
    @StateObject private var smithersUpgrader: SmithersUpgrader

    init(workspacePath: String? = nil) {
        let resolved = Smithers.CWD.resolve(workspacePath)
        _store = StateObject(wrappedValue: SessionStore(workingDirectory: resolved))
        _smithers = StateObject(wrappedValue: SmithersClient(cwd: resolved))
        _fileSearchIndex = StateObject(wrappedValue: WorkspaceFileSearchIndex(rootPath: resolved))
        _smithersUpgrader = StateObject(wrappedValue: SmithersUpgrader(cwd: resolved))
    }

    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @AppStorage(AppPreferenceKeys.guiControlSidebarEnabled) private var guiControlSidebarEnabled = false
    @State private var destination: NavDestination = .home
    @State private var navHistory: [NavDestination] = [.home]
    @State private var navHistoryIndex: Int = 0
    @State private var isNavigatingThroughHistory = false
    @State private var navigationSplitVisibility: NavigationSplitViewVisibility = .all
    #if os(macOS)
    @State private var runSnapshotsSelection: RunSnapshotsRouteSelection?
    #endif
    @State private var workflowsInitialID: String?
    @State private var changesInitialID: String?
    @State private var developerDebugPanelVisible = false
    @State private var guiControlSidebarExpanded = false
    @State private var pendingTerminalCloseId: String?
    @State private var pendingTerminalCloseTitle: String = ""
    @State private var commandPaletteVisible = false
    @State private var commandPaletteSeedQuery = ""
    @State private var detailRefreshNonce = 0
    @State private var keyboardShortcutController = KeyboardShortcutController()
    @StateObject private var shortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var paletteWorkflows: [Workflow] = []
    @State private var palettePrompts: [SmithersPrompt] = []
    @State private var paletteIssues: [SmithersIssue] = []
    @State private var paletteTickets: [Ticket] = []
    @State private var paletteLandings: [Landing] = []
    @State private var paletteAgents: [SmithersAgent] = []
    @State private var paletteDataLastRefreshAt: Date = .distantPast
    @State private var paletteDataRefreshTask: Task<Void, Never>?
    @State private var commandPaletteItemsRevision = 0
    @State private var quickLaunchState: QuickLaunchState?

    private struct QuickLaunchState: Identifiable {
        let id = UUID()
        let workflow: Workflow
        let prompt: String
        var phase: Phase
        enum Phase {
            case parsing
            case confirming(fields: [WorkflowLaunchField], inputs: [String: JSONValue], notes: String)
            case error(String)
        }
    }

    private var defaultDestination: NavDestination {
        .home
    }

    private var activeTerminalId: String? {
        if case .terminal(let id) = destination { return id }
        return nil
    }

    private var paletteSlashCommands: [SlashCommandItem] {
        let dynamic = SlashCommandRegistry.dynamicCommands(
            workflows: paletteWorkflows,
            prompts: palettePrompts
        )
        return SlashCommandRegistry.builtInCommands + dynamic.workflows + dynamic.prompts
    }

    private var shouldShowSmithersVersionWarning: Bool {
        switch destination {
        case .dashboard,
             .agents,
             .runs,
             .snapshots,
             .workflows,
             .triggers,
             .approvals,
             .prompts,
             .scores,
             .memory,
             .search,
             .sql,
             .workspaces,
             .logs,
             .liveRun,
             .runInspect:
            return true
        default:
            return false
        }
    }

    var body: some View {
        #if os(macOS)
        BootstrapStageView(smithers: smithers, onReady: handleBootstrapReady) {
            macOSShell
        }
        #else
        // On iOS, ContentView is not used; the iOS target composes
        // `IOSContentShell` directly from `SmithersApp.swift`.
        EmptyView()
        #endif
    }

    #if os(macOS)
    private var macOSShell: some View {
        MacOSContentShell(
            store: store,
            smithers: smithers,
            smithersUpgrader: smithersUpgrader,
            destination: $destination,
            navigationSplitVisibility: $navigationSplitVisibility,
            runSnapshotsSelection: $runSnapshotsSelection,
            developerDebugPanelVisible: $developerDebugPanelVisible,
            developerToolsEnabled: developerToolsEnabled,
            guiControlSidebarEnabled: guiControlSidebarEnabled,
            guiControlSidebarExpanded: $guiControlSidebarExpanded,
            activeTerminalId: activeTerminalId,
            shouldShowSmithersVersionWarning: shouldShowSmithersVersionWarning,
            detailRefreshNonce: detailRefreshNonce,
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            goBack: goBack,
            goForward: goForward,
            onOpenNewTabPicker: { openCommandPalette(prefill: NewTabPaletteCatalog.expandedQuery) },
            onAppShortcutCommand: handleKeyboardShortcutCommand,
            onRequestTerminalClose: requestTerminalClose,
            onTerminalProcessExited: handleTerminalProcessExited,
            onDropMarkdown: handleMarkdownFileDrop,
            onHandleNavigation: handleNavigation,
            onDestinationChanged: { newValue in recordHistory(newValue) },
            onSmithersActionNotification: handleSmithersActionNotification,
            onAppear: handleShellAppear,
            onDisappear: handleShellDisappear,
            onUpgradeSmithers: {
                Task {
                    await smithersUpgrader.upgrade()
                    _ = await smithers.getOrchestratorVersion()
                }
            },
            versionProvider: { await smithers.getOrchestratorVersion() },
            terminateTerminalBinding: terminateTerminalConfirmationBinding,
            pendingTerminalCloseTitle: pendingTerminalCloseTitle,
            confirmTerminalClose: confirmTerminalClose,
            clearPendingTerminalClose: clearPendingTerminalClose,
            detailContent: {
                DetailRouterView(
                    store: store,
                    smithers: smithers,
                    destination: destination,
                    workflowsInitialID: workflowsInitialID,
                    changesInitialID: changesInitialID,
                    actions: detailRouterActions
                )
            },
            commandPaletteOverlay: {
                if commandPaletteVisible {
                    CommandPaletteView(
                        initialQuery: commandPaletteSeedQuery,
                        itemsRevision: commandPaletteItemsRevision,
                        itemsProvider: { query in
                            commandPaletteItems(for: query)
                        },
                        onExecute: { item, query in
                            executePaletteItem(item, rawQuery: query)
                        },
                        onDismiss: {
                            commandPaletteVisible = false
                        }
                    )
                    .transition(.opacity)
                }
            },
            quickLaunchOverlay: {
                if let state = quickLaunchState {
                    quickLaunchOverlay(state: state)
                        .transition(.opacity)
                }
            },
            hiddenShortcutButtons: {
                hiddenShortcutButtons
            }
        )
    }

    private var detailRouterActions: DetailRouterActions {
        DetailRouterActions(
            navigate: { destination = $0 },
            requestTerminalClose: requestTerminalClose,
            handleKeyboardShortcutCommand: handleKeyboardShortcutCommand,
            openTerminalCommandTab: openTerminalCommandTab(command:workingDirectory:name:),
            openRunTabForRun: openRunTab(run:nodeId:),
            openRunTab: { runId, title, preview, nodeId in
                openRunTab(runId: runId, title: title, preview: preview, nodeId: nodeId)
            },
            setWorkflowsInitialID: { workflowsInitialID = $0 },
            setChangesInitialID: { changesInitialID = $0 },
            presentRunSnapshotsSheet: { run in
                runSnapshotsSelection = RunSnapshotsRouteSelection(runId: run.runId, workflowName: run.workflowName)
            },
            autoPopulateActiveRunTabs: { runs in
                store.autoPopulateActiveRunTabs(runs)
            },
            updateRunTab: { store.updateRunTab(with: $0) },
            commandPaletteItems: { commandPaletteItems(for: $0) },
            executePaletteItem: { item, rawQuery in
                executePaletteItem(item, rawQuery: rawQuery)
            }
        )
    }

    private func handleBootstrapReady() {
        let environment = ProcessInfo.processInfo.environment
        if UITestSupport.isEnabled,
           environment["SMITHERS_GUI_UITEST_OPEN_TREE_ON_LAUNCH"] == "1" {
            destination = .liveRun(runId: "ui-run-active-001", nodeId: nil)
        }
    }

    private func handleShellAppear() {
        installKeyboardShortcutMonitor()
        fileSearchIndex.updateRootPath(store.workspaceRootPath)
        fileSearchIndex.ensureLoaded()
    }

    private func handleShellDisappear() {
        keyboardShortcutController.uninstall()
        paletteDataRefreshTask?.cancel()
        paletteDataRefreshTask = nil
    }

    @ViewBuilder
    private var hiddenShortcutButtons: some View {
        VStack(spacing: 0) {
            Button("Open Launcher") {
                openCommandPalette(prefill: "")
            }
            .appKeyboardShortcut(.commandPalette)
            .accessibilityIdentifier("shortcut.openLauncher")
            .uiTestShortcutAnchor()

            Button("Open Command Palette") {
                openCommandPalette(prefill: ">")
            }
            .appKeyboardShortcut(.commandPaletteCommandMode)
            .accessibilityIdentifier("shortcut.commandPalette")
            .uiTestShortcutAnchor()

            Button("Open Ask AI Launcher") {
                openCommandPalette(prefill: "?")
            }
            .appKeyboardShortcut(.commandPaletteAskAI)
            .accessibilityIdentifier("shortcut.askAI")
            .uiTestShortcutAnchor()

            Button("New Terminal Workspace") {
                createNewTerminalTab()
            }
            .appKeyboardShortcut(.newTerminal)
            .accessibilityIdentifier("shortcut.newTerminal")
            .uiTestShortcutAnchor()

            Button("Reopen Closed Workspace") {
                AppNotifications.shared.post(
                    title: "Workspaces",
                    message: "Reopen closed workspace is not available yet.",
                    level: .info
                )
            }
            .appKeyboardShortcut(.reopenClosedTab)
            .accessibilityIdentifier("shortcut.reopenWorkspace")
            .uiTestShortcutAnchor()

            Button("Navigate Back") {
                goBack()
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(!canGoBack)
            .accessibilityIdentifier("shortcut.navBack")
            .uiTestShortcutAnchor()

            Button("Navigate Forward") {
                goForward()
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(!canGoForward)
            .accessibilityIdentifier("shortcut.navForward")
            .uiTestShortcutAnchor()

            Button("Previous Visible Workspace") {
                moveVisibleTab(offset: -1)
            }
            .appKeyboardShortcut(.prevSidebarTab)
            .accessibilityIdentifier("shortcut.previousWorkspace")
            .uiTestShortcutAnchor()

            Button("Next Visible Workspace") {
                moveVisibleTab(offset: 1)
            }
            .appKeyboardShortcut(.nextSidebarTab)
            .accessibilityIdentifier("shortcut.nextWorkspace")
            .uiTestShortcutAnchor()

            Button("Find in Context") {
                handleFindShortcut()
            }
            .appKeyboardShortcut(.find)
            .accessibilityIdentifier("shortcut.find")
            .uiTestShortcutAnchor()

            Button("Global Search") {
                destination = .search
            }
            .appKeyboardShortcut(.globalSearch)
            .accessibilityIdentifier("shortcut.globalSearch")
            .uiTestShortcutAnchor()

            Button("Refresh Current View") {
                refreshCurrentView()
            }
            .appKeyboardShortcut(.refreshCurrentView)
            .accessibilityIdentifier("shortcut.refresh")
            .uiTestShortcutAnchor()

            Button("Cancel Current Operation") {
                cancelCurrentOperation()
            }
            .appKeyboardShortcut(.cancelCurrentOperation)
            .accessibilityIdentifier("shortcut.cancel")
            .uiTestShortcutAnchor()

            Button("Shortcut Cheat Sheet") {
                openCommandPalette(prefill: ">shortcut")
            }
            .appKeyboardShortcut(.showShortcutCheatSheet)
            .accessibilityIdentifier("shortcut.cheatSheet")
            .uiTestShortcutAnchor()

            ForEach(1...9, id: \.self) { index in
                Button("Switch to Workspace \(index)") {
                    switchVisibleTab(at: index - 1)
                }
                .appNumberedKeyboardShortcut(.selectWorkspaceByNumber, digit: index)
                .accessibilityIdentifier("shortcut.switchWorkspace.\(index)")
                .uiTestShortcutAnchor()
            }

            if developerToolsEnabled {
                Button("Toggle Developer Debug") {
                    toggleDeveloperDebugPanel()
                }
                .appKeyboardShortcut(.toggleDeveloperDebug)
                .accessibilityIdentifier("shortcut.toggleDeveloperDebug")
                .uiTestShortcutAnchor()
            }

            if UITestSupport.isEnabled {
                ForEach(uiTestNavDestinations, id: \.label) { item in
                    Button(item.label) {
                        destination = item.destination
                    }
                    .accessibilityIdentifier("nav.\(item.label.replacingOccurrences(of: " ", with: ""))")
                    .uiTestShortcutAnchor()
                }
            }
        }
        .id(shortcutSettingsObserver.revision)
    }

    private var uiTestNavDestinations: [(label: String, destination: NavDestination)] {
        [
            ("Home", .home),
            ("Dashboard", .dashboard),
            ("VCSDashboard", .vcsDashboard),
            ("Agents", .agents),
            ("Changes", .changes),
            ("Runs", .runs),
            ("Snapshots", .snapshots),
            ("Workflows", .workflows),
            ("Triggers", .triggers),
            ("JJHub Workflows", .jjhubWorkflows),
            ("Approvals", .approvals),
            ("Prompts", .prompts),
            ("Scores", .scores),
            ("Memory", .memory),
            ("Search", .search),
            ("SQL Browser", .sql),
            ("Landings", .landings),
            ("Tickets", .tickets),
            ("Issues", .issues),
            ("Workspaces", .workspaces),
            ("Logs", .logs),
            ("Terminal", .terminal()),
        ]
    }

    private func installKeyboardShortcutMonitor() {
        keyboardShortcutController.install(
            onCommand: { command in
                handleKeyboardShortcutCommand(command)
            },
            focusState: {
                let window = NSApp.keyWindow
                return KeyboardShortcutFocusState(
                    textInputFocused: KeyboardShortcutController.isTextInputFocused(window: window),
                    terminalFocused: KeyboardShortcutController.isTerminalFocused(window: window),
                    paletteVisible: commandPaletteVisible
                )
            }
        )
    }

    private func handleKeyboardShortcutCommand(_ command: KeyboardShortcutCommand) {
        switch command {
        case .shortcut(let action):
            handleShortcutAction(action)
        case .numbered(let action, let digit):
            handleNumberedShortcut(action, digit: digit)
        case .palette(let action):
            executePaletteAction(action, rawQuery: "")
        }
    }

    private func handleNumberedShortcut(_ action: ShortcutAction, digit: Int) {
        switch action {
        case .selectWorkspaceByNumber:
            switchVisibleTab(at: digit - 1)
        case .selectSurfaceByNumber:
            currentTerminalWorkspace()?.focusSurface(at: digit - 1)
        default:
            break
        }
    }

    private func handleShortcutAction(_ action: ShortcutAction) {
        switch action {
        case .commandPalette:
            if destination != .home { openCommandPalette(prefill: "") }
        case .commandPaletteCommandMode:
            if destination != .home { openCommandPalette(prefill: ">") }
        case .commandPaletteAskAI:
            if destination != .home { openCommandPalette(prefill: "?") }
        case .newTerminal:
            createNewTerminalTab()
        case .reopenClosedTab:
            AppNotifications.shared.post(title: "Tabs", message: "Reopen closed tab is not available yet.", level: .info)
        case .closeCurrentTab:
            closeCurrentTab()
        case .nextSidebarTab:
            moveVisibleTab(offset: 1)
        case .prevSidebarTab:
            moveVisibleTab(offset: -1)
        case .selectWorkspaceByNumber:
            break
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .toggleSidebar:
            toggleSidebar()
        case .splitRight:
            if !splitFocused(axis: .horizontal, kind: .terminal) {
                createNewTerminalTab()
            }
        case .splitDown:
            if !splitFocused(axis: .vertical, kind: .terminal), developerToolsEnabled {
                toggleDeveloperDebugPanel()
            }
        case .focusLeft, .focusUp:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: -1)
        case .focusRight, .focusDown:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: 1)
        case .toggleSplitZoom:
            AppNotifications.shared.post(title: "Workspace", message: "Split zoom is not available yet.", level: .info)
        case .nextSurface:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: 1)
        case .prevSurface:
            currentTerminalWorkspace()?.focusAdjacentSurface(offset: -1)
        case .selectSurfaceByNumber:
            break
        case .renameWorkspace:
            AppNotifications.shared.post(title: "Workspace", message: "Rename from keyboard is not available yet.", level: .info)
        case .renameSurface:
            AppNotifications.shared.post(title: "Workspace", message: "Rename surface from keyboard is not available yet.", level: .info)
        case .jumpToUnread:
            jumpToLatestUnreadSurface()
        case .triggerFlash:
            SurfaceNotificationStore.shared.flashFocusedSurface()
        case .showNotifications:
            showNotificationSummary()
        case .toggleFullScreen:
            PlatformAdapters.toggleFullScreen()
        case .focusBrowserAddressBar:
            focusBrowserAddressBar()
        case .browserBack:
            performFocusedBrowserAction { $0.goBack() }
        case .browserForward:
            performFocusedBrowserAction { $0.goForward() }
        case .browserReload:
            if !performFocusedBrowserAction({ $0.reload() }) {
                refreshCurrentView()
            }
        case .find:
            handleFindShortcut()
        case .findNext:
            AppNotifications.shared.post(title: "Find", message: "Find next is not available in this view.", level: .info)
        case .findPrevious:
            AppNotifications.shared.post(title: "Find", message: "Find previous is not available in this view.", level: .info)
        case .hideFind:
            destination = .search
        case .useSelectionForFind:
            AppNotifications.shared.post(title: "Find", message: "Use selection for find is not available in this view.", level: .info)
        case .openBrowser:
            if !splitFocused(axis: .horizontal, kind: .browser) {
                AppNotifications.shared.post(title: "Browser", message: "Open a terminal workspace before adding a browser surface.", level: .info)
            }
        case .globalSearch:
            destination = .search
        case .refreshCurrentView:
            refreshCurrentView()
        case .cancelCurrentOperation:
            cancelCurrentOperation()
        case .showShortcutCheatSheet:
            openCommandPalette(prefill: ">shortcut")
        case .linearNavigationPrefix, .tmuxPrefix:
            break
        }
    }

    private func openCommandPalette(prefill: String) {
        commandPaletteSeedQuery = prefill
        commandPaletteVisible = true
        fileSearchIndex.updateRootPath(store.workspaceRootPath)
        fileSearchIndex.ensureLoaded()
        refreshPaletteDataIfNeeded()
    }

    private func refreshPaletteDataIfNeeded(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(paletteDataLastRefreshAt) < 30 {
            return
        }

        paletteDataLastRefreshAt = now
        paletteDataRefreshTask?.cancel()
        paletteDataRefreshTask = Task {
            async let workflowsTask = smithers.listWorkflows()
            async let promptsTask = smithers.listPrompts()
            async let issuesTask = smithers.listIssues(state: "open")
            async let ticketsTask = smithers.listTickets()
            async let landingsTask = smithers.listLandings(state: "open")
            async let agentsTask = smithers.listAgents()

            let workflows = (try? await workflowsTask) ?? []
            let prompts = (try? await promptsTask) ?? []
            let issues = (try? await issuesTask) ?? []
            let tickets = (try? await ticketsTask) ?? []
            let landings = (try? await landingsTask) ?? []
            let agents = (try? await agentsTask) ?? []

            guard !Task.isCancelled else { return }
            paletteWorkflows = workflows
            palettePrompts = prompts
            paletteIssues = issues
            paletteTickets = tickets
            paletteLandings = landings
            paletteAgents = agents
            commandPaletteItemsRevision += 1
        }
    }

    private func commandPaletteItems(for rawQuery: String) -> [CommandPaletteItem] {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        let tabQuery = parsed.mode == .openAnything ? parsed.searchText : ""
        let fileQuery = (parsed.mode == .openAnything || parsed.mode == .mentionFile) ? parsed.searchText : ""

        let context = CommandPaletteContext(
            destination: destination,
            sidebarTabs: store.sidebarTabs(matching: tabQuery),
            runTabs: store.runTabs,
            workflows: paletteWorkflows,
            prompts: palettePrompts,
            issues: paletteIssues,
            tickets: paletteTickets,
            landings: paletteLandings,
            slashCommands: paletteSlashCommands,
            files: fileSearchIndex.matches(for: fileQuery),
            developerToolsEnabled: developerToolsEnabled
        )

        let baseItems = CommandPaletteBuilder.items(for: rawQuery, context: context)
        return ContentViewCommandPaletteModel.items(
            for: rawQuery,
            baseItems: baseItems,
            agents: paletteAgents
        )
    }

    private func executePaletteItem(_ item: CommandPaletteItem, rawQuery: String) {
        if let followUpQuery = ContentViewCommandPaletteModel.followUpQuery(
            afterSelecting: item,
            rawQuery: rawQuery
        ) {
            openCommandPalette(prefill: followUpQuery)
            return
        }
        commandPaletteVisible = false
        executePaletteAction(item.action, rawQuery: rawQuery)
    }

    @ViewBuilder
    private func quickLaunchOverlay(state: QuickLaunchState) -> some View {
        switch state.phase {
        case .parsing:
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { quickLaunchState = nil }
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Parsing prompt for \(state.workflow.name)…")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(24)
                .background(Theme.surface1)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 160)
            }
        case .confirming(let fields, let inputs, let notes):
            QuickLaunchConfirmSheet(
                smithers: smithers,
                target: state.workflow,
                fields: fields,
                initialInputs: inputs,
                notes: notes,
                prompt: state.prompt,
                onLaunched: { result in
                    quickLaunchState = nil
                    destination = .liveRun(runId: result.runId, nodeId: nil)
                },
                onDismiss: { quickLaunchState = nil }
            )
        case .error(let message):
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                    .onTapGesture { quickLaunchState = nil }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick-launch failed")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(6)
                    HStack {
                        Spacer()
                        Button("Close") { quickLaunchState = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
                .padding(16)
                .frame(maxWidth: 520)
                .background(Theme.surface1)
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 160)
                .padding(.horizontal, 24)
            }
        }
    }

    private func startQuickLaunch(workflow: Workflow, prompt: String) {
        quickLaunchState = QuickLaunchState(workflow: workflow, prompt: prompt, phase: .parsing)
        let client = smithers
        Task { @MainActor in
            do {
                let result = try await client.runQuickLaunchParser(target: workflow, prompt: prompt)
                let dag = try await client.getWorkflowDAG(workflow)
                quickLaunchState = QuickLaunchState(
                    workflow: workflow,
                    prompt: prompt,
                    phase: .confirming(fields: dag.launchFields, inputs: result.inputs, notes: result.notes)
                )
            } catch {
                quickLaunchState = QuickLaunchState(
                    workflow: workflow,
                    prompt: prompt,
                    phase: .error(error.localizedDescription)
                )
            }
        }
    }

    private func executePaletteAction(_ action: CommandPaletteAction, rawQuery: String) {
        if let request = CommandPaletteQuickLaunchResolver.request(
            for: action,
            rawQuery: rawQuery,
            slashCommands: paletteSlashCommands
        ) {
            startQuickLaunch(workflow: request.workflow, prompt: request.prompt)
            if !rawQuery.isEmpty {
                commandPaletteSeedQuery = ""
            }
            return
        }

        switch action {
        case .navigate(let next):
            navigateFromPalette(to: next)
        case .selectSidebarTab(let id):
            activateSidebarTab(withID: id)
        case .newTerminal:
            createNewTerminalTab()
        case .newTab(let selection):
            handleNewTabSelection(selection)
        case .expandNewTabs:
            openCommandPalette(prefill: NewTabPaletteCatalog.expandedQuery)
        case .openMarkdownFilePicker:
            openMarkdownFilePicker()
        case .closeCurrentTab:
            closeCurrentTab()
        case .askAI(let query):
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                openCommandPalette(prefill: "?")
            } else {
                askMainAI(trimmed)
            }
        case .slashCommand(let name):
            executeSlashCommandFromPalette(name)
        case .runWorkflow(let workflow):
            startQuickLaunch(workflow: workflow, prompt: "")
        case .openFile(let path):
            openFileFromPalette(path)
        case .globalSearch(let query):
            _ = query
            destination = .search
        case .refreshCurrentView:
            refreshCurrentView()
        case .cancelCurrentOperation:
            cancelCurrentOperation()
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .switchToTabIndex(let index):
            switchVisibleTab(at: index)
        case .nextVisibleTab:
            moveVisibleTab(offset: 1)
        case .previousVisibleTab:
            moveVisibleTab(offset: -1)
        case .showShortcutCheatSheet:
            openCommandPalette(prefill: ">shortcut")
        case .openTabSwitcher:
            openCommandPalette(prefill: "workspace")
        case .findTab:
            openCommandPalette(prefill: "workspace")
        case .unsupported(let message):
            AppNotifications.shared.post(
                title: "Command Palette",
                message: message,
                level: .info
            )
        }

        if !rawQuery.isEmpty {
            commandPaletteSeedQuery = ""
        }
    }

    private func navigateFromPalette(to next: NavDestination) {
        switch next {
        case .terminal(id: _):
            let terminalId = store.ensureTerminalTab()
            destination = .terminal(id: terminalId)
        default:
            handleNavigation(next)
        }
    }

    private func currentTerminalWorkspace() -> TerminalWorkspace? {
        guard case .terminal(let terminalId) = destination else { return nil }
        return store.terminalWorkspaceIfAvailable(terminalId) ?? store.ensureTerminalWorkspace(terminalId)
    }

    @discardableResult
    private func splitFocused(axis: WorkspaceSplitAxis, kind: WorkspaceSurfaceKind) -> Bool {
        guard let workspace = currentTerminalWorkspace() else { return false }
        workspace.splitFocused(axis: axis, kind: kind)
        return true
    }

    private func toggleSidebar() {
        navigationSplitVisibility = navigationSplitVisibility == .detailOnly ? .all : .detailOnly
    }

    private func jumpToLatestUnreadSurface() {
        let notifications = SurfaceNotificationStore.shared
        if let workspace = currentTerminalWorkspace(),
           let surfaceId = notifications.latestUnreadSurface(in: workspace.id.rawValue) {
            workspace.focusSurface(surfaceId)
            return
        }

        guard let surfaceId = notifications.latestUnreadSurface(),
              let workspaceId = notifications.surfaceWorkspaceIds[surfaceId]
        else {
            AppNotifications.shared.post(title: "Notifications", message: "No unread surfaces.", level: .info)
            return
        }

        destination = .terminal(id: workspaceId)
        let workspace = store.terminalWorkspaceIfAvailable(workspaceId) ?? store.ensureTerminalWorkspace(workspaceId)
        workspace.focusSurface(surfaceId)
    }

    private func showNotificationSummary() {
        let notifications = AppNotifications.shared.toasts
        if notifications.isEmpty {
            AppNotifications.shared.post(title: "Notifications", message: "No notifications.", level: .info)
        } else {
            AppNotifications.shared.post(
                title: "Notifications",
                message: "\(notifications.count) notification\(notifications.count == 1 ? "" : "s") visible.",
                level: .info
            )
        }
    }

    private func focusedBrowserSurfaceId() -> String? {
        guard let workspace = currentTerminalWorkspace(),
              let surfaceId = workspace.focusedSurfaceId,
              workspace.surfaces[surfaceId]?.kind == .browser
        else {
            return nil
        }
        return surfaceId.rawValue
    }

    @discardableResult
    private func performFocusedBrowserAction(_ action: (WKWebView) -> Void) -> Bool {
        guard let surfaceId = focusedBrowserSurfaceId() else { return false }
        action(BrowserSurfaceRegistry.shared.webView(for: surfaceId))
        return true
    }

    private func focusBrowserAddressBar() {
        guard let surfaceId = focusedBrowserSurfaceId() else { return }
        NotificationCenter.default.post(
            name: BrowserSurfaceView.focusAddressBarNotification,
            object: nil,
            userInfo: [BrowserSurfaceView.surfaceIdUserInfoKey: surfaceId]
        )
    }

    private func createNewTerminalTab() {
        let terminalId = store.addTerminalTab()
        destination = .terminal(id: terminalId)
    }

    private func handleSmithersActionNotification(_ notification: Notification) {
        guard let action = notification.userInfo?["action"] as? Smithers.Action,
              let kind = action.sessionKind
        else {
            return
        }
        openSmithersSession(kind)
    }

    private func openSmithersSession(_ kind: Smithers.Session.Kind) {
        switch kind {
        case .terminal, .chat:
            createNewTerminalTab()
        case .runInspect:
            destination = .runs
        case .workflow:
            destination = .workflows
        case .memory:
            destination = .memory
        case .dashboard:
            destination = .dashboard
        }
    }

    private func handleNewTabSelection(_ selection: NewTabSelection) {
        switch selection {
        case .terminal:
            let terminalId = store.addTerminalTab()
            destination = .terminal(id: terminalId)
        case .browser:
            let terminalId = store.addBrowserTab()
            destination = .terminal(id: terminalId)
        case .externalAgent(let target):
            let terminalId = store.launchExternalAgentTab(
                name: target.name,
                command: target.binary
            )
            destination = .terminal(id: terminalId)
        }
    }

    private func openMarkdownFilePicker() {
        PlatformAdapters.presentMarkdownOpenPanel(
            startingAt: store.workspaceRootPath,
            completion: { url in openMarkdownFile(url) }
        )
    }

    private func openMarkdownFile(_ url: URL) {
        guard isMarkdownFile(url) else {
            AppNotifications.shared.post(
                title: "Markdown",
                message: "Choose a .md file.",
                level: .warning
            )
            return
        }

        let normalizedPath = (url.path as NSString).standardizingPath
        let terminalId: String
        if case .terminal(let id) = destination {
            terminalId = id
        } else {
            let rawTitle = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? "Markdown" : rawTitle
            terminalId = store.addTerminalTab(title: title, workingDirectory: store.workspaceRootPath)
        }

        let workspace = store.ensureTerminalWorkspace(terminalId)
        if let existing = workspace.orderedSurfaces.first(where: {
            $0.kind == .markdown && $0.markdownFilePath == normalizedPath
        }) {
            workspace.focusSurface(existing.id)
        } else {
            workspace.addMarkdown(filePath: normalizedPath, splitAxis: .horizontal)
        }
        destination = .terminal(id: terminalId)
    }

    private func handleMarkdownFileDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }

                DispatchQueue.main.async {
                    openMarkdownFile(url)
                }
            }
        }

        return true
    }

    private func handleFindShortcut() {
        if destination == .search {
            return
        }
        openCommandPalette(prefill: "\(destination.label.lowercased()) ")
    }

    private func refreshCurrentView() {
        detailRefreshNonce += 1
    }

    private func cancelCurrentOperation() {
        if case .liveRun(let runId, _) = destination {
            Task { @MainActor in
                do {
                    try await smithers.cancelRun(runId)
                    AppNotifications.shared.post(
                        title: "Runs",
                        message: "Cancel requested for run \(runId).",
                        level: .info
                    )
                } catch {
                    AppNotifications.shared.post(
                        title: "Runs",
                        message: error.localizedDescription,
                        level: .warning
                    )
                }
            }
            return
        }

        AppNotifications.shared.post(
            title: "Cancel",
            message: "No cancellable operation is active.",
            level: .info
        )
    }

    private func askMainAI(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppNotifications.shared.post(
            title: "Ask AI",
            message: "Open a terminal tab with your preferred agent CLI to ask: \(trimmed)",
            level: .info
        )
    }

    private func closeCurrentTab() {
        switch destination {
        case .terminal(let terminalID):
            requestTerminalClose(terminalID)

        case .liveRun(let runId, _):
            store.removeRunTab(runId)
            destination = .runs

        case .runInspect(runId: _, workflowName: _):
            destination = .runs

        default:
            break
        }
    }

    private func switchVisibleTab(at index: Int) {
        let tabs = store.sidebarTabs(matching: "")
        guard tabs.indices.contains(index) else { return }
        activateSidebarTab(tabs[index])
    }

    private func moveVisibleTab(offset: Int) {
        let tabs = store.sidebarTabs(matching: "")
        guard !tabs.isEmpty else { return }

        let currentIndex = activeVisibleTabIndex(in: tabs) ?? 0
        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activateSidebarTab(tabs[nextIndex])
    }

    private func activeVisibleTabIndex(in tabs: [SidebarTab]) -> Int? {
        tabs.firstIndex { tab in
            switch tab.kind {
            case .run:
                if case .liveRun(let runId, _) = destination {
                    return runId == tab.runId
                }
                return false
            case .terminal:
                if case .terminal(let terminalId) = destination {
                    return terminalId == tab.terminalId
                }
                return false
            }
        }
    }

    private func activateSidebarTab(withID tabID: String) {
        guard let tab = store.sidebarTabs(matching: "").first(where: { $0.id == tabID }) else { return }
        activateSidebarTab(tab)
    }

    private func activateSidebarTab(_ tab: SidebarTab) {
        switch tab.kind {
        case .run:
            if let runID = tab.runId {
                destination = .liveRun(runId: runID, nodeId: nil)
            }
        case .terminal:
            if let terminalID = tab.terminalId {
                destination = .terminal(id: terminalID)
            }
        }
    }

    private func executeSlashCommandFromPalette(_ name: String) {
        guard let command = paletteSlashCommands.first(where: { $0.name == name }) else {
            AppNotifications.shared.post(
                title: "Slash Command",
                message: "Command /\(name) is not currently available.",
                level: .warning
            )
            return
        }

        switch command.action {
        case .navigate(let nav):
            navigateFromPalette(to: nav)
        case .toggleDeveloperDebug:
            toggleDeveloperDebugPanel()
        case .showHelp:
            openCommandPalette(prefill: ">")
        case .quit:
            PlatformAdapters.terminateApp()
        case .runWorkflow(let workflow):
            startQuickLaunch(workflow: workflow, prompt: "")
        case .runSmithersPrompt(_):
            destination = .prompts
            AppNotifications.shared.post(
                title: "Prompt Command",
                message: "Use /\(name) from an external agent terminal to run this prompt with arguments.",
                level: .info
            )
        }
    }

    private func openFileFromPalette(_ path: String) {
        let fileMention = "@\(path)"
        let absolutePath = absoluteWorkspacePath(for: path)
        let fileURL = URL(fileURLWithPath: absolutePath)
        if FileManager.default.fileExists(atPath: absolutePath) {
            if isMarkdownFile(fileURL) {
                openMarkdownFile(fileURL)
            } else {
                PlatformAdapters.open(fileURL)
            }
        } else {
            PlatformAdapters.copyToClipboard(fileMention)
            AppNotifications.shared.post(
                title: "File Missing",
                message: "Copied \(fileMention) to clipboard instead.",
                level: .warning
            )
        }
    }

    private func absoluteWorkspacePath(for path: String) -> String {
        if path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        return ((store.workspaceRootPath as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }

    private func isMarkdownFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private func openRunTab(run: RunSummary, nodeId: String?) {
        let previewParts = [
            run.status.label,
            nodeId.map { "Node \($0)" },
            run.elapsedString.isEmpty ? nil : run.elapsedString,
        ].compactMap { $0 }
        openRunTab(
            runId: run.runId,
            title: run.workflowName,
            preview: previewParts.joined(separator: " · "),
            nodeId: nodeId
        )
    }

    private func openRunTab(runId: String, title: String?, preview: String, nodeId: String? = nil) {
        store.addRunTab(runId: runId, title: title, preview: preview)
        destination = .liveRun(runId: runId, nodeId: nodeId)
    }

    private var terminateTerminalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingTerminalCloseId != nil },
            set: { presented in
                if !presented {
                    clearPendingTerminalClose()
                }
            }
        )
    }

    private func requestTerminalClose(_ terminalId: String) {
        pendingTerminalCloseId = terminalId
        pendingTerminalCloseTitle = store.terminalTabs.first(where: { $0.terminalId == terminalId })?.title ?? terminalId
    }

    private func handleTerminalProcessExited(_ terminalId: String) {
        store.removeTerminalTab(terminalId)
        if case .terminal(let activeId) = destination, activeId == terminalId {
            destination = defaultDestination
        }
        if pendingTerminalCloseId == terminalId {
            clearPendingTerminalClose()
        }
    }

    private func confirmTerminalClose() {
        guard let terminalId = pendingTerminalCloseId else { return }
        store.removeTerminalTab(terminalId)
        if case .terminal(let activeId) = destination, activeId == terminalId {
            destination = defaultDestination
        }
        clearPendingTerminalClose()
    }

    private func clearPendingTerminalClose() {
        pendingTerminalCloseId = nil
        pendingTerminalCloseTitle = ""
    }

    private func handleNavigation(_ next: NavDestination) {
        switch next {
        case .terminalCommand(let binary, let workingDirectory, let name):
            openTerminalCommandTab(command: binary, workingDirectory: workingDirectory, name: name)
        default:
            destination = next
        }
    }

    private var canGoBack: Bool { navHistoryIndex > 0 }
    private var canGoForward: Bool { navHistoryIndex < navHistory.count - 1 }

    private func recordHistory(_ next: NavDestination) {
        if isNavigatingThroughHistory {
            isNavigatingThroughHistory = false
            return
        }
        if navHistory.indices.contains(navHistoryIndex),
           navHistory[navHistoryIndex] == next {
            return
        }
        if navHistoryIndex < navHistory.count - 1 {
            navHistory.removeSubrange((navHistoryIndex + 1)...)
        }
        navHistory.append(next)
        navHistoryIndex = navHistory.count - 1
        trimHistoryIfNeeded()
    }

    private func trimHistoryIfNeeded() {
        let cap = 50
        if navHistory.count > cap {
            let overflow = navHistory.count - cap
            navHistory.removeFirst(overflow)
            navHistoryIndex -= overflow
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        navHistoryIndex -= 1
        isNavigatingThroughHistory = true
        destination = navHistory[navHistoryIndex]
    }

    private func goForward() {
        guard canGoForward else { return }
        navHistoryIndex += 1
        isNavigatingThroughHistory = true
        destination = navHistory[navHistoryIndex]
    }

    private func openTerminalCommandTab(command: String, workingDirectory: String, name: String) {
        let terminalId = store.addTerminalTab(
            title: name,
            workingDirectory: workingDirectory,
            command: SessionStore.applyDefaultAgentFlags(command)
        )
        destination = .terminal(id: terminalId)
    }

    private func toggleDeveloperDebugPanel() {
        guard developerToolsEnabled else { return }
        developerDebugPanelVisible.toggle()
        AppLogger.ui.info(
            "Developer debug panel toggled",
            metadata: ["visible": String(developerDebugPanelVisible)]
        )
    }

    private func emptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(Theme.textTertiary)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
    }
    #endif
}

#if os(macOS)
private extension View {
    func uiTestShortcutAnchor() -> some View {
        frame(width: 1, height: 1)
            // Keep shortcut anchors effectively invisible in production while
            // making them visible enough for XCUITest to expose them in the
            // accessibility tree.
            .opacity(UITestSupport.isEnabled ? 1 : 0.01)
            .clipped()
    }
}

struct HomeView: View {
    let itemsProvider: (String) -> [CommandPaletteItem]
    let onExecute: (CommandPaletteItem, String) -> Void

    var body: some View {
        CommandPaletteView(
            initialQuery: "",
            isInline: true,
            itemsProvider: itemsProvider,
            onExecute: onExecute,
            onDismiss: {}
        )
        .padding(.top, 88)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface1)
    }
}
#endif
