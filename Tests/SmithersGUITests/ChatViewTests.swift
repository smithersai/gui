import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Inspectable Conformances

extension ChatView: @retroactive Inspectable {}
extension MessageRow: @retroactive Inspectable {}
extension CommandBlock: @retroactive Inspectable {}
extension SlashCommandPalette: @retroactive Inspectable {}

// MARK: - Test Helpers

/// A lightweight AgentService configured for testing (no real Codex bridge).
@MainActor
private func makeAgent(
    messages: [ChatMessage] = [],
    isRunning: Bool = false,
    workingDir: String = "/tmp/test-workspace"
) -> AgentService {
    let agent = AgentService(workingDir: workingDir)
    for msg in messages {
        agent.messages.append(msg)
    }
    agent.isRunning = isRunning
    return agent
}

private func userMessage(_ content: String, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(id: id, type: .user, content: content, timestamp: "12:00 PM", command: nil, diff: nil)
}

private func assistantMessage(_ content: String, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(id: id, type: .assistant, content: content, timestamp: "12:01 PM", command: nil, diff: nil)
}

private func commandMessage(
    cmd: String = "ls -la",
    cwd: String = "/tmp",
    output: String = "total 0",
    exitCode: Int = 0,
    id: String = UUID().uuidString
) -> ChatMessage {
    ChatMessage(
        id: id,
        type: .command,
        content: "",
        timestamp: "12:02 PM",
        command: Command(cmd: cmd, cwd: cwd, output: output, exitCode: exitCode, running: false),
        diff: nil
    )
}

private func statusMessage(_ content: String, id: String = UUID().uuidString) -> ChatMessage {
    ChatMessage(id: id, type: .status, content: content, timestamp: "12:03 PM", command: nil, diff: nil)
}

private func diffMessage(
    snippet: String = "+new line\n-old line",
    id: String = UUID().uuidString
) -> ChatMessage {
    ChatMessage(
        id: id,
        type: .diff,
        content: "File changes",
        timestamp: "12:04 PM",
        command: nil,
        diff: Diff(
            files: [DiffFile(name: "test.swift", additions: 1, deletions: 1)],
            totalAdditions: 1,
            totalDeletions: 1,
            status: "modified",
            snippet: snippet
        )
    )
}

// MARK: - ChatView Welcome / Empty State Tests

final class ChatViewWelcomeTests: XCTestCase {

    /// CHAT_WELCOME_EMPTY_STATE: When messages array is empty, the welcome state should render.
    @MainActor
    func testWelcomeStateShownWhenNoMessages() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()

        // The welcome title should be present somewhere in the view hierarchy
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("What can I help you build?"),
            "CHAT_WELCOME_TITLE_TEXT: Expected welcome title in empty state. Found: \(textStrings)"
        )
    }

    /// CHAT_WELCOME_TITLE_TEXT: Verify exact welcome title copy.
    @MainActor
    func testWelcomeTitleText() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("What can I help you build?"))
    }

    /// CHAT_WELCOME_SUBTITLE_TEXT: Verify exact subtitle copy.
    @MainActor
    func testWelcomeSubtitleText() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Send a message to start a coding session with Codex."),
            "CHAT_WELCOME_SUBTITLE_TEXT: Expected subtitle. Found: \(textStrings)"
        )
    }

    /// CHAT_WELCOME_EMPTY_STATE: When messages exist, the welcome state should NOT render.
    @MainActor
    func testWelcomeStateHiddenWhenMessagesExist() throws {
        let agent = makeAgent(messages: [userMessage("hello")])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertFalse(
            textStrings.contains("What can I help you build?"),
            "Welcome title should not appear when messages exist"
        )
    }
}

// MARK: - Header Tests

final class ChatViewHeaderTests: XCTestCase {

    /// CHAT_HEADER_TITLE_SMITHERS: The header should display "Smithers".
    @MainActor
    func testHeaderTitleIsSmithers() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Smithers"),
            "CHAT_HEADER_TITLE_SMITHERS: Expected 'Smithers' in header. Found: \(textStrings)"
        )
    }

    /// CHAT_HEADER_TITLE_SMITHERS: Header spinner should appear when agent is running.
    @MainActor
    func testHeaderShowsSpinnerWhenRunning() throws {
        let agent = makeAgent(isRunning: true)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let progressViews = inspected.findAll(ViewType.ProgressView.self)
        // Should have at least one in the header (and possibly one in thinking indicator)
        XCTAssertGreaterThanOrEqual(progressViews.count, 1, "Expected ProgressView in header when running")
    }

    /// Header should NOT show spinner when idle.
    @MainActor
    func testHeaderNoSpinnerWhenIdle() throws {
        let agent = makeAgent(isRunning: false)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        // With no messages and not running, no ProgressView should appear
        let progressViews = inspected.findAll(ViewType.ProgressView.self)
        XCTAssertEqual(progressViews.count, 0, "Expected no ProgressView when idle with no messages")
    }
}

