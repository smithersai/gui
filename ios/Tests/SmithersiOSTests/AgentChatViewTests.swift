#if os(iOS)
import Foundation
import XCTest
import ViewInspector
@testable import SmithersiOS

extension AgentChatView: Inspectable {}

@MainActor
final class AgentChatViewTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testSendAppendsUserMessageToTranscript() async throws {
        let session = makeStubbedSession()
        let createdAt = Date()

        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/repos/acme/widgets/agent/sessions/sess-1/messages"):
                return try jsonResponse(for: request, statusCode: 200, jsonObject: [:])
            case ("GET", "/api/repos/acme/widgets/agent/sessions/sess-1/messages"):
                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: [
                        Self.messagePayload(
                            id: "msg-user-1",
                            role: "user",
                            text: "hello from iOS",
                            createdAt: createdAt
                        ),
                    ]
                )
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let model = makeModel(session: session)
        model.draft = "  hello from iOS  "
        model.send()

        XCTAssertTrue(
            model.messages.contains(where: { $0.role == "user" && $0.text == "hello from iOS" }),
            "send() should optimistically append the user message"
        )

        let userMessageSettled = await waitUntil {
            model.messages.contains(where: {
                $0.role == "user" && $0.text == "hello from iOS" && !$0.isPending
            })
        }
        XCTAssertTrue(userMessageSettled)

        try? await Task.sleep(nanoseconds: 50_000_000)
        model.stopPolling()
    }

    func testPollingMergesAssistantPartsIntoTranscript() async throws {
        let session = makeStubbedSession()
        let fetchCount = LockedBox(0)
        let createdAt = Date()

        URLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/repos/acme/widgets/agent/sessions/sess-1/messages"):
                return try jsonResponse(for: request, statusCode: 200, jsonObject: [:])
            case ("GET", "/api/repos/acme/widgets/agent/sessions/sess-1/messages"):
                let call = fetchCount.withValue {
                    $0 += 1
                    return $0
                }

                let baseMessages: [[String: Any]] = [
                    Self.messagePayload(
                        id: "msg-user-1",
                        role: "user",
                        text: "hello from iOS",
                        createdAt: createdAt
                    ),
                ]

                if call == 1 {
                    return try jsonResponse(for: request, statusCode: 200, jsonObject: baseMessages)
                }

                return try jsonResponse(
                    for: request,
                    statusCode: 200,
                    jsonObject: baseMessages + [
                        Self.multipartMessagePayload(
                            id: "msg-assistant-1",
                            role: "assistant",
                            parts: ["part one", "part two"],
                            createdAt: createdAt.addingTimeInterval(1)
                        ),
                    ]
                )
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let model = makeModel(session: session)
        model.draft = "hello from iOS"
        model.send()

        let assistantMessageMerged = await waitUntil(timeout: 4) {
            model.messages.contains(where: { $0.role == "assistant" && $0.text == "part one\npart two" })
        }
        XCTAssertTrue(
            assistantMessageMerged,
            "polling should merge assistant parts into a rendered transcript message"
        )

        model.stopPolling()
    }

    func testHttpFailureSurfacesErrorMessage() async throws {
        let session = makeStubbedSession()

        URLProtocolStub.handler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/repos/acme/widgets/agent/sessions/sess-1/messages"):
                return try textResponse(for: request, statusCode: 500, body: "backend exploded")
            default:
                return try textResponse(for: request, statusCode: 404, body: "unexpected request")
            }
        }

        let model = makeModel(session: session)
        model.draft = "trigger failure"
        model.send()

        let surfacedError = await waitUntil {
            model.errorMessage == "Chat request failed with HTTP 500: backend exploded"
        }
        XCTAssertTrue(surfacedError)
        XCTAssertEqual(model.messages, [])
    }

    func testEmptySessionUsesStableEmptyStateIdentifier() throws {
        let source = try String(contentsOf: Self.agentChatViewSourceURL(), encoding: .utf8)
        XCTAssertTrue(source.contains(#""No messages yet""#))
        XCTAssertTrue(source.contains(#".accessibilityIdentifier("chat.empty")"#))
    }

    private func makeModel(session: URLSession) -> AgentChatViewModel {
        AgentChatViewModel(
            client: AgentChatAPIClient(
                baseURL: URL(string: "https://plue.test")!,
                repoOwner: "acme",
                repoName: "widgets",
                sessionID: "sess-1",
                bearerProvider: { "test-token" },
                session: session
            )
        )
    }

    private static func messagePayload(
        id: String,
        role: String,
        text: String,
        createdAt: Date
    ) -> [String: Any] {
        [
            "id": id,
            "role": role,
            "created_at": iso8601Formatter.string(from: createdAt),
            "parts": [[
                "type": "text",
                "content": ["value": text],
            ]],
        ]
    }

    private static func multipartMessagePayload(
        id: String,
        role: String,
        parts: [String],
        createdAt: Date
    ) -> [String: Any] {
        [
            "id": id,
            "role": role,
            "created_at": iso8601Formatter.string(from: createdAt),
            "parts": parts.map { part in
                [
                    "type": "text",
                    "content": ["value": part],
                ]
            },
        ]
    }

    private static func agentChatViewSourceURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/Sources/SmithersiOS/Chat/AgentChatView.swift")
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
#endif
