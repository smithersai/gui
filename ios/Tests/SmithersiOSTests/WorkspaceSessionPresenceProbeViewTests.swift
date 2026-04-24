#if os(iOS)
import Foundation
import XCTest
@testable import SmithersiOS

@MainActor
final class WorkspaceSessionPresenceProbeViewTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPresentSessionProbeMapsToMountedTerminalSurface() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/repos/acme/widgets/workspace/sessions/sess-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return try textResponse(for: request, statusCode: 200, body: "")
        }

        let result = try await makeProbe().fetch(
            repoOwner: "acme",
            repoName: "widgets",
            sessionID: "sess-123"
        )

        XCTAssertEqual(result, .present)
        let source = try contentShellSource()
        XCTAssertTrue(source.contains("case .present:"))
        XCTAssertTrue(source.contains("terminalMountState = .mounted(sessionID: sessionID)"))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("content.ios.workspace-detail.terminal")"#))
    }

    func testMissingSessionProbeMapsToTerminalEmptyState() async throws {
        URLProtocolStub.handler = { request in
            try textResponse(for: request, statusCode: 404, body: "")
        }

        let result = try await makeProbe().fetch(
            repoOwner: "acme",
            repoName: "widgets",
            sessionID: "sess-123"
        )

        XCTAssertEqual(result, .missing)
        let source = try contentShellSource()
        XCTAssertTrue(source.contains("case .missing:"))
        XCTAssertTrue(source.contains("terminalMountState = .missing(sessionID: sessionID)"))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("content.ios.workspace-detail.terminal-empty")"#))
        XCTAssertTrue(source.contains("Terminal session not found"))
    }

    func testUnauthorizedSessionProbeMapsToAuthRetryError() async throws {
        URLProtocolStub.handler = { request in
            try textResponse(for: request, statusCode: 401, body: "")
        }

        do {
            _ = try await makeProbe().fetch(
                repoOwner: "acme",
                repoName: "widgets",
                sessionID: "sess-123"
            )
            XCTFail("Expected authExpired")
        } catch RemoteWorkspaceSessionPresenceError.authExpired {
        } catch {
            XCTFail("Expected authExpired, got \(error)")
        }

        let source = try contentShellSource()
        XCTAssertTrue(source.contains("catch RemoteWorkspaceSessionPresenceError.authExpired"))
        XCTAssertTrue(source.contains("Workspace session lookup requires an active signed-in session."))
        XCTAssertTrue(source.contains(#"retryIdentifier: "content.ios.workspace-detail.terminal.error.retry""#))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("content.ios.workspace-detail.terminal.error")"#))
    }

    private func makeProbe() -> URLSessionRemoteWorkspaceSessionPresenceProbe {
        URLSessionRemoteWorkspaceSessionPresenceProbe(
            baseURL: URL(string: "https://plue.test")!,
            bearer: { "test-token" },
            session: makeStubbedSession()
        )
    }

    private func contentShellSource() throws -> String {
        try String(contentsOf: Self.contentShellSourceURL(), encoding: .utf8)
    }

    private static func contentShellSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("SmithersiOS")
            .appendingPathComponent("ContentShell.iOS.swift")
    }
}
#endif
