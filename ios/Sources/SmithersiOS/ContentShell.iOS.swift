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
//
// Ticket ios-e2e-harness: XCUITest harness attaches to the shell via
// stable accessibility identifiers: `app.root.ios` (shell root),
// `content.ios.open-switcher`, `content.ios.sign-out`,
// `content.ios.workspace-detail`, and the switcher's own
// `switcher.ios.root` / `switcher.state.*` identifiers. When
// `PLUE_E2E_MODE=1` is set, the shell wires a real
// `URLSessionRemoteWorkspaceFetcher` against `PLUE_BASE_URL` so
// `/api/user/workspaces` is exercised end-to-end.

#if os(iOS)
import SwiftUI

/// Minimal iOS shell wrapping the shared `NavigationStateStore`. Tickets
/// 0123/0124 expand this to use the real leaf views once they compile on
/// iOS.
struct IOSContentShell: View {
    @StateObject private var navigation = NavigationStateStore()
    @StateObject private var switcherVM: WorkspaceSwitcherViewModel
    @State private var showSwitcher: Bool = false
    @State private var openedWorkspace: SwitcherWorkspace? = nil

    let e2e: E2EConfig?
    let onSignOut: () -> Void

    init(
        e2e: E2EConfig?,
        bearerProvider: @escaping () -> String?,
        onSignOut: @escaping () -> Void
    ) {
        self.e2e = e2e
        self.onSignOut = onSignOut
        // Base URL: either the E2E override or the SMITHERS_PLUE_URL dev
        // knob, with the production Smithers endpoint as final fallback.
        let base: URL
        if let e2e {
            base = e2e.baseURL
        } else if let dev = ProcessInfo.processInfo.environment["SMITHERS_PLUE_URL"].flatMap(URL.init(string:)) {
            base = dev
        } else {
            base = URL(string: "https://app.smithers.sh")!
        }
        let fetcher = URLSessionRemoteWorkspaceFetcher(
            baseURL: base,
            bearer: bearerProvider
        )
        _switcherVM = StateObject(
            wrappedValue: WorkspaceSwitcherViewModel(fetcher: fetcher)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let opened = openedWorkspace {
                    WorkspaceDetailPlaceholder(workspace: opened, onBack: {
                        openedWorkspace = nil
                    })
                    .accessibilityIdentifier("content.ios.workspace-detail")
                } else {
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

                        Section("Workspaces") {
                            Button {
                                showSwitcher = true
                            } label: {
                                Label("Open workspace switcher", systemImage: "rectangle.stack")
                            }
                            .accessibilityIdentifier("content.ios.open-switcher")
                        }

                        Section("Account") {
                            Button("Sign out", role: .destructive, action: onSignOut)
                                .accessibilityIdentifier("content.ios.sign-out")
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
            }
        }
        // Attach the full-screen cover to the root — presenting from an
        // inner List inside NavigationStack occasionally swallows the
        // binding change on iOS 17+, so we hoist the modifier here.
        .workspaceSwitcherSheet(
            isPresented: $showSwitcher,
            viewModel: switcherVM,
            onOpen: { workspace in
                openedWorkspace = workspace
            },
            onSignIn: {
                // Auth expired — the root surface re-evaluates on the
                // auth model's phase change. Nothing to do from here.
            }
        )
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

/// Placeholder "workspace detail" pane so the E2E test has a rendered
/// surface to assert against. Tickets 0123/0124 replace this with the
/// real chat + terminal shell once the shared leaves compile for iOS.
private struct WorkspaceDetailPlaceholder: View {
    let workspace: SwitcherWorkspace
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(workspace.title)
                .font(.title3.weight(.semibold))
            Text("Remote chat shell is not yet available on iOS.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Workspace id: \(workspace.id)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Button("Back", action: onBack)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("content.ios.workspace-detail.back")
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
