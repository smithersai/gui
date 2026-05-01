#if os(iOS)
import Foundation
import XCTest
@testable import SmithersiOS

final class DiagnosticsBundleTests: XCTestCase {
    func testGenerateProducesWellFormedJSONWithExpectedKeys() async throws {
        let recorder = DiagnosticsNetworkRecorder()
        await recorder.record(
            url: URL(string: "https://plue.test/api/workspaces?access_token=secret&workspace_id=abc")!,
            statusCode: 201,
            duration: 0.124,
            startedAt: Date(timeIntervalSince1970: 1)
        )

        let diagnostics = DiagnosticsBundle(
            logLineLimit: 5,
            featureFlagsProvider: {
                [
                    "approvals_flow_enabled": true,
                    "remote_sandbox_enabled": false,
                ]
            },
            logLinesProvider: { _ in
                ["2026-04-24T12:00:00Z INFO SmithersiOS Test log line"]
            },
            networkRecorder: recorder,
            bundle: Bundle(for: Self.self),
            now: { Date(timeIntervalSince1970: 1_777_000_000) },
            deviceInfoProvider: {
                DiagnosticsDeviceInfo(
                    system_name: "iOS",
                    system_version: "17.0",
                    model: "iPhone",
                    localized_model: "iPhone",
                    user_interface_idiom: "phone",
                    is_simulator: true,
                    low_power_mode_enabled: false,
                    thermal_state: "nominal"
                )
            }
        )

        let url = try await diagnostics.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertTrue(
            Set(["schema_version", "generated_at", "app", "device", "feature_flags", "logs", "network_requests"])
                .isSubset(of: Set(object.keys))
        )
        XCTAssertNotNil(object["app"] as? [String: Any])
        XCTAssertNotNil(object["device"] as? [String: Any])
        XCTAssertEqual((object["logs"] as? [String])?.count, 1)

        let flags = try XCTUnwrap(object["feature_flags"] as? [String: Bool])
        XCTAssertEqual(flags["approvals_flow_enabled"], true)
        XCTAssertEqual(flags["remote_sandbox_enabled"], false)

        let requests = try XCTUnwrap(object["network_requests"] as? [[String: Any]])
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request["status"] as? Int, 201)
        XCTAssertEqual(request["duration_ms"] as? Int, 124)
        XCTAssertEqual(
            request["url"] as? String,
            "https://plue.test/api/workspaces?access_token=REDACTED&workspace_id=abc"
        )
        XCTAssertNil(String(data: data, encoding: .utf8)?.range(of: "secret"))
    }
}
#endif
