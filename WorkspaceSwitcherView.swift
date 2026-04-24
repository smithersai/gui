// WorkspaceSwitcherView.swift — cross-platform (iOS + macOS) rows view
// for ticket 0138.
//
// Only the rows list + its empty/signed-out/offline states live here.
// Platform presentation (full-screen modal on iOS, section-in-sidebar
// on macOS) is decided by the platform-specific wrappers in
// `ios/Sources/SmithersiOS/WorkspaceSwitcher/…` and
// `macos/Sources/Smithers/Smithers.WorkspaceSwitcherSection.macOS.swift`.

import SwiftUI
#if os(iOS)
import UIKit
#endif
#if SWIFT_PACKAGE
import SmithersStore
#endif

public struct WorkspaceSwitcherView: View {
    @ObservedObject public var viewModel: WorkspaceSwitcherViewModel
    public let onOpen: (SwitcherWorkspace) -> Void
    public let onSignIn: (() -> Void)?
    public let onRetry: (() -> Void)?
    public let onSelectRepoFilter: (() -> Void)?
    public let onClearRepoFilter: (() -> Void)?
    public let focusedWorkspaceID: String?
    public let onFocusedWorkspaceResolved: ((SwitcherWorkspace) -> Void)?

    public init(
        viewModel: WorkspaceSwitcherViewModel,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: (() -> Void)? = nil,
        onRetry: (() -> Void)? = nil,
        onSelectRepoFilter: (() -> Void)? = nil,
        onClearRepoFilter: (() -> Void)? = nil,
        focusedWorkspaceID: String? = nil,
        onFocusedWorkspaceResolved: ((SwitcherWorkspace) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onSignIn = onSignIn
        self.onRetry = onRetry
        self.onSelectRepoFilter = onSelectRepoFilter
        self.onClearRepoFilter = onClearRepoFilter
        self.focusedWorkspaceID = focusedWorkspaceID
        self.onFocusedWorkspaceResolved = onFocusedWorkspaceResolved
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let errorMessage = inlineErrorMessage {
                WorkspaceSwitcherErrorBanner(
                    message: errorMessage,
                    onRetry: { retry() }
                )
            }

            if onSelectRepoFilter != nil {
                repoFilterBar
            }

            Group {
                switch viewModel.state {
                case .loading:
                    ProgressView("Loading workspaces…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("switcher.loading")
                case .loaded(let items):
                    if items.isEmpty, let selectedRepo = viewModel.selectedRepoFilter {
                        emptyState(
                            icon: "tray",
                            title: "No workspaces in \(selectedRepo.label)",
                            subtitle: "Create a workspace or choose all repos.",
                            identifier: "switcher.empty.filtered"
                        )
                    } else {
                        rowsList(items)
                    }
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
                case .backendUnavailable:
                    emptyState(
                        icon: "exclamationmark.triangle",
                        title: "Backend unavailable",
                        subtitle: "Pull to refresh or retry to reconnect.",
                        identifier: "switcher.empty.backendUnavailable",
                        action: { retry() },
                        actionLabel: "Retry"
                    )
                }
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
#if os(iOS)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
#endif
                Task { await viewModel.confirmDelete(id: id) }
            }
            .accessibilityIdentifier("switcher.delete.confirm")
            Button("Cancel", role: .cancel) { viewModel.cancelDelete() }
                .accessibilityIdentifier("switcher.delete.cancel")
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    private var repoFilterBar: some View {
        HStack(spacing: 8) {
            Button {
                onSelectRepoFilter?()
            } label: {
                Label(viewModel.repoFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("switcher.filter.repo")

            if viewModel.selectedRepoFilter != nil {
                Button {
                    onClearRepoFilter?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear repo filter")
                .accessibilityIdentifier("switcher.filter.repo.clear")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(repoFilterBarBackground)
    }

    private var repoFilterBarBackground: Color {
#if os(iOS)
        Color(.secondarySystemBackground)
#else
        Color.secondary.opacity(0.08)
#endif
    }

    @ViewBuilder
    private func rowsList(_ items: [SwitcherWorkspace]) -> some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    WorkspaceSwitcherRow(item: item) {
                        onOpen(item)
                    } onRequestDelete: {
                        viewModel.requestDelete(id: item.id)
                    }
                    .id(item.id)
                    .accessibilityIdentifier(workspaceRowAccessibilityID(for: item.id))
                    .onAppear {
                        publishFocusedWorkspaceIfNeeded(item)
                    }
                }
            }
            .refreshable {
                await viewModel.refresh()
            }
            .accessibilityIdentifier("switcher.rows")
            .onAppear {
                scrollToFocusedWorkspace(in: proxy, items: items)
            }
            .onChange(of: focusedWorkspaceScrollKey(items)) { _, _ in
                scrollToFocusedWorkspace(in: proxy, items: items)
            }
        }
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

    private var inlineErrorMessage: String? {
        if let errorMessage = viewModel.errorMessage {
            return errorMessage
        }
        if case let .backendUnavailable(message) = viewModel.state {
            return message
        }
        return nil
    }

    private func retry() {
        if let onRetry {
            onRetry()
        } else {
            Task { await viewModel.refresh() }
        }
    }

    private func workspaceRowAccessibilityID(for rowID: String) -> String {
        rowID == focusedWorkspaceID ? "deeplink.focused.\(rowID)" : "switcher.row.\(rowID)"
    }

    private func focusedWorkspaceScrollKey(_ items: [SwitcherWorkspace]) -> String {
        "\(focusedWorkspaceID ?? "")|\(items.map(\.id).joined(separator: ","))"
    }

    private func scrollToFocusedWorkspace(
        in proxy: ScrollViewProxy,
        items: [SwitcherWorkspace]
    ) {
        guard let focusedWorkspaceID,
              items.contains(where: { $0.id == focusedWorkspaceID })
        else {
            return
        }

        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(focusedWorkspaceID, anchor: .center)
            }
        }
    }

    private func publishFocusedWorkspaceIfNeeded(_ item: SwitcherWorkspace) {
        guard item.id == focusedWorkspaceID else { return }
        onFocusedWorkspaceResolved?(item)
    }
}

private struct WorkspaceSwitcherErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("switcher.error.retry")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("switcher.error")
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
