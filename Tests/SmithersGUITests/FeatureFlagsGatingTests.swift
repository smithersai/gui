import XCTest
import ViewInspector
@testable import SmithersGUI

extension SidebarView: @retroactive Inspectable {}

@MainActor
final class FeatureFlagsGatingTests: XCTestCase {
    func test_server_flag_false_disables_remote_even_with_persisted_user_default() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [:],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: false),
            authModel: makeSignedOutAuthModel(),
            featureFlagRefreshInterval: 600
        )

        await controller.refreshFeatureFlagsNow()

        XCTAssertFalse(controller.isRemoteFeatureEnabled)
        XCTAssertEqual(controller.phase, .disabled)
    }

    func test_server_flag_true_reenables_remote_surface() async throws {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [:],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel(),
            featureFlagRefreshInterval: 600
        )

        await controller.refreshFeatureFlagsNow()

        XCTAssertTrue(controller.isRemoteFeatureEnabled)
        XCTAssertEqual(controller.phase, .signedOut)
    }

    func test_sidebar_hides_remote_section_when_server_flag_is_off() async throws {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [:],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: false),
            authModel: makeSignedOutAuthModel(),
            featureFlagRefreshInterval: 600
        )
        await controller.refreshFeatureFlagsNow()

        let view = SidebarView(
            store: SessionStore(workingDirectory: NSTemporaryDirectory(), userDefaults: defaults),
            destination: .constant(.dashboard),
            remoteMode: controller
        )

        XCTAssertThrowsError(try view.inspect().find(text: "REMOTE"))
    }

    func test_sidebar_shows_remote_section_when_server_flag_is_on() async throws {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [:],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel(),
            featureFlagRefreshInterval: 600
        )
        await controller.refreshFeatureFlagsNow()

        let view = SidebarView(
            store: SessionStore(workingDirectory: NSTemporaryDirectory(), userDefaults: defaults),
            destination: .constant(.dashboard),
            remoteMode: controller
        )

        XCTAssertNoThrow(try view.inspect().find(text: "REMOTE"))
    }

    private func makeMockFlagsClient(remoteEnabled: Bool) -> FeatureFlagsClient {
        FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { nil },
            mockResponseProvider: {
                FeatureFlagsSnapshot(flags: [
                    "remote_sandbox_enabled": remoteEnabled,
                    "approvals_flow_enabled": true,
                ])
            }
        )
    }

    private func makeSignedOutAuthModel() -> AuthViewModel {
        let client = OAuth2Client(
            config: OAuth2ClientConfig(
                baseURL: URL(string: "https://plue.test")!,
                clientID: "test-client",
                redirectURI: "smithers://callback"
            ),
            transport: URLSessionHTTPTransport()
        )
        let manager = TokenManager(client: client, store: InMemoryTokenStore())
        return AuthViewModel(
            client: client,
            tokens: manager,
            driver: NoopAuthorizeSessionDriver(),
            callbackScheme: "smithers"
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "FeatureFlagsGatingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class NoopAuthorizeSessionDriver: AuthorizeSessionDriver {
    func start(
        authorizeURL: URL,
        callbackScheme: String,
        expectedState: String
    ) async throws -> AuthorizeCallback {
        _ = authorizeURL
        _ = callbackScheme
        _ = expectedState
        throw AuthorizeSessionError.userCancelled
    }
}
