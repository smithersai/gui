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
// `PLUE_BASE_URL`, seeds an in-memory `TokenStore`, and validates that
// bearer against plue before mounting the signed-in shell. The gate is
// strictly env-var-based: in a shipped build with no such env vars,
// every E2E branch is a no-op.

#if os(iOS)
import Foundation
import SwiftUI
import UIKit
import UserNotifications

enum SmithersPlueEndpoint {
    static let baseURLInfoKey = "SmithersPlueBaseURL"
    static let previewURLInfoKey = "SmithersPreviewURL"

    static func configuredBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> URL? {
        if let url = parsedURL(environment["PLUE_BASE_URL"]) {
            return url
        }
        if let url = parsedURL(environment["PLUE_PREVIEW_URL"]) {
            return url
        }
        if let url = parsedURL(bundle.object(forInfoDictionaryKey: baseURLInfoKey)) {
            return url
        }
        if let url = parsedURL(bundle.object(forInfoDictionaryKey: previewURLInfoKey)) {
            return url
        }
        if environment["PLUE_E2E_MODE"] == "1" {
            return URL(string: "http://localhost:4000")!
        }
        return nil
    }

    static func parsedURL(_ rawValue: Any?) -> URL? {
        guard let raw = rawValue as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            return nil
        }
        if components.path == "/api" {
            components.path = ""
        }
        return components.url
    }
}

@main
struct SmithersiOSApp: App {
    @UIApplicationDelegateAdaptor(SmithersiOSAppDelegate.self) private var appDelegate
    @StateObject private var authModel: AuthViewModel
    @StateObject private var featureFlags: FeatureFlagsClient
    // The E2E config is captured at `init` so every child view
    // (switcher, content shell) can see the overridden base URL + bearer
    // without having to re-parse env vars.
    private let e2e: E2EConfig?

    init() {
        DiagnosticsNetworkObserver.install()

        let parsedE2E = E2EEnvironment.parse()
        self.e2e = parsedE2E
        let model = Self.makeAuthModel(e2e: parsedE2E)
        let flags = FeatureFlagsClient(
            baseURL: model.client.config.baseURL,
            bearerProvider: {
                try? model.tokens.currentAccessToken()
            }
        )
        let tokenManager = model.tokens
        ApprovalNotificationHandler.shared.configure(
            baseURL: model.client.config.baseURL,
            bearerProvider: {
                try? tokenManager.currentAccessToken()
            }
        )
        _authModel = StateObject(wrappedValue: model)
        _featureFlags = StateObject(wrappedValue: flags)
    }

    var body: some Scene {
        WindowGroup {
            RootSurface(model: authModel, featureFlags: featureFlags, e2e: e2e)
                .onOpenURL { url in
                    DeepLinkRouter.shared.handle(url)
                }
        }
    }

    private static func makeAuthModel(e2e: E2EConfig?) -> AuthViewModel {
        // Base URL precedence:
        //   1. E2E (`PLUE_BASE_URL` via E2EEnvironment) when E2E mode is on
        //   2. Device/simulator preview URL from env or Info.plist
        //   3. `SMITHERS_PLUE_URL` dev override
        //   4. Debug default to local Plue
        //   5. Production default.
        let base: URL
        let environment = ProcessInfo.processInfo.environment
        if let e2e {
            base = e2e.baseURL
        } else if let preview = SmithersPlueEndpoint.configuredBaseURL(environment: environment) {
            base = preview
        } else if let dev = environment["SMITHERS_PLUE_URL"].flatMap(URL.init(string:)) {
            base = dev
        } else {
            #if DEBUG
            base = URL(string: "http://localhost:4000")!
            #else
            base = URL(string: "https://app.smithers.sh")!
            #endif
        }

        let config = OAuth2ClientConfig(
            baseURL: base,
            clientID: "smithers-ios",
            redirectURI: "smithers://oauth2/callback",
            scopes: ["read:user", "read:repo", "write:workspace", "write:approval", "write:agent"]
        )
        let client = OAuth2Client(config: config)

        // Token store: production uses the Keychain. E2E mode uses an
        // in-memory store pre-seeded with the test bearer so the app can
        // validate the bearer against plue without an
        // `ASWebAuthenticationSession` round trip.
        let store: TokenStore
        if let e2e {
            let initial = E2EEnvironment.syntheticTokens(from: e2e)
            store = InMemoryTokenStore(initial: initial)
        } else {
            store = KeychainTokenStore(service: "com.smithers.oauth2.ios", account: "default")
        }

        let manager = TokenManager(client: client, store: store)
        let startupSessionValidator: (() async -> AccessTokenValidationResult)?
        if e2e != nil {
            startupSessionValidator = {
                guard let accessToken = try? manager.currentAccessToken() else {
                    return .invalid
                }
                return await client.validateAccessToken(accessToken)
            }
        } else {
            startupSessionValidator = nil
        }
        let presenter = iOSWebAuthPresenter()
        let driver = WebAuthSessionDriver(presenter: presenter)
        return AuthViewModel(
            client: client,
            tokens: manager,
            driver: driver,
            callbackScheme: "smithers",
            startupSessionValidator: startupSessionValidator
        )
    }
}

