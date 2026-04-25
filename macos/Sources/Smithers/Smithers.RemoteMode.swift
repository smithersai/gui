// Smithers.RemoteMode.swift — desktop-remote productization (ticket 0126).
//
// Owns the macOS-only product surfaces for remote (JJHub sandbox) mode
// that sit on top of the shared SmithersAuth (0109) + SmithersStore
// (0124) + SmithersRuntime (0120) layers.
//
// Responsibilities:
//   1. Read the `remote_sandbox_enabled` feature flag (0112).
//   2. Own the single `AuthViewModel` / `TokenManager` / `KeychainTokenStore`
//      tuple for the macOS app.
//   3. On successful sign-in, bootstrap a `SmithersSessionLifecycle` and
//      publish it so the shell can surface remote tabs.
//   4. Track slow-boot and reconnect states so the UI can show progressive
//      messaging ("this is taking longer than expected" at 8s, "allow cancel"
//      at 30s) without blanking the shell.
//   5. On sign-out, drop remote tabs + wipe the shape cache; leave
//      WorkspaceManager (local) state untouched.
//
// This file is macOS-only. The iOS target owns its own composition root.

#if os(macOS)

import Foundation
import SwiftUI
import AppKit
#if canImport(SmithersAuth)
import SmithersAuth
#endif
#if canImport(SmithersStore)
import SmithersStore
#endif
#if canImport(SmithersRuntime)
import SmithersRuntime
#endif
#if canImport(SmithersE2ESupport)
import SmithersE2ESupport
#endif

// MARK: - Feature flag plumbing

/// Reads the `remote_sandbox_enabled` feature flag (0112).
///
/// Startup precedence:
///   1. `PLUE_REMOTE_SANDBOX_ENABLED` when explicitly set to a true/false-ish
///      value. This remains the highest-priority dev/test override.
///   2. Otherwise read `UserDefaults["remote_sandbox_enabled"]` — the last
///      server-backed value persisted after a successful `/api/feature-flags`
///      refresh.
///   3. Off by default. With flag off, the macOS app preserves its existing
///      local-only behaviour verbatim (no sign-in UI, no remote sections).
enum RemoteSandboxFlag {
    static let key = "remote_sandbox_enabled"
    static let envVar = "PLUE_REMOTE_SANDBOX_ENABLED"

    static func environmentOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool? {
        guard let raw = environment[envVar]?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    static func persisted(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        environmentOverride(environment: environment) ?? persisted(defaults: defaults)
    }

    /// Persist a flag value reported by plue (`/api/feature-flags`) so the
    /// next app launch opens with the correct UX without waiting on a
    /// network round-trip. Called opportunistically after sign-in.
    static func persist(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }
}

// MARK: - Remote mode state machine

enum RemoteModePhase: Equatable {
    /// Remote feature flag is off. The app operates as local-only.
    case disabled
    /// Flag on, user signed out.
    case signedOut
    /// OAuth2 flow in progress.
    case signingIn
    /// OAuth2 succeeded but the session/snapshot has not yet arrived.
    /// While in this phase, the UI blocks the remote workspace surface
    /// (acceptance criterion).
    case bootBlocked(since: Date)
    /// Boot still going past the 8s "taking longer than expected" mark.
    case slowBoot(since: Date)
    /// Boot still going past the 30s "allow cancel" mark.
    case stalledBoot(since: Date)
    /// Session live, first snapshot received, remote workspaces available.
    case active
    /// A reconnect is in progress but cached state is still on-screen.
    /// The UI shows a status banner; we do NOT flip to `bootBlocked`.
    case reconnecting
    /// Sign-in was blocked (whitelist / structured error).
    case whitelistDenied(String)
    /// Transient error; callers may retry.
    case error(String)

    var isRemoteAvailable: Bool {
        switch self {
        case .active, .reconnecting, .slowBoot, .stalledBoot:
            return true
        default:
            return false
        }
    }

    var allowsRemoteSurface: Bool {
        switch self {
        case .active, .reconnecting:
            return true
        default:
            return false
        }
    }

