import XCTest
import ViewInspector
@testable import SmithersGUI
#if canImport(SmithersAuth)
import SmithersAuth
#endif
#if canImport(SmithersStore)
import SmithersStore
#endif

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

    // MARK: - Hybrid workspace tab lifecycle (0126)

    func test_openWorkspaceById_addsTabToOpenWorkspaceTabs() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [RemoteSandboxFlag.envVar: "1"],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel()
        )
        XCTAssertTrue(controller.openWorkspaceTabs.isEmpty)

        controller.openWorkspaceById(id: "ws-abc", name: "My Sandbox")

        XCTAssertEqual(controller.openWorkspaceTabs.count, 1)
        XCTAssertEqual(controller.openWorkspaceTabs.first?.id, "ws-abc")
        XCTAssertEqual(controller.openWorkspaceTabs.first?.name, "My Sandbox")
    }

    func test_openWorkspaceById_idempotent() {
        let defaults = isolatedDefaults()
        let controller = RemoteModeController(
            environment: [RemoteSandboxFlag.envVar: "1"],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel()
        )

        controller.openWorkspaceById(id: "ws-abc", name: "My Sandbox")
        controller.openWorkspaceById(id: "ws-abc", name: "My Sandbox")

        XCTAssertEqual(controller.openWorkspaceTabs.count, 1, "duplicate open should be ignored")
    }

    func test_closeRemoteWorkspace_removesTab() {
        let defaults = isolatedDefaults()
        let controller = RemoteModeController(
            environment: [RemoteSandboxFlag.envVar: "1"],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel()
        )
        controller.openWorkspaceById(id: "ws-abc", name: "Alpha")
        controller.openWorkspaceById(id: "ws-def", name: "Beta")
        XCTAssertEqual(controller.openWorkspaceTabs.count, 2)

        controller.closeRemoteWorkspace(id: "ws-abc")

        XCTAssertEqual(controller.openWorkspaceTabs.count, 1)
        XCTAssertEqual(controller.openWorkspaceTabs.first?.id, "ws-def")
    }

    func test_signOut_clears_openWorkspaceTabs_but_not_local_workspaces() async {
        let defaults = isolatedDefaults()
        let controller = RemoteModeController(
            environment: [RemoteSandboxFlag.envVar: "1"],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel()
        )
        controller.openWorkspaceById(id: "ws-abc", name: "Remote Box")
        XCTAssertEqual(controller.openWorkspaceTabs.count, 1)

        // Local WorkspaceManager is a separate singleton — sign-out must not touch it.
        let localManager = WorkspaceManager(
            userDefaults: defaults,
            launchArguments: [],
            environment: [:]
        )
        localManager.openWorkspace(at: URL(fileURLWithPath: NSTemporaryDirectory()))
        let localPathBefore = localManager.activeWorkspacePath

        await controller.signOut()

        XCTAssertTrue(controller.openWorkspaceTabs.isEmpty, "sign-out must wipe remote tabs")
        XCTAssertEqual(localManager.activeWorkspacePath, localPathBefore,
                       "sign-out must not affect local WorkspaceManager state")
    }

    func test_remoteShellRoute_toggle_and_signOut_reset() async {
        let defaults = isolatedDefaults()
        let controller = RemoteModeController(
            environment: [RemoteSandboxFlag.envVar: "1"],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: true),
            authModel: makeSignedOutAuthModel()
        )

        XCTAssertFalse(controller.shouldPresentRemoteShell)

        controller.presentRemoteShell()
        XCTAssertTrue(controller.shouldPresentRemoteShell, "presentRemoteShell should request shell routing")

        controller.dismissRemoteShell()
        XCTAssertFalse(controller.shouldPresentRemoteShell, "dismissRemoteShell should clear shell routing")

        controller.presentRemoteShell()
        await controller.signOut()
        XCTAssertFalse(controller.shouldPresentRemoteShell, "sign-out should clear remote shell routing")
    }

    func test_remote_flag_off_hides_open_button_in_workspaces_view() throws {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: RemoteSandboxFlag.key)

        let controller = RemoteModeController(
            environment: [:],
            defaults: defaults,
            e2eConfig: nil,
            featureFlags: makeMockFlagsClient(remoteEnabled: false),
            authModel: makeSignedOutAuthModel()
        )

        // With flag off, isSignedIn is false and isRemoteFeatureEnabled is false.
        // The "Open" button in WorkspacesView is gated on remoteMode.isSignedIn.
        XCTAssertFalse(controller.isRemoteFeatureEnabled)
        XCTAssertFalse(controller.isSignedIn)
    }

    func test_welcome_browse_button_is_not_blocked_by_snapshot_phase() throws {
        let source = try sourceFile("WelcomeView.swift")
        XCTAssertTrue(
            source.contains("welcome.remote.browse"),
            "WelcomeView should expose the remote browse entry"
        )
        XCTAssertFalse(
            source.contains(".disabled(!remoteMode.phase.allowsRemoteSurface)"),
            "Welcome browse entry should stay tappable so WorkspacesView can show blocked/slow-boot states"
        )
    }

    func test_root_remote_shell_route_not_gated_by_allowsRemoteSurface() throws {
        let source = try sourceFile("macos/Sources/Smithers/Smithers.AppDelegate.swift")
        XCTAssertFalse(
            source.contains("remoteMode.phase.allowsRemoteSurface"),
            "SmithersRootView should allow entering the remote shell before the first snapshot is ready"
        )
    }

    func test_remoteMode_applies_initial_workspace_snapshot_immediately() throws {
        let source = try sourceFile("macos/Sources/Smithers/Smithers.RemoteMode.swift")
        XCTAssertTrue(
            source.contains("applyWorkspacesSnapshot(lifecycle.store.workspaces)"),
            "RemoteModeController should hydrate the initial workspace snapshot immediately after wiring observers"
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "FeatureFlagsGatingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
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