private struct RootSurface: View {
    @ObservedObject var model: AuthViewModel
    @ObservedObject var featureFlags: FeatureFlagsClient
    let e2e: E2EConfig?
    @StateObject private var access: IOSRemoteAccessGateModel
    @StateObject private var onboarding: OnboardingCoordinator

    init(
        model: AuthViewModel,
        featureFlags: FeatureFlagsClient,
        e2e: E2EConfig?
    ) {
        self.model = model
        self.featureFlags = featureFlags
        self.e2e = e2e
        _access = StateObject(
            wrappedValue: IOSRemoteAccessGateModel(featureFlags: featureFlags)
        )
        _onboarding = StateObject(wrappedValue: OnboardingCoordinator())
    }

    var body: some View {
        Group {
            switch model.phase {
            case .signedIn:
                SignedInRemoteAccessSurface(
                    access: access,
                    featureFlags: featureFlags,
                    baseURL: model.client.config.baseURL,
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
                    },
                    replayTour: {
                        onboarding.replay()
                    }
                )
            case .restoringSession:
                StartupValidationView()
            default:
                NavigationStack {
                    SignInView(model: model)
                        .navigationTitle("Smithers")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .task {
            await model.resolveRestoredSessionIfNeeded()
        }
        .smithersOnboarding(coordinator: onboarding)
    }
}

private struct StartupValidationView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            ProgressView()
                .progressViewStyle(.circular)
            Text("Checking session…")
                .font(.headline)
            Text("Validating your bearer with Smithers.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityIdentifier("auth.restoring.root")
    }
}

final class SmithersiOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([ApprovalNotificationCategory.make()])
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            IOSPushNotificationRegistrar.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("Smithers APNS registration failed: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let payload = NotificationPayload.parse(
            response.notification.request.content.userInfo,
            actionIdentifier: response.actionIdentifier
        ) else {
            completionHandler()
            return
        }

        Task {
            await ApprovalNotificationHandler.shared.handle(payload)
            completionHandler()
        }
    }
}

@MainActor
final class IOSPushNotificationRegistrar {
    static let shared = IOSPushNotificationRegistrar()

    private var baseURL: URL?
    private var bearerProvider: (@Sendable () -> String?)?
    private var didAttemptRemoteRegistration = false
    private var pendingToken: String?

    private init() {}

    func configure(baseURL: URL, bearerProvider: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.bearerProvider = bearerProvider

        if let pendingToken {
            self.pendingToken = nil
            Task { await postDeviceToken(pendingToken) }
        }
    }

    func requestRegistrationOnFirstWorkspaceOpen() {
        guard !didAttemptRemoteRegistration else { return }
        didAttemptRemoteRegistration = true

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                    if granted {
                        await MainActor.run {
                            UIApplication.shared.registerForRemoteNotifications()
                        }
                    }
                } catch {
                    NSLog("Smithers notification permission failed: \(error.localizedDescription)")
                }
            case .authorized, .provisional, .ephemeral:
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await postDeviceToken(token) }
    }

    private func postDeviceToken(_ token: String) async {
        guard let baseURL,
              let bearer = bearerProvider?(),
              !bearer.isEmpty
        else {
            pendingToken = token
            return
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/user/devices"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONEncoder().encode(DeviceRegistration(apnsToken: token, platform: "ios"))
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                NSLog("Smithers APNS device registration failed: invalid HTTP response")
                return
            }
        } catch {
            NSLog("Smithers APNS device registration failed: \(error.localizedDescription)")
        }
    }

    private struct DeviceRegistration: Encodable {
        let apnsToken: String
        let platform: String

        enum CodingKeys: String, CodingKey {
            case apnsToken = "apns_token"
            case platform
        }
    }
}
#endif
