import XCTest
@testable import SmithersGUI

private func makeMergedBlock(
    id: String? = nil,
    itemId: String? = nil,
    runId: String? = "run-1",
    nodeId: String? = "task:review:0",
    attempt: Int? = 0,
    role: String = "assistant",
    content: String,
    timestampMs: Int64? = nil
) -> ChatBlock {
    ChatBlock(
        id: id,
        itemId: itemId,
        runId: runId,
        nodeId: nodeId,
        attempt: attempt,
        role: role,
        content: content,
        timestampMs: timestampMs
    )
}

final class ChatBlockMergerTests: XCTestCase {
    func testEmptyStreamProducesEmptyTranscript() {
        var merger = ChatBlockMerger()
        merger.append(contentsOf: [])
        XCTAssertTrue(merger.blocks.isEmpty)
    }

    func testSingleBlockAppends() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: "a", content: "hello"))

        XCTAssertEqual(merger.blocks.count, 1)
        XCTAssertEqual(merger.blocks[0].content, "hello")
    }

    func testDifferentLifecycleIdsAppendBoth() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: "a", content: "one"))
        merger.append(makeMergedBlock(id: "b", content: "two"))

        XCTAssertEqual(merger.blocks.count, 2)
        XCTAssertEqual(merger.blocks.map(\.content), ["one", "two"])
    }

    func testSameLifecycleIdReplacesExistingEntry() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: "same", role: "system", content: "old"))
        merger.append(makeMergedBlock(id: "same", role: "system", content: "new"))

        XCTAssertEqual(merger.blocks.count, 1)
        XCTAssertEqual(merger.blocks[0].content, "new")
    }

    func testOutOfOrderDeliveryUsesLatestArrivalForSameLifecycle() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: "same", role: "system", content: "seq=3", timestampMs: 3))
        merger.append(makeMergedBlock(id: "same", role: "system", content: "seq=2", timestampMs: 2))

        // Document current behavior: for non-assistant blocks, latest arrival wins.
        XCTAssertEqual(merger.blocks.count, 1)
        XCTAssertEqual(merger.blocks[0].content, "seq=2")
    }

    func testStreamingAssistantPartialsMergeToLastVariant() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: "stream", content: "Hello"))
        merger.append(makeMergedBlock(id: "stream", content: "Hello world"))
        merger.append(makeMergedBlock(id: "stream", content: "Hello world!"))

        XCTAssertEqual(merger.blocks.count, 1)
        XCTAssertEqual(merger.blocks[0].content, "Hello world!")
    }

    func testThousandUniqueBlocksAppearExactlyOnce() {
        var merger = ChatBlockMerger()

        for index in 0..<1_000 {
            merger.append(
                makeMergedBlock(
                    id: "id-\(index)",
                    role: "system",
                    content: "message-\(index)"
                )
            )
        }

        XCTAssertEqual(merger.blocks.count, 1_000)
        let uniqueIds = Set(merger.blocks.compactMap(\.lifecycleId))
        XCTAssertEqual(uniqueIds.count, 1_000)
    }

    func testDuplicateBlockDeduplicatesToOne() {
        var merger = ChatBlockMerger()
        let block = makeMergedBlock(id: "dup", role: "system", content: "same")

        merger.append(block)
        merger.append(block)

        XCTAssertEqual(merger.blocks.count, 1)
        XCTAssertEqual(merger.blocks[0].content, "same")
    }

    func testMissingLifecycleIdNeverMerges() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: nil, itemId: nil, content: "first"))
        merger.append(makeMergedBlock(id: nil, itemId: nil, content: "second"))

        XCTAssertEqual(merger.blocks.count, 2)
        XCTAssertEqual(merger.blocks.map(\.content), ["first", "second"])
    }

    func testMissingIdAppendsAsSeparateEntry() {
        var merger = ChatBlockMerger()
        merger.append(makeMergedBlock(id: nil, itemId: nil, role: "tool", content: "call a"))
        merger.append(makeMergedBlock(id: nil, itemId: nil, role: "tool", content: "call b"))

        XCTAssertEqual(merger.blocks.count, 2)
    }
}
