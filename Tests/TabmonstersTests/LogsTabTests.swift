import XCTest
@testable import Tabmonsters

private enum MockStreamError: Error {
    case failed
}

@MainActor
private final class MockChatStreamProvider: ChatStreamProviding {
    private(set) var subscribeCalls: [(runId: String, continuationIndex: Int)] = []
    private(set) var terminationCount = 0
    private var continuations: [AsyncThrowingStream<SSEEvent, Error>.Continuation] = []

    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let index = continuations.count
            continuations.append(continuation)
            subscribeCalls.append((runId, index))

            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.terminationCount += 1
                }
            }
        }
    }

    func send(
        _ block: ChatBlock,
        expectedRunId: String = "run-1",
        continuationIndex: Int = 0
    ) {
        guard continuations.indices.contains(continuationIndex),
              let data = try? JSONEncoder().encode(block),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }

        continuations[continuationIndex].yield(
            SSEEvent(event: "message", data: payload, runId: expectedRunId)
        )
    }

    func fail(continuationIndex: Int = 0) {
        guard continuations.indices.contains(continuationIndex) else { return }
        continuations[continuationIndex].finish(throwing: MockStreamError.failed)
    }
}

private final class MockTranscriptPasteboard: TranscriptPasteboarding {
    private(set) var lastText: String?

    func write(_ text: String) {
        lastText = text
    }
}

@MainActor
private func makeLogsBlock(
    runId: String? = "run-1",
    nodeId: String? = "task:review:0",
    role: String = "assistant",
    content: String,
    id: String = UUID().uuidString
) -> ChatBlock {
    ChatBlock(
        id: id,
        runId: runId,
        nodeId: nodeId,
        attempt: 0,
        role: role,
        content: content,
        timestampMs: 1_700_000_000_000
    )
}

@MainActor
final class LogsTabTests: XCTestCase {
    func testActivateSubscribesToStream() {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")

        XCTAssertEqual(provider.subscribeCalls.count, 1)
        XCTAssertEqual(provider.subscribeCalls.first?.runId, "run-1")
        XCTAssertTrue(model.isStreaming)
    }

