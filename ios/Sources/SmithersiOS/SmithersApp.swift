// SmithersApp.swift — iOS entry point (ticket 0121, expanded by 0109/0122).
//
// The app starts at the sign-in shell. Once the user completes OAuth2
// (0106 + 0109) the `IOSContentShell` takes over. The iOS shell hosts a
// `NavigationStack`-based composition that reuses the shared
// `NavigationStateStore` and `NavDestination` from
// `SharedNavigation.swift`. Tickets 0123/0124 expand the leaves it can
// render once TerminalView / libsmithers-core are iOS-portable.

#if os(iOS)
import SwiftUI

@main
struct SmithersiOSApp: App {
    @StateObject private var authModel: AuthViewModel

    init() {
        let model = Self.makeAuthModel()
        _authModel = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootSurface(model: authModel)
        }
    }

    private static func makeAuthModel() -> AuthViewModel {
        // Plue base URL lives in an env-driven config; default to the
        // production endpoint. `SMITHERS_PLUE_URL` overrides for dev.
        let base = ProcessInfo.processInfo.environment["SMITHERS_PLUE_URL"]
            .flatMap(URL.init(string:)) ?? URL(string: "https://app.smithers.sh")!
        let config = OAuth2ClientConfig(
            baseURL: base,
            clientID: "smithers-ios",
            redirectURI: "smithers://auth/callback"
        )
        let client = OAuth2Client(config: config)
        let store = KeychainTokenStore(service: "com.smithers.oauth2.ios", account: "default")
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

    var body: some View {
        switch model.phase {
        case .signedIn:
            IOSContentShell(onSignOut: {
                Task { await model.signOut() }
            })
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
