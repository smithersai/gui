import XCTest
@testable import SmithersGUI

private func makeFilterBlock(role: String, content: String) -> ChatBlock {
    ChatBlock(
        id: UUID().uuidString,
        runId: "run-1",
        nodeId: "task:review:0",
        attempt: 0,
        role: role,
        content: content,
        timestampMs: nil
    )
}

final class ChatBlockFilterTests: XCTestCase {
    func testEmptyStderrHiddenWhenFilterEnabled() {
        let block = makeFilterBlock(role: "stderr", content: "   ")
        XCTAssertTrue(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testWarningStderrHidden() {
        let block = makeFilterBlock(role: "stderr", content: "warning: foo")
        XCTAssertTrue(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testAssistantNeverHidden() {
        let block = makeFilterBlock(role: "assistant", content: "warning: foo")
        XCTAssertFalse(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testToolNeverHidden() {
        let block = makeFilterBlock(role: "tool", content: "warning: foo")
        XCTAssertFalse(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testRegexAnchoringPreservesCounterExamples() {
        let block = makeFilterBlock(role: "stderr", content: "context before warning: foo")
        XCTAssertFalse(ChatBlockFilter.shouldHide(block, enabled: true))
    }

    func testInvalidRegexFallsBackToDefault() {
        let block = makeFilterBlock(role: "stderr", content: "warning: foo")
        XCTAssertTrue(
            ChatBlockFilter.shouldHide(
                block,
                enabled: true,
                regexPattern: "("
            )
        )
    }
}
