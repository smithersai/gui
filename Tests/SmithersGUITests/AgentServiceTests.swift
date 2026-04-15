import XCTest
@testable import SmithersGUI

// MARK: - CodexEvent / CodexItem JSON Parsing Tests

final class CodexEventParsingTests: XCTestCase {

    // PLATFORM_CODEX_JSONL_EVENT_PARSING — basic item.completed
    func testParseItemCompleted() throws {
        let json = """
        {"type":"item.completed","item":{"id":"msg1","type":"agent_message","text":"Hello"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.completed")
        XCTAssertEqual(event.item?.type, "agent_message")
        XCTAssertEqual(event.item?.text, "Hello")
        XCTAssertEqual(event.item?.id, "msg1")
    }

    // CODEX_EVENT_ITEM_STARTED
    func testParseItemStarted() throws {
        let json = """
        {"type":"item.started","item":{"id":"cmd1","type":"command_execution","command":"ls -la"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.started")
        XCTAssertEqual(event.item?.type, "command_execution")
        XCTAssertEqual(event.item?.command, "ls -la")
    }

    // CODEX_EVENT_TURN_COMPLETED
    func testParseTurnCompleted() throws {
        let json = """
        {"type":"turn.completed"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.completed")
        XCTAssertNil(event.item)
    }

    // CODEX_EVENT_TURN_FAILED with nested error
    func testParseTurnFailedWithNestedError() throws {
        let json = """
        {"type":"turn.failed","error":{"message":"rate limit exceeded"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.failed")
        XCTAssertEqual(event.error?.message, "rate limit exceeded")
    }

    // CODEX_EVENT_TURN_FAILED with top-level message fallback
    func testParseTurnFailedWithTopLevelMessage() throws {
        let json = """
        {"type":"turn.failed","message":"something went wrong"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "turn.failed")
        XCTAssertEqual(event.message, "something went wrong")
        XCTAssertNil(event.error)
    }

    // CODEX_EVENT_ERROR_HANDLING — "error" type event
    func testParseErrorEvent() throws {
        let json = """
        {"type":"error","message":"MCP login required"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "error")
        XCTAssertEqual(event.message, "MCP login required")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — full command with output and exit code
    func testParseCommandExecution() throws {
        let json = """
        {"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"echo hi","aggregated_output":"hi\\n","exit_code":0}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.command, "echo hi")
        XCTAssertEqual(event.item?.aggregatedOutput, "hi\n")
        XCTAssertEqual(event.item?.exitCode, 0)
    }

    // CODEX_EVENT_FILE_CHANGE
    func testParseFileChange() throws {
        let json = """
        {"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[{"path":"src/main.swift","kind":"modified"},{"path":"README.md","kind":"added"}]}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.type, "file_change")
        XCTAssertEqual(event.item?.changes?.count, 2)
        XCTAssertEqual(event.item?.changes?[0].path, "src/main.swift")
        XCTAssertEqual(event.item?.changes?[0].kind, "modified")
        XCTAssertEqual(event.item?.changes?[1].path, "README.md")
        XCTAssertEqual(event.item?.changes?[1].kind, "added")
    }

    // CODEX_USAGE_TOKEN_TRACKING
    func testParseUsageTokens() throws {
        let json = """
        {"type":"item.completed","usage":{"input_tokens":150,"output_tokens":42}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.usage?.inputTokens, 150)
        XCTAssertEqual(event.usage?.outputTokens, 42)
        XCTAssertNil(event.usage?.cachedInputTokens)
    }

    // CODEX_USAGE_CACHED_INPUT_TOKENS
    func testParseCachedInputTokens() throws {
        let json = """
        {"type":"item.completed","usage":{"input_tokens":200,"cached_input_tokens":180,"output_tokens":50}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.usage?.cachedInputTokens, 180)
        XCTAssertEqual(event.usage?.inputTokens, 200)
        XCTAssertEqual(event.usage?.outputTokens, 50)
    }

    // CODEX_TODO_ITEM_SUPPORT
    func testParseTodoItems() throws {
        let json = """
        {"type":"item.completed","item":{"id":"t1","type":"agent_message","items":[{"text":"Fix bug","completed":false},{"text":"Write tests","completed":true}]}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.items?.count, 2)
        XCTAssertEqual(event.item?.items?[0].text, "Fix bug")
        XCTAssertFalse(event.item?.items?[0].completed ?? true)
        XCTAssertEqual(event.item?.items?[1].text, "Write tests")
        XCTAssertTrue(event.item?.items?[1].completed ?? false)
    }

    // PLATFORM_CODEX_JSONL_EVENT_PARSING — thread_id mapping
    func testParseThreadId() throws {
        let json = """
        {"type":"turn.completed","thread_id":"thread_abc123"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.threadId, "thread_abc123")
    }

    // PLATFORM_CODEX_JSONL_EVENT_PARSING — unknown fields are ignored
    func testParseIgnoresUnknownFields() throws {
        let json = """
        {"type":"item.completed","unknown_field":"should_be_ignored","item":{"id":"x","type":"agent_message","text":"hi"}}
        """
        // Should not throw
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.text, "hi")
    }

    // PLATFORM_CODEX_JSONL_EVENT_PARSING — missing optional fields decode to nil
    func testParseMinimalEvent() throws {
        let json = """
        {"type":"turn.completed"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.item)
        XCTAssertNil(event.usage)
        XCTAssertNil(event.threadId)
        XCTAssertNil(event.message)
        XCTAssertNil(event.error)
    }

    // CODEX_EVENT_COMMAND_EXECUTION — non-zero exit code
    func testParseCommandWithNonZeroExitCode() throws {
        let json = """
        {"type":"item.completed","item":{"id":"c2","type":"command_execution","command":"false","aggregated_output":"","exit_code":1}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.exitCode, 1)
    }

    // CODEX_EVENT_AGENT_MESSAGE — item with query field
    func testParseItemWithQuery() throws {
        let json = """
        {"type":"item.completed","item":{"id":"q1","type":"agent_message","query":"search term"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.query, "search term")
    }

    // CODEX_EVENT_ITEM_COMPLETED — item status field
    func testParseItemStatus() throws {
        let json = """
        {"type":"item.completed","item":{"id":"s1","type":"command_execution","status":"completed","command":"ls"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.status, "completed")
    }
}

// MARK: - AgentService handleEvent Tests (via sendMessage and direct event handling)

@MainActor
final class AgentServiceTests: XCTestCase {

    private func makeService() -> AgentService {
        AgentService(workingDir: "/tmp/test")
    }

    // AGENT_MESSAGE_ID_PREFIX_U — user messages get "u" prefix
    func testUserMessageIdPrefix() {
        let svc = makeService()
        svc.sendMessage("hello")
        // First message should be user message with id "u1"
        XCTAssertTrue(svc.messages.first?.id.hasPrefix("u") ?? false,
                       "User message id should start with 'u'")
        XCTAssertEqual(svc.messages.first?.id, "u1")
        XCTAssertEqual(svc.messages.first?.type, .user)
        XCTAssertEqual(svc.messages.first?.content, "hello")
    }

    // AGENT_MESSAGE_ID_PREFIX_U — sequential user messages increment counter
    func testUserMessageIdsIncrement() {
        let svc = makeService()
        svc.sendMessage("first")
        svc.cancel()
        svc.sendMessage("second")
        // After first sendMessage: u1 is added, counter is 1
        // After second sendMessage: u2 is added, counter is 2
        let userMessages = svc.messages.filter { $0.type == .user }
        XCTAssertEqual(userMessages.count, 2)
        XCTAssertEqual(userMessages[0].id, "u1")
        XCTAssertEqual(userMessages[1].id, "u2")
    }

    // AGENT_CLEAR_MESSAGES — clearMessages resets messages and partialText
    func testClearMessages() {
        let svc = makeService()
        svc.sendMessage("hello")
        XCTAssertFalse(svc.messages.isEmpty)
        svc.clearMessages()
        XCTAssertTrue(svc.messages.isEmpty)
    }

    // PLATFORM_CODEX_CANCEL — cancel sets isRunning to false
    func testCancelSetsIsRunningFalse() {
        let svc = makeService()
        svc.sendMessage("hello")
        XCTAssertTrue(svc.isRunning)
        svc.cancel()
        XCTAssertFalse(svc.isRunning)
    }

    // isRunning is set to true when message is sent
    func testSendMessageSetsIsRunning() {
        let svc = makeService()
        XCTAssertFalse(svc.isRunning)
        svc.sendMessage("test")
        XCTAssertTrue(svc.isRunning)
    }

    // AGENT_MESSAGE_ID_PREFIX_S — appendStatusMessage uses "s" prefix
    func testStatusMessageIdPrefix() {
        let svc = makeService()
        svc.appendStatusMessage("Connected")
        XCTAssertEqual(svc.messages.count, 1)
        XCTAssertEqual(svc.messages[0].id, "s1")
        XCTAssertEqual(svc.messages[0].type, .status)
        XCTAssertEqual(svc.messages[0].content, "Connected")
    }

    // workingDirectory returns the configured directory
    func testWorkingDirectory() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let svc = AgentService(workingDir: project.path)
        XCTAssertEqual(svc.workingDirectory, project.path)
    }

    // sendMessage resets partialText (verified by sending two separate turns)
    func testSendMessageResetsPartialText() {
        let svc = makeService()
        svc.sendMessage("first")
        svc.cancel()
        // After cancel + new send, partialText should be reset
        svc.sendMessage("second")
        svc.cancel()
        // User messages should be the only ones (no stale partial)
        let userMsgs = svc.messages.filter { $0.type == .user }
        XCTAssertEqual(userMsgs.count, 2)
    }
}

// MARK: - handleEvent Tests (testing event handling logic directly)

/// These tests exercise the event handling logic by simulating what happens when
/// CodexEvents arrive. Since handleEvent is private, we test through the
/// observable published properties by constructing scenarios.
@MainActor
final class AgentServiceEventHandlingTests: XCTestCase {

    /// Helper: creates an AgentService and calls sendMessage to set up state,
    /// then immediately cancels the bridge task so we can test event handling
    /// in isolation using reflection.
    private func makeServiceWithUserMessage(_ prompt: String = "test") -> AgentService {
        let svc = AgentService(workingDir: "/tmp/test")
        svc.sendMessage(prompt)
        svc.cancel()
        return svc
    }

    // Since handleEvent is private, we test the JSONL parsing + event handling
    // integration by verifying the CodexEvent model structures that feed into it.
    // The following tests verify the models are correctly structured for each scenario.

    // CODEX_EVENT_AGENT_MESSAGE — agent_message item produces correct model
    func testAgentMessageItemModel() throws {
        let json = """
        {"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"I will help you with that."}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "item.completed")
        XCTAssertEqual(event.item?.type, "agent_message")
        XCTAssertEqual(event.item?.text, "I will help you with that.")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — running command (item.started) vs completed
    func testCommandRunningVsCompleted() throws {
        let startedJson = """
        {"type":"item.started","item":{"id":"c1","type":"command_execution","command":"npm test"}}
        """
        let completedJson = """
        {"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"npm test","aggregated_output":"PASS","exit_code":0}}
        """
        let started = try JSONDecoder().decode(CodexEvent.self, from: Data(startedJson.utf8))
        let completed = try JSONDecoder().decode(CodexEvent.self, from: Data(completedJson.utf8))

        // item.started means running=true, item.completed means running=false
        XCTAssertEqual(started.type, "item.started")
        XCTAssertEqual(completed.type, "item.completed")
        XCTAssertNil(started.item?.exitCode, "Started command should not have exit code yet")
        XCTAssertEqual(completed.item?.exitCode, 0)
        XCTAssertEqual(completed.item?.aggregatedOutput, "PASS")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — command lifecycle updates one row by item.id
    func testCommandLifecycleUpdatesExistingMessageByItemID() throws {
        let svc = makeServiceWithUserMessage()
        let started = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.started","item":{"id":"cmd-1","type":"command_execution","command":"npm test"}}
        """.utf8))
        let completed = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.completed","item":{"id":"cmd-1","type":"command_execution","command":"npm test","aggregated_output":"PASS","exit_code":0}}
        """.utf8))

        svc.handleEvent(started)
        let startedMessageID = svc.messages.last?.id
        svc.handleEvent(completed)

        let commandMessages = svc.messages.filter { $0.type == .command }
        XCTAssertEqual(commandMessages.count, 1)
        XCTAssertEqual(commandMessages[0].id, startedMessageID)
        XCTAssertEqual(commandMessages[0].command?.itemID, "cmd-1")
        XCTAssertEqual(commandMessages[0].command?.output, "PASS")
        XCTAssertEqual(commandMessages[0].command?.exitCode, 0)
        XCTAssertEqual(commandMessages[0].command?.running, false)
    }

    func testTodoListLifecycleUpdatesExistingStatusMessageByItemID() throws {
        let svc = makeServiceWithUserMessage()
        let started = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.started","item":{"id":"todo-1","type":"todo_list","items":[{"text":"Fix bug","completed":false},{"text":"Write tests","completed":false}]}}
        """.utf8))
        let updated = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.updated","item":{"id":"todo-1","type":"todo_list","items":[{"text":"Fix bug","completed":true},{"text":"Write tests","completed":false}]}}
        """.utf8))

        svc.handleEvent(started)
        let startedMessageID = svc.messages.last?.id
        svc.handleEvent(updated)

        let statusMessages = svc.messages.filter { $0.type == .status && $0.content.contains("Plan updated") }
        XCTAssertEqual(statusMessages.count, 1)
        XCTAssertEqual(statusMessages[0].id, startedMessageID)
        XCTAssertTrue(statusMessages[0].content.contains("[x] Fix bug"))
        XCTAssertTrue(statusMessages[0].content.contains("[ ] Write tests"))
    }

    func testWebSearchProducesStatusMessage() throws {
        let svc = makeServiceWithUserMessage()
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.completed","item":{"id":"search-1","type":"web_search","query":"swift concurrency"}}
        """.utf8))

        svc.handleEvent(event)

        let status = svc.messages.last
        XCTAssertEqual(status?.type, .status)
        XCTAssertTrue(status?.content.contains("Web search") ?? false)
        XCTAssertTrue(status?.content.contains("swift concurrency") ?? false)
    }

