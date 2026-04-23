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

// MARK: - Feature flag plumbing

/// Reads the `remote_sandbox_enabled` feature flag (0112).
///
/// v1 strategy (per ticket 0126 pragmatic note):
///   1. If `PLUE_REMOTE_SANDBOX_ENABLED` env var is set to "1"/"true"/"yes",
///      the flag is enabled for this process.
///   2. Otherwise read `UserDefaults["remote_sandbox_enabled"]` — allows
///      local testing + a future plue `/api/feature-flags` bridge to write
///      cached values here after sign-in.
///   3. Off by default. With flag off, the macOS app preserves its existing
///      local-only behaviour verbatim (no sign-in UI, no remote sections).
///
/// TODO(runtime): once `smithers_core_feature_flag(const char* key)` FFI
/// lands, resolve the flag via the runtime so plue-driven cohorts apply
/// without a process restart. For now the UserDefaults cache is written by
/// the sign-in code path once plue replies with flags.
enum RemoteSandboxFlag {
    static let key = "remote_sandbox_enabled"
    static let envVar = "PLUE_REMOTE_SANDBOX_ENABLED"

    static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> Bool {
        if let raw = environment[envVar]?.lowercased(),
           ["1", "true", "yes", "on"].contains(raw) {
            return true
        }
        return defaults.bool(forKey: key)
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

    // Auth plumbing.
    let authModel: AuthViewModel

    // Lifecycle (nil until sign-in completes). The session is owned here so
    // it survives as long as the user is signed in.
    private(set) var lifecycle: SmithersSessionLifecycle?
    private var snapshotObserver: NSObjectProtocol?
    private var reconnectObserver: NSObjectProtocol?
    private var authExpiredObserver: NSObjectProtocol?
    private var workspacesObservation: Task<Void, Never>?
    private var slowBootTimer: Task<Void, Never>?
    private let remoteEnabled: Bool

    private init() {
        self.remoteEnabled = RemoteSandboxFlag.isEnabled()

        // Build the auth stack. This is cheap (no network, no keychain write).
        let tokenStore = KeychainTokenStore()
        let transport = URLSessionHTTPTransport()
        let clientConfig = OAuth2ClientConfig(
            baseURL: URL(string: "https://jjhub.smithers.ai")!,
            clientID: "smithers-macos",
            redirectURI: "http://127.0.0.1:0/callback",
            scopes: ["read", "write"],
            audience: "smithers-api"
        )
        let oauthClient = OAuth2Client(config: clientConfig, transport: transport)
        let tokenManager = TokenManager(client: oauthClient, store: tokenStore)

        let presenter = MacOSWebAuthPresenter()
        let driver = WebAuthSessionDriver(presenter: presenter)
        self.authModel = AuthViewModel(
            client: oauthClient,
            tokens: tokenManager,
            driver: driver,
            callbackScheme: "smithers"
        )

        if !remoteEnabled {
            self.phase = .disabled
            return
        }
        // Seed phase from Keychain. If a session already exists we restore
        // into `.bootBlocked` until the first snapshot lands; otherwise
        // we're signed out.
        self.phase = authModel.phase == .signedIn ? .bootBlocked(since: Date()) : .signedOut

        // Observe auth model phase transitions.
        wireAuthObservation()
        if authModel.phase == .signedIn {
            Task { await bootstrapLifecycle() }
        }
    }

    deinit {
        if let o = snapshotObserver { NotificationCenter.default.removeObserver(o) }
        if let o = reconnectObserver { NotificationCenter.default.removeObserver(o) }
        if let o = authExpiredObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Public surface

    var isRemoteFeatureEnabled: Bool { remoteEnabled }

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
        guard remoteEnabled else { return }
        phase = .signingIn
        await authModel.signIn()
        // Phase gets finalized by `wireAuthObservation()`.
    }

    /// Wipe remote credentials + shape cache + open remote tabs. Local tabs
    /// (`WorkspaceManager`) are untouched.
    func signOut() async {
        // Close remote tabs first so any in-flight shape deltas don't try
        // to repaint a dying session.
        openWorkspaceTabs.removeAll()
        remoteWorkspaces.removeAll()

        // Order: drop session → wipe cache → revoke tokens.
        lifecycle?.wipeForSignOut()
        lifecycle = nil

        await authModel.signOut()
        phase = .signedOut
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

    // MARK: Bootstrap

    private func wireAuthObservation() {
        // Subscribe to phase changes on the AuthViewModel. SwiftUI already
        // re-renders; we just need to react to signIn completions.
        // Poll on objectWillChange so we don't need to own a Combine sink.
        Task { [weak self] in
            guard let self else { return }
            for await _ in self.authModel.objectWillChange.values {
                await self.handleAuthChanged()
            }
        }
    }

    private func handleAuthChanged() async {
        guard remoteEnabled else { return }
        switch authModel.phase {
        case .signedIn:
            if lifecycle == nil {
                await bootstrapLifecycle()
            }
        case .signedOut:
            if lifecycle != nil {
                lifecycle?.wipeForSignOut()
                lifecycle = nil
                openWorkspaceTabs.removeAll()
                remoteWorkspaces.removeAll()
            }
            phase = .signedOut
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
                baseURL: "https://jjhub.smithers.ai",
                shapeProxyURL: "https://jjhub.smithers.ai/shapes",
                wsPtyURL: "wss://jjhub.smithers.ai/pty",
                cacheDir: RemoteModeController.cacheDirectory(),
                cacheMaxMB: 512
            )
            let lc = try SmithersSessionLifecycle.bootstrap(
                tokenSource: tokenSource,
                engineConfig: config
            )
            self.lifecycle = lc
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

    private func wireStoreObservation(lifecycle: SmithersSessionLifecycle) {
        // First-snapshot → `.active`. We treat "workspaces has any row OR
        // lastRefreshedAt set" as the first snapshot; the 0124 store sets
        // `lastRefreshedAt` on every reloadFromCache (including empty result
        // sets), which fires once the initial shape sync completes.
        workspacesObservation?.cancel()
        workspacesObservation = Task { [weak self, weak lifecycle] in
            guard let self, let lifecycle else { return }
            for await _ in lifecycle.store.workspaces.objectWillChange.values {
                await MainActor.run {
                    self.remoteWorkspaces = lifecycle.store.workspaces.workspaces
                    if lifecycle.store.workspaces.lastRefreshedAt != nil {
                        self.phase = .active
                        self.cancelSlowBootTimer()
                    }
                }
            }
        }

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

    // MARK: Helpers

    private static func cacheDirectory() -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("SmithersRemoteCache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
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
        return try? auth.tokens.currentAccessToken()
    }

    func expiresAt() -> Date? {
        // TokenManager does not expose expiry directly; returning nil here
        // makes the runtime treat the token as "as fresh as the last load".
        // The runtime's 401 path covers rotation.
        return nil
    }
}

#endif
