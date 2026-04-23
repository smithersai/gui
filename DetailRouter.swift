// DetailRouter.swift
//
// Shared detail-router component extracted from ContentView.swift in
// ticket 0122. The router owns the route switch and forwards
// navigation actions through a small `DetailRouterActions` struct so
// both the macOS shell and the iOS shell can compose the same set of
// screens without duplicating the switch body.
//
// The leaf views (DashboardView, RunsView, RunInspectView, etc.) stay as
// they are. This file is about composition only.
//
// NOTE: Several leaf destinations still depend on macOS-only dependencies
// (TerminalWorkspaceRouteView, GhosttyApp, KeyboardShortcutCommand). Until
// tickets 0123/0124 port those leaves, the router is macOS-target-only and
// the iOS shell uses a lightweight placeholder detail view.

#if os(macOS)
import SwiftUI

/// Callbacks invoked by the detail router when a leaf view wants to
/// change navigation state or open a new tab. Keeping these on the
/// caller (the platform shell) means the router itself stays free of
/// platform-specific behavior.
struct DetailRouterActions {
    var navigate: (NavDestination) -> Void
    var requestTerminalClose: (String) -> Void
    var handleKeyboardShortcutCommand: (KeyboardShortcutCommand) -> Void
    var openTerminalCommandTab: (_ command: String, _ workingDirectory: String, _ name: String) -> Void
    var openRunTabForRun: (RunSummary, String?) -> Void
    var openRunTab: (_ runId: String, _ title: String?, _ preview: String, _ nodeId: String?) -> Void
    var setWorkflowsInitialID: (String?) -> Void
    var setChangesInitialID: (String?) -> Void
    var presentRunSnapshotsSheet: (RunSummary) -> Void
    var autoPopulateActiveRunTabs: ([RunSummary]) -> Void
    var updateRunTab: (RunSummary) -> Void
    var commandPaletteItems: (String) -> [CommandPaletteItem]
    var executePaletteItem: (CommandPaletteItem, String) -> Void
}

/// Timeline/Snapshots route view. Moved into the shared detail-router file
/// in ticket 0122 so ContentView.swift no longer owns the route switch or
/// any of its bespoke leaves.
struct SnapshotsRouteView: View {
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
        case .stale, .orphaned:
            return Theme.warning
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

/// Renders the leaf view for the current `destination`. The switch
/// itself is identical to the pre-0122 body of
/// `ContentView.detailContent`; only the data flow (via
/// `DetailRouterActions`) is new.
struct DetailRouterView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var smithers: SmithersClient
    let destination: NavDestination
    let workflowsInitialID: String?
    let changesInitialID: String?
    let actions: DetailRouterActions

    var body: some View {
        switch destination {
        case .terminal(let id):
            TerminalWorkspaceRouteView(
                store: store,
                terminalId: id,
                onClose: { actions.requestTerminalClose(id) },
                onAppShortcutCommand: { command in
                    actions.handleKeyboardShortcutCommand(command)
                }
            )
            .id(id)
            .logLifecycle("TerminalWorkspaceView")
            .accessibilityIdentifier("view.terminal")
        case .terminalCommand(let binary, let workingDirectory, let name):
            TerminalView(
                command: binary,
                workingDirectory: workingDirectory,
                onClose: { actions.navigate(.home) },
                onAppShortcutCommand: { command in
                    actions.handleKeyboardShortcutCommand(command)
                }
            )
            .id("\(binary)-\(workingDirectory)")
            .accessibilityIdentifier("view.terminalCommand.\(name)")
        case .liveRun(let runId, let nodeId):
            LiveRunView(
                smithers: smithers,
                runId: runId,
                nodeId: nodeId,
                onOpenTerminalCommand: actions.openTerminalCommandTab,
                onOpenWorkflow: { workflowName in
                    actions.setWorkflowsInitialID(workflowName)
                    actions.navigate(.workflows)
                },
                onOpenPrompt: { actions.navigate(.prompts) },
                onRunSummaryRefreshed: { actions.updateRunTab($0) },
                onClose: { actions.navigate(.runs) }
            )
            .id("live-run-\(runId)-\(nodeId ?? "all")")
            .logLifecycle("LiveRunView")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("view.liveRun")
        case .runInspect(let runId, let workflowName):
            RunInspectView(
                smithers: smithers,
                runId: runId,
                onOpenLiveChat: { runId, nodeId in
                    let preview = nodeId.map { "Node \($0)" } ?? "Live run"
                    actions.openRunTab(runId, workflowName, preview, nodeId)
                },
                onOpenTerminalCommand: actions.openTerminalCommandTab,
                onRunSummaryRefreshed: { actions.updateRunTab($0) },
                onClose: { actions.navigate(.runs) }
            )
            .id("run-inspect-\(runId)")
            .logLifecycle("RunInspectView")
            .accessibilityIdentifier("view.runinspect")
        case .home:
            HomeView(
                itemsProvider: { query in actions.commandPaletteItems(query) },
                onExecute: { item, query in actions.executePaletteItem(item, query) }
            )
            .id("home")
            .logLifecycle("HomeView")
            .accessibilityIdentifier("view.home")
        case .dashboard:
            DashboardView(
                smithers: smithers,
                onAutoPopulateActiveRuns: { runs in
                    actions.autoPopulateActiveRunTabs(runs)
                },
                onOpenLiveChat: { run, nodeId in
                    actions.openRunTabForRun(run, nodeId)
                },
                onOpenWorkflow: { workflow in
                    actions.setWorkflowsInitialID(workflow.id)
                    actions.navigate(.workflows)
                }
            )
            .logLifecycle("DashboardView")
            .accessibilityIdentifier("view.dashboard")
        case .vcsDashboard:
            VCSDashboardView(
                smithers: smithers,
                onNavigate: { actions.navigate($0) },
                onOpenChange: { change in
                    actions.setChangesInitialID(change.changeID)
                    actions.navigate(.changes)
                }
            )
            .logLifecycle("VCSDashboardView")
            .accessibilityIdentifier("view.vcsDashboard")
        case .agents:
            AgentsView(smithers: smithers)
                .logLifecycle("AgentsView")
                .accessibilityIdentifier("view.agents")
        case .changes:
            ChangesView(smithers: smithers, initialChangeID: changesInitialID)
                .id(changesInitialID ?? "changes-default")
                .logLifecycle("ChangesView")
                .accessibilityIdentifier("view.changes")
        case .runs:
            RunsView(
                smithers: smithers,
                onOpenLiveChat: { run, nodeId in
                    actions.openRunTabForRun(run, nodeId)
                },
                onOpenRunInspector: { run in
                    actions.navigate(.runInspect(runId: run.runId, workflowName: run.workflowName))
                },
                onOpenRunSnapshots: { run in
                    actions.presentRunSnapshotsSheet(run)
                },
                onOpenTerminalCommand: actions.openTerminalCommandTab
            )
            .logLifecycle("RunsView")
            .accessibilityIdentifier("view.runs")
        case .snapshots:
            SnapshotsRouteView(
                smithers: smithers,
                onOpenRunSnapshots: { run in
                    actions.presentRunSnapshotsSheet(run)
                }
            )
            .logLifecycle("SnapshotsRouteView")
            .accessibilityIdentifier("view.snapshots")
        case .workflows:
            WorkflowsView(
                smithers: smithers,
                onNavigate: { actions.navigate($0) },
                onRunStarted: { runId, title in
                    actions.openRunTab(runId, title, "Workflow run", nil)
                },
                initialWorkflowID: workflowsInitialID
            )
            .id(workflowsInitialID ?? "workflows-default")
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
}

#endif
