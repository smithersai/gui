import SwiftUI

// MARK: - Navigation Destination

enum NavDestination: Hashable {
    case chat
    case dashboard
    case agents
    case changes
    case runs
    case workflows
    case jjhubWorkflows
    case approvals
    case prompts
    case scores
    case memory
    case search
    case sql
    case landings
    case issues
    case terminal
    case terminalCommand(binary: String, workingDirectory: String, name: String)
    case workspaces

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .terminal: return "Terminal"
        case .terminalCommand(binary: _, workingDirectory: _, name: let name): return name
        case .dashboard: return "Dashboard"
        case .agents: return "Agents"
        case .changes: return "Changes"
        case .runs: return "Runs"
        case .workflows: return "Workflows"
        case .jjhubWorkflows: return "JJHub Workflows"
        case .approvals: return "Approvals"
        case .prompts: return "Prompts"
        case .scores: return "Scores"
        case .memory: return "Memory"
        case .search: return "Search"
        case .sql: return "SQL Browser"
        case .landings: return "Landings"
        case .issues: return "Issues"
        case .workspaces: return "Workspaces"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "message"
        case .terminal: return "terminal.fill"
        case .terminalCommand(binary: _, workingDirectory: _, name: _): return "terminal.fill"
        case .dashboard: return "square.grid.2x2"
        case .agents: return "person.2"
        case .changes: return "point.3.connected.trianglepath.dotted"
        case .runs: return "play.circle"
        case .workflows: return "arrow.triangle.branch"
        case .jjhubWorkflows: return "point.3.filled.connected.trianglepath.dotted"
        case .approvals: return "checkmark.shield"
        case .prompts: return "doc.text"
        case .scores: return "chart.bar"
        case .memory: return "brain"
        case .search: return "magnifyingglass"
        case .sql: return "tablecells"
        case .landings: return "arrow.down.to.line"
        case .issues: return "exclamationmark.circle"
        case .workspaces: return "desktopcomputer"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @Binding var destination: NavDestination
    @State private var searchText: String = ""

    private let smithersNav: [NavDestination] = [
        .dashboard, .agents, .changes, .runs, .workflows, .jjhubWorkflows, .approvals,
        .prompts, .scores, .memory, .search, .sql,
        .landings, .issues, .workspaces
    ]

    var body: some View {
        VStack(spacing: 0) {
            // App title
            HStack {
                Text("Smithers")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .border(Theme.border, edges: [.bottom])

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Chat section
                    SidebarSection(title: "CHAT") {
                        NewChatMenuRow(
                            newChatAction: startNewChat,
                            terminalAction: { destination = .terminal }
                        )

                        NavRow(
                            icon: NavDestination.chat.icon,
                            label: NavDestination.chat.label,
                            isSelected: destination == .chat
                        ) {
                            destination = .chat
                        }

                        NavRow(
                            icon: NavDestination.terminal.icon,
                            label: NavDestination.terminal.label,
                            isSelected: destination == .terminal
                        ) {
                            destination = .terminal
                        }
                    }

                    // Smithers section
                    SidebarSection(title: "SMITHERS") {
                        ForEach(smithersNav, id: \.self) { nav in
                            NavRow(
                                icon: nav.icon,
                                label: nav.label,
                                isSelected: destination == nav
                            ) {
                                destination = nav
                            }
                        }
                    }

                    // Sessions list
                    SidebarSection(title: "SESSIONS") {
                        // Search
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(Theme.textTertiary)
                                .font(.system(size: 10))
                            TextField("Search chats...", text: $searchText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 11))
                                .accessibilityIdentifier("sidebar.sessionSearch")
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(Theme.inputBg)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Theme.border, lineWidth: 1)
                        )
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)

                        let groups = ["Today", "Yesterday", "Older"]
                        let allSessions = store.chatSessions().filter {
                            searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText)
                        }
                        ForEach(groups, id: \.self) { group in
                            let sessions = allSessions.filter { $0.group == group }
                            if !sessions.isEmpty {
                                Text(group)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(Theme.textTertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 8)
                                    .padding(.bottom, 2)

                                ForEach(sessions) { session in
                                    SessionRow(
                                        session: session,
                                        isSelected: destination == .chat && store.activeSessionId == session.id
                                    ) {
                                        store.selectSession(session.id)
                                        destination = .chat
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(Theme.sidebarBg)
        .accessibilityIdentifier("sidebar")
    }

    private func startNewChat() {
        store.newSession()
        destination = .chat
    }
}

// MARK: - Sidebar Components

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 4)

            content
        }
    }
}

struct NavRow: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
            .background(isSelected ? Theme.sidebarSelected : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("nav.\(label.replacingOccurrences(of: " ", with: ""))")
    }
}

struct NewChatMenuRow: View {
    let newChatAction: () -> Void
    let terminalAction: () -> Void

    var body: some View {
        Menu {
            Button(action: terminalAction) {
                Label("Terminal", systemImage: NavDestination.terminal.icon)
            }
            Button(action: newChatAction) {
                Label("New Chat", systemImage: NavDestination.chat.icon)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text("New Chat")
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundColor(Theme.textSecondary)
            .background(Color.clear)
            .cornerRadius(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("sidebar.newChat")
    }
}

struct SessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(session.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(session.timestamp)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                }
                if !session.preview.isEmpty {
                    Text(session.preview)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.sidebarSelected : Color.clear)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("session.\(session.id)")
    }
}

// MARK: - Edge Border (kept from original)

extension View {
    func border(_ color: Color, edges: [Edge]) -> some View {
        overlay(EdgeBorder(width: 1, edges: edges).foregroundColor(color))
    }
}

struct EdgeBorder: Shape {
    var width: CGFloat
    var edges: [Edge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            var x: CGFloat {
                switch edge {
                case .top, .bottom, .leading: return rect.minX
                case .trailing: return rect.maxX - width
                }
            }
            var y: CGFloat {
                switch edge {
                case .top, .leading, .trailing: return rect.minY
                case .bottom: return rect.maxY - width
                }
            }
            var w: CGFloat {
                switch edge {
                case .top, .bottom: return rect.width
                case .leading, .trailing: return width
                }
            }
            var h: CGFloat {
                switch edge {
                case .top, .bottom: return width
                case .leading, .trailing: return rect.height
                }
            }
            path.addRect(CGRect(x: x, y: y, width: w, height: h))
        }
        return path
    }
}
