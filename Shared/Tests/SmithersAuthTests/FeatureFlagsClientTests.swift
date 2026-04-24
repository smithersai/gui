import XCTest
@testable import SmithersAuth

@MainActor
final class FeatureFlagsClientTests: XCTestCase {
    func test_refresh_fetches_flags_with_bearer_and_decodes_envelope() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            .json(payload: [
                "flags": [
                    "remote_sandbox_enabled": false,
                    "approvals_flow_enabled": true,
                    "run_shape_enabled": true,
                ],
            ]),
        ]

        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" }
        )

        let snapshot = try await client.refresh(force: true)

        XCTAssertFalse(snapshot.isRemoteSandboxEnabled)
        XCTAssertTrue(snapshot.isApprovalsFlowEnabled)
        XCTAssertTrue(snapshot.isRunShapeEnabled)
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(transport.recorded[0].method, "GET")
        XCTAssertEqual(
            transport.recorded[0].url.absoluteString,
            "https://plue.test/api/feature-flags"
        )
    }

    func test_refresh_uses_ttl_cache_until_expired() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            .json(payload: ["flags": ["remote_sandbox_enabled": true]]),
            .json(payload: ["flags": ["remote_sandbox_enabled": false]]),
        ]
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            transport: transport,
            bearerProvider: { "FAKE_BEARER" },
            ttl: 60,
            now: { clock.now }
        )

        let first = try await client.refresh(force: true)
        let cached = try await client.refresh()
        clock.now.addTimeInterval(61)
        let refreshed = try await client.refresh()

        XCTAssertTrue(first.isRemoteSandboxEnabled)
        XCTAssertTrue(cached.isRemoteSandboxEnabled)
        XCTAssertFalse(refreshed.isRemoteSandboxEnabled)
        XCTAssertEqual(transport.recorded.count, 2)
    }

    func test_mock_response_provider_supports_flag_flip_on_next_refresh() async throws {
        let box = FeatureFlagBox(remoteEnabled: true)
        let client = FeatureFlagsClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { nil },
            mockResponseProvider: {
                FeatureFlagsSnapshot(flags: [
                    "remote_sandbox_enabled": box.remoteEnabled,
                    "approvals_flow_enabled": true,
                ])
            }
        )

        let enabled = try await client.refresh(force: true)
        box.remoteEnabled = false
        let disabled = try await client.refresh(force: true)

        XCTAssertTrue(enabled.isRemoteSandboxEnabled)
        XCTAssertFalse(disabled.isRemoteSandboxEnabled)
        XCTAssertFalse(client.isRemoteSandboxEnabled)
    }
}

private final class TestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class FeatureFlagBox: @unchecked Sendable {
    var remoteEnabled: Bool

    init(remoteEnabled: Bool) {
        self.remoteEnabled = remoteEnabled
    }
}
