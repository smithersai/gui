import XCTest
@testable import SmithersGUI

private actor EnvelopeCapture {
    private var value: Data?

    func set(_ data: Data) {
        value = data
    }

    func get() -> Data? {
        value
    }
}

final class FeedbackReporterTests: XCTestCase {

    func testFeedbackContextFallsBackThreadID() {
        let context = FeedbackContext.make(
            appVersion: "1.2.3",
            workspace: "/tmp/workspace",
            activeView: "Chat",
            threadID: nil,
            recentError: nil
        )

        XCTAssertTrue(context.threadID.hasPrefix("no-active-thread-"))
    }

    func testSubmitWithoutLogsBuildsExpectedPayloadAndIssueURL() async throws {
        let capture = EnvelopeCapture()
        let reporter = FeedbackReporter(
            sendEnvelope: { envelope in
                await capture.set(envelope)
            },
            loadLogData: {
                Data("unused".utf8)
            }
        )

        let context = FeedbackContext.make(
            appVersion: "1.2.3",
            workspace: "/tmp/workspace",
            activeView: "Chat",
            threadID: "thread-123",
            recentError: "rate limit"
        )
        let request = FeedbackSubmissionRequest(
            category: .bug,
            note: "steps to reproduce",
            includeLogs: false,
            context: context
        )

        let result = try await reporter.submit(request)
        let capturedEnvelope = await capture.get()
        let envelope = try XCTUnwrap(capturedEnvelope)
        let payload = String(decoding: envelope, as: UTF8.self)

        XCTAssertEqual(result.threadID, "thread-123")
        XCTAssertFalse(result.includeLogs)
        XCTAssertTrue(result.issueURL.absoluteString.contains("template=2-bug-report.yml"))
        XCTAssertTrue(result.issueURL.absoluteString.contains("Uploaded%20thread:%20thread-123"))

        XCTAssertTrue(payload.contains("\"classification\":\"bug\""))
        XCTAssertTrue(payload.contains("\"thread_id\":\"thread-123\""))
        XCTAssertTrue(payload.contains("\"cli_version\":\"1.2.3\""))
        XCTAssertTrue(
            payload.contains("\"workspace\":\"/tmp/workspace\"") ||
            payload.contains("\"workspace\":\"\\/tmp\\/workspace\"")
        )
        XCTAssertTrue(payload.contains("\"active_view\":\"Chat\""))
        XCTAssertTrue(payload.contains("\"recent_error\":\"rate limit\""))
        XCTAssertTrue(payload.contains("\"reason\":\"steps to reproduce\""))
        XCTAssertFalse(payload.contains("\"filename\":\"codex-logs.log\""))
    }

    func testSubmitWithLogsAttachesCodexLogFile() async throws {
        let capture = EnvelopeCapture()
        let reporter = FeedbackReporter(
            sendEnvelope: { envelope in
                await capture.set(envelope)
            },
            loadLogData: {
                Data("line-1\nline-2".utf8)
            }
        )

        let context = FeedbackContext.make(
            appVersion: "2.0.0",
            workspace: "/tmp/workspace",
            activeView: "Chat",
            threadID: "thread-logs",
            recentError: nil
        )
        let request = FeedbackSubmissionRequest(
            category: .other,
            note: nil,
            includeLogs: true,
            context: context
        )

        _ = try await reporter.submit(request)
        let capturedEnvelope = await capture.get()
        let envelope = try XCTUnwrap(capturedEnvelope)
        let payload = String(decoding: envelope, as: UTF8.self)

        XCTAssertTrue(payload.contains("\"filename\":\"codex-logs.log\""))
        XCTAssertTrue(payload.contains("line-1\nline-2"))
    }
}
