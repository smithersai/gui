import SwiftUI

struct TerminalTabsLayer: View {
    @ObservedObject var store: SessionStore
    let activeTerminalId: String?
    var onRequestClose: (String) -> Void
    var onProcessExited: ((String) -> Void)? = nil
    var onAppShortcutCommand: ((KeyboardShortcutCommand) -> Void)? = nil

    var body: some View {
        ZStack {
            ForEach(store.terminalTabs, id: \.terminalId) { tab in
                TerminalWorkspaceRouteView(
                    store: store,
                    terminalId: tab.terminalId,
                    onClose: { onRequestClose(tab.terminalId) },
                    onProcessExited: onProcessExited.map { handler in { handler(tab.terminalId) } },
                    onAppShortcutCommand: onAppShortcutCommand
                )
                .id(tab.terminalId)
                .opacity(tab.terminalId == activeTerminalId ? 1 : 0)
                .allowsHitTesting(tab.terminalId == activeTerminalId)
                .accessibilityHidden(tab.terminalId != activeTerminalId)
            }
        }
    }
}

struct TerminalWorkspaceRouteView: View {
    @ObservedObject var store: SessionStore
    let terminalId: String
    var onClose: () -> Void
    var onProcessExited: (() -> Void)? = nil
    var onAppShortcutCommand: ((KeyboardShortcutCommand) -> Void)? = nil

    @State private var workspace: TerminalWorkspace?

    private var currentWorkspace: TerminalWorkspace? {
        workspace ?? store.terminalWorkspaceIfAvailable(terminalId)
    }