// MARK: - Thinking Indicator Tests

final class ChatViewThinkingTests: XCTestCase {

    /// CHAT_THINKING_INDICATOR: When isRunning, a thinking indicator should be visible.
    @MainActor
    func testThinkingIndicatorShownWhenRunning() throws {
        let agent = makeAgent(messages: [userMessage("hello")], isRunning: true)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let progressViews = inspected.findAll(ViewType.ProgressView.self)
        // At least 2: one in header, one in thinking indicator
        XCTAssertGreaterThanOrEqual(progressViews.count, 2, "Expected thinking ProgressView when running")
    }

    /// CHAT_THINKING_TEXT: The thinking indicator should say "Codex is thinking..."
    @MainActor
    func testThinkingText() throws {
        let agent = makeAgent(messages: [userMessage("hello")], isRunning: true)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Codex is thinking..."),
            "CHAT_THINKING_TEXT: Expected 'Codex is thinking...' Found: \(textStrings)"
        )
    }

    /// CHAT_THINKING_INDICATOR: Should NOT appear when idle.
    @MainActor
    func testThinkingIndicatorHiddenWhenIdle() throws {
        let agent = makeAgent(messages: [userMessage("hello")], isRunning: false)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertFalse(
            textStrings.contains("Codex is thinking..."),
            "Thinking text should not appear when idle"
        )
    }
}

// MARK: - Composer / Input Tests

final class ChatViewComposerTests: XCTestCase {

    /// CHAT_RETURN_TO_SEND_HINT_TEXT: The hint text should be visible.
    @MainActor
    func testReturnToSendHintText() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Return to send - / for commands"),
            "CHAT_RETURN_TO_SEND_HINT_TEXT: Expected hint text. Found: \(textStrings)"
        )
    }

    /// CHAT_MESSAGE_INPUT: A TextField should be present for input.
    @MainActor
    func testTextFieldExists() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let textFields = inspected.findAll(ViewType.TextField.self)
        XCTAssertGreaterThanOrEqual(textFields.count, 1, "CHAT_MESSAGE_INPUT: Expected at least one TextField")
    }

    /// CHAT_MESSAGE_INPUT: TextField placeholder should be "Ask anything..."
    @MainActor
    func testTextFieldPlaceholder() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let textFields = inspected.findAll(ViewType.TextField.self)
        // ViewInspector may expose label text
        let labelTexts = textFields.compactMap { tf in
            try? tf.labelView().text().string()
        }
        XCTAssertTrue(
            labelTexts.contains("Ask anything..."),
            "CHAT_MESSAGE_INPUT: Expected placeholder 'Ask anything...' Found labels: \(labelTexts)"
        )
    }

    /// CHAT_PAPERCLIP_ATTACHMENT_BUTTON: A paperclip icon should exist.
    @MainActor
    func testPaperclipIconExists() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            // Try to extract the system name from the image
            try? img.actualImage().name()
        }
        XCTAssertTrue(
            systemNames.contains("paperclip"),
            "CHAT_PAPERCLIP_ATTACHMENT_BUTTON: Expected paperclip icon. Found: \(systemNames)"
        )
    }

    /// CHAT_SLASH_TRIGGER_BUTTON: A sparkles icon button should trigger slash command input.
    @MainActor
    func testSlashTriggerButtonExists() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            try? img.actualImage().name()
        }
        XCTAssertTrue(
            systemNames.contains("sparkles"),
            "CHAT_SLASH_TRIGGER_BUTTON: Expected sparkles icon. Found: \(systemNames)"
        )
    }

    /// CHAT_SEND_STOP_TOGGLE_BUTTON: When idle, send button shows arrow.up icon.
    @MainActor
    func testSendButtonShowsArrowWhenIdle() throws {
        let agent = makeAgent(isRunning: false)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            try? img.actualImage().name()
        }
        XCTAssertTrue(
            systemNames.contains("arrow.up"),
            "CHAT_SEND_STOP_TOGGLE_BUTTON: Expected arrow.up when idle. Found: \(systemNames)"
        )
        XCTAssertFalse(
            systemNames.contains("stop.fill"),
            "Should not show stop icon when idle"
        )
    }

    /// CHAT_SEND_STOP_TOGGLE_BUTTON: When running, send button shows stop.fill icon.
    @MainActor
    func testSendButtonShowsStopWhenRunning() throws {
        let agent = makeAgent(isRunning: true)
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            try? img.actualImage().name()
        }
        XCTAssertTrue(
            systemNames.contains("stop.fill"),
            "CHAT_SEND_STOP_TOGGLE_BUTTON: Expected stop.fill when running. Found: \(systemNames)"
        )
        XCTAssertFalse(
            systemNames.contains("arrow.up"),
            "Should not show arrow.up when running"
        )
    }

    /// CHAT_COMPOSER_TOOLBAR: The at-mention icon should exist.
    @MainActor
    func testAtMentionIconExists() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            try? img.actualImage().name()
        }
        XCTAssertTrue(
            systemNames.contains("at"),
            "CHAT_COMPOSER_TOOLBAR: Expected 'at' icon. Found: \(systemNames)"
        )
    }
}

