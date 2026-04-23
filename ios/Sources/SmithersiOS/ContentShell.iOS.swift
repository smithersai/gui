// ContentShell.iOS.swift
//
// iOS platform shell created in ticket 0122. Hosts a `NavigationStack`
// and renders the shared navigation destinations. Leaf views that the
// macOS target already owns (DashboardView, RunsView, etc.) are macOS-
// target-only until tickets 0123 (TerminalView portability) and 0124
// (libsmithers-core runtime) make them iOS-compilable, so this shell
// currently renders a placeholder detail pane. The structure is the one
// a reviewer can grep and see: NavigationStack + iOS-appropriate toolbar,
// no AppKit assumptions, no direct route parity with the macOS detail
// router.
//
// Scope reminder: ticket 0122 is shell decomposition, not feature parity
// (that is 0124). The iOS shell exists so the route model and the shared
// navigation store drive both platforms from the start.

#if os(iOS)
import SwiftUI

/// Minimal iOS shell wrapping the shared `NavigationStateStore`. Tickets
/// 0123/0124 expand this to use the real leaf views once they compile on
/// iOS.
struct IOSContentShell: View {
    @StateObject private var navigation = NavigationStateStore()
    let onSignOut: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Navigate") {
                    ForEach(Self.iosRoutes, id: \.self) { dest in
                        Button {
                            navigation.navigate(to: dest)
                        } label: {
                            HStack {
                                Image(systemName: dest.icon)
                                Text(dest.label)
                                Spacer()
                                if navigation.destination == dest {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("Account") {
                    Button("Sign out", role: .destructive, action: onSignOut)
                }
            }
            .navigationTitle(navigation.destination.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: navigation.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!navigation.canGoBack)
                    .accessibilityIdentifier("nav.back")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: navigation.goForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!navigation.canGoForward)
                    .accessibilityIdentifier("nav.forward")
                }
            }
            .onChange(of: navigation.destination) { _, newValue in
                navigation.recordHistory(newValue)
            }
        }
        .accessibilityIdentifier("app.root.ios")
    }

    /// Destinations the iOS shell advertises today. Terminal, live-run,
    /// and run-inspect routes depend on leaves that tickets 0123/0124
    /// will port; they intentionally do not appear here yet.
    private static let iosRoutes: [NavDestination] = [
        .home,
        .dashboard,
        .runs,
        .approvals,
        .workflows,
        .prompts,
        .memory,
        .search,
        .workspaces,
        .settings,
    ]
}

#endif