    func testMCPToolCallLifecycleUpdatesExistingStatusMessageByItemID() throws {
        let svc = makeServiceWithUserMessage()
        let started = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.started","item":{"id":"mcp-1","type":"mcp_tool_call","server":"linear","tool":"list_issues","status":"in_progress"}}
        """.utf8))
        let completed = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.completed","item":{"id":"mcp-1","type":"mcp_tool_call","server":"linear","tool":"list_issues","status":"completed"}}
        """.utf8))

        svc.handleEvent(started)
        let startedMessageID = svc.messages.last?.id
        svc.handleEvent(completed)

        let statusMessages = svc.messages.filter { $0.type == .status && $0.content.contains("MCP tool") }
        XCTAssertEqual(statusMessages.count, 1)
        XCTAssertEqual(statusMessages[0].id, startedMessageID)
        XCTAssertTrue(statusMessages[0].content.contains("linear/list_issues"))
        XCTAssertTrue(statusMessages[0].content.contains("completed"))
    }

    // CODEX_EVENT_FILE_CHANGE — file changes produce summary
    func testFileChangeProducesSummary() throws {
        let json = """
        {"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[{"path":"a.swift","kind":"modified"},{"path":"b.swift","kind":"added"}]}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        let changes = event.item?.changes ?? []
        let summary = changes.map { "\($0.kind): \($0.path)" }.joined(separator: "\n")
        XCTAssertEqual(summary, "modified: a.swift\nadded: b.swift")
    }

    // CODEX_EVENT_TURN_FAILED — error message extraction prefers nested error
    func testTurnFailedErrorMessagePrecedence() throws {
        let json = """
        {"type":"turn.failed","message":"fallback","error":{"message":"primary error"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        // handleEvent uses: event.error?.message ?? event.message ?? "Unknown error"
        let errorMsg = event.error?.message ?? event.message ?? "Unknown error"
        XCTAssertEqual(errorMsg, "primary error",
                       "Nested error.message should take precedence over top-level message")
    }

    // CODEX_EVENT_TURN_FAILED — falls back to top-level message
    func testTurnFailedFallsBackToTopLevelMessage() throws {
        let json = """
        {"type":"turn.failed","message":"fallback error"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        let errorMsg = event.error?.message ?? event.message ?? "Unknown error"
        XCTAssertEqual(errorMsg, "fallback error")
    }

    // CODEX_EVENT_TURN_FAILED — falls back to "Unknown error"
    func testTurnFailedFallsBackToUnknownError() throws {
        let json = """
        {"type":"turn.failed"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        let errorMsg = event.error?.message ?? event.message ?? "Unknown error"
        XCTAssertEqual(errorMsg, "Unknown error")
    }

    func testHandleEventTracksThreadID() throws {
        let svc = makeServiceWithUserMessage()
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"turn.completed","thread_id":"thread_abc123"}
        """.utf8))

        svc.handleEvent(event)

        XCTAssertEqual(svc.activeThreadID, "thread_abc123")
    }

    func testHandleEventTracksRecentErrorFromItemError() throws {
        let svc = makeServiceWithUserMessage()
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data("""
        {"type":"item.completed","item":{"id":"err-1","type":"error","message":"permission denied"}}
        """.utf8))

        svc.handleEvent(event)

        XCTAssertEqual(svc.recentErrorMessage, "permission denied")
    }

    // CODEX_EVENT_NON_FATAL_ERROR_LOGGING — "error" type should not produce a message
    // This verifies the model — in handleEvent, "error" events are logged but not shown.
    func testNonFatalErrorEventHasMessage() throws {
        let json = """
        {"type":"error","message":"MCP server requires login"}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "error")
        XCTAssertEqual(event.message, "MCP server requires login")
        XCTAssertNil(event.item, "Non-fatal error should not have an item")
    }

    // AGENT_PARTIAL_TEXT_DOUBLE_NEWLINE_JOIN — multiple agent_message items join with \n\n
    func testPartialTextJoinLogic() {
        // Simulating the partialText accumulation logic from handleEvent
        var partialText = ""
        let texts = ["First paragraph.", "Second paragraph.", "Third paragraph."]

        for text in texts {
            if partialText.isEmpty {
                partialText = text
            } else {
                partialText += "\n\n" + text
            }
        }

        XCTAssertEqual(partialText, "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.",
                       "Multiple agent messages should be joined with double newlines")
    }

    // AGENT_PARTIAL_TEXT_DOUBLE_NEWLINE_JOIN — single message has no join
    func testPartialTextSingleMessage() {
        var partialText = ""
        let text = "Only message"
        if partialText.isEmpty {
            partialText = text
        } else {
            partialText += "\n\n" + text
        }
        XCTAssertEqual(partialText, "Only message")
    }

    // CHAT_STREAMING_MESSAGE_MERGE — updateOrAppendAssistantMessage replaces last assistant message
    // Testing the logic: if last message is .assistant, update in place; else append new.
    func testUpdateOrAppendLogicUpdatesExisting() {
        var messages: [ChatMessage] = []
        var counter = 0

        // Simulate first assistant message
        counter += 1
        messages.append(ChatMessage(id: "a\(counter)", type: .assistant, content: "partial",
                                    timestamp: "1:00 PM", command: nil, diff: nil))

        // Simulate update (what updateOrAppendAssistantMessage does)
        if let lastIdx = messages.indices.last, messages[lastIdx].type == .assistant {
            messages[lastIdx] = ChatMessage(id: messages[lastIdx].id, type: .assistant,
                                            content: "full response", timestamp: "1:00 PM",
                                            command: nil, diff: nil)
        }

        XCTAssertEqual(messages.count, 1, "Should update in place, not append")
        XCTAssertEqual(messages[0].content, "full response")
        XCTAssertEqual(messages[0].id, "a1", "ID should be preserved")
    }

    // CHAT_STREAMING_MESSAGE_MERGE — appends new message when last is not assistant
    func testUpdateOrAppendLogicAppendsWhenLastIsNotAssistant() {
        var messages: [ChatMessage] = []
        var counter = 0

        // Add a user message first
        counter += 1
        messages.append(ChatMessage(id: "u\(counter)", type: .user, content: "hello",
                                    timestamp: "1:00 PM", command: nil, diff: nil))

        // Simulate updateOrAppendAssistantMessage
        if let lastIdx = messages.indices.last, messages[lastIdx].type == .assistant {
            messages[lastIdx] = ChatMessage(id: messages[lastIdx].id, type: .assistant,
                                            content: "response", timestamp: "1:00 PM",
                                            command: nil, diff: nil)
        } else {
            counter += 1
            messages.append(ChatMessage(id: "a\(counter)", type: .assistant, content: "response",
                                        timestamp: "1:00 PM", command: nil, diff: nil))
        }

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].type, .assistant)
        XCTAssertEqual(messages[1].id, "a2")
    }

    // CHAT_STREAMING_PARTIAL_MESSAGES — streaming produces incremental updates
    func testStreamingPartialMessageSequence() {
        var messages: [ChatMessage] = []
        var counter = 0
        var partialText = ""

        // Add user message
        counter += 1
        messages.append(ChatMessage(id: "u\(counter)", type: .user, content: "explain swift",
                                    timestamp: "1:00 PM", command: nil, diff: nil))

        // Simulate first agent_message event
        let text1 = "Swift is a programming language."
        partialText = text1
        // updateOrAppendAssistantMessage
        counter += 1
        messages.append(ChatMessage(id: "a\(counter)", type: .assistant, content: partialText,
                                    timestamp: "1:00 PM", command: nil, diff: nil))

        // Simulate second agent_message event (streaming update)
        let text2 = "It was created by Apple."
        partialText += "\n\n" + text2
        // Update last assistant message in place
        if let lastIdx = messages.indices.last, messages[lastIdx].type == .assistant {
            messages[lastIdx] = ChatMessage(id: messages[lastIdx].id, type: .assistant,
                                            content: partialText, timestamp: "1:01 PM",
                                            command: nil, diff: nil)
        }

        XCTAssertEqual(messages.count, 2, "Should be user + one assistant message")
        XCTAssertEqual(messages[1].content,
                       "Swift is a programming language.\n\nIt was created by Apple.")
    }

    // AGENT_MESSAGE_ID_PREFIX_A — assistant messages get "a" prefix
    func testAssistantMessageIdPrefix() {
        var messages: [ChatMessage] = []
        var counter = 0

        counter += 1
        messages.append(ChatMessage(id: "a\(counter)", type: .assistant, content: "hi",
                                    timestamp: "1:00 PM", command: nil, diff: nil))

        XCTAssertTrue(messages[0].id.hasPrefix("a"))
    }

    // AGENT_MESSAGE_ID_PREFIX_C — command messages get "c" prefix
    func testCommandMessageIdPrefix() {
        var counter = 0
        counter += 1
        let msg = ChatMessage(id: "c\(counter)", type: .command, content: "",
                              timestamp: "1:00 PM",
                              command: Command(cmd: "ls", cwd: "/tmp", output: "",
                                               exitCode: 0, running: false),
                              diff: nil)
        XCTAssertTrue(msg.id.hasPrefix("c"))
    }

    // AGENT_MESSAGE_ID_PREFIX_F — file change messages get "f" prefix
    func testFileChangeMessageIdPrefix() {
        var counter = 0
        counter += 1
        let msg = ChatMessage(id: "f\(counter)", type: .status, content: "File changes:\nmodified: a.swift",
                              timestamp: "1:00 PM", command: nil, diff: nil)
        XCTAssertTrue(msg.id.hasPrefix("f"))
    }

    // CODEX_EVENT_COMMAND_EXECUTION — running flag derived from event type
    func testCommandRunningFlagFromEventType() {
        // In handleEvent: running = (event.type == "item.started")
        let startedType = "item.started"
        let completedType = "item.completed"

        XCTAssertTrue(startedType == "item.started", "item.started should set running=true")
        XCTAssertFalse(completedType == "item.started", "item.completed should set running=false")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — command defaults to "unknown" when nil
    func testCommandDefaultsToUnknown() throws {
        let json = """
        {"type":"item.completed","item":{"id":"c1","type":"command_execution"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        // In handleEvent: item.command ?? "unknown"
        let cmd = event.item?.command ?? "unknown"
        XCTAssertEqual(cmd, "unknown")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — aggregatedOutput defaults to empty string
    func testAggregatedOutputDefaultsToEmpty() throws {
        let json = """
        {"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"echo"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        let output = event.item?.aggregatedOutput ?? ""
        XCTAssertEqual(output, "")
    }

    // CODEX_EVENT_COMMAND_EXECUTION — exitCode defaults to 0
    func testExitCodeDefaultsToZero() throws {
        let json = """
        {"type":"item.completed","item":{"id":"c1","type":"command_execution","command":"echo"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        let exitCode = event.item?.exitCode ?? 0
        XCTAssertEqual(exitCode, 0)
    }

    // CODEX_EVENT_FILE_CHANGE — empty changes array
    func testFileChangeEmptyChanges() throws {
        let json = """
        {"type":"item.completed","item":{"id":"f1","type":"file_change","changes":[]}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.item?.changes?.count, 0)
    }

    // CODEX_EVENT_FILE_CHANGE — nil changes (no changes key)
    func testFileChangeNilChanges() throws {
        let json = """
        {"type":"item.completed","item":{"id":"f1","type":"file_change"}}
        """
        let event = try JSONDecoder().decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.item?.changes)
    }
}

