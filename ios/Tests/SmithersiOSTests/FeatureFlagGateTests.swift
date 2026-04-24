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
        let gate = IOSRemoteAccessGateModel(
            featureFlags: makeMockFlagsClient(box: box)
        )

        await gate.refreshNow(force: true)

        let view = SignedInRemoteAccessSurface(
            access: gate,
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
        let gate = IOSRemoteAccessGateModel(
            featureFlags: makeMockFlagsClient(box: box)
        )

        await gate.refreshNow(force: true)

        let view = SignedInRemoteAccessSurface(
            access: gate,
            baseURL: URL(string: "https://plue.test")!,
            e2e: nil,
            bearerProvider: { "FAKE_BEARER" },
            onSignOut: {}
        )

        XCTAssertNoThrow(try view.inspect().find(IOSContentShell.self))
    }

    func test_kill_switch_flip_takes_effect_on_next_refresh() async throws {
        let box = FeatureFlagBox(remoteEnabled: true)
        let gate = IOSRemoteAccessGateModel(
            featureFlags: makeMockFlagsClient(box: box)
        )

        await gate.refreshNow(force: true)
        XCTAssertEqual(gate.state, .enabled)

        box.remoteEnabled = false
        await gate.refreshNow(force: true)

        XCTAssertEqual(gate.state, .disabled)
    }

    private func makeMockFlagsClient(box: FeatureFlagBox) -> FeatureFlagsClient {
        FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { nil },
            mockResponseProvider: {
                FeatureFlagsSnapshot(flags: [
                    "remote_sandbox_enabled": box.remoteEnabled,
                    "approvals_flow_enabled": true,
                ])
            }
        )
    }
}

private final class FeatureFlagBox: @unchecked Sendable {
    var remoteEnabled: Bool

    init(remoteEnabled: Bool) {
        self.remoteEnabled = remoteEnabled
    }
}
#endif
