// ContentShell.iOS.swift
//
// iOS platform shell hosting the shared navigation destinations in a
// `NavigationStack`. Workspace detail now mounts chat via `AgentChatView`
// when an `agent_session` is present, and mounts the terminal after the
// workspace session probe succeeds. The structure remains iOS-specific:
// NavigationStack + iOS-appropriate toolbar, no AppKit assumptions, and
// no direct route parity with the macOS detail router.
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

/// iOS shell wrapping the shared `NavigationStateStore`.
struct IOSContentShell: View {
    @StateObject private var navigation = NavigationStateStore()
    @StateObject private var switcherVM: WorkspaceSwitcherViewModel
    @ObservedObject private var deepLinkRouter = DeepLinkRouter.shared
    @ObservedObject private var featureFlags: FeatureFlagsClient
    @State private var showSwitcher: Bool = false
    @State private var showApprovalsInbox: Bool = false
    @State private var focusedApprovalID: String?
    @State private var focusedWorkspaceID: String?
    @State private var openedWorkspace: SwitcherWorkspace? = nil
    @StateObject private var runtimeSessionHost: IOSRuntimeSessionHost

    let baseURL: URL
    let e2e: E2EConfig?
    let onSignOut: () -> Void
    let replayTour: () -> Void
    private let terminalSessionProbe: any RemoteWorkspaceSessionPresenceProbe
    private let bearerProvider: @Sendable () -> String?
    private let workspaceSessionContext: IOSWorkspaceSessionProbeContext?

    init(
        featureFlags: FeatureFlagsClient,
        baseURL: URL,
        e2e: E2EConfig?,
        bearerProvider: @escaping @Sendable () -> String?,
        onSignOut: @escaping () -> Void,
        replayTour: @escaping () -> Void = {}
    ) {
        self.featureFlags = featureFlags
        self.baseURL = baseURL
        self.e2e = e2e
        self.onSignOut = onSignOut
        self.replayTour = replayTour
        self.bearerProvider = bearerProvider
        self.workspaceSessionContext = nil
        let fetcher = URLSessionRemoteWorkspaceFetcher(
            baseURL: baseURL,
            bearer: bearerProvider
        )
        self.terminalSessionProbe = URLSessionRemoteWorkspaceSessionPresenceProbe(
            baseURL: baseURL,
            bearer: bearerProvider
        )
        _switcherVM = StateObject(
            wrappedValue: WorkspaceSwitcherViewModel(fetcher: fetcher)
        )
        _runtimeSessionHost = StateObject(
            wrappedValue: IOSRuntimeSessionHost(
                baseURL: baseURL,
                bearerProvider: bearerProvider
            )
        )
    }

