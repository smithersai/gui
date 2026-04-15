import SwiftUI

private struct RunSnapshotsSelection: Identifiable, Equatable {
    let runId: String
    let workflowName: String?

    var id: String { runId }
}

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var smithers = SmithersClient()
    @State private var destination: NavDestination = .dashboard
    @State private var runSnapshotsSelection: RunSnapshotsSelection?
    @State private var isLoading = true

    @ViewBuilder
    private var detailContent: some View {
        switch destination {
        case .chat:
            if let agent = store.activeAgent {
                ChatView(
                    agent: agent,
                    onSend: { store.sendMessage($0) },
                    smithers: smithers,
                    onNavigate: { destination = $0 },
                    onNewChat: {
                        store.newSession(reusingEmptyPlaceholder: true)
                        destination = .chat
                    },
                    onRunStarted: { runId, title in
                        openRunTab(runId: runId, title: title, preview: "Workflow run")
                    }
                )
                .id(store.activeSessionId)
                .accessibilityIdentifier("view.chat")
            } else {
                emptyState("No active session", icon: "message")
                    .accessibilityIdentifier("view.chat.empty")
            }
        case .terminal:
            TerminalView()
                .accessibilityIdentifier("view.terminal")
        case .terminalCommand(let binary, let workingDirectory, let name):
            TerminalView(command: binary, workingDirectory: workingDirectory)
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
            .accessibilityIdentifier("view.liveRun")
        case .runInspect(let runId, let workflowName):
            RunInspectView(
                smithers: smithers,
                runId: runId,
                onOpenLiveChat: { runId, nodeId in
                    let preview = nodeId.map { "Node \($0)" } ?? "Live run"
                    openRunTab(runId: runId, title: workflowName, preview: preview, nodeId: nodeId)
                },
                onOpenTerminalCommand: { command, workingDirectory, name in
                    destination = .terminalCommand(binary: command, workingDirectory: workingDirectory, name: name)
                },
                onClose: { destination = .runs }
            )
            .id("run-inspect-\(runId)")
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
                .accessibilityIdentifier("view.dashboard")
        case .agents:
            AgentsView(smithers: smithers)
                .accessibilityIdentifier("view.agents")
        case .changes:
            ChangesView(smithers: smithers)
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
                onOpenTerminalCommand: { command, workingDirectory, name in
                    destination = .terminalCommand(binary: command, workingDirectory: workingDirectory, name: name)
                }
            )
            .accessibilityIdentifier("view.runs")
        case .workflows:
            WorkflowsView(
                smithers: smithers,
                onNavigate: { destination = $0 },
                onRunStarted: { runId, title in
                    openRunTab(runId: runId, title: title, preview: "Workflow run")
                }
            )
            .accessibilityIdentifier("view.workflows")
        case .triggers:
            TriggersView(smithers: smithers)
                .accessibilityIdentifier("view.triggers")
        case .jjhubWorkflows:
            JJHubWorkflowsView(smithers: smithers)
                .accessibilityIdentifier("view.jjhubWorkflows")
        case .approvals:
            ApprovalsView(smithers: smithers)
                .accessibilityIdentifier("view.approvals")
        case .prompts:
            PromptsView(smithers: smithers)
                .accessibilityIdentifier("view.prompts")
        case .scores:
            ScoresView(smithers: smithers)
                .accessibilityIdentifier("view.scores")
        case .memory:
            MemoryView(smithers: smithers)
                .accessibilityIdentifier("view.memory")
        case .search:
            SearchView(smithers: smithers)
                .accessibilityIdentifier("view.search")
        case .sql:
            SQLBrowserView(smithers: smithers)
                .accessibilityIdentifier("view.sql")
        case .landings:
            LandingsView(smithers: smithers)
                .accessibilityIdentifier("view.landings")
        case .tickets:
            TicketsView(smithers: smithers)
                .accessibilityIdentifier("view.tickets")
        case .issues:
            IssuesView(smithers: smithers)
                .accessibilityIdentifier("view.issues")
        case .workspaces:
            WorkspacesView(smithers: smithers)
                .accessibilityIdentifier("view.workspaces")
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
                await smithers.checkConnection()
                isLoading = false
            }
        } else {
            NavigationSplitView {
                SidebarView(store: store, destination: $destination)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
            } detail: {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button("New Chat") {
                    store.newSession(reusingEmptyPlaceholder: true)
                    destination = .chat
                }
                .keyboardShortcut("n", modifiers: [.command])
                .accessibilityIdentifier("shortcut.newChat")
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
            .accessibilityIdentifier("app.root")
        } // end else (isLoading)
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
    }
}