    static func == (lhs: RemoteModePhase, rhs: RemoteModePhase) -> Bool {
        switch (lhs, rhs) {
        case (.disabled, .disabled), (.signedOut, .signedOut),
             (.signingIn, .signingIn), (.active, .active),
             (.reconnecting, .reconnecting):
            return true
        case (.bootBlocked, .bootBlocked),
             (.slowBoot, .slowBoot),
             (.stalledBoot, .stalledBoot):
            return true
        case (.whitelistDenied(let a), .whitelistDenied(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

/// Identity of a remote sandbox tab the user has opened. This is NOT the
/// full workspace snapshot — just the handle the sidebar needs to render a
/// row and that the shell uses to route.
struct RemoteWorkspaceTab: Identifiable, Equatable, Hashable {
    let workspaceId: String
    let name: String
    let engineId: String?

    var id: String { workspaceId }
}

/// Singleton shared by `SmithersRootView`, `WelcomeView`, and `SidebarView`.
/// The instance is created eagerly (it is cheap) but the sign-in / lifecycle
/// work is strictly on-demand.
@MainActor
final class RemoteModeController: ObservableObject {
    static let shared = RemoteModeController()

    // Published UI-facing state.
    @Published private(set) var phase: RemoteModePhase
    @Published private(set) var openWorkspaceTabs: [RemoteWorkspaceTab] = []
    @Published private(set) var remoteWorkspaces: [WorkspaceRow] = []
    @Published private(set) var isRemoteFeatureEnabled: Bool
    // Runtime-backed provider installed into `SmithersClient` whenever the
    // production lifecycle is live (non-E2E path).
    @Published private(set) var runtimeProvider: SmithersRemoteProvider?
    // Root-shell route toggle. Welcome uses this to enter the remote shell
    // without requiring a local folder to be opened first.
    @Published private(set) var shouldPresentRemoteShell: Bool = false

    // Auth plumbing.
    let authModel: AuthViewModel

    // Lifecycle (nil until sign-in completes). The session is owned here so
    // it survives as long as the user is signed in.
    private(set) var lifecycle: SmithersSessionLifecycle?
    private var reconnectObserver: NSObjectProtocol?
    private var authExpiredObserver: NSObjectProtocol?
    private var authObservationTask: Task<Void, Never>?
    private var workspacesObservation: Task<Void, Never>?
    private var slowBootTimer: Task<Void, Never>?
    private var featureFlagRefreshTask: Task<Void, Never>?
    private let featureFlags: FeatureFlagsClient
    private let serverBaseURL: URL
    private let environment: [String: String]
    private let defaults: UserDefaults
    private let featureFlagRefreshInterval: TimeInterval

    /// macOS E2E bypass (ticket macos-e2e-harness). When `PLUE_E2E_MODE=1`
    /// is set, we short-circuit the entire production auth + lifecycle
    /// path: tokens come from `SMITHERS_E2E_BEARER`, the base URL from
    /// `PLUE_BASE_URL`, the flag is force-enabled, and the remote
    /// workspace list is fetched directly via a single REST call so the
    /// XCUITest bundle does not depend on Electric shape bring-up.
    private let e2eConfig: E2EConfig?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        e2eConfig: E2EConfig? = E2EEnvironment.parse(),
        featureFlags: FeatureFlagsClient? = nil,
        authModel: AuthViewModel? = nil,
        featureFlagRefreshInterval: TimeInterval = 60
    ) {
        self.environment = environment
        self.defaults = defaults
        self.e2eConfig = e2eConfig
        self.featureFlagRefreshInterval = featureFlagRefreshInterval
        let initialRemoteFeatureEnabled = e2eConfig != nil || RemoteSandboxFlag.isEnabled(
            environment: environment,
            defaults: defaults
        )
        self.isRemoteFeatureEnabled = initialRemoteFeatureEnabled

        let effectiveBaseURL = authModel?.client.config.baseURL ?? Self.resolveBaseURL(
            environment: environment,
            e2eBaseURL: e2eConfig?.baseURL
        )
        self.serverBaseURL = effectiveBaseURL

        let resolvedAuthModel: AuthViewModel
        if let authModel {
            resolvedAuthModel = authModel
        } else {
            // Build the auth stack. This is cheap (no network, no keychain write).
            // In E2E mode, swap the Keychain-backed store for an in-memory one
            // pre-seeded with the injected bearer so `AuthViewModel.phase`
            // resolves to `.signedIn` from init without any OAuth round trip.
            let tokenStore: TokenStore
            if let e2eConfig {
                tokenStore = InMemoryTokenStore(initial: E2EEnvironment.syntheticTokens(from: e2eConfig))
            } else {
                tokenStore = KeychainTokenStore()
            }
            let transport = URLSessionHTTPTransport()
            let clientConfig = OAuth2ClientConfig(
                baseURL: effectiveBaseURL,
                clientID: "smithers-macos",
                redirectURI: "smithers://auth/callback",
                scopes: ["read", "write"],
                audience: "smithers-api"
            )
            let oauthClient = OAuth2Client(config: clientConfig, transport: transport)
            let tokenManager = TokenManager(client: oauthClient, store: tokenStore)

            let presenter = MacOSWebAuthPresenter()
            let driver = WebAuthSessionDriver(presenter: presenter)
            resolvedAuthModel = AuthViewModel(
                client: oauthClient,
                tokens: tokenManager,
                driver: driver,
                callbackScheme: "smithers"
            )
        }
        self.authModel = resolvedAuthModel

        let tokenManager = resolvedAuthModel.tokens
        self.featureFlags = featureFlags ?? FeatureFlagsClient(
            baseURL: effectiveBaseURL,
            bearerProvider: {
                try? tokenManager.currentAccessToken()
            }
        )

        if !initialRemoteFeatureEnabled {
            self.phase = .disabled
            return
        }

        // E2E fast path: bypass the full SmithersSessionLifecycle (which
        // requires Electric shape bring-up and a runtime cache directory)
        // and populate `remoteWorkspaces` via a direct plue REST call.
        if let e2e = e2eConfig {
            self.phase = .active
            wireAuthObservation()
            Task { [weak self] in
                await self?.bootstrapE2EWorkspaces(config: e2e)
            }
            return
        }

        // Seed phase from Keychain. If a session already exists we restore
        // into `.bootBlocked` until the first snapshot lands; otherwise
        // we're signed out.
        self.phase = resolvedAuthModel.phase == .signedIn ? .bootBlocked(since: Date()) : .signedOut

        // Observe auth model phase transitions.
        wireAuthObservation()
        if resolvedAuthModel.phase == .signedIn {
            Task { await handleSignedInState() }
        }
    }

    /// Fetch `/api/user/workspaces` with the E2E bearer, decode the plue
    /// response shape, and populate `remoteWorkspaces` + auto-open the
    /// seeded workspace so the sidebar shows a `sidebar.remote.row.<id>`
    /// button. Any failure flips the phase to `.error(...)` so the test
    /// harness fails loudly instead of silently asserting an empty list.
    private func bootstrapE2EWorkspaces(config: E2EConfig) async {
        struct PlueWorkspace: Decodable {
            let workspace_id: String
            let workspace_title: String
            let state: String
        }
        let fetchURL = config.baseURL.appendingPathComponent("api/user/workspaces")
        AppLogger.ui.info("E2E: fetching \(fetchURL.absoluteString)")
        var req = URLRequest(url: fetchURL)
        req.setValue("Bearer \(config.bearer)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                self.phase = .error("E2E fetch status=\(code)")
                return
            }
            let rows = try JSONDecoder().decode([PlueWorkspace].self, from: data)
            let mapped = rows.map { row in
                WorkspaceRow(
                    workspaceId: row.workspace_id,
                    name: row.workspace_title,
                    status: row.state,
                    engineId: nil,
                    createdAt: nil,
                    updatedAt: nil,
                    suspendedAt: nil
                )
            }
            self.remoteWorkspaces = mapped
            // Auto-open each seeded workspace as a sidebar tab. The test
            // harness expects the seeded workspace to appear as a
            // `sidebar.remote.row.<id>` button BEFORE the user interacts.
            self.openWorkspaceTabs = mapped.map { row in
                RemoteWorkspaceTab(
                    workspaceId: row.workspaceId,
                    name: row.name,
                    engineId: row.engineId
                )
            }
            AppLogger.ui.info("E2E: hydrated \(mapped.count) workspace(s)")
        } catch {
            AppLogger.ui.error("E2E fetch threw: \(error.localizedDescription)")
            self.phase = .error("E2E fetch err: \(error.localizedDescription)")
        }
    }

    deinit {
        if let o = reconnectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = authExpiredObserver { NotificationCenter.default.removeObserver(o) }
        authObservationTask?.cancel()
        workspacesObservation?.cancel()
        slowBootTimer?.cancel()
        featureFlagRefreshTask?.cancel()
    }

    // MARK: Public surface

    var isSignedIn: Bool {
        switch phase {
        case .signedOut, .disabled, .signingIn, .whitelistDenied, .error:
            return false
        default:
            return true
        }
    }

    /// Present the system browser for OAuth2. Idempotent.
    func beginSignIn() async {
        guard isRemoteFeatureEnabled else { return }
        phase = .signingIn
        await authModel.signIn()
        // Phase gets finalized by `wireAuthObservation()`.
    }

    /// Wipe remote credentials + shape cache + open remote tabs. Local tabs
    /// (`WorkspaceManager`) are untouched.
    func signOut() async {
        featureFlagRefreshTask?.cancel()
        featureFlagRefreshTask = nil
        teardownRemoteSession()
        await authModel.signOut()
        phase = isRemoteFeatureEnabled ? .signedOut : .disabled
    }

    func refreshFeatureFlagsNow(force: Bool = true) async {
        await refreshFeatureFlags(force: force)
    }

    /// Add a remote sandbox tab. The shell uses the returned identifier to
    /// route a navigation to this workspace.
    func openRemoteWorkspace(_ row: WorkspaceRow) {
        let tab = RemoteWorkspaceTab(
            workspaceId: row.workspaceId,
            name: row.name,
            engineId: row.engineId
        )
        if !openWorkspaceTabs.contains(where: { $0.id == tab.id }) {
            openWorkspaceTabs.append(tab)
        }
    }

    func closeRemoteWorkspace(id: String) {
        openWorkspaceTabs.removeAll { $0.id == id }
    }

    /// Bridge from the REST workspace picker (which yields id + name) to the
    /// shape-backed `WorkspaceRow` that `openRemoteWorkspace` expects.
    /// Idempotent: calling this twice for the same workspace id does nothing.
    func openWorkspaceById(id: String, name: String, engineId: String? = nil) {
        let row = WorkspaceRow(workspaceId: id, name: name, status: "active", engineId: engineId)
        openRemoteWorkspace(row)
    }

    func presentRemoteShell() {
        guard isRemoteFeatureEnabled else { return }
        shouldPresentRemoteShell = true
    }

    func dismissRemoteShell() {
        shouldPresentRemoteShell = false
    }

    // MARK: Bootstrap

    private func wireAuthObservation() {
        // Subscribe to phase changes on the AuthViewModel. SwiftUI already
        // re-renders; we just need to react to signIn completions.
        // Poll on objectWillChange so we don't need to own a Combine sink.
        authObservationTask?.cancel()
        authObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.authModel.objectWillChange.values {
                await self.handleAuthChanged()
            }
        }
    }

    private func handleAuthChanged() async {
        switch authModel.phase {
        case .signedIn:
            await handleSignedInState()
        case .restoringSession:
            phase = .signingIn
        case .signedOut:
            featureFlagRefreshTask?.cancel()
            featureFlagRefreshTask = nil
            teardownRemoteSession()
            phase = isRemoteFeatureEnabled ? .signedOut : .disabled
        case .signingIn:
            phase = .signingIn
        case .whitelistDenied(let m):
            phase = .whitelistDenied(m)
        case .error(let m):
            phase = .error(m)
        }
    }

    private func bootstrapLifecycle() async {
        let start = Date()
        phase = .bootBlocked(since: start)
        startSlowBootTimer(start: start)

        do {
            let tokenSource = AuthTokenSourceShim(auth: authModel)
            let config = EngineConfig(
                engineID: "default",
                baseURL: serverBaseURL.absoluteString,
                shapeProxyURL: serverBaseURL.appendingPathComponent("shapes").absoluteString,
                wsPtyURL: Self.websocketURL(from: serverBaseURL.appendingPathComponent("pty")).absoluteString,
                cacheDir: RemoteModeController.cacheDirectory(),
                cacheMaxMB: 512
            )
            let lc = try SmithersSessionLifecycle.bootstrap(
                tokenSource: tokenSource,
                engineConfig: config
            )
            self.lifecycle = lc
            self.runtimeProvider = SmithersRemoteProvider(lifecycle: lc)
            wireStoreObservation(lifecycle: lc)
            // We still wait for the first workspaces snapshot before flipping
            // to `.active`. `wireStoreObservation` handles that transition.
        } catch {
            AppLogger.ui.error(
                "Remote lifecycle bootstrap failed",
                metadata: ["error": error.localizedDescription]
            )
            phase = .error(error.localizedDescription)
            cancelSlowBootTimer()
        }
    }

    private func handleSignedInState() async {
        startFeatureFlagRefreshLoopIfNeeded()

        // In E2E mode we deliberately skip `bootstrapLifecycle` — the
        // remote workspace list is hydrated via `bootstrapE2EWorkspaces`
        // at init time and the Electric shape stack is not needed.
        if e2eConfig != nil {
            return
        }

        await refreshFeatureFlags(force: true)
        guard isRemoteFeatureEnabled else { return }
        if lifecycle == nil {
            await bootstrapLifecycle()
        }
    }

    private func startFeatureFlagRefreshLoopIfNeeded() {
        guard featureFlagRefreshTask == nil else { return }
        guard e2eConfig == nil else { return }
        guard RemoteSandboxFlag.environmentOverride(environment: environment) == nil else { return }
        featureFlagRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.nanoseconds(for: self.featureFlagRefreshInterval))
                if Task.isCancelled { break }
                await self.refreshFeatureFlags(force: true)
            }
        }
    }

