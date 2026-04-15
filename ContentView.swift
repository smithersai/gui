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
    @State private var developerDebugPanelVisible = DeveloperDebugMode.isEnabled

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
                    onNavigate: { destination = $0 },
                    onToggleDeveloperDebug: toggleDeveloperDebugPanel,
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
            TerminalView(sessionId: id)
                .id(id)
                .logLifecycle("TerminalView")
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
            .logLifecycle("LiveRunChatView")
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
                onOpenTerminalCommand: { command, workingDirectory, name in
                    destination = .terminalCommand(binary: command, workingDirectory: workingDirectory, name: name)
                }
            )
            .logLifecycle("RunsView")
            .accessibilityIdentifier("view.runs")
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
                        developerDebugAvailable: DeveloperDebugMode.isEnabled
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
                } detail: {
                    Group {
                        detailContent
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
                    VStack(spacing: 0) {
                        Button("New Chat") {
                            store.newSession(reusingEmptyPlaceholder: true)
                            destination = .chat
                        }
                        .keyboardShortcut("n", modifiers: [.command])
                        .accessibilityIdentifier("shortcut.newChat")
                        .frame(width: 1, height: 1)
                        .opacity(0.01)

                        if DeveloperDebugMode.isEnabled {
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
                .accessibilityIdentifier("app.root")
                .onChange(of: destination) { _, newValue in
                    AppLogger.ui.debug("Navigate to \(newValue.label)")
                }

                if developerDebugPanelVisible && DeveloperDebugMode.isEnabled {
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
            .background(Theme.base)
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

    private func toggleDeveloperDebugPanel() {
        guard DeveloperDebugMode.isEnabled else { return }
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
        }
        AppLogger.lifecycle.info("Application will terminate")
    }
}
