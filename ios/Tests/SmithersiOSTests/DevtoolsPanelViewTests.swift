#if os(iOS)
import Foundation
import XCTest
import ViewInspector
@testable import SmithersiOS

extension DevtoolsPanelView: Inspectable {}

@MainActor
final class DevtoolsPanelViewTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testClientLoadsLatestSnapshots() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/devtools/snapshots/latest")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "session_id", value: "session-1")]
            )

            return try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "snapshots": [
                        [
                            "id": "snap-1",
                            "kind": "command_output",
                            "created_at": "2026-04-24T00:00:00Z",
                            "summary": "Command finished",
                            "payload": [
                                "stdout": "hello from devtools",
                            ],
                        ],
                    ],
                ]
            )
        }

        let snapshots = try await makeClient().fetchLatestSnapshots()

        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, "snap-1")
        XCTAssertEqual(snapshots.first?.accessibilityKind, "command_output")
        XCTAssertEqual(snapshots.first?.summary, "Command finished")
    }

    func testEmptyStateRendersAfterEmptyLoad() async throws {
        URLProtocolStub.handler = { request in
            try jsonResponse(for: request, statusCode: 200, jsonObject: ["snapshots": []])
        }

        let client = makeClient()
        let model = DevtoolsPanelViewModel(client: client)
        await model.reload()

        let view = DevtoolsPanelView(client: client, viewModel: model)

        XCTAssertTrue(model.snapshots.isEmpty)
        XCTAssertNoThrow(try view.inspect().find(text: "No snapshots"))
        XCTAssertNoThrow(try view.inspect().find(viewWithAccessibilityIdentifier: "devtools.panel.empty"))
    }

    func testClientAcceptsHyphenatedKindAndTimestamp() async throws {
        URLProtocolStub.handler = { request in
            try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "snapshots": [
                        [
                            "snapshot_id": "snap-2",
                            "kind": "tool-state",
                            "timestamp": "2026-04-24T00:00:00Z",
                            "payload": [
                                "phase": "exec",
                            ],
                        ],
                    ],
                ]
            )
        }

        let snapshots = try await makeClient().fetchLatestSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, "snap-2")
        XCTAssertEqual(snapshots.first?.accessibilityKind, "tool-state")
        XCTAssertEqual(snapshots.first?.createdAtText, "2026-04-24T00:00:00Z")
    }

    private func makeClient() -> DevtoolsSnapshotsClient {
        DevtoolsSnapshotsClient(
            baseURL: URL(string: "https://plue.test")!,
            repoOwner: "acme",
            repoName: "widgets",
            sessionID: "session-1",
            bearerProvider: { "test-token" },
            session: makeStubbedSession()
        )
    }
}
#endif