    init(
        featureFlags: FeatureFlagsClient,
        baseURL: URL,
        e2e: E2EConfig?,
        bearerProvider: @escaping @Sendable () -> String?,
        terminalSessionProbe: any RemoteWorkspaceSessionPresenceProbe,
        initialOpenedWorkspace: SwitcherWorkspace?,
        workspaceSessionContext: IOSWorkspaceSessionProbeContext? = nil,
        onSignOut: @escaping () -> Void,
        replayTour: @escaping () -> Void = {}
    ) {
        self.featureFlags = featureFlags
        self.baseURL = baseURL
        self.e2e = e2e
        self.onSignOut = onSignOut
        self.replayTour = replayTour
        self.bearerProvider = bearerProvider
        self.terminalSessionProbe = terminalSessionProbe
        self.workspaceSessionContext = workspaceSessionContext
        let fetcher = URLSessionRemoteWorkspaceFetcher(
            baseURL: baseURL,
            bearer: bearerProvider
        )
        _switcherVM = StateObject(
            wrappedValue: WorkspaceSwitcherViewModel(fetcher: fetcher)
        )
        _runtimeSessionHost = StateObject(
            wrappedValue: IOSRuntimeSessionHost(
                baseURL: baseURL,
                bearerProvider: bearerProvider
            )
        )
        _openedWorkspace = State(initialValue: initialOpenedWorkspace)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let opened = openedWorkspace {
                    WorkspaceDetailPlaceholder(
                        workspace: opened,
                        featureFlags: featureFlags,
                        baseURL: baseURL,
                        bearerProvider: bearerProvider,
                        sessionProbe: terminalSessionProbe,
                        runtimeSessionHost: runtimeSessionHost,
                        workspaceSessionContext: workspaceSessionContext,
                        onRefreshSwitcher: {
                            await switcherVM.refresh()
                        },
                        onBack: {
                            openedWorkspace = nil
                        }
                    )
                    // `.contain` is REQUIRED here — without it SwiftUI
                    // treats the whole placeholder as one atomic a11y
                    // element and hides the inner terminal-gate / wrapper
                    // identifiers the e2e harness asserts on. With
                    // `.contain`, children's accessibilityIdentifiers
                    // bubble up alongside this one.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("content.ios.workspace-detail")
                } else {
                    routedContent
                }
            }
        }
        .onChange(of: navigation.destination) { _, newValue in
            navigation.recordHistory(newValue)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if openedWorkspace == nil {
                    Button(action: navigation.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!navigation.canGoBack)
                    .accessibilityIdentifier("nav.back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if openedWorkspace == nil {
                    Button("Runs") {
                        navigation.navigate(to: .runs)
                    }
                    .accessibilityIdentifier("content.ios.workflow-runs-button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Approvals") {
                    showApprovalsInbox = true
                }
                .accessibilityIdentifier("content.ios.approvals-button")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if openedWorkspace == nil {
                    Button(action: navigation.goForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!navigation.canGoForward)
                    .accessibilityIdentifier("nav.forward")
                }
            }
        }
        // Attach the full-screen cover to the root — presenting from an
        // inner List inside NavigationStack occasionally swallows the
        // binding change on iOS 17+, so we hoist the modifier here.
        .workspaceSwitcherSheet(
            isPresented: $showSwitcher,
            viewModel: switcherVM,
            baseURL: baseURL,
            bearerProvider: bearerProvider,
            focusedWorkspaceID: focusedWorkspaceID,
            autoOpenFocusedWorkspace: focusedWorkspaceID != nil,
            onOpen: { workspace in
                IOSPushNotificationRegistrar.shared.requestRegistrationOnFirstWorkspaceOpen()
                openedWorkspace = workspace
                if focusedWorkspaceID == workspace.id {
                    focusedWorkspaceID = nil
                }
            },
            onSignIn: {
                // Auth expired — the root surface re-evaluates on the
                // auth model's phase change. Nothing to do from here.
            },
            onDismiss: {
                focusedWorkspaceID = nil
            }
        )
        .sheet(
            isPresented: $showApprovalsInbox,
            onDismiss: {
                focusedApprovalID = nil
            }
        ) {
            ApprovalsInboxView(
                baseURL: baseURL,
                bearerProvider: bearerProvider,
                focusedApprovalID: focusedApprovalID
            )
        }
        .onAppear {
            IOSPushNotificationRegistrar.shared.configure(baseURL: baseURL, bearerProvider: bearerProvider)
            ApprovalNotificationHandler.shared.configure(baseURL: baseURL, bearerProvider: bearerProvider)
            if let route = deepLinkRouter.route {
                handleDeepLinkRoute(route)
            }
        }
        .onReceive(deepLinkRouter.$route) { route in
            guard let route else { return }
            handleDeepLinkRoute(route)
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

    @ViewBuilder
    private var routedContent: some View {
        switch navigation.destination {
        case .runs:
            WorkflowRunsListView(
                baseURL: baseURL,
                bearerProvider: bearerProvider
            )
        case .settings:
            SettingsView(
                baseURL: baseURL,
                bearerProvider: bearerProvider,
                featureFlagsProvider: { [featureFlags] in
                    await MainActor.run { featureFlags.snapshot.flags }
                },
                replayTour: replayTour,
                onSignOut: onSignOut,
                resetCachedData: {
                    try runtimeSessionHost.resetCachedData()
                }
            )
        default:
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
                        .accessibilityIdentifier("content.ios.nav.\(dest.label.lowercased().replacingOccurrences(of: " ", with: "-"))")
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
        }
    }

    private func handleDeepLinkRoute(_ route: DeepLinkRouter.Route) {
        switch route {
        case .approval(let id):
            focusedApprovalID = id
            showApprovalsInbox = true
            deepLinkRouter.clearRoute(if: route)
        case .workspace(let uuid):
            openedWorkspace = nil
            focusedWorkspaceID = uuid
            showSwitcher = true
            deepLinkRouter.clearRoute(if: route)
        case .oauth2Callback, .unknown:
            deepLinkRouter.clearRoute(if: route)
        }
    }
}

@MainActor
private final class IOSRuntimeSessionHost: ObservableObject {
    private let baseURL: URL
    private let credentialsProvider: CredentialsProvider
    private var runtime: SmithersRuntime?
    private var session: RuntimeSession?

    init(
        baseURL: URL,
        bearerProvider: @escaping @Sendable () -> String?
    ) {
        self.baseURL = baseURL
        self.credentialsProvider = {
            guard let bearer = bearerProvider(), !bearer.isEmpty else {
                return nil
            }
            return SmithersCredentials(bearer: bearer)
        }
    }

    func runtimeSession() throws -> RuntimeSession {
        if let session {
            return session
        }

        let runtime = try SmithersRuntime(credentials: credentialsProvider)
        let session = try runtime.connect(Self.engineConfig(baseURL: baseURL))
        self.runtime = runtime
        self.session = session
        return session
    }

    func resetCachedData() throws {
        try SettingsLocalCache.resetWithActiveRuntime(session)
    }

    private static func engineConfig(baseURL: URL) -> EngineConfig {
        EngineConfig(
            engineID: "default",
            baseURL: baseURL.absoluteString,
            shapeProxyURL: baseURL.appendingPathComponent("shapes").absoluteString,
            wsPtyURL: websocketURL(from: baseURL.appendingPathComponent("pty")).absoluteString,
            cacheDir: runtimeCacheDirectory(),
            cacheMaxMB: 512
        )
    }

    private static func websocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            break
        }

        return components.url ?? url
    }

    private static func runtimeCacheDirectory() -> String? {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let runtimeDirectory = cachesDirectory.appendingPathComponent(
            "SmithersRuntime",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            return runtimeDirectory.path
        } catch {
            return nil
        }
    }
}

