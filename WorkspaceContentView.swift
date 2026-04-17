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

            WorkspaceToolbarButton(title: "Split Right", systemName: "rectangle.split.1x2") {
                workspace.focusSurface(surface.id)
                workspace.splitFocused(axis: .horizontal, kind: .terminal)
            }
            .appKeyboardShortcut(.splitRight)
            .accessibilityIdentifier("workspace.surface.splitRight.\(surface.id)")

            WorkspaceToolbarButton(title: "Split Down", systemName: "rectangle.split.2x1") {
                workspace.focusSurface(surface.id)
                workspace.splitFocused(axis: .vertical, kind: .terminal)
            }
            .appKeyboardShortcut(.splitDown)
            .accessibilityIdentifier("workspace.surface.splitDown.\(surface.id)")

            WorkspaceToolbarButton(title: "Browser", systemName: "safari") {
                workspace.focusSurface(surface.id)
                workspace.splitFocused(axis: .horizontal, kind: .browser)
            }
            .appKeyboardShortcut(.openBrowser)
            .accessibilityIdentifier("workspace.surface.browser.\(surface.id)")

            WorkspaceToolbarButton(title: "Unread", systemName: "bell.badge") {
                jumpToLatestUnread()
            }
            .disabled(notifications.latestUnreadSurface(in: workspace.id) == nil)
            .appKeyboardShortcut(.jumpToUnread)
            .accessibilityIdentifier("workspace.surface.unreadBtn.\(surface.id)")

            WorkspaceToolbarButton(title: "Close", systemName: "xmark") {
                if workspace.orderedSurfaces.count <= 1 {
                    onCloseWorkspace()
                } else {
                    workspace.closeSurface(surface.id)
                }
            }
            .accessibilityIdentifier("workspace.surface.close.\(surface.id)")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(isFocused ? Theme.surface1 : Theme.base)
        .border(Theme.border, edges: [.bottom])
        .onTapGesture {
            workspace.focusSurface(surface.id)
        }
    }

    private func jumpToLatestUnread() {
        guard let surfaceId = notifications.latestUnreadSurface(in: workspace.id) else { return }
        workspace.focusSurface(surfaceId)
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
