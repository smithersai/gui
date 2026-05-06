// Smithers.ContentShell.macOS.swift
//
// The macOS platform shell extracted from ContentView.swift in ticket
// 0122. Owns the `NavigationSplitView`, the macOS-specific toolbar, the
// terminal tabs layer, the `TabmonstersControlSidebar`, the developer debug
// panel, the command palette overlay, and the quick-launch overlay.
//
// ContentView.swift composes this shell on top of the shared navigation
// store + detail router + bootstrap stage. The iOS shell uses
// `IOSContentShell` instead and does not share any of this file.

#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Everything the macOS shell needs the outer ContentView to expose.
/// Keeping these as explicit bindings + closures means the shell has no
/// hidden dependencies on ContentView's many helper methods.
struct MacOSContentShell<DetailContent: View, PaletteOverlay: View, QuickLaunchOverlay: View, ShortcutButtons: View>: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var smithers: SmithersClient
    @ObservedObject var smithersUpgrader: SmithersUpgrader

    @Binding var destination: NavDestination
    @Binding var navigationSplitVisibility: NavigationSplitViewVisibility
    @Binding var runSnapshotsSelection: RunSnapshotsRouteSelection?
    @Binding var developerDebugPanelVisible: Bool

    let developerToolsEnabled: Bool
    let tabmonstersControlSidebarEnabled: Bool
    let shortcutCheatSheetFooterEnabled: Bool
    @Binding var tabmonstersControlSidebarExpanded: Bool

    let activeTerminalId: String?
    let shouldShowSmithersVersionWarning: Bool
    let detailRefreshNonce: Int

    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    let onOpenNewTabPicker: () -> Void
    let onOpenLocalFolderTab: (String) -> Void
    let onAppShortcutCommand: (KeyboardShortcutCommand) -> Void
    let onRequestTerminalClose: (String) -> Void
    let onRequestTerminalRestart: (String) -> Void
    let onTerminalProcessExited: (String) -> Void
    let onDropMarkdown: ([NSItemProvider]) -> Bool
    let onHandleNavigation: (NavDestination) -> Void
    let onDestinationChanged: (NavDestination) -> Void
    let onSmithersActionNotification: (Notification) -> Void
    let onAppear: () -> Void
    let onDisappear: () -> Void

    let onUpgradeSmithers: () -> Void
    let versionProvider: () async -> String?

    let terminateTerminalBinding: Binding<Bool>
    let pendingTerminalCloseTitle: String
    let confirmTerminalClose: () -> Void
    let clearPendingTerminalClose: () -> Void

    @ViewBuilder let detailContent: () -> DetailContent
    @ViewBuilder let commandPaletteOverlay: () -> PaletteOverlay
    @ViewBuilder let quickLaunchOverlay: () -> QuickLaunchOverlay
    @ViewBuilder let hiddenShortcutButtons: () -> ShortcutButtons

    private var shortcutFooterActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { action in
            if action == .toggleDeveloperDebug {
                return developerToolsEnabled
            }
            return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $navigationSplitVisibility) {
                SidebarView(
                    store: store,
                    destination: $destination,
                    developerDebugPanelVisible: $developerDebugPanelVisible,
                    developerDebugAvailable: developerToolsEnabled,
                    onOpenNewTabPicker: onOpenNewTabPicker,
                    onOpenLocalFolderTab: onOpenLocalFolderTab,
                    versionProvider: versionProvider
                )
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
            } detail: {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        TerminalTabsLayer(
                        store: store,
                        activeTerminalId: activeTerminalId,
                        onRequestClose: onRequestTerminalClose,
                        onRequestRestart: onRequestTerminalRestart,
                        onProcessExited: onTerminalProcessExited,
                        onAppShortcutCommand: onAppShortcutCommand
                    )
                        .opacity(activeTerminalId != nil ? 1 : 0)
                        .allowsHitTesting(activeTerminalId != nil)
                        .accessibilityHidden(activeTerminalId == nil)

                        if activeTerminalId == nil {
                            VStack(spacing: 0) {
                                if shouldShowSmithersVersionWarning,
                                   let installed = smithers.orchestratorVersion,
                                   smithers.orchestratorVersionMeetsMinimum == false {
                                    SmithersVersionWarningBanner(
                                        installed: installed,
                                        onUpgrade: onUpgradeSmithers,
                                        upgradeStatus: smithersUpgrader.status
                                    )
                                }
                                detailContent()
                            }
                            .id("\(String(describing: destination)):\(detailRefreshNonce)")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if shortcutCheatSheetFooterEnabled {
                        ShortcutCheatSheetFooter(
                            actions: shortcutFooterActions,
                            onOpenCheatSheet: {
                                onAppShortcutCommand(.shortcut(.showShortcutCheatSheet))
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(!canGoBack)
                        .help("Back (⌘[)")
                        .accessibilityIdentifier("nav.back")

                        Button(action: goForward) {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(!canGoForward)
                        .help("Forward (⌘])")
                        .accessibilityIdentifier("nav.forward")

                        if let terminalId = activeTerminalId,
                           let workspace = store.terminalWorkspaceIfAvailable(terminalId) {
                            WorkspaceToolbarTitleView(workspace: workspace)
                        }
                    }
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
                hiddenShortcutButtons()
            }
            .accessibilityIdentifier("app.root")
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                onDropMarkdown(providers)
            }
            .onChange(of: destination) { _, newValue in
                AppLogger.ui.debug("Navigate to \(newValue.label)")
                onDestinationChanged(newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .smithersAction)) { notification in
                onSmithersActionNotification(notification)
            }

            if tabmonstersControlSidebarEnabled {
                TabmonstersControlSidebar(
                    isExpanded: $tabmonstersControlSidebarExpanded,
                    store: store,
                    smithers: smithers,
                    destination: destination,
                    onNavigate: onHandleNavigation
                )
            }

            if developerDebugPanelVisible && developerToolsEnabled {
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
        .overlay { commandPaletteOverlay() }
        .overlay { quickLaunchOverlay() }
        .background(Theme.base)
        .onAppear(perform: onAppear)
        .onDisappear(perform: onDisappear)
        .confirmationDialog(
            "Terminate Terminal?",
            isPresented: terminateTerminalBinding,
            titleVisibility: .visible
        ) {
            Button("Terminate Terminal", role: .destructive) {
                confirmTerminalClose()
            }
            Button("Cancel", role: .cancel) {
                clearPendingTerminalClose()
            }
        } message: {
            Text("Terminate \"\(pendingTerminalCloseTitle)\"? This will stop the terminal session and close the workspace. This action cannot be undone.")
        }
    }
}

private struct ShortcutCheatSheetFooter: View {
    let actions: [ShortcutAction]
    let onOpenCheatSheet: () -> Void
    @StateObject private var shortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared

    var body: some View {
        let _ = shortcutSettingsObserver.revision

        HStack(spacing: 10) {
            Button(action: onOpenCheatSheet) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open shortcut cheat sheet (\(shortcutString(for: .showShortcutCheatSheet)))")
            .accessibilityIdentifier("shortcutFooter.openCheatSheet")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        ShortcutCheatSheetFooterItem(
                            label: footerLabel(for: action),
                            shortcut: shortcutString(for: action)
                        )
                        .accessibilityIdentifier("shortcutFooter.item.\(action.rawValue)")
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .padding(.leading, 10)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(Theme.surface1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
        }
        .accessibilityIdentifier("shortcutFooter")
    }

    private func shortcutString(for action: ShortcutAction) -> String {
        action.displayedShortcutString(for: KeyboardShortcutSettings.current(for: action))
    }

    private func footerLabel(for action: ShortcutAction) -> String {
        switch action {
        case .commandPalette:
            return "Launcher"
        case .commandPaletteCommandMode:
            return "Commands"
        case .commandPaletteAskAI:
            return "Ask AI"
        case .newTerminal:
            return "Terminal"
        case .reopenClosedTab:
            return "Reopen"
        case .closeCurrentTab:
            return "Close"
        case .nextSidebarTab:
            return "Next Workspace"
        case .prevSidebarTab:
            return "Prev Workspace"
        case .selectWorkspaceByNumber:
            return "Workspace 1-9"
        case .toggleDeveloperDebug:
            return "Debug"
        case .toggleSidebar:
            return "Sidebar"
        case .splitRight:
            return "Split Right"
        case .splitDown:
            return "Split Down"
        case .focusLeft:
            return "Focus Left"
        case .focusRight:
            return "Focus Right"
        case .focusUp:
            return "Focus Up"
        case .focusDown:
            return "Focus Down"
        case .toggleSplitZoom:
            return "Zoom"
        case .nextSurface:
            return "Next Pane"
        case .prevSurface:
            return "Prev Pane"
        case .selectSurfaceByNumber:
            return "Pane 1-9"
        case .renameWorkspace:
            return "Rename Workspace"
        case .renameSurface:
            return "Rename Pane"
        case .jumpToUnread:
            return "Unread"
        case .triggerFlash:
            return "Flash"
        case .showNotifications:
            return "Notifications"
        case .toggleFullScreen:
            return "Full Screen"
        case .focusBrowserAddressBar:
            return "Address"
        case .browserBack:
            return "Browser Back"
        case .browserForward:
            return "Browser Forward"
        case .browserReload:
            return "Browser Reload"
        case .find:
            return "Find"
        case .findNext:
            return "Find Next"
        case .findPrevious:
            return "Find Previous"
        case .hideFind:
            return "Hide Find"
        case .useSelectionForFind:
            return "Selection Find"
        case .openBrowser:
            return "Browser"
        case .globalSearch:
            return "Search"
        case .refreshCurrentView:
            return "Refresh"
        case .cancelCurrentOperation:
            return "Cancel"
        case .showShortcutCheatSheet:
            return "All Shortcuts"
        case .linearNavigationPrefix:
            return "Navigation Prefix"
        case .muxPrefix:
            return "Zmux Prefix"
        }
    }
}

private struct ShortcutCheatSheetFooterItem: View {
    let label: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 5) {
            Text(shortcut)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.pillBg)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.pillBorder, lineWidth: 1)
                )

            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Toolbar title chip row. Moved out of ContentView.swift in ticket 0122
/// because the toolbar belongs to the macOS shell.
struct WorkspaceToolbarTitleView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(workspace.orderedSurfaces) { surface in
                WorkspaceToolbarSurfaceChip(
                    surface: surface,
                    isFocused: workspace.focusedSurfaceId == surface.id,
                    onSelect: { workspace.focusSurface(surface.id) }
                )
            }
        }
        .accessibilityIdentifier("toolbar.workspace.title")
    }
}

private struct WorkspaceToolbarSurfaceChip: View {
    let surface: WorkspaceSurface
    let isFocused: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(surface.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                if !surface.subtitle.isEmpty {
                    Text(surface.subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isFocused ? Theme.surface1 : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolbar.workspace.chip.\(surface.id.rawValue)")
    }
}

/// Run-snapshots route selection moved out of ContentView.swift since the
/// sheet is presented by the macOS shell. The iOS shell does not present
/// this sheet today.
struct RunSnapshotsRouteSelection: Identifiable, Equatable {
    let runId: String
    let workflowName: String?

    var id: String { runId }
}

#endif
