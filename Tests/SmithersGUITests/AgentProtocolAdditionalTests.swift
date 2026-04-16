import XCTest
@testable import SmithersGUI

// MARK: - CodexEvent Tests

final class CodexEventTests: XCTestCase {

    func testDecodeMessageEvent() throws {
        let json = """
        {"type":"message.delta","item":{"type":"text","text":"Hello world"}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.type, "message.delta")
        XCTAssertEqual(event.item?.text, "Hello world")
    }

    func testDecodeErrorEvent() throws {
        let json = """
        {"type":"error","message":"rate limited"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.type, "error")
        XCTAssertEqual(event.message, "rate limited")
    }

    func testDecodeTurnFailedWithNestedError() throws {
        let json = """
        {"type":"turn.failed","error":{"message":"timeout"}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.type, "turn.failed")
        XCTAssertEqual(event.error?.message, "timeout")
    }

    func testDecodeUsage() throws {
        let json = """
        {"type":"usage","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":200}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.usage?.inputTokens, 100)
        XCTAssertEqual(event.usage?.cachedInputTokens, 50)
        XCTAssertEqual(event.usage?.outputTokens, 200)
    }

    func testDecodeCommandItem() throws {
        let json = """
        {"type":"command","item":{"id":"cmd1","type":"command","command":"ls -la","aggregated_output":"file.txt","exit_code":0}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.item?.command, "ls -la")
        XCTAssertEqual(event.item?.aggregatedOutput, "file.txt")
        XCTAssertEqual(event.item?.exitCode, 0)
    }

    func testDecodeThreadId() throws {
        let json = """
        {"type":"turn.started","thread_id":"t123"}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.threadId, "t123")
    }

    func testDecodeFileChanges() throws {
        let json = """
        {"type":"changes","item":{"changes":[{"path":"foo.swift","kind":"modified"},{"path":"bar.swift","kind":"added"}]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.item?.changes?.count, 2)
        XCTAssertEqual(event.item?.changes?[0].path, "foo.swift")
        XCTAssertEqual(event.item?.changes?[1].kind, "added")
    }

    func testDecodeTodoItems() throws {
        let json = """
        {"type":"todo","item":{"items":[{"text":"Fix bug","completed":false},{"text":"Write tests","completed":true}]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.item?.items?.count, 2)
        XCTAssertEqual(event.item?.items?[0].text, "Fix bug")
        XCTAssertFalse(event.item?.items?[0].completed ?? true)
        XCTAssertTrue(event.item?.items?[1].completed ?? false)
    }

    func testDecodeMCPEvent() throws {
        let json = """
        {"type":"mcp","item":{"server":"my-server","tool":"search"}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(CodexEvent.self, from: json)
        XCTAssertEqual(event.item?.server, "my-server")
        XCTAssertEqual(event.item?.tool, "search")
    }
}

// MARK: - CodexJSONLLineBuffer Tests

final class CodexJSONLLineBufferTests: XCTestCase {

    func testAppendCompleteLine() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.append(#"{"type":"ping"}"# + "\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "ping")
    }

    func testAppendPartialLineThenComplete() {
        let buffer = CodexJSONLLineBuffer()
        let e1 = buffer.append(#"{"type":"#)
        XCTAssertTrue(e1.isEmpty)

        let e2 = buffer.append(#""ping"}"# + "\n")
        XCTAssertEqual(e2.count, 1)
        XCTAssertEqual(e2[0].type, "ping")
    }

    func testAppendMultipleLines() {
        let buffer = CodexJSONLLineBuffer()
        let input = #"{"type":"a"}"# + "\n" + #"{"type":"b"}"# + "\n"
        let events = buffer.append(input)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, "a")
        XCTAssertEqual(events[1].type, "b")
    }

    func testAppendCRDelimitedLines() {
        let buffer = CodexJSONLLineBuffer()
        let input = #"{"type":"a"}"# + "\r" + #"{"type":"b"}"# + "\r"
        let events = buffer.append(input)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, "a")
        XCTAssertEqual(events[1].type, "b")
    }

    func testAppendSplitCRLFBoundaryAcrossChunks() {
        let buffer = CodexJSONLLineBuffer()

        let first = buffer.append(#"{"type":"a"}"# + "\r")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].type, "a")

        let second = buffer.append("\n" + #"{"type":"b"}"# + "\n")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].type, "b")
        XCTAssertTrue(buffer.finish().isEmpty)
    }

    func testAppendEmptyString() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.append("")
        XCTAssertTrue(events.isEmpty)
    }

    func testAppendInvalidJSONIgnored() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.append("not json\n")
        XCTAssertTrue(events.isEmpty)
    }

    func testFinishDrainsPending() {
        let buffer = CodexJSONLLineBuffer()
        _ = buffer.append(#"{"type":"final"}"#)
        let events = buffer.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "final")
    }

    func testFinishEmptyBuffer() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.finish()
        XCTAssertTrue(events.isEmpty)
    }

    func testAppendBlankLinesIgnored() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.append("\n\n\n")
        XCTAssertTrue(events.isEmpty)
    }

    func testConcurrentAppendSafe() {
        let buffer = CodexJSONLLineBuffer()
        let group = DispatchGroup()

        for i in 0..<100 {
            group.enter()
            DispatchQueue.global().async {
                _ = buffer.append(#"{"type":"event\#(i)"}"# + "\n")
                group.leave()
            }
        }

        group.wait()
        // If we get here without crashing, thread safety is working
    }
}

// MARK: - CodexUsage Tests

final class CodexUsageTests: XCTestCase {

    func testDecodeAllFields() throws {
        let json = """
        {"input_tokens":100,"cached_input_tokens":25,"output_tokens":50}
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsage.self, from: json)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cachedInputTokens, 25)
        XCTAssertEqual(usage.outputTokens, 50)
    }

    func testDecodePartialFields() throws {
        let json = """
        {"input_tokens":100}
        """.data(using: .utf8)!
        let usage = try JSONDecoder().decode(CodexUsage.self, from: json)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.outputTokens)
    }
}