    var body: some View {
        Group {
            if let currentWorkspace {
                TerminalWorkspaceView(
                    workspace: currentWorkspace,
                    onCloseWorkspace: onClose,
                    onWorkspaceProcessExited: onProcessExited,
                    onAppShortcutCommand: onAppShortcutCommand
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
    var onWorkspaceProcessExited: (() -> Void)? = nil
    var onAppShortcutCommand: ((KeyboardShortcutCommand) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSplitNodeView(
                workspace: workspace,
                node: workspace.layout,
                onCloseWorkspace: onCloseWorkspace,
                onWorkspaceProcessExited: onWorkspaceProcessExited,
                onAppShortcutCommand: onAppShortcutCommand
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.base)
        .onAppear {
            if let focusedSurfaceId = workspace.focusedSurfaceId {
                notifications.setFocusedSurface(focusedSurfaceId.rawValue, workspaceId: workspace.id.rawValue)
            }
        }
        .accessibilityIdentifier("workspace.terminal.root")
    }
}

private struct WorkspaceSplitNodeView: View {
    @ObservedObject var workspace: TerminalWorkspace
    let node: WorkspaceLayoutNode
    var onCloseWorkspace: () -> Void
    var onWorkspaceProcessExited: (() -> Void)? = nil
    var onAppShortcutCommand: ((KeyboardShortcutCommand) -> Void)? = nil

    var body: some View {
        switch node {
        case .leaf(let surfaceId):
            if let surface = workspace.surfaces[surfaceId] {
                WorkspaceSurfaceContainer(
                    workspace: workspace,
                    surface: surface,
                    onCloseWorkspace: onCloseWorkspace,
                    onWorkspaceProcessExited: onWorkspaceProcessExited,
                    onAppShortcutCommand: onAppShortcutCommand
                )
            } else {
                EmptyView()
            }
        case .split(_, let axis, let first, let second):
            if axis == .horizontal {
                HSplitView {
                    WorkspaceSplitNodeView(
                        workspace: workspace,
                        node: first,
                        onCloseWorkspace: onCloseWorkspace,
                        onWorkspaceProcessExited: onWorkspaceProcessExited,
                        onAppShortcutCommand: onAppShortcutCommand
                    )
                        .frame(minWidth: 280, minHeight: 180)
                    WorkspaceSplitNodeView(
                        workspace: workspace,
                        node: second,
                        onCloseWorkspace: onCloseWorkspace,
                        onWorkspaceProcessExited: onWorkspaceProcessExited,
                        onAppShortcutCommand: onAppShortcutCommand
                    )
                        .frame(minWidth: 280, minHeight: 180)
                }
            } else {
                VSplitView {
                    WorkspaceSplitNodeView(
                        workspace: workspace,
                        node: first,
                        onCloseWorkspace: onCloseWorkspace,
                        onWorkspaceProcessExited: onWorkspaceProcessExited,
                        onAppShortcutCommand: onAppShortcutCommand
                    )
                        .frame(minWidth: 280, minHeight: 180)
                    WorkspaceSplitNodeView(
                        workspace: workspace,
                        node: second,
                        onCloseWorkspace: onCloseWorkspace,
                        onWorkspaceProcessExited: onWorkspaceProcessExited,
                        onAppShortcutCommand: onAppShortcutCommand
                    )
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
    var onWorkspaceProcessExited: (() -> Void)? = nil
    var onAppShortcutCommand: ((KeyboardShortcutCommand) -> Void)? = nil

    var body: some View {
        paneContent
        .background(Theme.base)
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusSurface(surface.id)
        }
        .accessibilityIdentifier("surface.\(surface.id.rawValue)")
        .contextMenu {
            surfaceContextMenu
        }
    }

    @ViewBuilder
    private var surfaceContextMenu: some View {
            Button("Split Right") {
                workspace.focusSurface(surface.id)
                workspace.splitFocused(axis: .horizontal, kind: .terminal)
            }
            .appKeyboardShortcut(.splitRight)

            Button("Split Down") {
                workspace.focusSurface(surface.id)
                workspace.splitFocused(axis: .vertical, kind: .terminal)
            }
            .appKeyboardShortcut(.splitDown)

            Divider()

            if notifications.latestUnreadSurface(in: workspace.id.rawValue) != nil {
                Button("Jump to Latest Unread") {
                    jumpToLatestUnread()
                }
                .appKeyboardShortcut(.jumpToUnread)

                Divider()
            }

            Button("Close", role: .destructive) {
                if workspace.orderedSurfaces.count <= 1 {
                    onCloseWorkspace()
                } else {
                    workspace.closeSurface(surface.id)
                }
            }
    }

    private func jumpToLatestUnread() {
        guard let surfaceId = notifications.latestUnreadSurface(in: workspace.id.rawValue) else { return }
        workspace.focusSurface(surfaceId)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch surface.kind {
        case .terminal:
            if surface.terminalBackend == .native {
                switch workspace.nativeTerminalState(surfaceId: surface.id) {
                case .ready:
                    terminalSurfaceView
                case .pending:
                    NativeTerminalStatusView(
                        title: surface.sessionId == nil ? "Starting terminal session..." : "Reattaching terminal session...",
                        message: "Waiting for the daemon-backed terminal to become available."
                    )
                case .unavailable(let message):
                    NativeTerminalStatusView(
                        title: "Terminal session unavailable",
                        message: message ?? "The saved terminal session no longer exists. Smithers will not start a fresh shell automatically."
                    )
                }
            } else {
                terminalSurfaceView
            }
        case .browser:
            BrowserSurfaceView(
                surface: surface,
                workspace: workspace,
                onFocus: {
                    workspace.focusSurface(surface.id)
                }
            )
        case .markdown:
            MarkdownSurfaceView(
                surface: surface,
                workspace: workspace,
                onFocus: {
                    workspace.focusSurface(surface.id)
                }
            )
        }
    }

    private var terminalSurfaceView: some View {
        TerminalView(
            sessionId: surface.id.rawValue,
            command: terminalCommand(for: surface),
            workingDirectory: surface.terminalWorkingDirectory,
            onClose: {
                if workspace.orderedSurfaces.count <= 1 {
                    onCloseWorkspace()
                } else {
                    workspace.closeSurface(surface.id)
                }
            },
            onProcessExited: {
                if workspace.orderedSurfaces.count <= 1 {
                    (onWorkspaceProcessExited ?? onCloseWorkspace)()
                } else {
                    workspace.closeSurface(surface.id)
                }
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
                    surfaceId: surface.id.rawValue,
                    title: title,
                    body: body
                )
            },
            onBell: {
                SurfaceNotificationStore.shared.addNotification(
                    surfaceId: surface.id.rawValue,
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
                if let surfaceId = SurfaceNotificationStore.shared.latestUnreadSurface(in: workspace.id.rawValue) {
                    workspace.focusSurface(surfaceId)
                }
            },
            onAppShortcutCommand: onAppShortcutCommand
        )
        .onAppear {
            let surfaceIdString = surface.id.rawValue
            TerminalProcessTracker.shared.register(
                surfaceId: surfaceIdString,
                workspaceId: workspace.id.rawValue
            ) { [weak workspace] sid, name in
                workspace?.updateRunningProcessName(surfaceId: SurfaceID(sid), name: name)
            }
        }
        .onDisappear {
            TerminalProcessTracker.shared.unregister(surfaceId: surface.id.rawValue)
        }
    }

    private func terminalCommand(for surface: WorkspaceSurface) -> String? {
        switch surface.terminalBackend {
        case .tmux:
            return TmuxController.attachCommand(
                socketName: surface.tmuxSocketName,
                sessionName: surface.tmuxSessionName
            ) ?? surface.terminalCommand
        case .native:
            return SessionStore.buildNativeAttachCommand(for: surface.sessionId)
        case .ghostty:
            return surface.terminalCommand
        }
    }
}

private struct NativeTerminalStatusView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundColor(Theme.textTertiary)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.base)
        .accessibilityIdentifier("terminal.native.status")
    }
}