#if canImport(CSmithersKit)
@MainActor
private final class WorkspaceDetailTerminalTransportOwner: ObservableObject {
    private(set) var transport: RuntimePTYTransport?
    private var sessionID: String?

    func prepare(
        sessionID: String,
        runtimeSessionProvider: () throws -> RuntimeSession
    ) {
        guard self.sessionID != sessionID || transport == nil else {
            return
        }

        reset()
        do {
            transport = RuntimePTYTransport(
                session: try runtimeSessionProvider(),
                sessionID: sessionID
            )
            self.sessionID = sessionID
        } catch {
            NSLog("iOS terminal runtime bootstrap failed: \(error.localizedDescription)")
        }
    }

    func reset() {
        transport?.stop()
        transport = nil
        sessionID = nil
    }

    deinit {
        transport?.stop()
    }
}
#endif

/// Workspace detail pane. Chat mounts through `AgentChatView` when an
/// `agent_session` is present; terminal mounts after the session probe
/// confirms the workspace session still exists.
///
/// E2E harness extension: the seeded workspace-session id still arrives
/// via `PLUE_E2E_WORKSPACE_SESSION_ID`, but the terminal now mounts only
/// after the app confirms the row still exists via
/// `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}`. This keeps
/// the iOS terminal surface aligned with backend session lifecycle
/// changes such as deleting the seeded row between launches.
struct IOSWorkspaceDetailSurfaceGate: Equatable {
    enum TerminalSurfaceState: Equatable {
        case hidden
        case lookupRequired(sessionID: String)
        case killSwitchDisabled
    }