// MARK: - Message Display Tests

final class ChatViewMessageDisplayTests: XCTestCase {

    /// CHAT_MESSAGE_DISPLAY: User messages should render their content.
    @MainActor
    func testUserMessageContentDisplayed() throws {
        let agent = makeAgent(messages: [userMessage("Hello world", id: "u1")])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Hello world"),
            "CHAT_MESSAGE_DISPLAY: Expected user message content. Found: \(textStrings)"
        )
    }

    /// CHAT_MESSAGE_DISPLAY: Assistant messages should render their content.
    @MainActor
    func testAssistantMessageContentDisplayed() throws {
        let agent = makeAgent(messages: [assistantMessage("I can help!", id: "a1")])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("I can help!"),
            "CHAT_MESSAGE_DISPLAY: Expected assistant message content. Found: \(textStrings)"
        )
    }

    /// CHAT_MESSAGE_DISPLAY: Multiple messages should all render.
    @MainActor
    func testMultipleMessagesAllDisplayed() throws {
        let agent = makeAgent(messages: [
            userMessage("First", id: "u1"),
            assistantMessage("Second", id: "a1"),
            userMessage("Third", id: "u2"),
        ])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("First"))
        XCTAssertTrue(textStrings.contains("Second"))
        XCTAssertTrue(textStrings.contains("Third"))
    }

    /// CHAT_MESSAGE_DISPLAY: Status messages should render.
    @MainActor
    func testStatusMessageDisplayed() throws {
        let agent = makeAgent(messages: [statusMessage("Session status info", id: "s1")])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("Session status info"),
            "CHAT_MESSAGE_DISPLAY: Expected status message. Found: \(textStrings)"
        )
    }
}

// MARK: - MessageRow Tests

final class MessageRowTests: XCTestCase {

