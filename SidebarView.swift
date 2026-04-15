import SwiftUI

// MARK: - Navigation Destination

enum NavDestination: Hashable {
    case chat
    case dashboard
    case agents
    case changes
    case runs
    case workflows
    case triggers
    case jjhubWorkflows
    case approvals
    case prompts
    case scores
    case memory
    case search
    case sql
    case landings
    case tickets
    case issues
    case terminal(id: String = "default")
    case terminalCommand(binary: String, workingDirectory: String, name: String)
    case liveRun(runId: String, nodeId: String?)
    case runInspect(runId: String, workflowName: String?)
    case workspaces
    case logs

    var isTerminal: Bool {
        if case .terminal = self { return true }
        if case .terminalCommand = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .chat: return "Chat"
        case .terminal: return "Terminal"
        case .terminalCommand(binary: _, workingDirectory: _, name: let name): return name
        case .liveRun: return "Live Run"
        case .runInspect: return "Run Inspector"
        case .dashboard: return "Dashboard"
        case .agents: return "Agents"
        case .changes: return "Changes"
        case .runs: return "Runs"
        case .workflows: return "Workflows"
        case .triggers: return "Triggers"
        case .jjhubWorkflows: return "JJHub Workflows"
        case .approvals: return "Approvals"
        case .prompts: return "Prompts"
        case .scores: return "Scores"
        case .memory: return "Memory"
        case .search: return "Search"
        case .sql: return "SQL Browser"
        case .landings: return "Landings"
        case .tickets: return "Tickets"
        case .issues: return "Issues"
        case .workspaces: return "Workspaces"
        case .logs: return "Logs"
        }
    }

    var icon: String {
        switch self {
        case .chat: return "message"
        case .terminal: return "terminal.fill"
        case .terminalCommand(binary: _, workingDirectory: _, name: _): return "terminal.fill"
        case .liveRun: return "dot.radiowaves.left.and.right"
        case .runInspect: return "sidebar.right"
        case .dashboard: return "square.grid.2x2"
        case .agents: return "person.2"
        case .changes: return "point.3.connected.trianglepath.dotted"
        case .runs: return "play.circle"
        case .workflows: return "arrow.triangle.branch"
        case .triggers: return "clock.arrow.circlepath"
        case .jjhubWorkflows: return "point.3.filled.connected.trianglepath.dotted"
        case .approvals: return "checkmark.shield"
        case .prompts: return "doc.text"
        case .scores: return "chart.bar"
        case .memory: return "brain"
        case .search: return "magnifyingglass"
        case .sql: return "tablecells"
        case .landings: return "arrow.down.to.line"
        case .tickets: return "ticket"
        case .issues: return "exclamationmark.circle"
        case .workspaces: return "desktopcomputer"
        case .logs: return "doc.text.below.ecg"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @Binding var destination: NavDestination
    @Binding private var developerDebugPanelVisible: Bool
    @State private var searchText: String = ""
    @State private var smithersCollapsed = false
    @State private var vcsCollapsed = true
    @State private var renameSessionID: String?
    @State private var renameSessionTitle: String = ""
    @State private var deleteSessionID: String?
    @State private var deleteSessionTitle: String = ""
    private let developerDebugAvailable: Bool

    init(
        store: SessionStore,
        destination: Binding<NavDestination>,
        developerDebugPanelVisible: Binding<Bool> = .constant(false),
        developerDebugAvailable: Bool = DeveloperDebugMode.isEnabled,
        smithersCollapsed: Bool = false,
        vcsCollapsed: Bool = true
    ) {
        self.store = store
        self._destination = destination
        self._developerDebugPanelVisible = developerDebugPanelVisible
        self.developerDebugAvailable = developerDebugAvailable
        self._smithersCollapsed = State(initialValue: smithersCollapsed)
        self._vcsCollapsed = State(initialValue: vcsCollapsed)
    }

    private let smithersNav: [NavDestination] = [
        .dashboard, .agents, .runs, .workflows, .triggers, .approvals,
        .prompts, .scores, .memory, .search, .sql, .workspaces, .logs
    ]

    private let vcsNav: [NavDestination] = [
        .changes, .jjhubWorkflows, .landings, .tickets, .issues
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
                            terminalAction: startNewTerminal
                        )

                        NavRow(
                            icon: NavDestination.chat.icon,
                            label: NavDestination.chat.label,
                            isSelected: destination == .chat
                        ) {
                            openCurrentChat()
                        }

                        NavRow(
                            icon: NavDestination.terminal().icon,
                            label: NavDestination.terminal().label,
                            isSelected: destination.isTerminal
                        ) {
                            openCurrentTerminal()
                        }
                    }

                    SidebarSection(title: "TABS") {
                        tabList
                    }

                    // Smithers section
                    CollapsibleSidebarSection(title: "SMITHERS", isCollapsed: $smithersCollapsed) {
                        ForEach(smithersNav, id: \.self) { nav in
                            NavRow(
                                icon: nav.icon,
                                label: nav.label,
                                isSelected: isSelected(nav)
                            ) {
                                destination = nav
                            }
                        }
                    }

                    // VCS section
                    CollapsibleSidebarSection(title: "VCS", isCollapsed: $vcsCollapsed) {
                        ForEach(vcsNav, id: \.self) { nav in
                            NavRow(
                                icon: nav.icon,
                                label: nav.label,
                                isSelected: isSelected(nav)
                            ) {
                                destination = nav
                            }
                        }
                    }

                    if developerDebugAvailable {
                        SidebarSection(title: "DEVELOPER") {
                            NavRow(
                                icon: "wrench.and.screwdriver",
                                label: "Developer Debug",
                                isSelected: developerDebugPanelVisible
                            ) {
                                developerDebugPanelVisible.toggle()
                                AppLogger.ui.info(
                                    "Developer debug panel toggled",
                                    metadata: ["visible": String(developerDebugPanelVisible)]
                                )
                            }
                        }
                    }
                }
            }
        }
        .alert("Rename Session", isPresented: renameAlertBinding) {
            TextField("Session title", text: $renameSessionTitle)
            Button("Cancel", role: .cancel) {
                renameSessionID = nil
                renameSessionTitle = ""
            }
            Button("Save") {
                if let sessionID = renameSessionID {
                    store.renameSession(sessionID, to: renameSessionTitle)
                }
                renameSessionID = nil
                renameSessionTitle = ""
            }
        } message: {
            Text("Enter a new title for this session.")
        }
        .alert("Delete Session?", isPresented: deleteAlertBinding) {
            Button("Cancel", role: .cancel) {
                deleteSessionID = nil
                deleteSessionTitle = ""
            }
            Button("Delete", role: .destructive) {
                if let sessionID = deleteSessionID {
                    store.deleteSession(sessionID)
                }
                deleteSessionID = nil
                deleteSessionTitle = ""
            }
        } message: {
            Text("This permanently removes \"\(deleteSessionTitle)\" and its chat history.")
        }
        .background(Theme.sidebarBg)
        .accessibilityIdentifier("sidebar")
    }

    private func startNewChat() {
        store.newSession(reusingEmptyPlaceholder: false)
        destination = .chat
    }

    private func startNewTerminal() {
        let terminalId = store.addTerminalTab()
        destination = .terminal(id: terminalId)
    }

    private func openCurrentChat() {
        _ = store.ensureActiveSession()
        destination = .chat
    }

    private func openCurrentTerminal() {
        let terminalId = store.ensureTerminalTab()
        destination = .terminal(id: terminalId)
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textTertiary)
                    .font(.system(size: 10))
                TextField("Search tabs...", text: $searchText)
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
            let allTabs = store.sidebarTabs(matching: searchText)

            if allTabs.isEmpty {
                Text("No tabs yet")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            ForEach(groups, id: \.self) { group in
                let tabs = allTabs.filter { $0.group == group }
                if !tabs.isEmpty {
                    Text(group)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    ForEach(tabs) { tab in
                        SidebarTabRow(
                            tab: tab,
                            isSelected: isSelected(tab)
                        ) {
                            selectTab(tab)
                        }
                        .contextMenu {
                            if tab.kind == .chat, let sessionID = tab.chatSessionId {
                                Button("Load Session") {
                                    store.loadSessionFromPersistence(sessionID)
                                    destination = .chat
                                }
                                Button("Rename Session…") {
                                    beginRenameSession(sessionID: sessionID, currentTitle: tab.title)
                                }
                                Button("Delete Session", role: .destructive) {
                                    beginDeleteSession(sessionID: sessionID, currentTitle: tab.title)
                                }
                                .disabled(!store.canDeleteSession(sessionID))
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectTab(_ tab: SidebarTab) {
        switch tab.kind {
        case .chat:
            if let sessionId = tab.chatSessionId {
                store.selectSession(sessionId)
                destination = .chat
            }
        case .run:
            if let runId = tab.runId {
                destination = .liveRun(runId: runId, nodeId: nil)
            }
        case .terminal:
            if let terminalId = tab.terminalId {
                destination = .terminal(id: terminalId)
            }
        }
    }

    private func isSelected(_ nav: NavDestination) -> Bool {
        if case .runInspect = destination, nav == .runs {
            return true
        }
        return destination == nav
    }

    private func isSelected(_ tab: SidebarTab) -> Bool {
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

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renameSessionID != nil },
            set: { presented in
                if !presented {
                    renameSessionID = nil
                    renameSessionTitle = ""
                }
            }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteSessionID != nil },
            set: { presented in
                if !presented {
                    deleteSessionID = nil
                    deleteSessionTitle = ""
                }
            }
        )
    }

    private func beginRenameSession(sessionID: String, currentTitle: String) {
        renameSessionID = sessionID
        renameSessionTitle = currentTitle
    }

    private func beginDeleteSession(sessionID: String, currentTitle: String) {
        deleteSessionID = sessionID
        deleteSessionTitle = currentTitle
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

struct CollapsibleSidebarSection<Content: View>: View {
    let title: String
    @Binding var isCollapsed: Bool
    @ViewBuilder let content: Content

    private var accessibilityKey: String {
        title.replacingOccurrences(of: " ", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: { isCollapsed.toggle() }) {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                    Text(title)
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                }
                .foregroundColor(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.section.\(accessibilityKey)")

            if !isCollapsed {
                content
            }
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
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
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
                Label("Terminal", systemImage: NavDestination.terminal().icon)
            }
            .accessibilityIdentifier("sidebar.newTerminal")

            Button(action: newChatAction) {
                Label("New Chat", systemImage: NavDestination.chat.icon)
            }
            .accessibilityIdentifier("sidebar.newChatMenuItem")
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
            .themedSidebarRowBackground(isSelected: false, cornerRadius: 6)
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
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("session.\(session.id)")
    }
}

struct SidebarTabRow: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Image(systemName: tab.kind.icon)
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? Theme.accent : Theme.textTertiary)
                        .frame(width: 14)

                    Text(tab.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(tab.timestamp)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                }

                if !tab.preview.isEmpty {
                    Text(tab.preview)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .padding(.leading, 21)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityIdentifier("tab.\(tab.id)")
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
