import SwiftUI

private struct LiveRunChatSelection: Identifiable, Equatable {
    let runId: String
    let nodeId: String?

    var id: String {
        if let nodeId {
            return "\(runId)::\(nodeId)"
        }
        return runId
    }
}

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var smithers = SmithersClient()
    @State private var destination: NavDestination = .dashboard
    @State private var terminalSessionId = UUID()
    @State private var liveRunChatSelection: LiveRunChatSelection?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                destination: $destination,
                onNewTerminal: {
                    terminalSessionId = UUID()
                }
            )
                .frame(width: 240)

            Divider()
                .background(Theme.border)

            Group {
                switch destination {
                case .chat:
                    if let agent = store.activeAgent {
                        ChatView(
                            agent: agent,
                            onSend: { store.sendMessage($0) },
                            smithers: smithers,
                            onNavigate: { destination = $0 },
                            onNewChat: {
                                store.newSession()
                                destination = .chat
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
                        .id(terminalSessionId)
                        .accessibilityIdentifier("view.terminal")
                case .dashboard:
                    DashboardView(smithers: smithers)
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
                        onOpenLiveChat: { runId, nodeId in
                            liveRunChatSelection = LiveRunChatSelection(runId: runId, nodeId: nodeId)
                        }
                    )
                        .accessibilityIdentifier("view.runs")
                case .workflows:
                    WorkflowsView(smithers: smithers, onNavigate: { destination = $0 })
                        .accessibilityIdentifier("view.workflows")
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
                case .issues:
                    IssuesView(smithers: smithers)
                        .accessibilityIdentifier("view.issues")
                case .workspaces:
                    WorkspacesView(smithers: smithers)
                        .accessibilityIdentifier("view.workspaces")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $liveRunChatSelection) { selection in
            LiveRunChatView(
                smithers: smithers,
                runId: selection.runId,
                nodeId: selection.nodeId,
                onClose: { liveRunChatSelection = nil }
            )
            .frame(minWidth: 900, minHeight: 620)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Theme.base)
        .overlay(alignment: .topLeading) {
            Button("New Chat") {
                store.newSession()
                destination = .chat
            }
            .keyboardShortcut("n", modifiers: [.command])
            .accessibilityIdentifier("shortcut.newChat")
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .accessibilityIdentifier("app.root")
        .task {
            await smithers.checkConnection()
        }
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
