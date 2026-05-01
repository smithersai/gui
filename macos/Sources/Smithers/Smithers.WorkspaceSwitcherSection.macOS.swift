// Smithers.WorkspaceSwitcherSection.macOS.swift
//
// macOS presentation of the workspace switcher (ticket 0138). Contract:
//   - Local (libsmithers SQLite `recent_workspaces`) and Remote
//     (0135/0116) are rendered as VISUALLY SEPARATE sections per spec.
//   - Remote rows do not get re-grouped by repo; they are one flat
//     recent-first list.
//   - Coordinate carefully with ticket 0126 (desktop-remote toggle) if
//     that lane also touches SidebarView — our additions are limited to
//     a self-contained `WorkspaceSwitcherSection` view that the sidebar
//     / welcome / command-palette can embed without conflicts.

#if os(macOS)
import SwiftUI
#if SWIFT_PACKAGE
import SmithersStore
#endif

struct WorkspaceSwitcherSection: View {
    @ObservedObject var viewModel: WorkspaceSwitcherViewModel
    let localRecents: [RecentWorkspace]
    let onOpenLocal: (URL) -> Void
    let onRemoveLocal: (String) -> Void
    let onOpenRemote: (SwitcherWorkspace) -> Void
    let onSignIn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            localSection
            Divider()
            remoteSection
        }
        .task { await viewModel.refresh() }
        .accessibilityIdentifier("switcher.macos.root")
    }

    // MARK: - Local

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCAL")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            if localRecents.isEmpty {
                Text("No local recents — open a folder to get started.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(localRecents) { entry in
                    LocalRecentRow(
                        entry: entry,
                        onOpen: { onOpenLocal(entry.url) },
                        onRemove: { onRemoveLocal(entry.path) }
                    )
                }
            }
        }
        .accessibilityIdentifier("switcher.macos.local")
    }

    // MARK: - Remote

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("REMOTE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Refresh remote workspaces")
                .accessibilityIdentifier("switcher.macos.refresh")
            }
            WorkspaceSwitcherView(
                viewModel: viewModel,
                onOpen: onOpenRemote,
                onSignIn: onSignIn,
                onRetry: { Task { await viewModel.refresh() } }
            )
            .frame(minHeight: 180, maxHeight: 320)
        }
        .accessibilityIdentifier("switcher.macos.remote")
    }
}

private struct LocalRecentRow: View {
    let entry: RecentWorkspace
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(entry.exists ? .accentColor : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(entry.exists ? .primary : .secondary)
                        .strikethrough(!entry.exists)
                    Text((entry.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from recents")
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            .cornerRadius(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!entry.exists)
        .accessibilityIdentifier("switcher.macos.local.row")
    }
}
#endif
