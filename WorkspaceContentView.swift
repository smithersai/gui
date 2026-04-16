import SwiftUI

struct TerminalWorkspaceRouteView: View {
    @ObservedObject var store: SessionStore
    let terminalId: String
    var onClose: () -> Void

    @State private var workspace: TerminalWorkspace?

    private var currentWorkspace: TerminalWorkspace? {
        workspace ?? store.terminalWorkspaceIfAvailable(terminalId)
    }

    var body: some View {
        Group {
            if let currentWorkspace {
                TerminalWorkspaceView(
                    workspace: currentWorkspace,
                    onCloseWorkspace: onClose
                )
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Opening terminal workspace...")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.base)
            }
        }
        .onAppear {
            workspace = store.ensureTerminalWorkspace(terminalId)
        }
    }
}

struct TerminalWorkspaceView: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject private var notifications = SurfaceNotificationStore.shared
    var onCloseWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            WorkspaceSplitNodeView(
                workspace: workspace,
                node: workspace.layout,
                onCloseWorkspace: onCloseWorkspace
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.base)
        .onAppear {
            if let focusedSurfaceId = workspace.focusedSurfaceId {
                notifications.setFocusedSurface(focusedSurfaceId, workspaceId: workspace.id)
            }
        }
        .accessibilityIdentifier("terminalWorkspace.root")
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                Text(workspace.displayPreview)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            WorkspaceToolbarButton(title: "Terminal", systemName: "terminal.fill") {
                workspace.splitFocused(axis: .horizontal, kind: .terminal)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .accessibilityIdentifier("terminalWorkspace.toolbar.terminal")

            WorkspaceToolbarButton(title: "Split Down", systemName: "rectangle.split.2x1") {
                workspace.splitFocused(axis: .vertical, kind: .terminal)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .accessibilityIdentifier("terminalWorkspace.toolbar.splitDown")

            WorkspaceToolbarButton(title: "Browser", systemName: "safari") {
                workspace.splitFocused(axis: .horizontal, kind: .browser)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .accessibilityIdentifier("terminalWorkspace.toolbar.browser")

            WorkspaceToolbarButton(title: "Unread", systemName: "bell.badge") {
                jumpToLatestUnread()
            }
            .disabled(notifications.latestUnreadSurface(in: workspace.id) == nil)
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .accessibilityIdentifier("terminalWorkspace.toolbar.unread")

            WorkspaceToolbarButton(title: "Close", systemName: "xmark") {
                if workspace.orderedSurfaces.count <= 1 {
                    onCloseWorkspace()
                } else {
                    workspace.closeFocusedSurface()
                }
            }
            .accessibilityIdentifier("terminalWorkspace.toolbar.close")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Theme.surface1)
        .border(Theme.border, edges: [.bottom])
        .accessibilityIdentifier("terminalWorkspace.toolbar")
    }

    private func jumpToLatestUnread() {
        guard let surfaceId = notifications.latestUnreadSurface(in: workspace.id) else { return }
        workspace.focusSurface(surfaceId)
    }
}

private struct WorkspaceSplitNodeView: View {
    @ObservedObject var workspace: TerminalWorkspace
    let node: WorkspaceLayoutNode
    var onCloseWorkspace: () -> Void

    var body: some View {
        switch node {
        case .leaf(let surfaceId):
            if let surface = workspace.surfaces[surfaceId] {
                WorkspaceSurfaceContainer(
                    workspace: workspace,
                    surface: surface,
                    onCloseWorkspace: onCloseWorkspace
                )
            } else {
                EmptyView()
            }
        case .split(_, let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    WorkspaceSplitNodeView(workspace: workspace, node: first, onCloseWorkspace: onCloseWorkspace)
                        .frame(minWidth: 280, minHeight: 180)
                    WorkspaceSplitNodeView(workspace: workspace, node: second, onCloseWorkspace: onCloseWorkspace)
                        .frame(minWidth: 280, minHeight: 180)
                }
            } else {
                VSplitView {
                    WorkspaceSplitNodeView(workspace: workspace, node: first, onCloseWorkspace: onCloseWorkspace)
                        .frame(minWidth: 280, minHeight: 180)
                    WorkspaceSplitNodeView(workspace: workspace, node: second, onCloseWorkspace: onCloseWorkspace)
                        .frame(minWidth: 280, minHeight: 180)
                }
            }
        }
    }
}