    private func refreshFeatureFlags(force: Bool) async {
        do {
            let snapshot = try await featureFlags.refresh(force: force)
            RemoteSandboxFlag.persist(snapshot.isRemoteSandboxEnabled, defaults: defaults)
            applyRemoteFeatureFlag(snapshot.isRemoteSandboxEnabled)
            if isRemoteFeatureEnabled, authModel.phase == .signedIn, lifecycle == nil, e2eConfig == nil {
                await bootstrapLifecycle()
            }
        } catch {
            AppLogger.ui.warning(
                "Remote feature flag refresh failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func applyRemoteFeatureFlag(_ serverEnabled: Bool) {
        let effectiveEnabled = RemoteSandboxFlag.environmentOverride(environment: environment) ?? serverEnabled
        let wasEnabled = isRemoteFeatureEnabled
        isRemoteFeatureEnabled = effectiveEnabled

        if !effectiveEnabled {
            teardownRemoteSession()
            phase = .disabled
            return
        }

        if !wasEnabled {
            phase = authModel.phase == .signedIn ? .bootBlocked(since: Date()) : .signedOut
        } else if case .disabled = phase {
            phase = authModel.phase == .signedIn ? .bootBlocked(since: Date()) : .signedOut
        }
    }

    private func wireStoreObservation(lifecycle: SmithersSessionLifecycle) {
        // First-snapshot → `.active`. We treat "workspaces has any row OR
        // lastRefreshedAt set" as the first snapshot; the 0124 store sets
        // `lastRefreshedAt` on every reloadFromCache (including empty result
        // sets), which fires once the initial shape sync completes.
        //
        // Important: the store may already have a refreshed snapshot by the
        // time this observer is wired (bootstrap race). We therefore apply an
        // immediate snapshot first, then keep listening for subsequent deltas.
        workspacesObservation?.cancel()
        workspacesObservation = Task { [weak self, weak lifecycle] in
            guard let self, let lifecycle else { return }
            for await _ in lifecycle.store.workspaces.objectWillChange.values {
                await MainActor.run {
                    self.applyWorkspacesSnapshot(lifecycle.store.workspaces)
                }
            }
        }
        applyWorkspacesSnapshot(lifecycle.store.workspaces)

        reconnectObserver = NotificationCenter.default.addObserver(
            forName: .smithersReconnected,
            object: lifecycle.store,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Show a reconnect banner but do NOT wipe cache or blank UI.
            if case .active = self.phase {
                self.phase = .reconnecting
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if case .reconnecting = self?.phase {
                        self?.phase = .active
                    }
                }
            }
        }
        authExpiredObserver = NotificationCenter.default.addObserver(
            forName: .smithersAuthExpired,
            object: lifecycle.store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.signOut()
            }
        }
    }