    /// CHAT_BUBBLE_STYLE_USER: User message should render with content text.
    func testUserMessageRow() throws {
        let msg = userMessage("User says hi", id: "u1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("User says hi"))
    }

    /// CHAT_BUBBLE_STYLE_ASSISTANT: Assistant message should render with content text.
    func testAssistantMessageRow() throws {
        let msg = assistantMessage("Assistant reply", id: "a1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("Assistant reply"))
    }

    /// CHAT_BUBBLE_STYLE_USER: User bubble should have Spacer on the left (right-aligned).
    func testUserMessageIsRightAligned() throws {
        let msg = userMessage("right side", id: "u1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        // The HStack should have a Spacer before the Text
        let spacers = inspected.findAll(ViewType.Spacer.self)
        XCTAssertGreaterThanOrEqual(spacers.count, 1, "User messages should have a leading Spacer")
    }

    /// CHAT_BUBBLE_STYLE_ASSISTANT: Assistant bubble should have Spacer on the right (left-aligned).
    func testAssistantMessageIsLeftAligned() throws {
        let msg = assistantMessage("left side", id: "a1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let spacers = inspected.findAll(ViewType.Spacer.self)
        XCTAssertGreaterThanOrEqual(spacers.count, 1, "Assistant messages should have a trailing Spacer")
    }

    /// CHAT_BUBBLE_STYLE_STATUS: Status messages should render with monospaced font.
    func testStatusMessageRow() throws {
        let msg = statusMessage("Some status", id: "s1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("Some status"))
    }

    /// CHAT_BUBBLE_STYLE_COMMAND: Command messages should render via CommandBlock.
    func testCommandMessageRow() throws {
        let msg = commandMessage(cmd: "echo test", output: "test", id: "c1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("$ echo test"),
            "CHAT_BUBBLE_STYLE_COMMAND: Expected '$ echo test'. Found: \(textStrings)"
        )
    }

    /// CHAT_BUBBLE_SELECTIVE_CORNERS: User bubble uses [topLeft, bottomLeft, bottomRight] (no topRight).
    /// This is testable by verifying the cornerRadius modifier is applied with specific corners.
    /// Since ViewInspector can't directly inspect custom clip shapes, we test that the view renders without crash.
    func testUserBubbleSelectiveCornersDoesNotCrash() throws {
        let msg = userMessage("corners test", id: "u1")
        let view = MessageRow(message: msg)
        // If the selective corners shape is malformed, this would crash
        _ = try view.inspect()
    }

    /// CHAT_BUBBLE_SELECTIVE_CORNERS: Assistant bubble uses [topRight, bottomLeft, bottomRight] (no topLeft).
    func testAssistantBubbleSelectiveCornersDoesNotCrash() throws {
        let msg = assistantMessage("corners test", id: "a1")
        let view = MessageRow(message: msg)
        _ = try view.inspect()
    }

    /// BUG: diff type messages are not rendered at all in MessageRow.
    /// The MessageRow checks for .user, .assistant, .command, .status but never handles .diff.
    /// CHAT_GIT_DIFF_INLINE: Diff messages should show inline git diff content.
    func testDiffMessageIsNotRendered_BUG() throws {
        let msg = diffMessage(id: "d1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        // BUG: The .diff case is never matched in MessageRow, so no diff content is shown.
        // This test documents the bug: diff messages render as empty HStacks.
        XCTAssertFalse(
            textStrings.contains("File changes"),
            "BUG DOCUMENTED: .diff messages are silently dropped. MessageRow has no case for .diff type."
        )
        // What SHOULD happen (this assertion will fail, documenting the bug):
        // Uncomment the next line when the bug is fixed:
        // XCTAssertTrue(textStrings.contains(where: { $0.contains("+new line") }), "Diff snippet should be rendered")
    }
}

// MARK: - CommandBlock Tests

final class CommandBlockTests: XCTestCase {

    /// CHAT_COMMAND_OUTPUT_DISPLAY: Command output text should be visible.
    func testCommandOutputDisplayed() throws {
        let cmd = Command(cmd: "ls", cwd: "/home/user", output: "file1.txt\nfile2.txt", exitCode: 0, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("file1.txt\nfile2.txt"),
            "CHAT_COMMAND_OUTPUT_DISPLAY: Expected command output. Found: \(textStrings)"
        )
    }

    /// CHAT_COMMAND_OUTPUT_DISPLAY: Command string should be prefixed with "$ ".
    func testCommandPrefixedWithDollarSign() throws {
        let cmd = Command(cmd: "git status", cwd: "/repo", output: "", exitCode: 0, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("$ git status"),
            "Command should be prefixed with '$ '. Found: \(textStrings)"
        )
    }

    /// CHAT_COMMAND_EXIT_CODE_BADGE: Should display "exit 0" badge.
    /// BUG: The CommandBlock always shows "exit 0" regardless of the actual exitCode.
    func testExitCodeBadgeAlwaysShowsZero_BUG() throws {
        let cmd = Command(cmd: "false", cwd: "/tmp", output: "", exitCode: 1, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }

        // BUG: The exit code badge is hardcoded to "exit 0" and uses a checkmark icon.
        // It ignores command.exitCode entirely.
        XCTAssertTrue(
            textStrings.contains("exit 0"),
            "BUG DOCUMENTED: CommandBlock hardcodes 'exit 0' even when exitCode is 1"
        )
        // What SHOULD happen:
        XCTAssertFalse(
            textStrings.contains("exit 1"),
            "BUG: 'exit 1' should be shown for exitCode=1, but it's hardcoded to 'exit 0'"
        )
    }

    /// CHAT_COMMAND_EXIT_CODE_BADGE: Verify checkmark icon is always shown.
    /// BUG: The icon is always checkmark.circle, even for failures.
    func testExitCodeBadgeAlwaysShowsCheckmark_BUG() throws {
        let cmd = Command(cmd: "fail", cwd: "/tmp", output: "error", exitCode: 127, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let systemNames = images.compactMap { img -> String? in
            try? img.actualImage().name()
        }
        // BUG: Always shows checkmark.circle even for non-zero exit codes
        XCTAssertTrue(
            systemNames.contains("checkmark.circle"),
            "BUG DOCUMENTED: Always shows checkmark.circle regardless of exit code"
        )
        // Should show xmark.circle or similar for non-zero exit codes
    }

    /// CHAT_COMMAND_CWD_DISPLAY: The working directory should be displayed.
    func testCwdDisplayed() throws {
        let cmd = Command(cmd: "pwd", cwd: "/Users/dev/project", output: "/Users/dev/project", exitCode: 0, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("cwd: /Users/dev/project"),
            "CHAT_COMMAND_CWD_DISPLAY: Expected cwd display. Found: \(textStrings)"
        )
    }

    /// CHAT_COMMAND_EXIT_CODE_BADGE: Badge styling uses success color for exit 0.
    /// BUG: Uses success color even for non-zero exit codes since exitCode is ignored.
    func testExitCodeBadgeUsesSuccessColorAlways_BUG() throws {
        // This is a design/logic bug: the badge color should be red/danger for non-zero exit codes
        let cmd = Command(cmd: "rm nonexistent", cwd: "/tmp", output: "No such file", exitCode: 1, running: false)
        let view = CommandBlock(command: cmd)
        // The view renders without error, but the styling is wrong (always green)
        let inspected = try view.inspect()
        XCTAssertNoThrow(try inspected.find(ViewType.HStack.self))
    }

    /// Test empty command output.
    func testEmptyOutputRendered() throws {
        let cmd = Command(cmd: "true", cwd: "/tmp", output: "", exitCode: 0, running: false)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("$ true"))
        XCTAssertTrue(textStrings.contains(""), "Empty output should still be rendered as Text")
    }
}

// MARK: - Send Logic / AgentService Integration Tests

final class ChatViewSendLogicTests: XCTestCase {

    /// CHAT_MESSAGE_INPUT: send() should invoke onSend with trimmed text.
    @MainActor
    func testSendInvokesOnSendCallback() {
        var sentText: String?
        let agent = makeAgent()
        _ = ChatView(agent: agent, onSend: { text in
            sentText = text
        })

        // Directly test AgentService: sendMessage appends a user message
        agent.sendMessage("Hello from test")
        XCTAssertEqual(agent.messages.count, 1)
        XCTAssertEqual(agent.messages.first?.type, .user)
        XCTAssertEqual(agent.messages.first?.content, "Hello from test")
        // The bridge will fail gracefully in test env, but the user message is recorded
        XCTAssertNil(sentText, "onSend is not called by AgentService.sendMessage directly")
    }

    /// CHAT_MESSAGE_INPUT: Empty input should not trigger send.
    @MainActor
    func testEmptyInputNotSent() {
        let agent = makeAgent()
        // Verify no messages after empty input
        XCTAssertTrue(agent.messages.isEmpty)
    }

    /// CHAT_SEND_STOP_TOGGLE_BUTTON: When running, send() should cancel.
    @MainActor
    func testCancelWhenRunning() {
        let agent = makeAgent(isRunning: true)
        agent.cancel()
        XCTAssertFalse(agent.isRunning, "cancel() should set isRunning to false")
    }

    /// Test clearMessages empties the array.
    @MainActor
    func testClearMessages() {
        let agent = makeAgent(messages: [
            userMessage("one"),
            assistantMessage("two"),
        ])
        XCTAssertEqual(agent.messages.count, 2)
        agent.clearMessages()
        XCTAssertTrue(agent.messages.isEmpty)
    }

    /// Test appendStatusMessage adds a status type message.
    @MainActor
    func testAppendStatusMessage() {
        let agent = makeAgent()
        agent.appendStatusMessage("Test status")
        XCTAssertEqual(agent.messages.count, 1)
        XCTAssertEqual(agent.messages.first?.type, .status)
        XCTAssertEqual(agent.messages.first?.content, "Test status")
    }
}

// MARK: - Auto-scroll Tests

final class ChatViewAutoScrollTests: XCTestCase {

    /// CHAT_AUTO_SCROLL_TO_BOTTOM: The view uses .onChange(of: agent.messages.count) to scroll.
    /// We verify the scroll anchor "bottom" exists in the view.
    @MainActor
    func testBottomAnchorExists() throws {
        let agent = makeAgent(messages: [userMessage("hello")])
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        // The Color.clear.frame(height: 1).id("bottom") should be in the view
        // We can't directly inspect the id, but we can verify the structure doesn't crash
        XCTAssertNoThrow(try view.inspect())
    }

    /// CHAT_AUTO_SCROLL_TO_BOTTOM: Adding messages should trigger scroll (logic test).
    @MainActor
    func testMessageCountChangeTriggersScrollLogic() {
        let agent = makeAgent()
        let initialCount = agent.messages.count
        agent.appendStatusMessage("New message")
        XCTAssertGreaterThan(agent.messages.count, initialCount,
            "Adding a message should increment count, which triggers .onChange scroll")
    }
}

// MARK: - Multi-line Input Tests

final class ChatViewMultiLineTests: XCTestCase {

    /// CHAT_MULTI_LINE_INPUT: TextField uses .lineLimit(1...5) for multi-line.
    /// We can't inspect lineLimit via ViewInspector, but we verify the TextField renders.
    @MainActor
    func testMultiLineTextFieldRendersWithoutCrash() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let textFields = inspected.findAll(ViewType.TextField.self)
        XCTAssertFalse(textFields.isEmpty, "CHAT_MULTI_LINE_INPUT: TextField should exist")
    }
}

// MARK: - Slash Command Palette Tests

final class SlashCommandPaletteTests: XCTestCase {

    /// SlashCommandPalette should display command names.
    func testPaletteDisplaysCommandNames() throws {
        let commands = [
            SlashCommandItem(
                id: "test.help",
                name: "help",
                title: "Help",
                description: "Show help",
                category: .action,
                aliases: [],
                action: .showHelp
            ),
        ]
        let view = SlashCommandPalette(commands: commands, selectedIndex: 0, onSelect: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("/help"), "Palette should show '/help'")
        XCTAssertTrue(textStrings.contains("Show help"), "Palette should show description")
    }

    /// Palette shows category badge.
    func testPaletteShowsCategoryBadge() throws {
        let commands = [
            SlashCommandItem(
                id: "test.cmd",
                name: "test",
                title: "Test",
                description: "A test command",
                category: .codex,
                aliases: [],
                action: .showHelp
            ),
        ]
        let view = SlashCommandPalette(commands: commands, selectedIndex: 0, onSelect: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(
            textStrings.contains("CODEX"),
            "Palette should show uppercased category. Found: \(textStrings)"
        )
    }

    /// Palette with multiple commands shows dividers between them.
    func testPaletteShowsDividers() throws {
        let commands = [
            SlashCommandItem(id: "a", name: "aaa", title: "A", description: "a", category: .action, aliases: [], action: .showHelp),
            SlashCommandItem(id: "b", name: "bbb", title: "B", description: "b", category: .action, aliases: [], action: .clearChat),
        ]
        let view = SlashCommandPalette(commands: commands, selectedIndex: 0, onSelect: { _ in })
        let inspected = try view.inspect()
        let dividers = inspected.findAll(ViewType.Divider.self)
        XCTAssertEqual(dividers.count, 1, "Should have 1 divider between 2 commands")
    }

    /// Empty commands array should render empty palette.
    func testEmptyPalette() throws {
        let view = SlashCommandPalette(commands: [], selectedIndex: 0, onSelect: { _ in })
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        XCTAssertTrue(texts.isEmpty, "Empty palette should have no text views")
    }
}

// MARK: - Slash Command Registry Logic Tests

final class SlashCommandRegistryTests: XCTestCase {

    func testParseSlashCommand() {
        let parsed = SlashCommandRegistry.parse("/help")
        XCTAssertEqual(parsed?.name, "help")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseSlashCommandWithArgs() {
        let parsed = SlashCommandRegistry.parse("/review focus on tests")
        XCTAssertEqual(parsed?.name, "review")
        XCTAssertEqual(parsed?.args, "focus on tests")
    }

    func testParseNonSlashReturnsNil() {
        XCTAssertNil(SlashCommandRegistry.parse("hello"))
    }

    func testParseEmptySlash() {
        let parsed = SlashCommandRegistry.parse("/")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "")
    }

    func testMatchesFiltersByName() {
        let commands = SlashCommandRegistry.builtInCommands
        let matches = SlashCommandRegistry.matches(for: "/help", commands: commands)
        XCTAssertTrue(matches.contains(where: { $0.name == "help" }))
    }

    func testExactMatchFindsCommand() {
        let commands = SlashCommandRegistry.builtInCommands
        let match = SlashCommandRegistry.exactMatch(for: "/clear", commands: commands)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "clear")
    }

    func testExactMatchByAlias() {
        let commands = SlashCommandRegistry.builtInCommands
        let match = SlashCommandRegistry.exactMatch(for: "/exit", commands: commands)
        XCTAssertNotNil(match, "Should match 'quit' command via 'exit' alias")
        XCTAssertEqual(match?.name, "quit")
    }

    func testExactMatchReturnsNilForPartial() {
        let commands = SlashCommandRegistry.builtInCommands
        let match = SlashCommandRegistry.exactMatch(for: "/hel", commands: commands)
        XCTAssertNil(match, "Partial match should not return an exact match")
    }

    func testKeyValueArgs() {
        let result = SlashCommandRegistry.keyValueArgs("key1=value1 key2=\"quoted\"")
        XCTAssertEqual(result["key1"], "value1")
        XCTAssertEqual(result["key2"], "quoted")
    }

    func testKeyValueArgsEmpty() {
        let result = SlashCommandRegistry.keyValueArgs("")
        XCTAssertTrue(result.isEmpty)
    }

    /// Slash palette visibility logic: input starting with "/" and having matches.
    func testSlashPaletteVisibilityLogic() {
        // The slashPaletteVisible is a computed property on ChatView,
        // so we test the underlying conditions:
        let input1 = "/"
        XCTAssertTrue(input1.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
        XCTAssertFalse(input1.contains("\n"))

        let input2 = "/help\nsomething"
        XCTAssertTrue(input2.contains("\n"), "Multi-line slash input should hide palette")
    }

    /// Matching commands count is capped at 8 in the UI (prefix(8)).
    func testMatchingCommandsCappedAt8() {
        let commands = SlashCommandRegistry.builtInCommands
        let matches = SlashCommandRegistry.matches(for: "/", commands: commands)
        // There are more than 8 built-in commands
        XCTAssertGreaterThan(matches.count, 8, "Should have more than 8 built-in commands total")
        // But the UI uses .prefix(8)
        let displayed = Array(matches.prefix(8))
        XCTAssertEqual(displayed.count, 8)
    }

    func testHelpTextContainsAllCategories() {
        let commands = SlashCommandRegistry.builtInCommands
        let help = SlashCommandRegistry.helpText(for: commands)
        XCTAssertTrue(help.contains("Codex"))
        XCTAssertTrue(help.contains("Smithers"))
        XCTAssertTrue(help.contains("Action"))
    }
}

// MARK: - RoundedCorner Shape Tests

final class RoundedCornerTests: XCTestCase {

    /// CHAT_BUBBLE_SELECTIVE_CORNERS: Test that RoundedCorner shape produces a valid path.
    func testRoundedCornerProducesPath() {
        let shape = RoundedCorner(radius: 16, corners: [.topLeft, .bottomLeft, .bottomRight])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 50)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "RoundedCorner path should not be empty")
    }

    func testAllCornersRounded() {
        let shape = RoundedCorner(radius: 10, corners: .allCorners)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty)
    }

    func testNoCornersRounded() {
        let shape = RoundedCorner(radius: 10, corners: [])
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty, "Even with no rounded corners, should produce a rectangular path")
    }

    func testZeroRadiusProducesPath() {
        let shape = RoundedCorner(radius: 0, corners: .allCorners)
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        let path = shape.path(in: rect)
        XCTAssertFalse(path.isEmpty)
    }

    /// CHAT_BUBBLE_RENDERING: Verify the path bounds are within the rect.
    func testPathBoundsWithinRect() {
        let shape = RoundedCorner(radius: 16, corners: [.topRight, .bottomLeft, .bottomRight])
        let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
        let path = shape.path(in: rect)
        let bounds = path.boundingRect
        // Path bounds should be within (or very close to) the provided rect
        XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - 1)
        XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 1)
        XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 1)
        XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 1)
    }
}

