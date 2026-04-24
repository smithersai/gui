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
// `switcher.ios.root`, `switcher.loading`, `switcher.empty.signedIn`,
// `switcher.empty.signedOut`, `switcher.empty.backendUnavailable`, and
// `switcher.rows` identifiers. When
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

    let baseURL: URL
    let e2e: E2EConfig?
    let onSignOut: () -> Void

    init(
        baseURL: URL,
        e2e: E2EConfig?,
        bearerProvider: @escaping () -> String?,
        onSignOut: @escaping () -> Void
    ) {
        self.baseURL = baseURL
        self.e2e = e2e
        self.onSignOut = onSignOut
        let fetcher = URLSessionRemoteWorkspaceFetcher(
            baseURL: baseURL,
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
                    // `.contain` is REQUIRED here — without it SwiftUI
                    // treats the whole placeholder as one atomic a11y
                    // element and hides the inner terminal-gate / wrapper
                    // identifiers the e2e harness asserts on. With
                    // `.contain`, children's accessibilityIdentifiers
                    // bubble up alongside this one.
                    .accessibilityElement(children: .contain)
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
///
/// E2E harness extension: when `PLUE_E2E_WORKSPACE_SESSION_ID` is present
/// in the process environment, the detail view also mounts a
/// `TerminalSurface` so the terminal PTY scenario group can assert the
/// `terminal.ios.surface` accessibility identifier renders. Without a
/// live Freestyle sandbox the transport stays detached and the surface
/// shows its empty state — that is intentional: the scenario asserts
/// "the surface mounted and is wired", not "bytes flowed through a real
/// sandbox" (which is a Freestyle-live follow-up, not a v1 e2e goal).
private struct WorkspaceDetailPlaceholder: View {
    let workspace: SwitcherWorkspace
    let onBack: () -> Void

    /// Session id threaded through from `run-e2e.sh` after the seed
    /// script writes a `workspace_sessions` row. Non-empty only when the
    /// harness is exercising the terminal scenario group.
    private var seededSessionID: String? {
        ProcessInfo.processInfo.environment["PLUE_E2E_WORKSPACE_SESSION_ID"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

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
            // Diagnostic: expose whether the env var made it into the
            // app process. The e2e harness asserts on the `content.ios.
            // workspace-detail.terminal-gate` identifier to distinguish
            // "env forwarded but TerminalSurface failed to render" from
            // "env never arrived" — a SwiftUI lazy-init quirk that has
            // bitten this test once already (the `if let` below was
            // evaluated in a context where ProcessInfo didn't yet have
            // the launchEnvironment merged in).
            Text(seededSessionID ?? "no-session")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("content.ios.workspace-detail.terminal-gate")
            if let sessionID = seededSessionID {
                // TODO(ticket 0156): replace this env-gated mount with
                // real workspace-session lifecycle state so the
                // `terminal.status.*` identifiers reflect live websocket
                // status instead of only "seeded session id exists".
                // Mount the shared terminal surface so the e2e harness
                // can assert `terminal.ios.surface` is present. The
                // surface is detached (transport=nil) in v1 — a live
                // Freestyle sandbox would attach a real PTYTransport.
                TerminalSurface(
                    transport: nil,
                    sessionID: sessionID,
                    command: nil,
                    workingDirectory: nil
                )
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .accessibilityIdentifier("content.ios.workspace-detail.terminal")
            }
            Button("Back", action: onBack)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("content.ios.workspace-detail.back")
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
