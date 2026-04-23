// SmithersApp.swift — iOS entry point (ticket 0121, expanded by 0109/0122).
//
// The app starts at the sign-in shell. Once the user completes OAuth2
// (0106 + 0109) the `IOSContentShell` takes over. The iOS shell hosts a
// `NavigationStack`-based composition that reuses the shared
// `NavigationStateStore` and `NavDestination` from
// `SharedNavigation.swift`. Tickets 0123/0124 expand the leaves it can
// render once TerminalView / libsmithers-core are iOS-portable.
//
// Ticket ios-e2e-harness: when `PLUE_E2E_MODE=1` is set in the process
// launch environment, the app reads `SMITHERS_E2E_BEARER` +
// `PLUE_BASE_URL` and installs a synthetic session into an in-memory
// `TokenStore` so XCUITest can drive the real app end-to-end without
// `ASWebAuthenticationSession`. The gate is strictly env-var-based: in a
// shipped build with no such env vars, every E2E branch is a no-op.

#if os(iOS)
import SwiftUI

@main
struct SmithersiOSApp: App {
    @StateObject private var authModel: AuthViewModel
    // The E2E config is captured at `init` so every child view
    // (switcher, content shell) can see the overridden base URL + bearer
    // without having to re-parse env vars.
    private let e2e: E2EConfig?

    init() {
        let parsedE2E = E2EEnvironment.parse()
        self.e2e = parsedE2E
        let model = Self.makeAuthModel(e2e: parsedE2E)
        _authModel = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootSurface(model: authModel, e2e: e2e)
        }
    }

    private static func makeAuthModel(e2e: E2EConfig?) -> AuthViewModel {
        // Base URL precedence:
        //   1. E2E (`PLUE_BASE_URL` via E2EEnvironment) when E2E mode is on
        //   2. `SMITHERS_PLUE_URL` dev override
        //   3. Production default.
        let base: URL
        if let e2e {
            base = e2e.baseURL
        } else if let dev = ProcessInfo.processInfo.environment["SMITHERS_PLUE_URL"].flatMap(URL.init(string:)) {
            base = dev
        } else {
            base = URL(string: "https://app.smithers.sh")!
        }

        let config = OAuth2ClientConfig(
            baseURL: base,
            clientID: "smithers-ios",
            redirectURI: "smithers://auth/callback"
        )
        let client = OAuth2Client(config: config)

        // Token store: production uses the Keychain. E2E mode uses an
        // in-memory store pre-seeded with the test bearer so
        // `TokenManager.hasSession` is true from init → `AuthViewModel.phase`
        // resolves to `.signedIn` without a sign-in round trip.
        let store: TokenStore
        if let e2e {
            let initial = E2EEnvironment.syntheticTokens(from: e2e)
            store = InMemoryTokenStore(initial: initial)
        } else {
            store = KeychainTokenStore(service: "com.smithers.oauth2.ios", account: "default")
        }

        let manager = TokenManager(client: client, store: store)
        let presenter = iOSWebAuthPresenter()
        let driver = WebAuthSessionDriver(presenter: presenter)
        return AuthViewModel(
            client: client,
            tokens: manager,
            driver: driver,
            callbackScheme: "smithers"
        )
    }
}

private struct RootSurface: View {
    @ObservedObject var model: AuthViewModel
    let e2e: E2EConfig?

    var body: some View {
        switch model.phase {
        case .signedIn:
            IOSContentShell(
                e2e: e2e,
                bearerProvider: { [weak model] in
                    // Safe to read on any thread — TokenManager internals
                    // serialize on an NSLock. On failure (signed-out)
                    // URLSessionRemoteWorkspaceFetcher throws authExpired
                    // which the view-model turns into the `.signedOut`
                    // state.
                    try? model?.tokens.currentAccessToken()
                },
                onSignOut: {
                    Task { await model.signOut() }
                }
            )
        default:
            NavigationStack {
                SignInView(model: model)
                    .navigationTitle("Smithers")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
#endif