    let terminalSurfaceState: TerminalSurfaceState
    let showsAgentChatSurface: Bool

    init(
        seededSessionID: String?,
        isRemoteSandboxEnabled: Bool,
        isElectricClientEnabled: Bool,
        isApprovalsFlowEnabled: Bool
    ) {
        if let seededSessionID {
            terminalSurfaceState = isRemoteSandboxEnabled
                ? .lookupRequired(sessionID: seededSessionID)
                : .killSwitchDisabled
        } else {
            terminalSurfaceState = .hidden
        }
        showsAgentChatSurface = isElectricClientEnabled && isApprovalsFlowEnabled
    }
}

struct IOSWorkspaceSessionProbeContext: Equatable {
    let sessionID: String
    let repoOwner: String
    let repoName: String
}

private struct WorkspaceDetailPlaceholder: View {
    private struct DevtoolsPanelContext: Identifiable {
        let repoOwner: String
        let repoName: String
        let sessionID: String

        var id: String {
            "\(repoOwner)/\(repoName)#\(sessionID)"
        }
    }

    private enum AgentChatMountState: Equatable {
        case hidden
        case loading
        case mounted(sessionID: String)
        case empty
        case unavailable(message: String)
    }

    private enum TerminalMountState: Equatable {
        case hidden
        case probing
        case mounted(sessionID: String)
        case missing(sessionID: String)
        case unavailable(message: String)
    }

    @ObservedObject var featureFlags: FeatureFlagsClient
    let baseURL: URL
    let bearerProvider: AgentChatAPIClient.BearerProvider
    let sessionProbe: any RemoteWorkspaceSessionPresenceProbe
    let runtimeSessionHost: IOSRuntimeSessionHost
    let workspaceSessionContext: IOSWorkspaceSessionProbeContext?
    let onBack: () -> Void
    @State private var agentChatMountState: AgentChatMountState
    @State private var terminalMountState: TerminalMountState = .hidden
    @State private var presentedDevtoolsContext: DevtoolsPanelContext?
    @StateObject private var actionModel: WorkspaceDetailActionModel
    #if canImport(CSmithersKit)
    @StateObject private var terminalTransportOwner = WorkspaceDetailTerminalTransportOwner()
    #endif

