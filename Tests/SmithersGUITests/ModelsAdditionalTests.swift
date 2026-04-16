import XCTest
@testable import SmithersGUI

// MARK: - SidebarTabKind Tests

final class SidebarTabKindTests: XCTestCase {

    func testChatIcon() {
        XCTAssertEqual(SidebarTabKind.chat.icon, "message")
    }

    func testRunIcon() {
        XCTAssertEqual(SidebarTabKind.run.icon, "dot.radiowaves.left.and.right")
    }

    func testHashable() {
        let set: Set<SidebarTabKind> = [.chat, .run, .chat]
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - RunTab Tests

final class RunTabTests: XCTestCase {

    func testIdIsRunId() {
        let tab = RunTab(runId: "r123", title: "Test", preview: "Preview", timestamp: Date(), createdAt: Date())
        XCTAssertEqual(tab.id, "r123")
    }

    func testHashable() {
        let a = RunTab(runId: "r1", title: "A", preview: "Pa", timestamp: Date(), createdAt: Date())
        let b = RunTab(runId: "r2", title: "B", preview: "Pb", timestamp: Date(), createdAt: Date())
        let set: Set = [a, b, a]
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - ChatMessage Tests

final class ChatMessageTypeTests: XCTestCase {

    func testMessageTypeRawValues() {
        XCTAssertEqual(ChatMessage.MessageType.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.MessageType.assistant.rawValue, "assistant")
        XCTAssertEqual(ChatMessage.MessageType.command.rawValue, "command")
        XCTAssertEqual(ChatMessage.MessageType.diff.rawValue, "diff")
        XCTAssertEqual(ChatMessage.MessageType.status.rawValue, "status")
    }
}

// MARK: - Deduplication Tests

final class DeduplicationTests: XCTestCase {

    private func msg(id: String, type: ChatMessage.MessageType = .command, content: String = "", itemID: String? = nil) -> ChatMessage {
        ChatMessage(
            id: id,
            type: type,
            content: content,
            timestamp: "",
            command: itemID.map { Command(itemID: $0, cmd: "ls", cwd: "/", output: "", exitCode: 0, running: nil) },
            diff: nil
        )
    }

    func testNoDuplication() {
        let messages = [
            msg(id: "1", type: .user, content: "hi"),
            msg(id: "2", type: .assistant, content: "hello"),
        ]
        XCTAssertEqual(deduplicatedChatMessages(messages).count, 2)
    }

    func testDuplicateCommandsDeduped() {
        let messages = [
            msg(id: "1", itemID: "cmd1"),
            msg(id: "2", itemID: "cmd1"),
        ]
        let result = deduplicatedChatMessages(messages)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "2") // Last one wins
    }

    func testNilItemIDNotDeduped() {
        let messages = [
            msg(id: "1", itemID: nil),
            msg(id: "2", itemID: nil),
        ]
        XCTAssertEqual(deduplicatedChatMessages(messages).count, 2)
    }

    func testEmptyItemIDNotDeduped() {
        let messages = [
            msg(id: "1", itemID: ""),
            msg(id: "2", itemID: ""),
        ]
        XCTAssertEqual(deduplicatedChatMessages(messages).count, 2)
    }

    func testMixedMessagesPreserveOrder() {
        let messages = [
            msg(id: "1", type: .user, content: "hi"),
            msg(id: "2", itemID: "cmd1"),
            msg(id: "3", type: .assistant, content: "done"),
            msg(id: "4", itemID: "cmd1"),
        ]
        let result = deduplicatedChatMessages(messages)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].id, "1")
        XCTAssertEqual(result[1].id, "4") // Updated in place
        XCTAssertEqual(result[2].id, "3")
    }

    func testEmptyInput() {
        XCTAssertTrue(deduplicatedChatMessages([]).isEmpty)
    }
}

// MARK: - Diff / DiffFile Tests

final class DiffModelTests: XCTestCase {

    func testDiffInit() {
        let d = Diff(files: [DiffFile(name: "a.swift", additions: 5, deletions: 2)],
                     totalAdditions: 5, totalDeletions: 2, status: "changed", snippet: "+hello")
        XCTAssertEqual(d.files.count, 1)
        XCTAssertEqual(d.totalAdditions, 5)
    }
}

// MARK: - Agent Tests

final class AgentModelTests: XCTestCase {

    func testAgentStatusRawValues() {
        XCTAssertEqual(Agent.AgentStatus.idle.rawValue, "idle")
        XCTAssertEqual(Agent.AgentStatus.working.rawValue, "working")
        XCTAssertEqual(Agent.AgentStatus.completed.rawValue, "completed")
        XCTAssertEqual(Agent.AgentStatus.failed.rawValue, "failed")
    }

    func testAgentIdentifiable() {
        let a = Agent(id: "a1", name: "Agent1", status: .idle, task: "none", changes: 0)
        XCTAssertEqual(a.id, "a1")
    }
}

// MARK: - JJChange Tests

final class JJChangeAdditionalTests: XCTestCase {

    func testIdIncludesStatusAndFile() {
        let c = JJChange(file: "src/main.swift", status: "M", additions: 10, deletions: 5)
        XCTAssertEqual(c.id, "M:src/main.swift")
    }
}

// MARK: - ChatSession Tests

final class ChatSessionModelTests: XCTestCase {

    func testHashable() {
        let a = ChatSession(id: "s1", title: "T", preview: "P", timestamp: "now", group: "Today")
        let b = ChatSession(id: "s2", title: "T2", preview: "P2", timestamp: "now", group: "Today")
        let set: Set = [a, b, a]
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - SidebarTab Tests

final class SidebarTabTests: XCTestCase {

    func testSidebarTabHashable() {
        let a = SidebarTab(id: "t1", kind: .chat, chatSessionId: "c1", runId: nil, terminalId: nil,
                           title: "Chat", preview: "Hi", timestamp: "now", group: "Today", sortDate: Date())
        let b = SidebarTab(id: "t2", kind: .run, chatSessionId: nil, runId: "r1", terminalId: nil,
                           title: "Run", preview: "...", timestamp: "now", group: "Today", sortDate: Date())
        let set: Set = [a, b]
        XCTAssertEqual(set.count, 2)
    }
}
