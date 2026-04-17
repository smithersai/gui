import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - Navigation Destination

enum NavDestination: Hashable {
    case chat
    case dashboard
    case vcsDashboard
    case agents
    case changes
    case runs
    case snapshots
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
    case settings

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
        case .vcsDashboard: return "VCS Dashboard"
        case .agents: return "Agents"
        case .changes: return "Changes"
        case .runs: return "Runs"
        case .snapshots: return "Snapshots"
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
        case .settings: return "Settings"
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
        case .vcsDashboard: return "point.3.connected.trianglepath.dotted"
        case .agents: return "person.2"
        case .changes: return "point.3.connected.trianglepath.dotted"
        case .runs: return "play.circle"
        case .snapshots: return "camera"
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
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var surfaceNotifications = SurfaceNotificationStore.shared
    @Binding var destination: NavDestination
    @Binding private var developerDebugPanelVisible: Bool
    @State private var searchText: String = ""
    @State private var smithersVersion: String?
    @AppStorage(AppPreferenceKeys.smithersFeatureEnabled) private var smithersFeatureEnabled = false
    @AppStorage(AppPreferenceKeys.vcsFeatureEnabled) private var vcsFeatureEnabled = false
    @State private var renameSessionID: String?
    @State private var renameSessionTitle: String = ""
    @State private var renameTerminalID: String?
    @State private var renameTerminalTitle: String = ""
    @State private var deleteSessionID: String?
    @State private var deleteSessionTitle: String = ""
    @State private var terminateTerminalID: String?
    @State private var terminateTerminalTitle: String = ""
    private let developerDebugAvailable: Bool
    private let onOpenNewTabPicker: () -> Void
    private let versionProvider: (() async -> String?)?

    init(
        store: SessionStore,
        destination: Binding<NavDestination>,
        developerDebugPanelVisible: Binding<Bool> = .constant(false),
        developerDebugAvailable: Bool = DeveloperDebugMode.isEnabled,
        onOpenNewTabPicker: @escaping () -> Void = {},
        versionProvider: (() async -> String?)? = nil
    ) {
        self.store = store
        self._destination = destination
        self._developerDebugPanelVisible = developerDebugPanelVisible
        self.developerDebugAvailable = developerDebugAvailable
        self.onOpenNewTabPicker = onOpenNewTabPicker
        self.versionProvider = versionProvider
    }

    private static let smithersNav: Set<NavDestination> = [
        .dashboard, .agents, .runs, .snapshots, .workflows, .triggers, .approvals,
        .prompts, .scores, .memory, .search, .sql, .workspaces, .logs
    ]

    private static let vcsNav: Set<NavDestination> = [
        .vcsDashboard, .changes, .jjhubWorkflows, .landings, .tickets, .issues
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
                    if smithersFeatureEnabled || vcsFeatureEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            if smithersFeatureEnabled {
                                NavRow(
                                    icon: "square.grid.2x2",
                                    label: "Smithers",
                                    isSelected: SidebarView.smithersNav.contains(destination)
                                ) {
                                    destination = .dashboard
                                }
                            }

                            if vcsFeatureEnabled {
                                NavRow(
                                    icon: "point.3.connected.trianglepath.dotted",
                                    label: "VCS",
                                    isSelected: SidebarView.vcsNav.contains(destination)
                                ) {
                                    destination = .vcsDashboard
                                }
                            }
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                    }

