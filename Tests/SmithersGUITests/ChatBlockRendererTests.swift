import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

extension ChatBlockRenderer: @retroactive Inspectable {}

private func makeRendererBlock(role: String, content: String) -> ChatBlock {
    ChatBlock(
        id: UUID().uuidString,
        runId: "run-1",
        nodeId: "task:review:0",
        attempt: 0,
        role: role,
        content: content,
        timestampMs: 1_700_000_000_000
    )
}

final class ChatBlockRendererTests: XCTestCase {
    func testAssistantBlockShowsTimestampAndBubbleContent() throws {
        let block = makeRendererBlock(role: "assistant", content: "hello from assistant")
        let view = ChatBlockRenderer(block: block, timestamp: "12:34:56")

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "ASSISTANT"))
        XCTAssertNoThrow(try inspected.find(text: "12:34:56"))
        XCTAssertNoThrow(try inspected.find(text: "hello from assistant"))
    }

    func testUserPromptBlockUsesPromptLabelAndLineLimit() throws {
        let longPrompt = Array(repeating: "line", count: 20).joined(separator: "\n")
        let block = makeRendererBlock(role: "prompt", content: longPrompt)
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "PROMPT"))
        XCTAssertNoThrow(try inspected.find(button: "[expand]"))
    }

    func testToolCallBlockRendersMonospaceCompactSection() throws {
        let block = makeRendererBlock(role: "tool_call", content: "run tool --flag")
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(ViewType.Image.self))
        XCTAssertNoThrow(try inspected.find(text: "run tool --flag"))
    }

    func testToolResultBlockUsesSeparateStylingLabel() throws {
        let block = makeRendererBlock(role: "tool_result", content: "tool completed")
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: "TOOL RESULT"))
        XCTAssertNoThrow(try inspected.find(text: "tool completed"))
    }

    func testVeryLongBlockShowsExpandControl() throws {
        let longText = Array(repeating: "row", count: 10_000).joined(separator: "\n")
        let block = makeRendererBlock(role: "assistant", content: longText)
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        XCTAssertNoThrow(try view.inspect().find(button: "[expand]"))
    }

    func testUnicodeEmojiAndCodeFencesArePreserved() throws {
        let content = "😀 привет\n```swift\nprint(\"hi\")\n```"
        let block = makeRendererBlock(role: "assistant", content: content)
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(text: content))
    }

    func testMarkdownInAssistantBlockRemainsRawText() throws {
        let content = "**bold** _italic_"
        let block = makeRendererBlock(role: "assistant", content: content)
        let view = ChatBlockRenderer(block: block, timestamp: nil)

        XCTAssertNoThrow(try view.inspect().find(text: content))
    }
}
