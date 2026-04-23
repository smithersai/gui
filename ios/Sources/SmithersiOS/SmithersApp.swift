// SmithersApp.swift — iOS entry point (ticket 0121, expanded by 0109).
//
// The app starts at the sign-in shell. Once the user completes OAuth2
// (0106 + 0109) the placeholder post-signin surface is shown. Tickets
// 0122/0123 replace that placeholder with the shared ContentView.

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
            NavigationStack {
                RootSurface(model: authModel)
            }
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
            PlaceholderSignedInView(model: model)
        default:
            SignInView(model: model)
                .navigationTitle("Smithers")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Temporary post-signin landing. 0122 replaces this with the shared
/// ContentView.
private struct PlaceholderSignedInView: View {
    @ObservedObject var model: AuthViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Smithers")
                .font(.largeTitle.bold())
            Text("Signed in. Main UI lands in 0122/0123.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Sign out") {
                Task { await model.signOut() }
            }
            .buttonStyle(.bordered)
        }
        .navigationTitle("Smithers")
    }
}
#endif
