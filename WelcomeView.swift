import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WelcomeView: View {
    @ObservedObject var manager: WorkspaceManager

    private static let githubURL = URL(string: "https://github.com/smithersai/gui")!

    var body: some View {
        ZStack {
            Theme.base.ignoresSafeArea()

            VStack(spacing: 32) {
                header
                actionButtons
                Divider()
                    .background(Theme.border)
                    .frame(maxWidth: 560)
                recentsSection
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: 720)
        }
        .frame(minWidth: 720, minHeight: 560)
        .accessibilityIdentifier("view.welcome")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(Theme.accent)
            Text("Smithers")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
            Text("The workspace-native IDE for AI-driven development")
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: { manager.presentOpenFolderPanel() }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Open Folder…")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(minWidth: 200)
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .background(Theme.accent)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("welcome.openFolder")

            Button(action: openGitHub) {
                HStack(spacing: 8) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 15))
                    Text("Star on GitHub")
                        .font(.system(size: 15, weight: .medium))
                }
                .frame(minWidth: 180)
                .padding(.vertical, 14)
                .padding(.horizontal, 24)
                .background(Theme.surface1)
                .foregroundColor(Theme.textPrimary)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("welcome.starGitHub")
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Workspaces")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if manager.recents.isEmpty {
                Text("No recent workspaces yet — open a folder to get started.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(manager.recents) { entry in
                            RecentWorkspaceRow(entry: entry) {
                                manager.openWorkspace(at: entry.url)
                            } onRemove: {
                                manager.removeRecent(path: entry.path)
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private func openGitHub() {
        #if os(macOS)
        NSWorkspace.shared.open(Self.githubURL)
        #endif
    }
}

private struct RecentWorkspaceRow: View {
    let entry: RecentWorkspace
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 15))
                    .foregroundColor(entry.exists ? Theme.accent : Theme.textTertiary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(entry.exists ? Theme.textPrimary : Theme.textTertiary)
                        .strikethrough(!entry.exists)
                    Text(abbreviated(path: entry.path))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isHovered {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from recents")
                    .accessibilityIdentifier("welcome.recent.remove")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Theme.sidebarHover : Color.clear)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .disabled(!entry.exists)
        .accessibilityIdentifier("welcome.recent.row")
    }

    private func abbreviated(path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}