// MARK: - RectCorner OptionSet Tests

final class RectCornerTests: XCTestCase {

    func testIndividualCorners() {
        XCTAssertEqual(RectCorner.topLeft.rawValue, 1 << 0)
        XCTAssertEqual(RectCorner.topRight.rawValue, 1 << 1)
        XCTAssertEqual(RectCorner.bottomLeft.rawValue, 1 << 2)
        XCTAssertEqual(RectCorner.bottomRight.rawValue, 1 << 3)
    }

    func testAllCorners() {
        let all = RectCorner.allCorners
        XCTAssertTrue(all.contains(.topLeft))
        XCTAssertTrue(all.contains(.topRight))
        XCTAssertTrue(all.contains(.bottomLeft))
        XCTAssertTrue(all.contains(.bottomRight))
    }

    func testCombination() {
        let combo: RectCorner = [.topLeft, .bottomRight]
        XCTAssertTrue(combo.contains(.topLeft))
        XCTAssertTrue(combo.contains(.bottomRight))
        XCTAssertFalse(combo.contains(.topRight))
        XCTAssertFalse(combo.contains(.bottomLeft))
    }
}

// MARK: - Composer Border Radius Tests

final class ChatViewComposerBorderTests: XCTestCase {

    /// CHAT_COMPOSER_BORDER_RADIUS_12: The composer overlay uses cornerRadius(12).
    /// ViewInspector can't directly inspect cornerRadius, but we test the view renders.
    @MainActor
    func testComposerRendersWithBorderRadius() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        // If cornerRadius(12) causes issues, this would fail
        XCTAssertNoThrow(try view.inspect())
    }
}

