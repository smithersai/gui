import XCTest
@testable import SmithersGUI

@MainActor
private final class MockLastLogStreamProvider: ChatStreamProviding {
    private(set) var subscribeCount = 0
    private var continuations: [AsyncThrowingStream<SSEEvent, Error>.Continuation] = []

    func streamChat(runId: String) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            subscribeCount += 1
            continuations.append(continuation)
        }
    }

    func send(_ block: ChatBlock, runId: String = "run-1", index: Int = 0) {
        guard continuations.indices.contains(index),
              let data = try? JSONEncoder().encode(block),
              let payload = String(data: data, encoding: .utf8) else { return }
        continuations[index].yield(SSEEvent(event: "message", data: payload, runId: runId))
    }

    func finish(index: Int = 0) {
        guard continuations.indices.contains(index) else { return }
        continuations[index].finish()
    }
}

private final class MockLastLogHistoryProvider: ChatHistoryProviding, @unchecked Sendable {
    var blocks: [ChatBlock] = []
    var called: Bool = false

    func getChatOutput(runId: String) async throws -> [ChatBlock] {
        called = true
        return blocks
    }
}

private func block(
    nodeId: String?,
    role: String = "assistant",
    content: String,
    runId: String? = "run-1"
) -> ChatBlock {
    ChatBlock(
        id: UUID().uuidString,
        runId: runId,
        nodeId: nodeId,
        attempt: 0,
        role: role,
        content: content,
        timestampMs: 1_700_000_000_000
    )
}

@MainActor
final class LastLogPerNodeStoreTests: XCTestCase {

    func testSingleLinePreviewCollapsesWhitespace() {
        let input = "  first line\n  second   line\tthird  "
        XCTAssertEqual(
            LastLogPerNodeStore.singleLinePreview(from: input),
            "first line second line third"
        )
    }

    func testIngestingStreamBlockUpdatesLastContent() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:review:0", content: "running checks"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.lastLog(forTaskNodeId: "task:review:0"), "running checks")
    }

    func testNoiseStderrIsDropped() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:review:0", role: "stderr", content: "warning: noisy"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(store.lastLog(forTaskNodeId: "task:review:0"))
    }

    func testLaterBlockOverwritesEarlier() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:a", content: "first"))
        provider.send(block(nodeId: "task:a", content: "second"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.lastLog(forTaskNodeId: "task:a"), "second")
    }

    func testDisconnectClearsState() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:a", content: "hi"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        store.disconnect()
        XCTAssertTrue(store.lastContent.isEmpty)
    }

    func testReconnectingToDifferentRunResetsState() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:a", content: "one"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        store.connect(runId: "run-2")
        XCTAssertNil(store.lastLog(forTaskNodeId: "task:a"))
        XCTAssertEqual(provider.subscribeCount, 2)
    }

    func testPrefixFallbackForIterationSuffixedBlocks() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:review:0", content: "iteration zero"))
        provider.send(block(nodeId: "task:review:1", content: "iteration one"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.lastLog(forTaskNodeId: "task:review"), "iteration one")
    }

    func testHistoryPrimingPopulatesLastContent() async {
        let provider = MockLastLogStreamProvider()
        let history = MockLastLogHistoryProvider()
        history.blocks = [
            block(nodeId: "task:a", content: "historical"),
        ]
        let store = LastLogPerNodeStore(streamProvider: provider, historyProvider: history)

        store.connect(runId: "run-1")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(history.called)
        XCTAssertEqual(store.lastLog(forTaskNodeId: "task:a"), "historical")
    }

    func testRunIdMismatchIsDropped() async {
        let provider = MockLastLogStreamProvider()
        let store = LastLogPerNodeStore(streamProvider: provider)

        store.connect(runId: "run-1")
        provider.send(block(nodeId: "task:a", content: "wrong run", runId: "run-2"), runId: "run-2")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(store.lastLog(forTaskNodeId: "task:a"))
    }
}
