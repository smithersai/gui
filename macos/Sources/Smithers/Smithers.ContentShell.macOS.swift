// Smithers.ContentShell.macOS.swift
//
// The macOS platform shell extracted from ContentView.swift in ticket
// 0122. Owns the `NavigationSplitView`, the macOS-specific toolbar, the
// terminal tabs layer, the `GUIControlSidebar`, the developer debug
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
    let guiControlSidebarEnabled: Bool
    @Binding var guiControlSidebarExpanded: Bool

    let activeTerminalId: String?
    let shouldShowSmithersVersionWarning: Bool
    let detailRefreshNonce: Int

    let canGoBack: Bool
    let canGoForward: Bool
    let goBack: () -> Void
    let goForward: () -> Void

    let onOpenNewTabPicker: () -> Void
    let onAppShortcutCommand: (KeyboardShortcutCommand) -> Void
    let onRequestTerminalClose: (String) -> Void
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

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $navigationSplitVisibility) {
                SidebarView(
                    store: store,
                    destination: $destination,
                    developerDebugPanelVisible: $developerDebugPanelVisible,
                    developerDebugAvailable: developerToolsEnabled,
                    onOpenNewTabPicker: onOpenNewTabPicker,
                    versionProvider: versionProvider
                )
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
            } detail: {
                ZStack(alignment: .topLeading) {
                    TerminalTabsLayer(
                        store: store,
                        activeTerminalId: activeTerminalId,
                        onRequestClose: onRequestTerminalClose,
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

            if guiControlSidebarEnabled {
                GUIControlSidebar(
                    isExpanded: $guiControlSidebarExpanded,
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