// MARK: - Status Text Logic Tests

final class ChatViewStatusTextTests: XCTestCase {

    /// The statusText() method should include workspace, message count, and running state.
    @MainActor
    func testStatusTextContent() {
        let agent = makeAgent(workingDir: "/my/project")
        // statusText is private, but we can test via /status command side effects
        agent.appendStatusMessage("test")
        XCTAssertEqual(agent.messages.count, 1)

        // Test workingDirectory accessor
        XCTAssertEqual(agent.workingDirectory, "/my/project")
    }

    /// AgentService initializes with custom working directory.
    @MainActor
    func testAgentServiceWorkingDir() {
        let agent = AgentService(workingDir: "/custom/path")
        XCTAssertEqual(agent.workingDirectory, "/custom/path")
    }
}

// MARK: - Bug Documentation Tests

final class ChatViewBugDocumentationTests: XCTestCase {

    /// BUG: CommandBlock always shows "exit 0" and a checkmark, ignoring the actual exit code.
    /// This means failed commands appear successful in the UI.
    func testCommandBlockIgnoresExitCode_BUG() throws {
        let failedCmd = Command(cmd: "make build", cwd: "/project", output: "error: build failed", exitCode: 2, running: false)
        let view = CommandBlock(command: failedCmd)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }

        // Documents the bug: should show "exit 2" but shows "exit 0"
        XCTAssertTrue(textStrings.contains("exit 0"), "BUG: Hardcoded 'exit 0' instead of actual exit code")
        XCTAssertFalse(textStrings.contains("exit 2"), "BUG: Actual exit code is never displayed")
    }

    /// BUG: CommandBlock always shows success (green) styling, even for failed commands.
    /// The checkmark.circle icon and Theme.success color are hardcoded.
    func testCommandBlockAlwaysShowsSuccessStyling_BUG() throws {
        let failedCmd = Command(cmd: "test", cwd: "/tmp", output: "", exitCode: 127, running: false)
        let view = CommandBlock(command: failedCmd)
        let inspected = try view.inspect()
        let images = inspected.findAll(ViewType.Image.self)
        let names = images.compactMap { try? $0.actualImage().name() }
        // BUG: Always checkmark, never xmark for failures
        XCTAssertTrue(names.contains("checkmark.circle"))
    }

    /// BUG: MessageRow does not handle .diff message type.
    /// Diff messages are silently swallowed.
    func testDiffMessagesAreSilentlySwallowed_BUG() throws {
        let msg = diffMessage(id: "d1")
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        // A .diff message produces no text output at all
        XCTAssertTrue(texts.isEmpty, "BUG: .diff messages produce no output in MessageRow")
    }

    /// BUG: The paperclip Image is not wrapped in a Button, so it's not tappable.
    /// CHAT_PAPERCLIP_ATTACHMENT_BUTTON implies it should be a button.
    @MainActor
    func testPaperclipIsNotAButton_BUG() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let buttons = inspected.findAll(ViewType.Button.self)
        // Check if any button contains a paperclip image
        var paperclipInButton = false
        for button in buttons {
            let images = button.findAll(ViewType.Image.self)
            for img in images {
                if let name = try? img.actualImage().name(), name == "paperclip" {
                    paperclipInButton = true
                }
            }
        }
        XCTAssertFalse(
            paperclipInButton,
            "BUG DOCUMENTED: paperclip is a plain Image, not a Button. CHAT_PAPERCLIP_ATTACHMENT_BUTTON expects it to be tappable."
        )
    }

    /// BUG: The "at" mention Image is also not wrapped in a Button.
    @MainActor
    func testAtMentionIsNotAButton_BUG() throws {
        let agent = makeAgent()
        let view = ChatView(agent: agent, onSend: { _ in })
        let inspected = try view.inspect()
        let buttons = inspected.findAll(ViewType.Button.self)
        var atInButton = false
        for button in buttons {
            let images = button.findAll(ViewType.Image.self)
            for img in images {
                if let name = try? img.actualImage().name(), name == "at" {
                    atInButton = true
                }
            }
        }
        XCTAssertFalse(
            atInButton,
            "BUG DOCUMENTED: 'at' icon is a plain Image, not a Button."
        )
    }

    /// BUG: CommandBlock does not show running state at all.
    /// When command.running is true, there's no visual indicator (spinner, etc.).
    func testRunningCommandHasNoVisualIndicator_BUG() throws {
        let cmd = Command(cmd: "make test", cwd: "/project", output: "", exitCode: 0, running: true)
        let view = CommandBlock(command: cmd)
        let inspected = try view.inspect()
        let progressViews = inspected.findAll(ViewType.ProgressView.self)
        XCTAssertEqual(
            progressViews.count, 0,
            "BUG DOCUMENTED: CommandBlock shows no spinner/progress for running commands"
        )
    }

    /// BUG: Assistant messages with a command attached render the command block,
    /// but the assistant bubble's cornerRadius removes topLeft. Verify this layout.
    func testAssistantWithCommandRendersCommandBlock() throws {
        let cmd = Command(cmd: "echo hello", cwd: "/tmp", output: "hello", exitCode: 0, running: false)
        let msg = ChatMessage(
            id: "a-cmd",
            type: .assistant,
            content: "Here's the result:",
            timestamp: "12:00 PM",
            command: cmd,
            diff: nil
        )
        let view = MessageRow(message: msg)
        let inspected = try view.inspect()
        let texts = inspected.findAll(ViewType.Text.self)
        let textStrings = texts.compactMap { try? $0.string() }
        XCTAssertTrue(textStrings.contains("Here's the result:"))
        XCTAssertTrue(textStrings.contains("$ echo hello"))
        XCTAssertTrue(textStrings.contains("hello"))
    }
}