private struct WorkspaceSurfaceContainer: View {
    @ObservedObject var workspace: TerminalWorkspace
    @ObservedObject private var notifications = SurfaceNotificationStore.shared
    let surface: WorkspaceSurface
    var onCloseWorkspace: () -> Void

    private var isFocused: Bool {
        workspace.focusedSurfaceId == surface.id
    }

    private var needsAttention: Bool {
        notifications.hasVisibleIndicator(surfaceId: surface.id)
    }

    private var ringColor: Color {
        if needsAttention {
            return Theme.danger
        }
        return isFocused ? Theme.accent : Theme.border
    }

    private var ringWidth: CGFloat {
        needsAttention ? 3 : (isFocused ? 2 : 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            paneHeader
            paneContent
        }
        .background(Theme.base)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(ringColor, lineWidth: ringWidth)
                .padding(2)
                .animation(.easeInOut(duration: 0.16), value: needsAttention)
                .animation(.easeInOut(duration: 0.16), value: isFocused)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusSurface(surface.id)
        }
        .accessibilityIdentifier("workspace.surface.\(surface.id)")
    }

    private var paneHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: surface.kind.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(needsAttention ? Theme.danger : (isFocused ? Theme.accent : Theme.textTertiary))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(surface.title)
                    .font(.system(size: 11, weight: needsAttention ? .bold : .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                if !surface.subtitle.isEmpty {
                    Text(surface.subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if needsAttention {
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 7, height: 7)
                    .accessibilityIdentifier("workspace.surface.unread.\(surface.id)")
            }

            Button {
                if workspace.orderedSurfaces.count <= 1 {
                    onCloseWorkspace()
                } else {
                    workspace.closeSurface(surface.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityIdentifier("workspace.surface.close.\(surface.id)")
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(isFocused ? Theme.inputBg : Theme.surface1)
        .border(Theme.border, edges: [.bottom])
        .onTapGesture {
            workspace.focusSurface(surface.id)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch surface.kind {
        case .terminal:
            TerminalView(
                sessionId: surface.id,
                command: terminalCommand(for: surface),
                workingDirectory: surface.terminalWorkingDirectory,
                onClose: {
                    workspace.closeSurface(surface.id)
                },
                onFocus: {
                    workspace.focusSurface(surface.id)
                },
                onTitleChange: { title in
                    workspace.updateTerminalTitle(surfaceId: surface.id, title: title)
                },
                onWorkingDirectoryChange: { workingDirectory in
                    workspace.updateTerminalWorkingDirectory(surfaceId: surface.id, workingDirectory: workingDirectory)
                },
                onNotification: { title, body in
                    SurfaceNotificationStore.shared.addNotification(
                        surfaceId: surface.id,
                        title: title,
                        body: body
                    )
                },
                onBell: {
                    SurfaceNotificationStore.shared.addNotification(
                        surfaceId: surface.id,
                        title: surface.title,
                        body: "Terminal bell"
                    )
                },
                onSplitRight: {
                    workspace.splitFocused(axis: .horizontal, kind: .terminal)
                },
                onSplitDown: {
                    workspace.splitFocused(axis: .vertical, kind: .terminal)
                },
                onOpenBrowser: {
                    workspace.splitFocused(axis: .horizontal, kind: .browser)
                },
                onJumpToUnread: {
                    if let surfaceId = SurfaceNotificationStore.shared.latestUnreadSurface(in: workspace.id) {
                        workspace.focusSurface(surfaceId)
                    }
                }
            )
        case .browser:
            BrowserSurfaceView(
                surface: surface,
                workspace: workspace,
                onFocus: {
                    workspace.focusSurface(surface.id)
                }
            )
        }
    }

    private func terminalCommand(for surface: WorkspaceSurface) -> String? {
        guard surface.terminalBackend == .tmux else {
            return surface.terminalCommand
        }

        return TmuxController.attachCommand(
            socketName: surface.tmuxSocketName,
            sessionName: surface.tmuxSessionName
        ) ?? surface.terminalCommand
    }
}

private struct WorkspaceToolbarButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Theme.inputBg)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