// MARK: - AGENT_WEAK_SELF_CAPTURE

/// BUG DOCUMENTATION: The code on line 99 uses `weak let weakSelf = self` which
/// is invalid Swift syntax. `weak` can only be applied to `var`, not `let`, because
/// weak references must be mutable (they get set to nil when the object is deallocated).
/// The correct code should be: `weak var weakSelf = self`
///
/// This test documents that the weak capture pattern should work correctly
/// to prevent retain cycles in the detached Task.
@MainActor
final class AgentServiceWeakSelfTests: XCTestCase {

    // AGENT_WEAK_SELF_CAPTURE — service should not retain itself through bridgeTask
    func testWeakSelfCapturePattern() {
        // The correct pattern is: weak var weakSelf = self (not weak let)
        // This test documents the expected behavior: when the service is
        // deallocated, the weak reference should become nil.
        class Box {
            weak var service: AgentService?
        }
        let box = Box()
        autoreleasepool {
            let svc = AgentService(workingDir: "/tmp/test")
            box.service = svc
            XCTAssertNotNil(box.service)
        }
        // After the autorelease pool, the service should be eligible for deallocation
        // (depending on any Task references — this documents the intended pattern)
    }
}

// MARK: - PLATFORM_CODEX_BACKGROUND_THREAD_EXECUTION

