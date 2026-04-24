#if os(iOS)
import Foundation
import XCTest
import ViewInspector
@testable import SmithersiOS

extension ApprovalsInboxView: Inspectable {}

@MainActor
final class ApprovalsInboxViewTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testApprovePathRemovesResolvedRow() async throws {
        let session = makeStubbedSession()
        let recordedDecisions = LockedBox<[String]>([])

        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/user/workspaces":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "limit", value: "100"),
                ])
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "workspaces": [[
                            "workspace_id": "ws-1",
                            "repo_owner": "acme",
                            "repo_name": "widgets",
                            "name": "Widgets",
                            "state": "active",
                        ]],
                    ]
                )
            case "/api/repos/acme/widgets/approvals":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "state", value: "pending"),
                ])
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [[
                        "id": "approval-1",
                        "title": "Deploy production",
                        "description": "Ship it",
                        "status": "pending",
                    ]]
                )
            case "/api/repos/acme/widgets/approvals/approval-1/decide":
                XCTAssertEqual(request.httpMethod, "POST")
                recordedDecisions.withValue {
                    $0.append(Self.decisionValue(from: request))
                }
                return try jsonResponse(for: request, statusCode: 200, jsonObject: [:])
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let viewModel = makeViewModel(session: session)
        await viewModel.reload()
        XCTAssertEqual(viewModel.rows.map(\.id), ["approval-1"])

        let row = try XCTUnwrap(viewModel.rows.first)
        await viewModel.decide(row, decision: .approved)

        XCTAssertEqual(recordedDecisions.withValue { $0 }, ["approved"])
        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.inlineError(for: "approval-1"))
    }

    func testDenyPathRemovesResolvedRow() async throws {
        let session = makeStubbedSession()
        let recordedDecisions = LockedBox<[String]>([])

        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/user/workspaces":
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "workspaces": [[
                            "workspace_id": "ws-1",
                            "repo_owner": "acme",
                            "repo_name": "widgets",
                            "name": "Widgets",
                            "state": "active",
                        ]],
                    ]
                )
            case "/api/repos/acme/widgets/approvals":
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [[
                        "id": "approval-1",
                        "title": "Deploy production",
                        "status": "pending",
                    ]]
                )
            case "/api/repos/acme/widgets/approvals/approval-1/decide":
                recordedDecisions.withValue {
                    $0.append(Self.decisionValue(from: request))
                }
                return try jsonResponse(for: request, statusCode: 200, jsonObject: [:])
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let viewModel = makeViewModel(session: session)
        await viewModel.reload()

        let row = try XCTUnwrap(viewModel.rows.first)
        await viewModel.decide(row, decision: .rejected)

        XCTAssertEqual(recordedDecisions.withValue { $0 }, ["rejected"])
        XCTAssertTrue(viewModel.rows.isEmpty)
        XCTAssertNil(viewModel.inlineError(for: "approval-1"))
    }

    func testHttpFailureKeepsRowAndShowsInlineError() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/api/user/workspaces":
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        "workspaces": [[
                            "workspace_id": "ws-1",
                            "repo_owner": "acme",
                            "repo_name": "widgets",
                            "name": "Widgets",
                            "state": "active",
                        ]],
                    ]
                )
            case "/api/repos/acme/widgets/approvals":
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [[
                        "id": "approval-1",
                        "title": "Deploy production",
                        "status": "pending",
                    ]]
                )
            case "/api/repos/acme/widgets/approvals/approval-1/decide":
                return try jsonResponse(
                    for: request,
                    statusCode: 500,
                    jsonObject: ["message": "approval backend unavailable"]
                )
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let viewModel = makeViewModel(session: session)
        await viewModel.reload()

        let row = try XCTUnwrap(viewModel.rows.first)
        await viewModel.decide(row, decision: .approved)

        XCTAssertEqual(viewModel.rows.map(\.id), ["approval-1"])
        XCTAssertEqual(viewModel.inlineError(for: "approval-1"), "approval backend unavailable")
        XCTAssertFalse(viewModel.isWorking(on: "approval-1"))
    }

    func testEmptyStateRendersNoPendingApprovalsMessage() throws {
        let view = ApprovalsInboxView(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { "test-token" }
        )

        XCTAssertNoThrow(try view.inspect().find(text: "No pending approvals"))
    }

    private func makeViewModel(session: URLSession) -> ApprovalsInboxViewModel {
        ApprovalsInboxViewModel(
            client: URLSessionApprovalsInboxClient(
                baseURL: URL(string: "https://plue.test")!,
                bearerProvider: { "test-token" },
                session: session
            )
        )
    }

    private static func decisionValue(from request: URLRequest) -> String {
        guard
            let body = bodyData(from: request),
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let decision = object["decision"]
                as? String
        else {
            XCTFail("expected decision payload in approvals request body")
            return ""
        }
        return decision
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }

        return data.isEmpty ? nil : data
    }
}
#endif
