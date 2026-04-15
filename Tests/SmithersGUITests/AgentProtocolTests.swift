import XCTest
@testable import SmithersGUI

// MARK: - AgentProtocol Comprehensive Unit Tests

final class AgentProtocolTests: XCTestCase {

    // MARK: - CodexEvent Tests

    // CODEX_EVENT — all fields present
    func testCodexEventAllFieldsPresent() throws {
        let json = """
        {"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"hi"},"usage":{"input_tokens":10,"cached_input_tokens":5,"output_tokens":3},"thread_id":"t1","message":"msg","error":{"message":"err"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.completed")
        XCTAssertEqual(event.item?.id, "i1")
        XCTAssertEqual(event.usage?.inputTokens, 10)
        XCTAssertEqual(event.threadId, "t1")
        XCTAssertEqual(event.message, "msg")
        XCTAssertEqual(event.error?.message, "err")
    }

    // CODEX_EVENT — minimal with just type
    func testCodexEventMinimalJustType() throws {
        let json = """
        {"type":"turn.completed"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.completed")
        XCTAssertNil(event.item)
        XCTAssertNil(event.usage)
        XCTAssertNil(event.threadId)
        XCTAssertNil(event.message)
        XCTAssertNil(event.error)
    }

    // CODEX_EVENT — type "item.completed"
    func testCodexEventTypeItemCompleted() throws {
        let json = """
        {"type":"item.completed","item":{"id":"a","type":"agent_message","text":"done"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.completed")
        XCTAssertEqual(event.item?.text, "done")
    }

    // CODEX_EVENT — type "item.started"
    func testCodexEventTypeItemStarted() throws {
        let json = """
        {"type":"item.started","item":{"id":"b","type":"command_execution","command":"pwd"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.started")
        XCTAssertEqual(event.item?.command, "pwd")
    }

    // CODEX_EVENT — type "turn.failed"
    func testCodexEventTypeTurnFailed() throws {
        let json = """
        {"type":"turn.failed","error":{"message":"timeout"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.failed")
        XCTAssertEqual(event.error?.message, "timeout")
    }

    // CODEX_EVENT — type "error"
    func testCodexEventTypeError() throws {
        let json = """
        {"type":"error","message":"fatal error"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "error")
        XCTAssertEqual(event.message, "fatal error")
    }

    // CODEX_EVENT — CodingKeys thread_id maps to threadId
    func testCodexEventThreadIdCodingKey() throws {
        let json = """
        {"type":"turn.completed","thread_id":"abc-123"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.threadId, "abc-123")
    }

    // CODEX_EVENT — missing type should fail
    func testCodexEventMissingTypeThrows() {
        let json = """
        {"item":{"id":"x","type":"agent_message"}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8)))
    }

    // CODEX_EVENT — extra unknown fields are ignored
    func testCodexEventIgnoresUnknownFields() throws {
        let json = """
        {"type":"turn.completed","foo":"bar","baz":123,"nested":{"a":1}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.completed")
    }

    // CODEX_EVENT — null vs missing optional fields
    func testCodexEventExplicitNulls() throws {
        let json = """
        {"type":"item.completed","item":null,"usage":null,"thread_id":null,"message":null,"error":null}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.completed")
        XCTAssertNil(event.item)
        XCTAssertNil(event.usage)
        XCTAssertNil(event.threadId)
        XCTAssertNil(event.message)
        XCTAssertNil(event.error)
    }

    func testCodexJSONLLineBufferBuffersPartialLine() {
        let buffer = CodexJSONLLineBuffer()

        XCTAssertTrue(buffer.append("{\"type\":\"item.completed\",\"item\":{\"id\":\"m1\"").isEmpty)
        XCTAssertTrue(buffer.append(",\"type\":\"agent_message\",\"text\":\"Hello\"}}").isEmpty)

        let events = buffer.append("\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "item.completed")
        XCTAssertEqual(events[0].item?.id, "m1")
        XCTAssertEqual(events[0].item?.text, "Hello")
    }

    func testCodexJSONLLineBufferKeepsTrailingPartial() {
        let buffer = CodexJSONLLineBuffer()
        let events = buffer.append(
            "{\"type\":\"turn.started\"}\n" +
            "{\"type\":\"item.completed\",\"item\":{\"id\":\"m1\",\"type\":\"agent_message\",\"text\":\"partial\"}"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "turn.started")
    }

    func testCodexJSONLLineBufferFlushesFinalLine() {
        let buffer = CodexJSONLLineBuffer()

        XCTAssertTrue(buffer.append("{\"type\":\"turn.completed\"}").isEmpty)
        let events = buffer.finish()

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "turn.completed")
    }

    // MARK: - CodexErrorInfo Tests

    // CODEX_ERROR_INFO — with message
    func testCodexErrorInfoWithMessage() throws {
        let json = """
        {"message":"rate limit exceeded"}
        """
        let info = try JSONDecoder().decode(CodexErrorInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.message, "rate limit exceeded")
    }

    // CODEX_ERROR_INFO — nil message
    func testCodexErrorInfoNilMessage() throws {
        let json = """
        {}
        """
        let info = try JSONDecoder().decode(CodexErrorInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.message)
    }

    // CODEX_ERROR_INFO — explicit null message
    func testCodexErrorInfoExplicitNullMessage() throws {
        let json = """
        {"message":null}
        """
        let info = try JSONDecoder().decode(CodexErrorInfo.self, from: Data(json.utf8))
        XCTAssertNil(info.message)
    }

    // CODEX_ERROR_INFO — empty message
    func testCodexErrorInfoEmptyMessage() throws {
        let json = """
        {"message":""}
        """
        let info = try JSONDecoder().decode(CodexErrorInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.message, "")
    }

    // MARK: - CodexItem Tests

    // CODEX_ITEM — all fields present
    func testCodexItemAllFields() throws {
        let json = """
        {"id":"i1","type":"command_execution","text":"hello","command":"ls","aggregated_output":"out","exit_code":0,"status":"completed","changes":[{"path":"a.txt","kind":"modified"}],"query":"search","items":[{"text":"todo","completed":true}],"server":"srv","tool":"tool_a","message":"item failed"}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, "i1")
        XCTAssertEqual(item.type, "command_execution")
        XCTAssertEqual(item.text, "hello")
        XCTAssertEqual(item.command, "ls")
        XCTAssertEqual(item.aggregatedOutput, "out")
        XCTAssertEqual(item.exitCode, 0)
        XCTAssertEqual(item.status, "completed")
        XCTAssertEqual(item.changes?.count, 1)
        XCTAssertEqual(item.query, "search")
        XCTAssertEqual(item.items?.count, 1)
        XCTAssertEqual(item.server, "srv")
        XCTAssertEqual(item.tool, "tool_a")
        XCTAssertEqual(item.message, "item failed")
    }

    // CODEX_ITEM — minimal empty object
    func testCodexItemMinimal() throws {
        let json = """
        {}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertNil(item.id)
        XCTAssertNil(item.type)
        XCTAssertNil(item.text)
        XCTAssertNil(item.command)
        XCTAssertNil(item.aggregatedOutput)
        XCTAssertNil(item.exitCode)
        XCTAssertNil(item.status)
        XCTAssertNil(item.changes)
        XCTAssertNil(item.query)
        XCTAssertNil(item.items)
        XCTAssertNil(item.server)
        XCTAssertNil(item.tool)
        XCTAssertNil(item.message)
    }

    func testCodexItemWebSearchFields() throws {
        let json = """
        {"id":"w1","type":"web_search","query":"swift concurrency"}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.type, "web_search")
        XCTAssertEqual(item.query, "swift concurrency")
    }

    func testCodexItemMCPToolCallFields() throws {
        let json = """
        {"id":"mcp1","type":"mcp_tool_call","server":"linear","tool":"list_issues","status":"in_progress"}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.type, "mcp_tool_call")
        XCTAssertEqual(item.server, "linear")
        XCTAssertEqual(item.tool, "list_issues")
        XCTAssertEqual(item.status, "in_progress")
    }

