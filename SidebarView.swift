import SwiftUI

#if os(macOS)
import AppKit
#endif

// NOTE: `NavDestination` moved to `SharedNavigation.swift` in ticket 0122.

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var surfaceNotifications = SurfaceNotificationStore.shared
    #if os(macOS)
    // 0126: Remote-mode section. Read directly from the shared controller so
    // the sidebar reacts to sign-in/out without plumbing bindings through
    // ContentView (which 0122 just refactored and the ticket asks us to keep
    // narrow).
    @ObservedObject private var remoteMode: RemoteModeController = .shared
    #endif
    @Binding var destination: NavDestination
    @Binding private var developerDebugPanelVisible: Bool
    @State private var smithersVersion: String?
    @State private var renameTerminalID: String?
    @State private var renameTerminalTitle: String = ""
    @State private var terminateTerminalID: String?
    @State private var terminateTerminalTitle: String = ""
    private let developerDebugAvailable: Bool
    private let onOpenNewTabPicker: () -> Void
    private let versionProvider: (() async -> String?)?

    fileprivate static let guiVersion: String = {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "0.0.1"
    }()

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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SidebarSection(
                        title: localSectionTitle,
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
                        workspaceList
                    }

                    #if os(macOS)
                    // 0126: Remote section. Only rendered when the
                    // `remote_sandbox_enabled` flag is on. With flag off the
                    // sidebar is visually indistinguishable from pre-0126.
                    if remoteMode.isRemoteFeatureEnabled {
                        SidebarSection(title: "REMOTE") {
                            remoteSectionContent
                        }
                    }
                    #endif

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

                VStack(spacing: 2) {
                    if let smithersVersion {
                        let meetsMin = SmithersClient.versionAtLeast(
                            smithersVersion,
                            minimum: SmithersClient.minimumOrchestratorVersion
                        )
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
                    Text("GUI \(Self.guiVersion)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.textTertiary)
                        .accessibilityIdentifier("sidebar.guiVersion")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 6)
            }
        }
        .task {
            if smithersVersion == nil, let versionProvider {
                smithersVersion = await versionProvider()
            }
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

    private var workspaceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = ["Pinned", "Today", "Yesterday", "Older"]
            let _ = surfaceNotifications.unreadSurfaceIds
            let _ = surfaceNotifications.focusedIndicatorSurfaceIds
            let allTabs = store.sidebarWorkspaces(matching: "")

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
                            if tab.kind == .terminal, let terminalId = tab.terminalId {
                                Button(tab.isPinned ? "Unpin terminal" : "Pin terminal") {
                                    store.toggleTerminalPinned(terminalId)
                                }
                                Button("Rename terminal") {
                                    beginRenameTerminal(terminalID: terminalId, currentTitle: tab.title)
                                }
                                if tab.agentKind?.supportsResume == true {
                                    Button("Fork chat") {
                                        store.forkTerminalTab(terminalId)
                                    }
                                    .disabled(!store.canForkTerminalTab(terminalId))
                                    .accessibilityIdentifier("sidebar.contextMenu.forkChat")
                                }
                                Divider()
                                Button("Copy working directory") {
                                    copyTextToClipboard(tab.workingDirectory ?? store.terminalWorkingDirectory(terminalId) ?? "")
                                }
                                .disabled((tab.workingDirectory ?? store.terminalWorkingDirectory(terminalId)) == nil)
                                Button("Copy workspace ID") {
                                    copyTextToClipboard(terminalId)
                                }
                                Button("Copy session ID") {
                                    copyTextToClipboard(tab.agentSessionId ?? "")
                                }
                                .disabled(tab.agentSessionId == nil)
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

                        if tab.kind == .terminal,
                           let terminalId = tab.terminalId,
                           let workspace = store.terminalWorkspaces[terminalId] {
                            SidebarTerminalPaneChildren(
                                workspace: workspace,
                                tabId: tab.id,
                                isParentSelected: isSelected(tab)
                            ) { surfaceId in
                                destination = .terminal(id: terminalId)
                                workspace.focusSurface(surfaceId)
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectTab(_ tab: SidebarTab) {
        switch tab.kind {
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

    private func beginRenameTerminal(terminalID: String, currentTitle: String) {
        renameTerminalID = terminalID
        renameTerminalTitle = currentTitle
    }

    // MARK: - 0126 Remote section

    private var localSectionTitle: String {
        #if os(macOS)
        return remoteMode.isRemoteFeatureEnabled ? "LOCAL" : "Smithers"
        #else
        return "Smithers"
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    private var remoteSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            remoteStatusRow

            if remoteMode.isSignedIn {
                if remoteMode.openWorkspaceTabs.isEmpty {
                    Text("No remote sandboxes open")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("sidebar.remote.empty")
                } else {
                    ForEach(remoteMode.openWorkspaceTabs) { tab in
                        remoteWorkspaceRow(tab)
                    }
                }

                NavRow(
                    icon: "rectangle.stack",
                    label: "Browse sandboxes",
                    isSelected: destination == .workspaces
                ) {
                    destination = .workspaces
                }
            }
        }
    }

    @ViewBuilder
    private var remoteStatusRow: some View {
        let label: String = {
            switch remoteMode.phase {
            case .disabled, .signedOut: return "Signed out"
            case .signingIn: return "Signing in…"
            case .bootBlocked: return "Connecting…"
            case .slowBoot: return "This is taking longer than expected…"
            case .stalledBoot: return "Still connecting — tap to cancel"
            case .active: return "Signed in"
            case .reconnecting: return "Reconnecting…"
            case .whitelistDenied(let m): return "Access denied: \(m)"
            case .error(let m): return "Error: \(m)"
            }
        }()
        HStack(spacing: 8) {
            Image(systemName: remoteStatusIcon)
                .font(.system(size: 11))
                .foregroundColor(remoteStatusColor)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(2)
            Spacer()
            if case .stalledBoot = remoteMode.phase {
                Button("Cancel") {
                    Task { await remoteMode.cancelBoot() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.danger)
                .accessibilityIdentifier("sidebar.remote.cancelBoot")
            } else if remoteMode.isSignedIn {
                Button("Sign out") {
                    Task { await remoteMode.signOut() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Theme.textTertiary)
                .accessibilityIdentifier("sidebar.remote.signOut")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .accessibilityIdentifier("sidebar.remote.statusRow")
    }

    private var remoteStatusIcon: String {
        switch remoteMode.phase {
        case .active: return "checkmark.icloud.fill"
        case .reconnecting, .slowBoot, .stalledBoot, .bootBlocked, .signingIn:
            return "icloud.and.arrow.down"
        case .whitelistDenied, .error: return "exclamationmark.icloud"
        default: return "icloud.slash"
        }
    }

    private var remoteStatusColor: Color {
        switch remoteMode.phase {
        case .active: return Theme.success
        case .reconnecting, .slowBoot, .bootBlocked, .signingIn: return Theme.warning
        case .stalledBoot, .whitelistDenied, .error: return Theme.danger
        default: return Theme.textTertiary
        }
    }

    @ViewBuilder
    private func remoteWorkspaceRow(_ tab: RemoteWorkspaceTab) -> some View {
        Button {
            // 0138 will install a dedicated remote-workspace route. Until
            // that lands, route remote-tab selections to the existing
            // `.workspaces` destination so the user still has a surface.
            destination = .workspaces
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.accent)
                    .frame(width: 12)
                Text(tab.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Close sandbox") {
                remoteMode.closeRemoteWorkspace(id: tab.id)
            }
        }
        .accessibilityIdentifier("sidebar.remote.workspace.\(tab.id)")
    }
    #endif

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

struct SidebarWorkspaceRow: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
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

struct SidebarTerminalPaneChildren: View {
    @ObservedObject var workspace: TerminalWorkspace
    let tabId: String
    let isParentSelected: Bool
    let onSelectPane: (SurfaceID) -> Void
    @State private var renameSurfaceId: SurfaceID?
    @State private var renameSurfaceTitle: String = ""

    var body: some View {
        let surfaceIds = workspace.layout.surfaceIds
        if surfaceIds.count > 1 {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(surfaceIds, id: \.self) { surfaceId in
                    if let surface = workspace.surfaces[surfaceId] {
                        paneRow(surface: surface, isFocused: workspace.focusedSurfaceId == surfaceId)
                    }
                }
            }
            .alert("Rename surface", isPresented: renameSurfaceAlertBinding) {
                TextField("Surface title", text: $renameSurfaceTitle)
                Button("Cancel", role: .cancel) {
                    renameSurfaceId = nil
                    renameSurfaceTitle = ""
                }
                Button("Save") {
                    if let surfaceId = renameSurfaceId {
                        workspace.updateSurfaceTitle(surfaceId: surfaceId, title: renameSurfaceTitle)
                    }
                    renameSurfaceId = nil
                    renameSurfaceTitle = ""
                }
            } message: {
                Text("Enter a new title for this surface.")
            }
        }
    }

    private var renameSurfaceAlertBinding: Binding<Bool> {
        Binding(
            get: { renameSurfaceId != nil },
            set: { presented in
                if !presented {
                    renameSurfaceId = nil
                    renameSurfaceTitle = ""
                }
            }
        )
    }

    @ViewBuilder
    private func paneRow(surface: WorkspaceSurface, isFocused: Bool) -> some View {
        let isHighlighted = isParentSelected && isFocused
        Button {
            onSelectPane(surface.id)
        } label: {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 14)
                    .padding(.leading, 10)
                Text(surface.title)
                    .font(.system(size: 11, weight: isHighlighted ? .semibold : .regular))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .themedSidebarRowBackground(isSelected: isHighlighted, cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .contextMenu {
            Button("Rename surface") {
                renameSurfaceId = surface.id
                renameSurfaceTitle = surface.title
            }
        }
        .accessibilityIdentifier("workspace.pane.\(tabId).\(surface.id.rawValue)")
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

struct SmithersVersionWarningBanner: View {
    let installed: String
    let onUpgrade: () -> Void
    var upgradeStatus: SmithersUpgrader.Status = .idle

    private let required = SmithersClient.minimumOrchestratorVersion

    private var statusText: String? {
        switch upgradeStatus {
        case .idle: return nil
        case .running(let step): return step
        case .failed(let msg): return "Update failed: \(msg)"
        case .succeeded(let summary): return summary
        }
    }

    private var isRunning: Bool {
        if case .running = upgradeStatus { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
                .font(.system(size: 12))
            Text("Smithers \(installed) is too old — update to ≥ \(required).")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            if let statusText {
                Text("· \(statusText)")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button(action: onUpgrade) {
                HStack(spacing: 4) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    }
                    Text(isRunning ? "Updating…" : "Update")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.white.opacity(isRunning ? 0.15 : 0.22))
                .foregroundColor(.white)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isRunning)
            .accessibilityIdentifier("smithersVersion.upgradeButton")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger)
        .accessibilityIdentifier("smithersVersion.banner")
    }
}
