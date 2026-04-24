#if os(iOS)
import Foundation
import XCTest
@testable import SmithersiOS

@MainActor
final class WorkspaceDetailActionsTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSuspendUpdatesWorkspaceStateAndRefreshesSwitcher() async throws {
        let session = makeStubbedSession()
        let refreshCount = LockedBox(0)

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/workspaces/ws-1/suspend")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return try jsonResponse(
                for: request,
                statusCode: 200,
                jsonObject: [
                    "id": "ws-1",
                    "name": "Workspace Alpha",
                    "status": "suspended",
                ]
            )
        }

        let model = makeModel(session: session) {
            refreshCount.withValue { $0 += 1 }
        }

        await model.perform(.suspend)

        XCTAssertEqual(model.workspace.state, "suspended")
        XCTAssertTrue(model.showsResumeAction)
        XCTAssertEqual(refreshCount.withValue { $0 }, 1)
        XCTAssertEqual(
            model.banner,
            WorkspaceDetailBanner(
                message: "Workspace suspended.",
                style: .success,
                autoDismiss: true
            )
        )
    }

    func testForkUsesTitleRequestBody() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/workspaces/ws-1/fork")

            let body = try self.requestBodyData(from: request)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: String]
            )
            XCTAssertEqual(object["title"], "Workspace Alpha (fork)")
            XCTAssertNil(object["name"])

            return try jsonResponse(
                for: request,
                statusCode: 201,
                jsonObject: [
                    "id": "ws-2",
                    "name": "Workspace Alpha (fork)",
                    "status": "running",
                ]
            )
        }

        let client = URLSessionWorkspaceDetailMutationClient(
            baseURL: URL(string: "https://plue.test")!,
            bearerProvider: { "test-token" },
            session: session
        )

        let response = try await client.perform(.fork, workspace: makeWorkspace())

        XCTAssertNil(response.workspace)
        XCTAssertEqual(response.createdWorkspaceID, "ws-2")
    }

    func testRateLimitParsesRetryAfterIntoWarningBanner() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/workspaces/ws-1/fork")
            return try self.response(
                for: request,
                statusCode: 429,
                headers: [
                    "Content-Type": "application/json",
                    "Retry-After": "12",
                ],
                body: try JSONSerialization.data(
                    withJSONObject: ["message": "workspace quota exceeded"],
                    options: []
                )
            )
        }

        let model = makeModel(session: session)

        await model.perform(.fork)

        XCTAssertEqual(
            model.banner,
            WorkspaceDetailBanner(
                message: "workspace quota exceeded. Try again in 12s.",
                style: .warning,
                autoDismiss: false
            )
        )
    }

    func testContentShellDefinesWorkspaceDetailActionAccessibilityIdentifiers() throws {
        let source = try String(contentsOf: Self.contentShellSourceURL(), encoding: .utf8)

        XCTAssertTrue(source.contains(#".accessibilityIdentifier("workspace-detail.actions.menu")"#))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("workspace-detail.actions.suspend")"#))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("workspace-detail.actions.resume")"#))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("workspace-detail.actions.fork")"#))
    }

    private func makeModel(
        session: URLSession,
        onRefreshSwitcher: @escaping @MainActor () async -> Void = {}
    ) -> WorkspaceDetailActionModel {
        WorkspaceDetailActionModel(
            workspace: makeWorkspace(),
            client: URLSessionWorkspaceDetailMutationClient(
                baseURL: URL(string: "https://plue.test")!,
                bearerProvider: { "test-token" },
                session: session
            ),
            onRefreshSwitcher: onRefreshSwitcher
        )
    }

    private func makeWorkspace(state: String = "running") -> SwitcherWorkspace {
        SwitcherWorkspace(
            id: "ws-1",
            repoOwner: "acme",
            repoName: "widgets",
            title: "Workspace Alpha",
            state: state,
            lastAccessedAt: nil,
            lastActivityAt: nil,
            createdAt: nil,
            source: .remote
        )
    }

    private func response(
        for request: URLRequest,
        statusCode: Int,
        headers: [String: String],
        body: Data
    ) throws -> (HTTPURLResponse, Data) {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: request.url ?? URL(string: "https://plue.test")!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headers
            )
        )
        return (response, body)
    }

    private static func contentShellSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/Sources/SmithersiOS/ContentShell.iOS.swift")
    }

    private func requestBodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }

        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead < 0 {
                throw stream.streamError ?? WorkspaceDetailMutationError.invalidResponse
            }
            if bytesRead == 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return data
    }
}
#endif
