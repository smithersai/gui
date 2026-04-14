import SwiftUI

struct ContentView: View {
    @StateObject private var store = SessionStore()
    @StateObject private var smithers = SmithersClient()
    @State private var destination: NavDestination = .chat

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store, destination: $destination)
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
                    } else {
                        emptyState("No active session", icon: "message")
                    }
                case .terminal:
                    TerminalView()
                case .dashboard:
                    DashboardView(smithers: smithers)
                case .runs:
                    RunsView(smithers: smithers)
                case .workflows:
                    WorkflowsView(smithers: smithers)
                case .approvals:
                    ApprovalsView(smithers: smithers)
                case .prompts:
                    PromptsView(smithers: smithers)
                case .scores:
                    ScoresView(smithers: smithers)
                case .memory:
                    MemoryView(smithers: smithers)
                case .search:
                    SearchView(smithers: smithers)
                case .landings:
                    LandingsView(smithers: smithers)
                case .issues:
                    IssuesView(smithers: smithers)
                case .workspaces:
                    WorkspacesView(smithers: smithers)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Theme.base)
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