    func testSwitchTaskCancelsPreviousSubscriptionAndStartsNewOne() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:a")
        model.activate(runId: "run-1", nodeId: "task:b")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(provider.subscribeCalls.count, 2)
        XCTAssertGreaterThanOrEqual(provider.terminationCount, 1)
    }

    func testDeactivateCancelsSubscriptionAndReenterResubscribes() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")
        model.deactivate(reason: "tab_hidden")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(model.isStreaming)
        XCTAssertGreaterThanOrEqual(provider.terminationCount, 1)

        model.activate(runId: "run-1", nodeId: "task:review")
        XCTAssertEqual(provider.subscribeCalls.count, 2)
    }

    func testFollowToBottomRequestsScrollWhenEnabled() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)
        model.activate(runId: "run-1", nodeId: "task:review")

        let before = model.scrollRequestToken
        provider.send(makeLogsBlock(nodeId: "task:review", content: "hello"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotEqual(before, model.scrollRequestToken)
    }

    func testFollowToBottomDoesNotScrollWhenDisabled() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)
        model.activate(runId: "run-1", nodeId: "task:review")
        model.followToBottom = false

        let before = model.scrollRequestToken
        provider.send(makeLogsBlock(nodeId: "task:review", content: "hello"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(before, model.scrollRequestToken)
    }

    func testUserScrollUpDisablesFollow() {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.followToBottom = true
        model.userScrolledAwayFromBottom()

        XCTAssertFalse(model.followToBottom)
    }

    func testUserScrollToBottomAutoResumesFollowWhenEnabled() {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.followToBottom = false
        model.userReachedBottom(autoResume: true)

        XCTAssertTrue(model.followToBottom)
    }

    func testCopyTranscriptWritesPlainTextToPasteboard() async {
        let provider = MockChatStreamProvider()
        let pasteboard = MockTranscriptPasteboard()
        let model = LogsTabModel(streamProvider: provider, pasteboard: pasteboard)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", content: "copied text", id: "copy-1"))
        let receivedBlock = await waitUntil(timeout: 1.0) { model.visibleBlocks.count == 1 }
        XCTAssertTrue(receivedBlock)

        let rendered = model.copyVisibleTranscript { _ in "12:00:00" }

        XCTAssertEqual(rendered, pasteboard.lastText)
        XCTAssertTrue(rendered.contains("[12:00:00] ASSISTANT"))
        XCTAssertTrue(rendered.contains("copied text"))
    }

    func testCopyTranscriptHonorsPrivacyMode() async {
        let provider = MockChatStreamProvider()
        let pasteboard = MockTranscriptPasteboard()
        let model = LogsTabModel(streamProvider: provider, pasteboard: pasteboard)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", role: "prompt", content: "secret prompt", id: "copy-private-1"))
        let receivedBlock = await waitUntil(timeout: 1.0) { model.visibleBlocks.count == 1 }
        XCTAssertTrue(receivedBlock)

        model.privacyMode = true
        let rendered = model.copyVisibleTranscript { _ in "12:00:00" }

        XCTAssertEqual(rendered, pasteboard.lastText)
        XCTAssertTrue(rendered.contains("[12:00:00] USER"))
        XCTAssertTrue(rendered.contains("[prompt hidden in privacy mode]"))
        XCTAssertFalse(rendered.contains("secret prompt"))
    }

    func testTranscriptSearchFiltersVisibleBlocksByContentAndRole() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", role: "assistant", content: "Deploy succeeded", id: "search-1"))
        provider.send(makeLogsBlock(nodeId: "task:review", role: "prompt", content: "Review the docs", id: "search-2"))
        provider.send(makeLogsBlock(nodeId: "task:review", role: "tool", content: "cat README.md", id: "search-3"))
        let receivedBlocks = await waitUntil(timeout: 1.0) { model.visibleBlocks.count == 3 }
        XCTAssertTrue(receivedBlocks)

        model.transcriptSearchQuery = "DEPLOY"
        XCTAssertEqual(model.visibleBlocks.map(\.id), ["search-1"])

        model.transcriptSearchQuery = "prompt docs"
        XCTAssertEqual(model.visibleBlocks.map(\.id), ["search-2"])

        model.transcriptSearchQuery = "tool readme"
        XCTAssertEqual(model.visibleBlocks.map(\.id), ["search-3"])

        model.transcriptSearchQuery = "missing"
        XCTAssertTrue(model.visibleBlocks.isEmpty)
    }

    func testCopyTranscriptHonorsSearchFilter() async {
        let provider = MockChatStreamProvider()
        let pasteboard = MockTranscriptPasteboard()
        let model = LogsTabModel(streamProvider: provider, pasteboard: pasteboard)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", content: "first answer", id: "copy-search-1"))
        provider.send(makeLogsBlock(nodeId: "task:review", content: "second answer", id: "copy-search-2"))
        let receivedBlocks = await waitUntil(timeout: 1.0) { model.visibleBlocks.count == 2 }
        XCTAssertTrue(receivedBlocks)

        model.transcriptSearchQuery = "second"
        let rendered = model.copyVisibleTranscript { _ in nil }

        XCTAssertEqual(rendered, pasteboard.lastText)
        XCTAssertTrue(rendered.contains("second answer"))
        XCTAssertFalse(rendered.contains("first answer"))
    }

    func testNoiseToggleReappliesImmediately() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", role: "assistant", content: "keep me", id: "a1"))
        provider.send(makeLogsBlock(nodeId: "task:review", role: "stderr", content: "warning: foo", id: "s1"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.visibleBlocks.count, 1)

        model.hideNoise = false
        XCTAssertEqual(model.visibleBlocks.count, 2)
    }

    func testBlockFromDifferentRunIsIgnored() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(
            makeLogsBlock(runId: "run-2", nodeId: "task:review", content: "wrong run"),
            expectedRunId: "run-2"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.visibleBlocks.isEmpty)
    }

    func testStreamErrorShowsBannerStateAndPreservesBlocks() async {
        let provider = MockChatStreamProvider()
        let model = LogsTabModel(streamProvider: provider)

        model.activate(runId: "run-1", nodeId: "task:review")
        provider.send(makeLogsBlock(nodeId: "task:review", content: "before error", id: "b1"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        provider.fail()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.visibleBlocks.count, 1)
        XCTAssertEqual(model.visibleBlocks.first?.content, "before error")
        XCTAssertEqual(model.streamError, "Stream error. Try reconnecting.")
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollIntervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return condition()
    }
}
