#if os(iOS)
import XCTest
import ViewInspector
@testable import SmithersiOS

extension SignedInRemoteAccessSurface: Inspectable {}
extension IOSContentShell: Inspectable {}

@MainActor
final class IOSFeatureFlagGateTests: XCTestCase {
    func test_signed_in_surface_renders_disabled_message_when_remote_flag_is_off() async throws {
        let box = FeatureFlagBox(remoteEnabled: false)
        let featureFlags = makeMockFlagsClient(box: box)
        let gate = IOSRemoteAccessGateModel(
            featureFlags: featureFlags
        )

        await gate.refreshNow(force: true)

        let view = SignedInRemoteAccessSurface(
            access: gate,
            featureFlags: featureFlags,
            baseURL: URL(string: "https://plue.test")!,
            e2e: nil,
            bearerProvider: { nil },
            onSignOut: {}
        )

        XCTAssertNoThrow(
            try view.inspect().find(text: "Remote sandboxes aren't enabled for your account. Contact support.")
        )
    }

    func test_signed_in_surface_mounts_content_shell_when_remote_flag_is_on() async throws {
        let box = FeatureFlagBox(remoteEnabled: true)
        let featureFlags = makeMockFlagsClient(box: box)
        let gate = IOSRemoteAccessGateModel(
            featureFlags: featureFlags
        )

        await gate.refreshNow(force: true)

        let view = SignedInRemoteAccessSurface(
            access: gate,
            featureFlags: featureFlags,
            baseURL: URL(string: "https://plue.test")!,
            e2e: nil,
            bearerProvider: { "FAKE_BEARER" },
            onSignOut: {}
        )

        XCTAssertNoThrow(try view.inspect().find(IOSContentShell.self))
    }

    func test_kill_switch_flip_takes_effect_on_next_refresh() async throws {
        let box = FeatureFlagBox(remoteEnabled: true)
        let featureFlags = makeMockFlagsClient(box: box)
        let gate = IOSRemoteAccessGateModel(
            featureFlags: featureFlags
        )

        await gate.refreshNow(force: true)
        XCTAssertEqual(gate.state, .enabled)

        box.remoteEnabled = false
        await gate.refreshNow(force: true)

        XCTAssertEqual(gate.state, .disabled)
    }

    func test_effective_remote_flag_prefers_environment_override() async throws {
        let box = FeatureFlagBox(remoteEnabled: true)
        let client = makeMockFlagsClient(box: box)

        _ = try await client.refresh(force: true)

        XCTAssertFalse(
            client.effectiveRemoteSandboxEnabled(
                environment: ["PLUE_REMOTE_SANDBOX_ENABLED": "0"]
            )
        )
        XCTAssertTrue(
            client.effectiveRemoteSandboxEnabled(
                environment: ["PLUE_REMOTE_SANDBOX_ENABLED": "1"]
            )
        )
    }

    func test_workspace_detail_gate_shows_kill_switch_empty_state_when_seeded_terminal_disabled() {
        let gate = IOSWorkspaceDetailSurfaceGate(
            seededSessionID: "seeded-session",
            isRemoteSandboxEnabled: false,
            isElectricClientEnabled: true,
            isApprovalsFlowEnabled: true
        )

        XCTAssertEqual(gate.terminalSurfaceState, .killSwitchDisabled)
        XCTAssertTrue(gate.showsAgentChatSurface)
    }

    func test_workspace_detail_gate_hides_agent_chat_when_electric_client_disabled() {
        let gate = IOSWorkspaceDetailSurfaceGate(
            seededSessionID: nil,
            isRemoteSandboxEnabled: true,
            isElectricClientEnabled: false,
            isApprovalsFlowEnabled: true
        )

        XCTAssertEqual(gate.terminalSurfaceState, .hidden)
        XCTAssertFalse(gate.showsAgentChatSurface)
    }

    func test_workspace_detail_gate_hides_agent_chat_when_approvals_flow_disabled() {
        let gate = IOSWorkspaceDetailSurfaceGate(
            seededSessionID: nil,
            isRemoteSandboxEnabled: true,
            isElectricClientEnabled: true,
            isApprovalsFlowEnabled: false
        )

        XCTAssertFalse(gate.showsAgentChatSurface)
    }

    private func makeMockFlagsClient(box: FeatureFlagBox) -> FeatureFlagsClient {
        FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { nil },
            mockResponseProvider: {
                FeatureFlagsSnapshot(flags: [
                    "remote_sandbox_enabled": box.remoteEnabled,
                    "electric_client_enabled": box.electricEnabled,
                    "approvals_flow_enabled": box.approvalsEnabled,
                ])
            }
        )
    }
}

private final class FeatureFlagBox: @unchecked Sendable {
    var remoteEnabled: Bool
    var electricEnabled: Bool
    var approvalsEnabled: Bool

    init(
        remoteEnabled: Bool,
        electricEnabled: Bool = true,
        approvalsEnabled: Bool = true
    ) {
        self.remoteEnabled = remoteEnabled
        self.electricEnabled = electricEnabled
        self.approvalsEnabled = approvalsEnabled
    }
}
#endif