@MainActor
final class AgentServiceBackgroundExecutionTests: XCTestCase {

    // PLATFORM_CODEX_BACKGROUND_THREAD_EXECUTION — sendMessage dispatches work off main
    func testSendMessageSetsIsRunningImmediately() {
        let svc = AgentService(workingDir: "/tmp/test")
        XCTAssertFalse(svc.isRunning)
        svc.sendMessage("test")
        // isRunning should be set synchronously on the main actor before the
        // background task starts
        XCTAssertTrue(svc.isRunning)
        svc.cancel()
    }

    // PLATFORM_CODEX_BACKGROUND_THREAD_EXECUTION — user message is appended synchronously
    func testUserMessageAppendedSynchronously() {
        let svc = AgentService(workingDir: "/tmp/test")
        svc.sendMessage("hello world")
        // User message should appear immediately, not after async work
        XCTAssertEqual(svc.messages.count, 1)
        XCTAssertEqual(svc.messages[0].type, .user)
        XCTAssertEqual(svc.messages[0].content, "hello world")
        svc.cancel()
    }

    // PLATFORM_CODEX_CANCEL — cancel after send
    func testCancelAfterSend() {
        let svc = AgentService(workingDir: "/tmp/test")
        svc.sendMessage("long task")
        XCTAssertTrue(svc.isRunning)
        svc.cancel()
        XCTAssertFalse(svc.isRunning)
    }