    // CODEX_ITEM — CodingKeys aggregated_output
    func testCodexItemAggregatedOutputCodingKey() throws {
        let json = """
        {"aggregated_output":"some output here"}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.aggregatedOutput, "some output here")
    }

    // CODEX_ITEM — CodingKeys exit_code
    func testCodexItemExitCodeCodingKey() throws {
        let json = """
        {"exit_code":1}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.exitCode, 1)
    }

    // CODEX_ITEM — negative exit code
    func testCodexItemNegativeExitCode() throws {
        let json = """
        {"exit_code":-1}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.exitCode, -1)
    }

    // CODEX_ITEM — empty changes array
    func testCodexItemEmptyChangesArray() throws {
        let json = """
        {"changes":[]}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.changes?.count, 0)
    }

    // CODEX_ITEM — empty items array
    func testCodexItemEmptyItemsArray() throws {
        let json = """
        {"items":[]}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.items?.count, 0)
    }

    // CODEX_ITEM — unknown fields ignored
    func testCodexItemIgnoresUnknownFields() throws {
        let json = """
        {"id":"x","type":"agent_message","unknown_key":"value"}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.id, "x")
    }

    // MARK: - CodexFileChange Tests

    // CODEX_FILE_CHANGE — normal
    func testCodexFileChangeNormal() throws {
        let json = """
        {"path":"src/main.swift","kind":"added"}
        """
        let change = try JSONDecoder().decode(CodexFileChange.self, from: Data(json.utf8))
        XCTAssertEqual(change.path, "src/main.swift")
        XCTAssertEqual(change.kind, "added")
    }

    // CODEX_FILE_CHANGE — empty strings
    func testCodexFileChangeEmptyStrings() throws {
        let json = """
        {"path":"","kind":""}
        """
        let change = try JSONDecoder().decode(CodexFileChange.self, from: Data(json.utf8))
        XCTAssertEqual(change.path, "")
        XCTAssertEqual(change.kind, "")
    }

    // CODEX_FILE_CHANGE — missing required field throws
    func testCodexFileChangeMissingPathThrows() {
        let json = """
        {"kind":"modified"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexFileChange.self, from: Data(json.utf8)))
    }

    // CODEX_FILE_CHANGE — missing kind throws
    func testCodexFileChangeMissingKindThrows() {
        let json = """
        {"path":"a.txt"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexFileChange.self, from: Data(json.utf8)))
    }

    // MARK: - CodexTodoItem Tests

    // CODEX_TODO_ITEM — completed true
    func testCodexTodoItemCompletedTrue() throws {
        let json = """
        {"text":"Write tests","completed":true}
        """
        let todo = try JSONDecoder().decode(CodexTodoItem.self, from: Data(json.utf8))
        XCTAssertEqual(todo.text, "Write tests")
        XCTAssertTrue(todo.completed)
    }

    // CODEX_TODO_ITEM — completed false
    func testCodexTodoItemCompletedFalse() throws {
        let json = """
        {"text":"Fix bug","completed":false}
        """
        let todo = try JSONDecoder().decode(CodexTodoItem.self, from: Data(json.utf8))
        XCTAssertEqual(todo.text, "Fix bug")
        XCTAssertFalse(todo.completed)
    }

    // CODEX_TODO_ITEM — empty text
    func testCodexTodoItemEmptyText() throws {
        let json = """
        {"text":"","completed":false}
        """
        let todo = try JSONDecoder().decode(CodexTodoItem.self, from: Data(json.utf8))
        XCTAssertEqual(todo.text, "")
        XCTAssertFalse(todo.completed)
    }

    // CODEX_TODO_ITEM — missing required fields throws
    func testCodexTodoItemMissingFieldsThrows() {
        let json = """
        {"text":"hello"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexTodoItem.self, from: Data(json.utf8)))
    }

    // MARK: - CodexUsage Tests

    // CODEX_USAGE — all fields
    func testCodexUsageAllFields() throws {
        let json = """
        {"input_tokens":200,"cached_input_tokens":180,"output_tokens":50}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cachedInputTokens, 180)
        XCTAssertEqual(usage.outputTokens, 50)
    }

    // CODEX_USAGE — some nil
    func testCodexUsagePartialFields() throws {
        let json = """
        {"input_tokens":100,"output_tokens":25}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertEqual(usage.outputTokens, 25)
    }

    // CODEX_USAGE — all nil (empty object)
    func testCodexUsageEmptyObject() throws {
        let json = """
        {}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertNil(usage.inputTokens)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.outputTokens)
    }

    // CODEX_USAGE — CodingKeys input_tokens
    func testCodexUsageCodingKeys() throws {
        let json = """
        {"input_tokens":1,"cached_input_tokens":2,"output_tokens":3}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.inputTokens, 1)
        XCTAssertEqual(usage.cachedInputTokens, 2)
        XCTAssertEqual(usage.outputTokens, 3)
    }

    // CODEX_USAGE — zero values
    func testCodexUsageZeroValues() throws {
        let json = """
        {"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
    }

    // CODEX_USAGE — large token counts
    func testCodexUsageLargeTokenCounts() throws {
        let json = """
        {"input_tokens":999999999,"cached_input_tokens":888888888,"output_tokens":777777777}
        """
        let usage = try JSONDecoder().decode(CodexUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.inputTokens, 999999999)
        XCTAssertEqual(usage.cachedInputTokens, 888888888)
        XCTAssertEqual(usage.outputTokens, 777777777)
    }

    // MARK: - Edge Case Tests

    // EDGE_CASE — CodexEvent with only item, no usage
    func testCodexEventItemWithoutUsage() throws {
        let json = """
        {"type":"item.completed","item":{"id":"z","type":"agent_message","text":"response"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertNotNil(event.item)
        XCTAssertNil(event.usage)
    }

    // EDGE_CASE — CodexEvent with only usage, no item
    func testCodexEventUsageWithoutItem() throws {
        let json = """
        {"type":"item.completed","usage":{"input_tokens":50,"output_tokens":10}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.item)
        XCTAssertNotNil(event.usage)
        XCTAssertEqual(event.usage?.inputTokens, 50)
    }

    // EDGE_CASE — CodexItem with multiple file changes
    func testCodexItemMultipleFileChanges() throws {
        let json = """
        {"changes":[{"path":"a.swift","kind":"added"},{"path":"b.swift","kind":"deleted"},{"path":"c.swift","kind":"modified"}]}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.changes?.count, 3)
        XCTAssertEqual(item.changes?[0].kind, "added")
        XCTAssertEqual(item.changes?[1].kind, "deleted")
        XCTAssertEqual(item.changes?[2].kind, "modified")
    }

    // EDGE_CASE — CodexItem with exit_code 127 (command not found)
    func testCodexItemExitCode127() throws {
        let json = """
        {"type":"command_execution","command":"nonexistent","exit_code":127}
        """
        let item = try JSONDecoder().decode(CodexItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.exitCode, 127)
    }

    // EDGE_CASE — CodexEvent with both message and error
    func testCodexEventBothMessageAndError() throws {
        let json = """
        {"type":"turn.failed","message":"top level","error":{"message":"nested"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.message, "top level")
        XCTAssertEqual(event.error?.message, "nested")
    }

    // EDGE_CASE — empty JSON object missing required type throws for CodexEvent
    func testCodexEventEmptyObjectThrows() {
        let json = """
        {}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8)))
    }
}