    /// Session id threaded through from `run-e2e.sh` after the seed
    /// script writes a `workspace_sessions` row. Non-empty only when the
    /// harness is exercising the terminal scenario group.
    private var seededSessionID: String? {
        if let sessionID = workspaceSessionContext?.sessionID, !sessionID.isEmpty {
            return sessionID
        }
        return ProcessInfo.processInfo.environment["PLUE_E2E_WORKSPACE_SESSION_ID"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var seededRepoOwner: String? {
        if let repoOwner = workspaceSessionContext?.repoOwner, !repoOwner.isEmpty {
            return repoOwner
        }
        return ProcessInfo.processInfo.environment["PLUE_E2E_REPO_OWNER"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private var seededRepoName: String? {
        if let repoName = workspaceSessionContext?.repoName, !repoName.isEmpty {
            return repoName
        }
        return ProcessInfo.processInfo.environment["PLUE_E2E_REPO_NAME"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static var seededAgentSessionID: String? {
        ProcessInfo.processInfo.environment["PLUE_E2E_AGENT_SESSION_ID"]
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    init(
        workspace: SwitcherWorkspace,
        featureFlags: FeatureFlagsClient,
        baseURL: URL,
        bearerProvider: @escaping AgentChatAPIClient.BearerProvider,
        sessionProbe: any RemoteWorkspaceSessionPresenceProbe,
        runtimeSessionHost: IOSRuntimeSessionHost,
        workspaceSessionContext: IOSWorkspaceSessionProbeContext? = nil,
        onRefreshSwitcher: @escaping @MainActor () async -> Void,
        onBack: @escaping () -> Void
    ) {
        self.featureFlags = featureFlags
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider
        self.sessionProbe = sessionProbe
        self.runtimeSessionHost = runtimeSessionHost
        self.workspaceSessionContext = workspaceSessionContext
        self.onBack = onBack
        let seededAgentSessionID = Self.seededAgentSessionID
        _agentChatMountState = State(
            initialValue: seededAgentSessionID.map { .mounted(sessionID: $0) } ?? .hidden
        )
        _actionModel = StateObject(
            wrappedValue: WorkspaceDetailActionModel(
                workspace: workspace,
                client: URLSessionWorkspaceDetailMutationClient(
                    baseURL: baseURL,
                    bearerProvider: bearerProvider
                ),
                onRefreshSwitcher: onRefreshSwitcher
            )
        )
    }

    private var surfaceGate: IOSWorkspaceDetailSurfaceGate {
        IOSWorkspaceDetailSurfaceGate(
            seededSessionID: seededSessionID,
            isRemoteSandboxEnabled: featureFlags.effectiveRemoteSandboxEnabled(),
            isElectricClientEnabled: featureFlags.isElectricClientEnabled,
            isApprovalsFlowEnabled: featureFlags.isApprovalsFlowEnabled
        )
    }

    private var probeTaskKey: String {
        [
            seededSessionID ?? "no-session",
            seededRepoOwner ?? "no-owner",
            seededRepoName ?? "no-repo",
            featureFlags.effectiveRemoteSandboxEnabled() ? "remote-on" : "remote-off",
            featureFlags.isElectricClientEnabled ? "electric-on" : "electric-off",
            featureFlags.isApprovalsFlowEnabled ? "approvals-on" : "approvals-off",
            featureFlags.isDevtoolsSnapshotEnabled ? "devtools-on" : "devtools-off",
            actionModel.workspace.id,
        ].joined(separator: "|")
    }

    private var activeAgentSessionID: String? {
        if case let .mounted(sessionID) = agentChatMountState {
            return sessionID
        }
        return nil
    }

    private var devtoolsPanelContext: DevtoolsPanelContext? {
        guard
            featureFlags.isDevtoolsSnapshotEnabled,
            let repoOwner = actionModel.workspace.repoOwner, !repoOwner.isEmpty,
            let repoName = actionModel.workspace.repoName, !repoName.isEmpty,
            let sessionID = activeAgentSessionID
        else {
            return nil
        }

        return DevtoolsPanelContext(
            repoOwner: repoOwner,
            repoName: repoName,
            sessionID: sessionID
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            if let banner = actionModel.banner {
                WorkspaceDetailInlineBanner(banner: banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Text(actionModel.workspace.title)
                .font(.title3.weight(.semibold))
            if surfaceGate.showsAgentChatSurface {
                agentChatView
            }
            Text("Workspace id: \(actionModel.workspace.id)")
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
            switch surfaceGate.terminalSurfaceState {
            case .hidden:
                EmptyView()
            case .lookupRequired:
                terminalMountView
            case .killSwitchDisabled:
                TerminalKillSwitchDisabledView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
            }
            Button("Back", action: onBack)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("content.ios.workspace-detail.back")
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: probeTaskKey) {
            await refreshTerminalMountState()
            await resolveAgentSessionIfNeeded()
        }
        .onChange(of: actionModel.workspace.state) { _, _ in
            Task { await refreshTerminalMountState() }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if featureFlags.isDevtoolsSnapshotEnabled {
                    Button("Devtools") {
                        presentedDevtoolsContext = devtoolsPanelContext
                    }
                    .disabled(devtoolsPanelContext == nil)
                    .accessibilityIdentifier("workspace-detail.devtools-button")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if actionModel.showsSuspendAction {
                        Button("Suspend") {
                            Task { await actionModel.perform(.suspend) }
                        }
                        .accessibilityIdentifier("workspace-detail.actions.suspend")
                    }
                    if actionModel.showsResumeAction {
                        Button("Resume") {
                            Task { await actionModel.perform(.resume) }
                        }
                        .accessibilityIdentifier("workspace-detail.actions.resume")
                    }
                    Button("Fork") {
                        Task { await actionModel.perform(.fork) }
                    }
                    .accessibilityIdentifier("workspace-detail.actions.fork")
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(actionModel.isPerformingAction)
                .accessibilityIdentifier("workspace-detail.actions.menu")
            }
        }
        .sheet(item: $presentedDevtoolsContext) { context in
            DevtoolsPanelView(
                baseURL: baseURL,
                repoOwner: context.repoOwner,
                repoName: context.repoName,
                sessionID: context.sessionID,
                bearerProvider: bearerProvider
            )
        }
    }

    @ViewBuilder
    private var agentChatView: some View {
        switch agentChatMountState {
        case .hidden, .loading:
            WorkspaceDetailLoadingState(
                title: "Loading chat…",
                systemImage: "bubble.left.and.bubble.right"
            )
            .accessibilityIdentifier("content.ios.workspace-detail.chat.loading")
        case let .mounted(sessionID):
            if let repoOwner = actionModel.workspace.repoOwner,
               let repoName = actionModel.workspace.repoName {
                AgentChatView(
                    baseURL: baseURL,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    sessionID: sessionID,
                    bearerProvider: bearerProvider
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceDetailEmptyState(
                    title: "No chat is available yet",
                    systemImage: "bubble.left.and.bubble.right",
                    message: "This workspace is missing repository context, so chat cannot be loaded."
                )
                .accessibilityIdentifier("content.ios.workspace-detail.chat.empty")
            }
        case .empty:
            WorkspaceDetailEmptyState(
                title: "No chat is available yet",
                systemImage: "bubble.left.and.bubble.right",
                message: "An agent session has not been created for this workspace yet."
            )
            .accessibilityIdentifier("content.ios.workspace-detail.chat.empty")
        case let .unavailable(message):
            WorkspaceDetailErrorBanner(
                message: message,
                retryIdentifier: "content.ios.workspace-detail.chat.error.retry"
            ) {
                Task { await resolveAgentSessionIfNeeded() }
            }
            .accessibilityIdentifier("content.ios.workspace-detail.chat.error")
        }
    }

    @ViewBuilder
    private var terminalMountView: some View {
        switch terminalMountState {
        case .hidden:
            WorkspaceDetailLoadingState(
                title: "Checking terminal session…",
                systemImage: "terminal"
            )
            .accessibilityIdentifier("content.ios.workspace-detail.terminal.loading")
        case .probing:
            WorkspaceDetailLoadingState(
                title: "Checking terminal session…",
                systemImage: "terminal"
            )
            .accessibilityIdentifier("content.ios.workspace-detail.terminal.loading")
        case let .mounted(sessionID):
            // The detail view owns the runtime-backed transport through a
            // StateObject so SwiftUI re-renders keep the PTY attachment, while
            // navigating back tears down the owner and stops the transport.
            TerminalSurface(
                transport: terminalTransport,
                sessionID: sessionID,
                command: nil,
                workingDirectory: nil
            )
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .accessibilityIdentifier("content.ios.workspace-detail.terminal")
        case let .missing(sessionID):
            WorkspaceDetailTerminalEmptyState(sessionID: sessionID)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("content.ios.workspace-detail.terminal-empty")
        case let .unavailable(message):
            WorkspaceDetailErrorBanner(
                message: message,
                retryIdentifier: "content.ios.workspace-detail.terminal.error.retry"
            ) {
                Task { await refreshTerminalMountState() }
            }
            .accessibilityIdentifier("content.ios.workspace-detail.terminal.error")
        }
    }

    @MainActor
    private func refreshTerminalMountState() async {
        guard case let .lookupRequired(sessionID) = surfaceGate.terminalSurfaceState else {
            resetTerminalTransport()
            terminalMountState = .hidden
            return
        }
        guard let repoOwner = seededRepoOwner, let repoName = seededRepoName else {
            resetTerminalTransport()
            terminalMountState = .unavailable(
                message: "Workspace session lookup is not configured for this workspace."
            )
            return
        }

        terminalMountState = .probing

        do {
            let presence = try await sessionProbe.fetch(
                repoOwner: repoOwner,
                repoName: repoName,
                sessionID: sessionID
            )
            guard !Task.isCancelled else { return }
            switch presence {
            case .present:
                prepareTerminalTransport(sessionID: sessionID)
                terminalMountState = .mounted(sessionID: sessionID)
            case .missing:
                resetTerminalTransport()
                terminalMountState = .missing(sessionID: sessionID)
            }
        } catch RemoteWorkspaceSessionPresenceError.authExpired {
            resetTerminalTransport()
            terminalMountState = .unavailable(
                message: "Workspace session lookup requires an active signed-in session."
            )
        } catch let RemoteWorkspaceSessionPresenceError.backendUnavailable(message) {
            resetTerminalTransport()
            terminalMountState = .unavailable(
                message: "Could not load the workspace session (\(message))."
            )
        } catch {
            resetTerminalTransport()
            terminalMountState = .unavailable(
                message: "Could not load the workspace session (\(error.localizedDescription))."
            )
        }
    }

    private var terminalTransport: TerminalPTYTransport? {
        #if canImport(CSmithersKit)
        terminalTransportOwner.transport
        #else
        nil
        #endif
    }

    @MainActor
    private func prepareTerminalTransport(sessionID: String) {
        #if canImport(CSmithersKit)
        terminalTransportOwner.prepare(
            sessionID: sessionID,
            runtimeSessionProvider: runtimeSessionHost.runtimeSession
        )
        #else
        _ = sessionID
        #endif
    }

    @MainActor
    private func resetTerminalTransport() {
        #if canImport(CSmithersKit)
        terminalTransportOwner.reset()
        #endif
    }

    @MainActor
    private func resolveAgentSessionIfNeeded() async {
        guard surfaceGate.showsAgentChatSurface || featureFlags.isDevtoolsSnapshotEnabled else {
            agentChatMountState = .hidden
            return
        }

        guard
            let repoOwner = actionModel.workspace.repoOwner, !repoOwner.isEmpty,
            let repoName = actionModel.workspace.repoName, !repoName.isEmpty
        else {
            agentChatMountState = .empty
            return
        }

        if let seededAgentSessionID = Self.seededAgentSessionID {
            agentChatMountState = .mounted(sessionID: seededAgentSessionID)
            return
        }

        agentChatMountState = .loading

        switch await AgentChatSessionDiscovery.discoverFirstSessionID(
            baseURL: baseURL,
            repoOwner: repoOwner,
            repoName: repoName,
            bearerProvider: bearerProvider
        ) {
        case let .found(sessionID):
            agentChatMountState = .mounted(sessionID: sessionID)
        case .empty:
            agentChatMountState = .empty
        case let .failure(message):
            agentChatMountState = .unavailable(message: message)
        }
    }
}

private struct WorkspaceDetailInlineBanner: View {
    let banner: WorkspaceDetailBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(foregroundColor)

            Text(banner.message)
                .font(.footnote)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("workspace-detail.banner")
    }

    private var iconName: String {
        switch banner.style {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "clock.badge.exclamationmark"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    private var foregroundColor: Color {
        switch banner.style {
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch banner.style {
        case .success:
            return Color.green.opacity(0.10)
        case .warning:
            return Color.orange.opacity(0.12)
        case .error:
            return Color.red.opacity(0.10)
        }
    }
}

private struct WorkspaceDetailLoadingState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            ProgressView(title)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct WorkspaceDetailEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct WorkspaceDetailErrorBanner: View {
    let message: String
    let retryIdentifier: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(retryIdentifier)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}

private struct WorkspaceDetailTerminalEmptyState: View {
    let sessionID: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Terminal session not found")
                .font(.headline)
            Text("The seeded workspace session no longer exists in the backend, so the terminal surface stays unmounted.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(sessionID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityIdentifier("content.ios.workspace-detail.terminal.empty")
    }
}

private struct TerminalKillSwitchDisabledView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal.slash")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Terminal unavailable")
                .font(.headline)
            Text("The remote sandbox kill switch is off, so WS PTY stays disabled.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("terminal.disabled.kill-switch")
    }
}
#endif