                    SidebarSection(
                        title: "WORKSPACES",
                        trailingAccessory: {
                            Button(action: onOpenNewTabPicker) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sidebar.newTabPlus")
                            .help("New Tab (⌘T)")
                        }
                    ) {
                        NewChatMenuRow(
                            newChatAction: startNewChat,
                            terminalAction: startNewTerminal
                        )
                        .padding(.bottom, 6)

                        workspaceList
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

            VStack(spacing: 0) {
                Divider().background(Theme.border)
                NavRow(
                    icon: NavDestination.settings.icon,
                    label: NavDestination.settings.label,
                    isSelected: destination == .settings
                ) {
                    destination = .settings
                }
                .padding(.vertical, 8)

                if let smithersVersion {
                    let meetsMin = SmithersClient.versionAtLeast(
                        smithersVersion,
                        minimum: SmithersClient.minimumOrchestratorVersion
                    )
                    VStack(spacing: 2) {
                        Text("Smithers \(smithersVersion)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(meetsMin ? Theme.textTertiary : Theme.danger)
                            .accessibilityIdentifier("sidebar.smithersVersion")
                        if !meetsMin {
                            Text("Update required (≥ \(SmithersClient.minimumOrchestratorVersion))")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(Theme.danger)
                                .accessibilityIdentifier("sidebar.smithersVersionWarning")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
                }
            }
        }
        .task {
            if smithersVersion == nil, let versionProvider {
                smithersVersion = await versionProvider()
            }
        }
        .alert("Rename thread", isPresented: renameAlertBinding) {
            TextField("Session title", text: $renameSessionTitle)
                .accessibilityIdentifier("sidebar.rename.field")
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
            Text("Enter a new title for this thread.")
        }
        .alert("Rename terminal", isPresented: renameTerminalAlertBinding) {
            TextField("Terminal title", text: $renameTerminalTitle)
                .accessibilityIdentifier("sidebar.renameTerminal.field")
            Button("Cancel", role: .cancel) {
                renameTerminalID = nil
                renameTerminalTitle = ""
            }
            Button("Save") {
                if let terminalID = renameTerminalID {
                    store.renameTerminalTab(terminalID, to: renameTerminalTitle)
                }
                renameTerminalID = nil
                renameTerminalTitle = ""
            }
        } message: {
            Text("Enter a new title for this terminal.")
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
        .confirmationDialog(
            "Terminate Terminal?",
            isPresented: terminateTerminalConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Terminate Terminal", role: .destructive) {
                confirmTerminateTerminal()
            }
            Button("Cancel", role: .cancel) {
                clearTerminateTerminalSelection()
            }
        } message: {
            Text("Terminate \"\(terminateTerminalTitle)\"? This will stop the terminal session and close the workspace. This action cannot be undone.")
        }
        .background(Theme.sidebarBg)
        .accessibilityIdentifier("sidebar")
    }

    private func openCurrentChat() {
        _ = store.ensureActiveSession()
        destination = .chat
    }

    private func openCurrentTerminal() {
        let terminalId = store.ensureTerminalTab()
        destination = .terminal(id: terminalId)
    }

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.textTertiary)
                    .font(.system(size: 10))
                TextField("Search workspaces...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("sidebar.workspaceSearch")
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

            let groups = ["Pinned", "Today", "Yesterday", "Older"]
            let _ = surfaceNotifications.unreadSurfaceIds
            let _ = surfaceNotifications.focusedIndicatorSurfaceIds
            let allTabs = store.sidebarWorkspaces(matching: searchText)

            if allTabs.isEmpty {
                Text("No workspaces yet")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            ForEach(groups, id: \.self) { group in
                let tabs = allTabs.filter { $0.group == group }
                if !tabs.isEmpty {
                    Text(group)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    ForEach(tabs) { tab in
                        SidebarWorkspaceRow(
                            tab: tab,
                            isSelected: isSelected(tab)
                        ) {
                            selectTab(tab)
                        }
                        .contextMenu {
                            if tab.kind == .chat, let sessionID = tab.chatSessionId {
                                Button(tab.isPinned ? "Unpin thread" : "Pin thread") {
                                    store.toggleSessionPinned(sessionID)
                                }
                                Button("Rename thread") {
                                    beginRenameSession(sessionID: sessionID, currentTitle: tab.title)
                                }
                                Button("Archive thread") {
                                    store.archiveSession(sessionID)
                                    destination = .chat
                                }
                                .disabled(!store.canArchiveSession(sessionID))
                                Button(tab.isUnread ? "Mark as read" : "Mark as unread") {
                                    store.toggleSessionUnread(sessionID)
                                }
                                Divider()
                                Button("Copy working directory") {
                                    copyTextToClipboard(tab.workingDirectory ?? store.sessionWorkingDirectory(sessionID) ?? "")
                                }
                                .disabled((tab.workingDirectory ?? store.sessionWorkingDirectory(sessionID)) == nil)
                                Button("Copy session ID") {
                                    copyTextToClipboard(tab.sessionIdentifier ?? store.sessionIdentifier(sessionID) ?? sessionID)
                                }
                                Button("Copy deeplink") {
                                    copyTextToClipboard(store.sessionDeeplink(sessionID) ?? "")
                                }
                                .disabled(store.sessionDeeplink(sessionID) == nil)
                                Divider()
                                Button("Fork into local") {
                                    if store.forkSessionIntoLocal(sessionID) != nil {
                                        destination = .chat
                                        AppNotifications.shared.post(
                                            title: "Thread forked",
                                            message: "Created a local fork.",
                                            level: .success
                                        )
                                    }
                                }
                                Button("Fork into new worktree") {
                                    forkSessionIntoNewWorktree(sessionID)
                                }
                                .disabled(!store.canArchiveSession(sessionID))
                            }
                            if tab.kind == .terminal, let terminalId = tab.terminalId {
                                Button(tab.isPinned ? "Unpin terminal" : "Pin terminal") {
                                    store.toggleTerminalPinned(terminalId)
                                }
                                Button("Rename terminal") {
                                    beginRenameTerminal(terminalID: terminalId, currentTitle: tab.title)
                                }
                                Divider()
                                Button("Copy working directory") {
                                    copyTextToClipboard(tab.workingDirectory ?? store.terminalWorkingDirectory(terminalId) ?? "")
                                }
                                .disabled((tab.workingDirectory ?? store.terminalWorkingDirectory(terminalId)) == nil)
                                Button("Copy workspace ID") {
                                    copyTextToClipboard(terminalId)
                                }
                                Button("Copy tmux attach command") {
                                    copyTextToClipboard(store.terminalAttachCommand(terminalId) ?? "")
                                }
                                .disabled(store.terminalAttachCommand(terminalId) == nil)
                                Divider()
                                Button("Terminate terminal", role: .destructive) {
                                    requestTerminateTerminal(terminalId: terminalId, title: tab.title)
                                }
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

    private var renameTerminalAlertBinding: Binding<Bool> {
        Binding(
            get: { renameTerminalID != nil },
            set: { presented in
                if !presented {
                    renameTerminalID = nil
                    renameTerminalTitle = ""
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

    private var terminateTerminalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { terminateTerminalID != nil },
            set: { presented in
                if !presented {
                    clearTerminateTerminalSelection()
                }
            }
        )
    }

    private func requestTerminateTerminal(terminalId: String, title: String) {
        terminateTerminalID = terminalId
        terminateTerminalTitle = title
    }

    private func confirmTerminateTerminal() {
        guard let terminalId = terminateTerminalID else { return }
        if case .terminal(let activeId) = destination, activeId == terminalId {
            destination = .dashboard
        }
        store.removeTerminalTab(terminalId)
        clearTerminateTerminalSelection()
    }

    private func clearTerminateTerminalSelection() {
        terminateTerminalID = nil
        terminateTerminalTitle = ""
    }

    private func beginRenameSession(sessionID: String, currentTitle: String) {
        renameSessionID = sessionID
        renameSessionTitle = currentTitle
    }

    private func beginRenameTerminal(terminalID: String, currentTitle: String) {
        renameTerminalID = terminalID
        renameTerminalTitle = currentTitle
    }

    private func beginDeleteSession(sessionID: String, currentTitle: String) {
        deleteSessionID = sessionID
        deleteSessionTitle = currentTitle
    }

    private func forkSessionIntoNewWorktree(_ sessionID: String) {
        Task {
            let result = await store.forkSessionIntoNewWorktree(sessionID)
            switch result {
            case .success:
                destination = .chat
                AppNotifications.shared.post(
                    title: "Thread forked",
                    message: "Created a new git worktree.",
                    level: .success
                )
            case .failure(let error):
                AppNotifications.shared.post(
                    title: "Worktree fork failed",
                    message: error.localizedDescription,
                    level: .error
                )
            }
        }
    }
}

private func copyTextToClipboard(_ text: String) {
    #if os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    #endif
}

// MARK: - Sidebar Components

struct SidebarSection<Content: View, TrailingAccessory: View>: View {
    let title: String
    let trailingAccessory: TrailingAccessory
    @ViewBuilder let content: Content

    init(
        title: String,
        @ViewBuilder trailingAccessory: () -> TrailingAccessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailingAccessory = trailingAccessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                trailingAccessory
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)

            content
        }
    }
}

extension SidebarSection where TrailingAccessory == EmptyView {
    init(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailingAccessory = EmptyView()
        self.content = content()
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? Theme.accent : Theme.textSecondary)
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("nav.\(label.replacingOccurrences(of: " ", with: ""))")
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("session.\(session.id)")
    }
}

struct SidebarWorkspaceRow: View {
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
                        .font(.system(size: 11, weight: tab.isUnread ? .semibold : .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if tab.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(Theme.textTertiary)
                            .accessibilityIdentifier("workspace.pinned.\(tab.id)")
                    }

                    if tab.isUnread {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 6, height: 6)
                            .accessibilityIdentifier("workspace.unread.\(tab.id)")
                    }

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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .themedSidebarRowBackground(isSelected: isSelected, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("workspace.\(tab.id)")
    }
}

typealias SidebarTabRow = SidebarWorkspaceRow

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

struct SmithersVersionWarningBanner: View {
    let installed: String
    private let required = SmithersClient.minimumOrchestratorVersion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Smithers \(installed) is too old — update to ≥ \(required)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text("Run lifecycle and heartbeat status will be inaccurate until you upgrade smithers-orchestrator.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger)
        .accessibilityIdentifier("smithersVersion.banner")
    }
}