    private func applyWorkspacesSnapshot(_ store: WorkspacesStore) {
        remoteWorkspaces = store.workspaces
        guard store.lastRefreshedAt != nil else { return }

        switch phase {
        case .bootBlocked, .slowBoot, .stalledBoot:
            phase = .active
            cancelSlowBootTimer()
        case .active:
            cancelSlowBootTimer()
        case .reconnecting:
            // Keep reconnect messaging visible until its timer clears.
            break
        default:
            break
        }
    }

    private func startSlowBootTimer(start: Date) {
        cancelSlowBootTimer()
        slowBootTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await MainActor.run {
                guard let self else { return }
                if case .bootBlocked = self.phase {
                    self.phase = .slowBoot(since: start)
                }
            }
            try? await Task.sleep(nanoseconds: 22_000_000_000) // +22 = 30s total
            await MainActor.run {
                guard let self else { return }
                if case .slowBoot = self.phase {
                    self.phase = .stalledBoot(since: start)
                }
            }
        }
    }

    private func cancelSlowBootTimer() {
        slowBootTimer?.cancel()
        slowBootTimer = nil
    }

    /// Cancel an in-flight boot. Only valid from `.stalledBoot`.
    func cancelBoot() async {
        guard case .stalledBoot = phase else { return }
        await signOut()
    }

    private func teardownRemoteSession() {
        shouldPresentRemoteShell = false
        openWorkspaceTabs.removeAll()
        remoteWorkspaces.removeAll()
        runtimeProvider = nil
        workspacesObservation?.cancel()
        workspacesObservation = nil
        if let reconnectObserver {
            NotificationCenter.default.removeObserver(reconnectObserver)
            self.reconnectObserver = nil
        }
        if let authExpiredObserver {
            NotificationCenter.default.removeObserver(authExpiredObserver)
            self.authExpiredObserver = nil
        }
        cancelSlowBootTimer()
        lifecycle?.wipeForSignOut()
        lifecycle = nil
    }

    // MARK: Helpers

    private static func cacheDirectory() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("SmithersRemoteCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func resolveBaseURL(
        environment: [String: String],
        e2eBaseURL: URL?
    ) -> URL {
        if let e2eBaseURL {
            return e2eBaseURL
        }
        if let dev = environment["SMITHERS_PLUE_URL"].flatMap(URL.init(string:)) {
            return dev
        }
        return URL(string: "https://jjhub.smithers.ai")!
    }

    private static func websocketURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        return components.url ?? url
    }

    private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
        UInt64((seconds * 1_000_000_000).rounded())
    }
}

// MARK: - Token source shim

/// Bridges `SmithersAuth.TokenManager` to the opaque `StoreTokenSource`
/// protocol `SmithersStore` expects. Keeps `SmithersStore` free of any
/// direct SmithersAuth import.
private final class AuthTokenSourceShim: StoreTokenSource {
    private let auth: AuthViewModel

    init(auth: AuthViewModel) { self.auth = auth }

    func currentAccessTokenOrNil() -> String? {
        return MainActor.assumeIsolated {
            try? auth.tokens.currentAccessToken()
        }
    }

    func expiresAt() -> Date? {
        // TokenManager does not expose expiry directly; returning nil here
        // makes the runtime treat the token as "as fresh as the last load".
        // The runtime's 401 path covers rotation.
        return nil
    }
}

#endif
