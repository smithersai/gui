import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct RunSnapshotsSelection: Identifiable, Equatable {
    let runId: String
    let workflowName: String?

    var id: String { runId }
}

private struct SnapshotsRouteView: View {
    @ObservedObject var smithers: SmithersClient
    var onOpenRunSnapshots: (RunSummary) -> Void

    @State private var runs: [RunSummary] = []
    @State private var selectedRunId: String?
    @State private var isLoading = true
    @State private var error: String?

    private var sortedRuns: [RunSummary] {
        runs.sortedByStartedAtDescending()
    }

    private var selectedRun: RunSummary? {
        if let selectedRunId,
           let selected = sortedRuns.first(where: { $0.runId == selectedRunId }) {
            return selected
        }
        return sortedRuns.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Theme.surface1)
        .task { await loadRuns() }
        .accessibilityIdentifier("view.snapshots")
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Timeline / Snapshots")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Choose a run to inspect snapshots.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
            }

            Button {
                Task { await loadRuns() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("Refresh")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.inputBg)
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("snapshots.refresh")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .border(Theme.border, edges: [.bottom])
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading runs...")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.warning)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    Task { await loadRuns() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Theme.accent)
                .accessibilityIdentifier("snapshots.retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        } else if sortedRuns.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 24))
                    .foregroundColor(Theme.textTertiary)
                Text("No runs found")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                Text("Run a workflow first, then open snapshots.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                runList
                    .frame(width: 340)
                    .background(Theme.surface2)

                Divider().background(Theme.border)

                runDetail
            }
        }
    }

    private var runList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(sortedRuns) { run in
                    let isSelected = run.runId == selectedRun?.runId
                    Button {
                        selectedRunId = run.runId
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.workflowName ?? run.runId)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(run.status.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(statusColor(run.status))
                            }

                            Text(run.runId)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.textTertiary)
                                .lineLimit(1)

                            if let startedAtMs = run.startedAtMs {
                                Text(runInspectorRelativeDate(startedAtMs))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(Theme.textTertiary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 8, defaultFill: Theme.surface2)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("snapshots.run.\(runInspectorSafeID(run.runId))")
                }
            }
            .padding(12)
        }
        .refreshable { await loadRuns() }
    }

    private var runDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedRun {
                Text(selectedRun.workflowName ?? "Run \(String(selectedRun.runId.prefix(8)))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.textPrimary)

                detailRow("Run ID", selectedRun.runId)
                detailRow("Status", selectedRun.status.label)
                detailRow("Started", selectedRun.startedAtMs.map(runInspectorShortDate) ?? "-")
                detailRow("Elapsed", selectedRun.elapsedString.isEmpty ? "-" : selectedRun.elapsedString)

                Divider().background(Theme.border)

                Text("Open Timeline")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
                Text("Open the snapshots viewer for this run to inspect timeline frames, then fork or replay.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)

                Button {
                    onOpenRunSnapshots(selectedRun)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .bold))
                        Text("Open Snapshots")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Theme.inputBg)
                    .cornerRadius(7)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("snapshots.open")

                Spacer(minLength: 0)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 20))
                        .foregroundColor(Theme.textTertiary)
                    Text("Select a run")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Theme.textTertiary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
            Spacer()
        }
    }

    private func statusColor(_ status: RunStatus) -> Color {
        switch status {
        case .running:
            return Theme.info
        case .waitingApproval:
            return Theme.warning
        case .finished:
            return Theme.success
        case .failed, .cancelled:
            return Theme.danger
        case .unknown:
            return Theme.textTertiary
        }
    }

    private func loadRuns() async {
        isLoading = true
        error = nil

        do {
            let fetched = try await smithers.listRuns()
            runs = fetched

            let sorted = fetched.sortedByStartedAtDescending()
            let availableRunIDs = Set(sorted.map(\.runId))
            if let selectedRunId, availableRunIDs.contains(selectedRunId) {
                self.selectedRunId = selectedRunId
            } else {
                self.selectedRunId = sorted.first?.runId
            }
        } catch {
            runs = []
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

struct SettingsView: View {
    @AppStorage(AppPreferenceKeys.vimModeEnabled) private var vimModeEnabled = false
    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @AppStorage(AppPreferenceKeys.externalAgentUnsafeFlagsEnabled) private var externalAgentUnsafeFlagsEnabled = false
    @AppStorage(AppPreferenceKeys.browserSearchEngine) private var browserSearchEngine = BrowserSearchEngine.duckDuckGo.rawValue
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
                    externalAgentSafetySection
                    browserSearchSection
                    neovimSection
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface1)
        .onAppear(perform: refreshNeovimPath)
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
                    Text("Opt in to append --dangerously-skip-permissions / --yolo when launching external agent CLIs.")
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

    private func refreshNeovimPath() {
        let detectedPath = NeovimDetector.executablePath()
        neovimPath = detectedPath
        if detectedPath == nil {
            vimModeEnabled = false
        }
    }
}

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var smithers = SmithersClient()
    @StateObject private var fileSearchIndex = WorkspaceFileSearchIndex(rootPath: CWDResolver.resolve(nil))
    @AppStorage(AppPreferenceKeys.developerToolsEnabled) private var developerToolsEnabled = false
    @State private var destination: NavDestination = .dashboard
    @State private var runSnapshotsSelection: RunSnapshotsSelection?
    @State private var isLoading = true
    @State private var developerDebugPanelVisible = false
    @State private var guiControlSidebarExpanded = false
    @State private var pendingTerminalCloseId: String?
    @State private var pendingTerminalCloseTitle: String = ""
    @State private var commandPaletteVisible = false
    @State private var commandPaletteSeedQuery = ""
    @State private var detailRefreshNonce = 0
    @State private var keyboardShortcutController = KeyboardShortcutController()
    @State private var paletteWorkflows: [Workflow] = []
    @State private var palettePrompts: [SmithersPrompt] = []
    @State private var paletteIssues: [SmithersIssue] = []
    @State private var paletteTickets: [Ticket] = []
    @State private var paletteLandings: [Landing] = []
    @State private var paletteDataLastRefreshAt: Date = .distantPast
    @State private var paletteDataRefreshTask: Task<Void, Never>?

    private var paletteSlashCommands: [SlashCommandItem] {
        let dynamic = SlashCommandRegistry.dynamicCommands(
            workflows: paletteWorkflows,
            prompts: palettePrompts
        )
        return SlashCommandRegistry.builtInCommands + dynamic.workflows + dynamic.prompts
    }

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .chat:
            if let agent = store.activeAgent {
                ChatView(
                    agent: agent,
                    onSend: { store.sendMessage($0) },
                    onSendRequest: { request in
                        store.sendMessage(request.prompt, displayText: request.displayText)
                    },
                    smithers: smithers,
                    onNavigate: handleNavigation,
                    onLaunchExternalAgent: { target in
                        let terminalId = store.launchExternalAgentTab(
                            name: target.name,
                            command: target.binary
                        )
                        destination = .terminal(id: terminalId)
                    },
                    onToggleDeveloperDebug: toggleDeveloperDebugPanel,
                    developerToolsEnabled: developerToolsEnabled,
                    onNewChat: {
                        store.newSession(reusingEmptyPlaceholder: false)
                        destination = .chat
                    },
                    onRunStarted: { runId, title in
                        openRunTab(runId: runId, title: title, preview: "Workflow run")
                    },
                    codexModelSelection: store.activeCodexSelection ?? store.codexSelectionDefaults,
                    onApplyCodexModelSelection: { selection in
                        store.applyCodexSelection(selection)
                    },
                    codexApprovalSelection: store.activeCodexApprovalSelection ?? store.codexApprovalDefaults,
                    onApplyCodexApprovalSelection: { selection in
                        store.applyCodexApprovalSelection(selection)
                    }
                )
                .id(store.activeSessionId)
                .logLifecycle("ChatView")
                .accessibilityIdentifier("view.chat")
            } else {
                emptyState("No active session", icon: "message")
                    .accessibilityIdentifier("view.chat.empty")
            }
        case .terminal(let id):
            TerminalWorkspaceRouteView(
                store: store,
                terminalId: id,
                onClose: {
                    requestTerminalClose(id)
                }
            )
                .id(id)
                .logLifecycle("TerminalWorkspaceView")
                .accessibilityIdentifier("view.terminal")
        case .terminalCommand(let binary, let workingDirectory, let name):
            TerminalView(command: binary, workingDirectory: workingDirectory, onClose: { destination = .dashboard })
                .id("\(binary)-\(workingDirectory)")
                .accessibilityIdentifier("view.terminalCommand.\(name)")
        case .liveRun(let runId, let nodeId):
            LiveRunChatView(
                smithers: smithers,
                runId: runId,
                nodeId: nodeId,
                onClose: { destination = .runs }
            )
            .id("live-run-\(runId)-\(nodeId ?? "all")")
            .logLifecycle("LiveRunChatView")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("view.liveRun")
        case .runInspect(let runId, let workflowName):
            RunInspectView(
                smithers: smithers,
                runId: runId,
                onOpenLiveChat: { runId, nodeId in
                    let preview = nodeId.map { "Node \($0)" } ?? "Live run"
                    openRunTab(runId: runId, title: workflowName, preview: preview, nodeId: nodeId)
                },
                onOpenTerminalCommand: openTerminalCommandTab,
                onClose: { destination = .runs }
            )
            .id("run-inspect-\(runId)")
            .logLifecycle("RunInspectView")
            .accessibilityIdentifier("view.runinspect")
        case .dashboard:
            DashboardView(
                smithers: smithers,
                sessionSnapshots: store.chatSessions(),
                onNavigate: { destination = $0 },
                onNewChat: {
                    store.newSession(reusingEmptyPlaceholder: true)
                    destination = .chat
                },
                onAutoPopulateActiveRuns: { runs in
                    store.autoPopulateActiveRunTabs(runs)
                }
            )
                .logLifecycle("DashboardView")
                .accessibilityIdentifier("view.dashboard")
        case .vcsDashboard:
            VCSDashboardView(
                smithers: smithers,
                onNavigate: { destination = $0 }
            )
                .logLifecycle("VCSDashboardView")
                .accessibilityIdentifier("view.vcsDashboard")
        case .agents:
            AgentsView(smithers: smithers)
                .logLifecycle("AgentsView")
                .accessibilityIdentifier("view.agents")
        case .changes:
            ChangesView(smithers: smithers)
                .logLifecycle("ChangesView")
                .accessibilityIdentifier("view.changes")
        case .runs:
            RunsView(
                smithers: smithers,
                onOpenLiveChat: { run, nodeId in
                    openRunTab(run: run, nodeId: nodeId)
                },
                onOpenRunInspector: { run in
                    destination = .runInspect(runId: run.runId, workflowName: run.workflowName)
                },
                onOpenRunSnapshots: { run in
                    runSnapshotsSelection = RunSnapshotsSelection(runId: run.runId, workflowName: run.workflowName)
                },
                onOpenTerminalCommand: openTerminalCommandTab
            )
            .logLifecycle("RunsView")
            .accessibilityIdentifier("view.runs")
        case .snapshots:
            SnapshotsRouteView(
                smithers: smithers,
                onOpenRunSnapshots: { run in
                    runSnapshotsSelection = RunSnapshotsSelection(runId: run.runId, workflowName: run.workflowName)
                }
            )
            .logLifecycle("SnapshotsRouteView")
            .accessibilityIdentifier("view.snapshots")
        case .workflows:
            WorkflowsView(
                smithers: smithers,
                onNavigate: { destination = $0 },
                onRunStarted: { runId, title in
                    openRunTab(runId: runId, title: title, preview: "Workflow run")
                }
            )
            .logLifecycle("WorkflowsView")
            .accessibilityIdentifier("view.workflows")
        case .triggers:
            TriggersView(smithers: smithers)
                .logLifecycle("TriggersView")
                .accessibilityIdentifier("view.triggers")
        case .jjhubWorkflows:
            JJHubWorkflowsView(smithers: smithers)
                .logLifecycle("JJHubWorkflowsView")
                .accessibilityIdentifier("view.jjhubWorkflows")
        case .approvals:
            ApprovalsView(smithers: smithers)
                .logLifecycle("ApprovalsView")
                .accessibilityIdentifier("view.approvals")
        case .prompts:
            PromptsView(smithers: smithers)
                .logLifecycle("PromptsView")
                .accessibilityIdentifier("view.prompts")
        case .scores:
            ScoresView(smithers: smithers)
                .logLifecycle("ScoresView")
                .accessibilityIdentifier("view.scores")
        case .memory:
            MemoryView(smithers: smithers)
                .logLifecycle("MemoryView")
                .accessibilityIdentifier("view.memory")
        case .search:
            SearchView(smithers: smithers)
                .logLifecycle("SearchView")
                .accessibilityIdentifier("view.search")
        case .sql:
            SQLBrowserView(smithers: smithers)
                .logLifecycle("SQLBrowserView")
                .accessibilityIdentifier("view.sql")
        case .landings:
            LandingsView(smithers: smithers)
                .logLifecycle("LandingsView")
                .accessibilityIdentifier("view.landings")
        case .tickets:
            TicketsView(smithers: smithers)
                .logLifecycle("TicketsView")
                .accessibilityIdentifier("view.tickets")
        case .issues:
            IssuesView(smithers: smithers)
                .logLifecycle("IssuesView")
                .accessibilityIdentifier("view.issues")
        case .workspaces:
            WorkspacesView(smithers: smithers)
                .logLifecycle("WorkspacesView")
                .accessibilityIdentifier("view.workspaces")
        case .logs:
            LogViewerView()
                .logLifecycle("LogViewerView")
                .accessibilityIdentifier("view.logs")
        case .settings:
            SettingsView()
                .logLifecycle("SettingsView")
                .accessibilityIdentifier("view.settings")
        }
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Connecting to Smithers...")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.base)
            .task {
                let logStats = await AppLogger.fileWriter.stats()
                AppLogger.lifecycle.info("File logging ready", metadata: [
                    "path": logStats.fileURL.path,
                    "entries": String(logStats.entryCount),
                    "size_bytes": String(logStats.sizeBytes)
                ])
                AppLogger.lifecycle.info("App launching, checking connection")
                await smithers.checkConnection()
                AppLogger.lifecycle.info("Connection check complete", metadata: [
                    "connected": String(smithers.isConnected),
                    "cliAvailable": String(smithers.cliAvailable)
                ])
                AppNotifications.shared.beginRunEventMonitoring(smithers: smithers)
                isLoading = false
            }
        } else {
            HStack(spacing: 0) {
                NavigationSplitView {
                    SidebarView(
                        store: store,
                        destination: $destination,
                        developerDebugPanelVisible: $developerDebugPanelVisible,
                        developerDebugAvailable: developerToolsEnabled
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
                } detail: {
                    Group {
                        detailContent
                            .id("\(String(describing: destination)):\(detailRefreshNonce)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .sheet(item: $runSnapshotsSelection) { selection in
                    RunSnapshotsSheet(
                        smithers: smithers,
                        runId: selection.runId,
                        nodeIdFilter: nil,
                        onClose: { runSnapshotsSelection = nil }
                    )
                    .frame(minWidth: 840, minHeight: 520)
                }
                .frame(minWidth: 800, minHeight: 600)
                .background(Theme.base)
                .overlay(alignment: .topLeading) {
                    hiddenShortcutButtons
                }
                .accessibilityIdentifier("app.root")
                .onChange(of: destination) { _, newValue in
                    AppLogger.ui.debug("Navigate to \(newValue.label)")
                }

                GUIControlSidebar(
                    isExpanded: $guiControlSidebarExpanded,
                    store: store,
                    smithers: smithers,
                    destination: destination,
                    onNavigate: handleNavigation
                )

                if developerDebugPanelVisible && developerToolsEnabled {
                    DeveloperDebugPanel(
                        store: store,
                        smithers: smithers,
                        destination: destination,
                        onClose: { developerDebugPanelVisible = false },
                        onOpenLogs: { destination = .logs }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                AppToastOverlay()
            }
            .overlay {
                if commandPaletteVisible {
                    CommandPaletteView(
                        initialQuery: commandPaletteSeedQuery,
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
            }
            .background(Theme.base)
            .onAppear {
                installKeyboardShortcutMonitor()
                fileSearchIndex.updateRootPath(store.workspaceRootPath)
                fileSearchIndex.ensureLoaded()
            }
            .onDisappear {
                keyboardShortcutController.uninstall()
                paletteDataRefreshTask?.cancel()
                paletteDataRefreshTask = nil
            }
            .confirmationDialog(
                "Terminate Terminal?",
                isPresented: terminateTerminalConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("Terminate Terminal", role: .destructive) {
                    confirmTerminalClose()
                }
                Button("Cancel", role: .cancel) {
                    clearPendingTerminalClose()
                }
            } message: {
                Text("Terminate \"\(pendingTerminalCloseTitle)\"? This will stop the terminal session and close the tab. This action cannot be undone.")
            }
        } // end else (isLoading)
    }

    @ViewBuilder
    private var hiddenShortcutButtons: some View {
        VStack(spacing: 0) {
            Button("Open Launcher") {
                openCommandPalette(prefill: "")
            }
            .keyboardShortcut("p", modifiers: [.command])
            .accessibilityIdentifier("shortcut.openLauncher")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Open Command Palette") {
                openCommandPalette(prefill: ">")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .accessibilityIdentifier("shortcut.commandPalette")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Open Ask AI Launcher") {
                openCommandPalette(prefill: "?")
            }
            .keyboardShortcut("k", modifiers: [.command])
            .accessibilityIdentifier("shortcut.askAI")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("New Chat") {
                startNewChat()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .accessibilityIdentifier("shortcut.newChat")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("New Terminal Tab") {
                createNewTerminalTab()
            }
            .keyboardShortcut("t", modifiers: [.command])
            .accessibilityIdentifier("shortcut.newTerminal")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Reopen Closed Tab") {
                AppNotifications.shared.post(
                    title: "Tabs",
                    message: "Reopen closed tab is not available yet.",
                    level: .info
                )
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .accessibilityIdentifier("shortcut.reopenTab")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Previous Visible Tab") {
                moveVisibleTab(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .accessibilityIdentifier("shortcut.previousTab")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Next Visible Tab") {
                moveVisibleTab(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .accessibilityIdentifier("shortcut.nextTab")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Find in Context") {
                handleFindShortcut()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .accessibilityIdentifier("shortcut.find")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Global Search") {
                destination = .search
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .accessibilityIdentifier("shortcut.globalSearch")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Refresh Current View") {
                refreshCurrentView()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityIdentifier("shortcut.refresh")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Cancel Current Operation") {
                cancelCurrentOperation()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .accessibilityIdentifier("shortcut.cancel")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            Button("Shortcut Cheat Sheet") {
                openCommandPalette(prefill: ">shortcut")
            }
            .keyboardShortcut("/", modifiers: [.command])
            .accessibilityIdentifier("shortcut.cheatSheet")
            .frame(width: 1, height: 1)
            .opacity(0.01)

            ForEach(1...9, id: \.self) { index in
                Button("Switch to Tab \(index)") {
                    switchVisibleTab(at: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index))), modifiers: [.command])
                .accessibilityIdentifier("shortcut.switchTab.\(index)")
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }

            if developerToolsEnabled {
                Button("Toggle Developer Debug") {
                    toggleDeveloperDebugPanel()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .accessibilityIdentifier("shortcut.toggleDeveloperDebug")
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
    }

    private func installKeyboardShortcutMonitor() {
        keyboardShortcutController.install(
            onAction: { action in
                executePaletteAction(action, rawQuery: "")
            },
            focusState: {
                let window = NSApp.keyWindow
                return KeyboardShortcutFocusState(
                    textInputFocused: KeyboardShortcutController.isTextInputFocused(window: window),
                    terminalFocused: KeyboardShortcutController.isTerminalFocused(window: window),
                    paletteVisible: commandPaletteVisible
                )
            },
            shouldHandleCommandW: {
                true
            }
        )
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

            let workflows = (try? await workflowsTask) ?? []
            let prompts = (try? await promptsTask) ?? []
            let issues = (try? await issuesTask) ?? []
            let tickets = (try? await ticketsTask) ?? []
            let landings = (try? await landingsTask) ?? []

            guard !Task.isCancelled else { return }
            paletteWorkflows = workflows
            palettePrompts = prompts
            paletteIssues = issues
            paletteTickets = tickets
            paletteLandings = landings
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

        return CommandPaletteBuilder.items(for: rawQuery, context: context)
    }

    private func executePaletteItem(_ item: CommandPaletteItem, rawQuery: String) {
        commandPaletteVisible = false
        executePaletteAction(item.action, rawQuery: rawQuery)
    }

    private func executePaletteAction(_ action: CommandPaletteAction, rawQuery: String) {
        switch action {
        case .navigate(let next):
            navigateFromPalette(to: next)
        case .selectSidebarTab(let id):
            activateSidebarTab(withID: id)
        case .newChat:
            startNewChat()
        case .newTerminal:
            createNewTerminalTab()
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
            openCommandPalette(prefill: "tab")
        case .findTab:
            openCommandPalette(prefill: "tab")
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

    private func startNewChat() {
        store.newSession(reusingEmptyPlaceholder: true)
        destination = .chat
    }

    private func createNewTerminalTab() {
        let terminalId = store.addTerminalTab()
        destination = .terminal(id: terminalId)
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
        if destination == .chat,
           let agent = store.activeAgent,
           agent.isRunning {
            agent.cancel()
            AppNotifications.shared.post(
                title: "Chat",
                message: "Stopped active chat turn.",
                level: .info
            )
            return
        }

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
        let _ = store.ensureActiveSession()
        destination = .chat

        guard !trimmed.isEmpty else { return }
        store.sendMessage(trimmed)
    }

    private func closeCurrentTab() {
        switch destination {
        case .chat:
            guard let sessionID = store.activeSessionId else { return }
            if store.discardSessionIfEmpty(sessionID) {
                let _ = store.ensureActiveSession()
                destination = .chat
                return
            }

            if store.canArchiveSession(sessionID) {
                store.archiveSession(sessionID)
                destination = .chat
            } else {
                AppNotifications.shared.post(
                    title: "Chat",
                    message: "The active chat is running and cannot be closed yet.",
                    level: .warning
                )
            }

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
            case .chat:
                return destination == .chat && store.activeSessionId == tab.chatSessionId
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
        case .chat:
            if let sessionID = tab.chatSessionId {
                store.selectSession(sessionID)
                destination = .chat
            }
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
        case .clearChat:
            let _ = store.ensureActiveSession()
            destination = .chat
            store.activeAgent?.messages.removeAll()
        case .showHelp:
            openCommandPalette(prefill: ">")
        case .runWorkflow(_):
            destination = .workflows
            AppNotifications.shared.post(
                title: "Workflow Command",
                message: "Use /\(name) in the chat composer to run this workflow with arguments.",
                level: .info
            )
        case .runSmithersPrompt(_):
            destination = .prompts
            AppNotifications.shared.post(
                title: "Prompt Command",
                message: "Use /\(name) in the chat composer to run this prompt with arguments.",
                level: .info
            )
        case .codex(let codexCommand):
            executeCodexSlashCommandFromPalette(codexCommand, name: name)
        }
    }

    private func executeCodexSlashCommandFromPalette(_ command: CodexSlashCommand, name: String) {
        switch command {
        case .new:
            startNewChat()
        case .review:
            askMainAI("Review my current changes and find issues. Prioritize bugs, regressions, and missing tests.")
        case .compact:
            askMainAI("Summarize the important context from this conversation so we can continue with a shorter working history.")
        case .mention:
            openCommandPalette(prefill: "@")
        case .status:
            AppNotifications.shared.post(
                title: "Session Status",
                message: sessionStatusText(),
                level: .info
            )
        case .initialize:
            askMainAI(SlashCommandRegistry.initPrompt)
        case .diff:
            askMainAI("Summarize the current git diff.")
        case .model, .approvals, .mcp, .logout, .quit, .feedback:
            destination = .chat
            AppNotifications.shared.post(
                title: "Slash Command",
                message: "/\(name) is available from the chat composer.",
                level: .info
            )
        }
    }

    private func sessionStatusText() -> String {
        let sessionState = store.activeSessionId == nil ? "No active session" : "Active session ready"
        let runningState = store.activeAgent?.isRunning == true ? "running" : "idle"
        return "\(sessionState) · Agent is \(runningState)."
    }

    private func openFileFromPalette(_ path: String) {
        let fileMention = "@\(path)"
        if destination == .chat {
            copyTextToClipboard(fileMention)
            AppNotifications.shared.post(
                title: "File Mention Copied",
                message: "Paste \(fileMention) into chat.",
                level: .info
            )
            return
        }

        let absolutePath = (store.workspaceRootPath as NSString).appendingPathComponent(path)
        let fileURL = URL(fileURLWithPath: absolutePath)
        if FileManager.default.fileExists(atPath: absolutePath) {
            NSWorkspace.shared.open(fileURL)
        } else {
            copyTextToClipboard(fileMention)
            AppNotifications.shared.post(
                title: "File Missing",
                message: "Copied \(fileMention) to clipboard instead.",
                level: .warning
            )
        }
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

    private func confirmTerminalClose() {
        guard let terminalId = pendingTerminalCloseId else { return }
        store.removeTerminalTab(terminalId)
        if case .terminal(let activeId) = destination, activeId == terminalId {
            destination = .dashboard
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
}

@main
struct SmithersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        AppLogger.lifecycle.info("Application did finish launching")
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            AppNotifications.shared.stopRunEventMonitoring()
            GhosttyApp.shared.shutdown()
        }
        AppLogger.lifecycle.info("Application will terminate")
    }
}