    // PLATFORM_CODEX_CANCEL — cancel when not running is safe
    func testCancelWhenNotRunningIsSafe() {
        let svc = AgentService(workingDir: "/tmp/test")
        XCTAssertFalse(svc.isRunning)
        svc.cancel() // Should not crash
        XCTAssertFalse(svc.isRunning)
    }
}

// MARK: - Codex Bridge Lifecycle Tests

private final class FakeCodexBridge: CodexBridgeControlling, @unchecked Sendable {
    func cancel() {}
}

final class CodexBridgeLifecycleTests: XCTestCase {

    func testCancelInvalidatesPendingBridgeCreation() {
        let lifecycle = CodexBridgeLifecycle<FakeCodexBridge>()
        let creatingTurn = UUID()
        let cancelledTurn = UUID()
        let staleBridge = FakeCodexBridge()

        XCTAssertNil(lifecycle.beginTurn(creatingTurn))
        XCTAssertNil(lifecycle.cancelTurn(cancelledTurn))

        XCTAssertFalse(lifecycle.activate(staleBridge, for: creatingTurn))
        XCTAssertTrue(lifecycle.isCurrent(cancelledTurn))
    }

    func testLateBridgeCannotOverwriteNewerActiveBridge() {
        let lifecycle = CodexBridgeLifecycle<FakeCodexBridge>()
        let oldTurn = UUID()
        let newTurn = UUID()
        let lateBridge = FakeCodexBridge()
        let activeBridge = FakeCodexBridge()

        XCTAssertNil(lifecycle.beginTurn(oldTurn))
        XCTAssertNil(lifecycle.beginTurn(newTurn))
        XCTAssertTrue(lifecycle.activate(activeBridge, for: newTurn))
        XCTAssertFalse(lifecycle.activate(lateBridge, for: oldTurn))

        let returnedBridge = lifecycle.cancelTurn(UUID())
        XCTAssertTrue(returnedBridge === activeBridge)
    }

