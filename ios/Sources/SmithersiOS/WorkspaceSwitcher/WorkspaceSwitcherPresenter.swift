// WorkspaceSwitcherPresenter.swift — iOS full-screen modal host for the
// shared workspace switcher (ticket 0138).
//
// On iOS the switcher is a dedicated surface (per spec: full-screen
// modal). Remote-only — Local recents are a desktop-only construct and
// are intentionally absent here.
//
// Composition:
//   - Caller passes in a `WorkspaceSwitcherViewModel` already wired to
//     a `RemoteWorkspaceFetcher` and (optionally) a `WorkspaceDeleter`.
//   - This wrapper provides the `.sheet` modifier plumbing so the iOS
//     shell can present the switcher without knowing about its inner
//     state.
//   - `.task` on present drives the initial load. On foreground (app
//     becoming active), the caller should call `refresh()` if the
//     shape isn't live — we surface a `refresh()` button in the
//     navigation bar for the explicit-refresh fallback path.

#if os(iOS)
import SwiftUI
#if SWIFT_PACKAGE
import SmithersStore
#endif

public struct WorkspaceSwitcherPresenter: View {
    @ObservedObject public var viewModel: WorkspaceSwitcherViewModel
    public let onOpen: (SwitcherWorkspace) -> Void
    public let onSignIn: () -> Void
    public let onDismiss: () -> Void

    public init(
        viewModel: WorkspaceSwitcherViewModel,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onSignIn = onSignIn
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NavigationStack {
            WorkspaceSwitcherView(
                viewModel: viewModel,
                onOpen: { workspace in
                    onOpen(workspace)
                    onDismiss()
                },
                onSignIn: onSignIn,
                onRetry: { Task { await viewModel.refresh() } }
            )
            .navigationTitle("Workspaces")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", action: onDismiss)
                        .accessibilityIdentifier("switcher.ios.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("switcher.ios.refresh")
                }
            }
        }
        .task { await viewModel.refresh() }
        .accessibilityIdentifier("switcher.ios.root")
    }
}

/// Convenience `.sheet` style modifier: `.workspaceSwitcherSheet(...)`
/// from the iOS shell presents the switcher full-screen when `isPresented`
/// becomes true.
public extension View {
    func workspaceSwitcherSheet(
        isPresented: Binding<Bool>,
        viewModel: WorkspaceSwitcherViewModel,
        onOpen: @escaping (SwitcherWorkspace) -> Void,
        onSignIn: @escaping () -> Void
    ) -> some View {
        self.fullScreenCover(isPresented: isPresented) {
            WorkspaceSwitcherPresenter(
                viewModel: viewModel,
                onOpen: onOpen,
                onSignIn: onSignIn,
                onDismiss: { isPresented.wrappedValue = false }
            )
        }
    }
}
#endif
