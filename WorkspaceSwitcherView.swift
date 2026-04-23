// WorkspaceSwitcherView.swift — cross-platform (iOS + macOS) rows view
// for ticket 0138.
//
// Only the rows list + its empty/signed-out/offline states live here.
// Platform presentation (full-screen modal on iOS, section-in-sidebar
// on macOS) is decided by the platform-specific wrappers in
// `ios/Sources/SmithersiOS/WorkspaceSwitcher/…` and
// `macos/Sources/Smithers/Smithers.WorkspaceSwitcherSection.macOS.swift`.

import SwiftUI
#if SWIFT_PACKAGE
import SmithersStore
#endif

public struct WorkspaceSwitcherView: View {
    @ObservedObject public var viewModel: WorkspaceSwitcherViewModel
    public let onOpen: (SwitcherWorkspace) -> Void
    public let onSignIn: (() -> Void)?
    public let onRetry: (() -> Void)?

    public init(
        viewModel: WorkspaceSwitcherViewModel,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onSignIn = onSignIn
        self.onRetry = onRetry
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("switcher.loading")
            case .loaded(let items):
                rowsList(items)
            case .emptySignedIn:
                emptyState(
                    icon: "tray",
                    title: "No remote workspaces yet",
                    subtitle: "When you create a workspace on the web or CLI, it will show up here.",
                    identifier: "switcher.empty.signedIn"
                )
            case .signedOut:
                emptyState(
                    icon: "person.crop.circle.badge.xmark",
                    title: "Signed out",
                    subtitle: "Your session expired. Sign in again to see your workspaces.",
                    identifier: "switcher.empty.signedOut",
                    action: onSignIn,
                    actionLabel: "Sign in"
                )
            case .backendUnavailable(let message):
                emptyState(
                    icon: "exclamationmark.triangle",
                    title: "Backend unavailable",
                    subtitle: message,
                    identifier: "switcher.empty.backendUnavailable",
                    action: onRetry,
                    actionLabel: "Retry"
                )
            }
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteID != nil },
                set: { if !$0 { viewModel.cancelDelete() } }
            ),
            presenting: viewModel.pendingDeleteID
        ) { id in
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete(id: id) }
            }
            .accessibilityIdentifier("switcher.delete.confirm")
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
                .accessibilityIdentifier("switcher.delete.cancel")
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    @ViewBuilder
    private func rowsList(_ items: [SwitcherWorkspace]) -> some View {
        List {
            ForEach(items) { item in
                WorkspaceSwitcherRow(item: item) {
                    onOpen(item)
                } onRequestDelete: {
                    viewModel.requestDelete(id: item.id)
                }
                .accessibilityIdentifier("switcher.row.\(item.id)")
            }
        }
        .accessibilityIdentifier("switcher.rows")
    }

    @ViewBuilder
    private func emptyState(
        icon: String,
        title: String,
        subtitle: String,
        identifier: String,
        action: (() -> Void)? = nil,
        actionLabel: String? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            if let action, let actionLabel {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("\(identifier).action")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Row

public struct WorkspaceSwitcherRow: View {
    public let item: SwitcherWorkspace
    public let onOpen: () -> Void
    public let onRequestDelete: () -> Void

    public init(
        item: SwitcherWorkspace,
        onOpen: @escaping () -> Void,
        onRequestDelete: @escaping () -> Void
    ) {
        self.item = item
        self.onOpen = onOpen
        self.onRequestDelete = onRequestDelete
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !item.repoLabel.isEmpty {
                            Text(item.repoLabel)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(item.state)
                            .font(.system(size: 11))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                        Text(recencyLabel(item.recencyKey))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if item.source == .remote {
                Button(role: .destructive, action: onRequestDelete) {
                    Label("Delete…", systemImage: "trash")
                }
                .accessibilityIdentifier("switcher.row.delete")
            }
        }
    }

    private var iconName: String {
        switch item.source {
        case .local: return "folder.fill"
        case .remote: return "globe"
        }
    }

    /// Relative-time label. Keep server-side precision and fall back to
    /// "—" if we have no timestamps at all.
    private func recencyLabel(_ date: Date) -> String {
        if date == .distantPast { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