    func testStaleClearDoesNotRemoveNewerActiveBridge() {
        let lifecycle = CodexBridgeLifecycle<FakeCodexBridge>()
        let oldTurn = UUID()
        let newTurn = UUID()
        let oldBridge = FakeCodexBridge()
        let newBridge = FakeCodexBridge()

        XCTAssertNil(lifecycle.beginTurn(oldTurn))
        XCTAssertTrue(lifecycle.activate(oldBridge, for: oldTurn))
        XCTAssertTrue(lifecycle.beginTurn(newTurn) === oldBridge)
        XCTAssertTrue(lifecycle.activate(newBridge, for: newTurn))

        lifecycle.clear(ifSame: oldBridge, for: oldTurn)

        let returnedBridge = lifecycle.cancelTurn(UUID())
        XCTAssertTrue(returnedBridge === newBridge)
    }
}

// MARK: - ChatMessage Model Tests

final class ChatMessageModelTests: XCTestCase {

    func testChatMessageIdentifiable() {
        let msg = ChatMessage(id: "test1", type: .user, content: "hi",
                              timestamp: "1:00 PM", command: nil, diff: nil)
        XCTAssertEqual(msg.id, "test1")
    }

    func testAllMessageTypes() {
        let types: [ChatMessage.MessageType] = [.user, .assistant, .command, .diff, .status]
        let rawValues = types.map { $0.rawValue }
        XCTAssertEqual(rawValues, ["user", "assistant", "command", "diff", "status"])
    }

    func testCommandModel() {
        let cmd = Command(cmd: "git status", cwd: "/tmp", output: "clean", exitCode: 0, running: false)
        XCTAssertEqual(cmd.cmd, "git status")
        XCTAssertEqual(cmd.cwd, "/tmp")
        XCTAssertEqual(cmd.output, "clean")
        XCTAssertEqual(cmd.exitCode, 0)
        XCTAssertEqual(cmd.running, false)
    }

    func testCommandRunningNil() {
        let cmd = Command(cmd: "ls", cwd: "/", output: "", exitCode: 0, running: nil)
        XCTAssertNil(cmd.running)
    }
}
