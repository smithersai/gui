import XCTest
@testable import SmithersGUI

final class ChatSessionTests: XCTestCase {

    // MARK: - Initialization

    func testInitAllFields() {
        let session = ChatSession(id: "s1", title: "Title", preview: "Preview text", timestamp: "2026-04-14", group: "Today")
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.title, "Title")
        XCTAssertEqual(session.preview, "Preview text")
        XCTAssertEqual(session.timestamp, "2026-04-14")
        XCTAssertEqual(session.group, "Today")
    }

    func testEmptyStrings() {
        let session = ChatSession(id: "", title: "", preview: "", timestamp: "", group: "")
        XCTAssertEqual(session.id, "")
        XCTAssertEqual(session.title, "")
    }

    // MARK: - Identifiable

    func testIdentifiable() {
        let session = ChatSession(id: "abc", title: "", preview: "", timestamp: "", group: "")
        XCTAssertEqual(session.id, "abc")
    }

    // MARK: - Hashable

    func testHashableEqualSessions() {
        let a = ChatSession(id: "1", title: "T", preview: "P", timestamp: "TS", group: "G")
        let b = ChatSession(id: "1", title: "T", preview: "P", timestamp: "TS", group: "G")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testHashableDifferentSessions() {
        let a = ChatSession(id: "1", title: "T", preview: "P", timestamp: "TS", group: "G")
        let b = ChatSession(id: "2", title: "T", preview: "P", timestamp: "TS", group: "G")
        XCTAssertNotEqual(a, b)
    }

    func testUsableInSet() {
        let a = ChatSession(id: "1", title: "A", preview: "", timestamp: "", group: "")
        let b = ChatSession(id: "2", title: "B", preview: "", timestamp: "", group: "")
        let c = ChatSession(id: "1", title: "A", preview: "", timestamp: "", group: "")
        let set: Set<ChatSession> = [a, b, c]
        XCTAssertEqual(set.count, 2)
    }
}

// MARK: - ChatMessage Tests

final class ChatMessageTests: XCTestCase {

    // MARK: - MessageType enum (MODEL_CHAT_BLOCK_ROLE_SYSTEM_ASSISTANT_USER)

    func testMessageTypeRawValues() {
        XCTAssertEqual(ChatMessage.MessageType.user.rawValue, "user")
        XCTAssertEqual(ChatMessage.MessageType.assistant.rawValue, "assistant")
        XCTAssertEqual(ChatMessage.MessageType.command.rawValue, "command")
        XCTAssertEqual(ChatMessage.MessageType.diff.rawValue, "diff")
        XCTAssertEqual(ChatMessage.MessageType.status.rawValue, "status")
    }

    /// CHAT_MESSAGE_TYPES_USER_ASSISTANT_COMMAND_STATUS_DIFF
    func testAllMessageTypesFromRawValue() {
        XCTAssertNotNil(ChatMessage.MessageType(rawValue: "user"))
        XCTAssertNotNil(ChatMessage.MessageType(rawValue: "assistant"))
        XCTAssertNotNil(ChatMessage.MessageType(rawValue: "command"))
        XCTAssertNotNil(ChatMessage.MessageType(rawValue: "diff"))
        XCTAssertNotNil(ChatMessage.MessageType(rawValue: "status"))
    }

    func testInvalidMessageTypeReturnsNil() {
        XCTAssertNil(ChatMessage.MessageType(rawValue: "system"))
        XCTAssertNil(ChatMessage.MessageType(rawValue: ""))
        XCTAssertNil(ChatMessage.MessageType(rawValue: "User"))
    }

    // MARK: - Initialization with all fields

    func testInitWithCommandAndDiff() {
        let cmd = Command(cmd: "ls", cwd: "/tmp", output: "file.txt", exitCode: 0, running: false)
        let diff = Diff(files: [], totalAdditions: 0, totalDeletions: 0, status: "clean", snippet: "")
        let msg = ChatMessage(id: "m1", type: .command, content: "ran ls", timestamp: "now", command: cmd, diff: diff)
        XCTAssertEqual(msg.id, "m1")
        XCTAssertEqual(msg.type, .command)
        XCTAssertEqual(msg.content, "ran ls")
        XCTAssertNotNil(msg.command)
        XCTAssertNotNil(msg.diff)
    }

    func testInitWithNilOptionals() {
        let msg = ChatMessage(id: "m2", type: .user, content: "hello", timestamp: "t", command: nil, diff: nil)
        XCTAssertNil(msg.command)
        XCTAssertNil(msg.diff)
    }

    // MARK: - MODEL_CHAT_BLOCK_FALLBACK_ID

    /// Verifies that an empty-string id is allowed (fallback id scenario).
    func testEmptyIdAsFallback() {
        let msg = ChatMessage(id: "", type: .status, content: "", timestamp: "", command: nil, diff: nil)
        XCTAssertEqual(msg.id, "")
    }

    // MARK: - Identifiable

    func testIdentifiable() {
        let msg = ChatMessage(id: "unique", type: .assistant, content: "", timestamp: "", command: nil, diff: nil)
        XCTAssertEqual(msg.id, "unique")
    }
}

// MARK: - Command Tests

final class CommandTests: XCTestCase {

    func testInitAllFields() {
        let cmd = Command(cmd: "echo hi", cwd: "/home", output: "hi\n", exitCode: 0, running: true)
        XCTAssertEqual(cmd.cmd, "echo hi")
        XCTAssertEqual(cmd.cwd, "/home")
        XCTAssertEqual(cmd.output, "hi\n")
        XCTAssertEqual(cmd.exitCode, 0)
        XCTAssertEqual(cmd.running, true)
    }

    /// MODEL_COMMAND_RUNNING_STATE: running can be nil, true, or false.
    func testRunningNil() {
        let cmd = Command(cmd: "", cwd: "", output: "", exitCode: 0, running: nil)
        XCTAssertNil(cmd.running)
    }

    func testRunningTrue() {
        let cmd = Command(cmd: "make", cwd: ".", output: "", exitCode: -1, running: true)
        XCTAssertEqual(cmd.running, true)
    }

    func testRunningFalse() {
        let cmd = Command(cmd: "make", cwd: ".", output: "done", exitCode: 0, running: false)
        XCTAssertEqual(cmd.running, false)
    }

    func testNonZeroExitCode() {
        let cmd = Command(cmd: "false", cwd: "/tmp", output: "", exitCode: 1, running: false)
        XCTAssertEqual(cmd.exitCode, 1)
    }

    func testNegativeExitCode() {
        let cmd = Command(cmd: "kill", cwd: "/", output: "", exitCode: -9, running: false)
        XCTAssertEqual(cmd.exitCode, -9)
    }

    func testEmptyCommand() {
        let cmd = Command(cmd: "", cwd: "", output: "", exitCode: 0, running: nil)
        XCTAssertEqual(cmd.cmd, "")
    }
}

// MARK: - Diff Tests

final class DiffTests: XCTestCase {

    /// MODEL_DIFF_WITH_PER_FILE_STATS
    func testDiffWithFiles() {
        let files = [
            DiffFile(name: "a.swift", additions: 10, deletions: 2),
            DiffFile(name: "b.swift", additions: 0, deletions: 5),
        ]
        let diff = Diff(files: files, totalAdditions: 10, totalDeletions: 7, status: "modified", snippet: "+foo\n-bar")
        XCTAssertEqual(diff.files.count, 2)
        XCTAssertEqual(diff.totalAdditions, 10)
        XCTAssertEqual(diff.totalDeletions, 7)
        XCTAssertEqual(diff.status, "modified")
        XCTAssertEqual(diff.snippet, "+foo\n-bar")
    }

    func testDiffEmptyFiles() {
        let diff = Diff(files: [], totalAdditions: 0, totalDeletions: 0, status: "", snippet: "")
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertEqual(diff.totalAdditions, 0)
        XCTAssertEqual(diff.totalDeletions, 0)
    }

    func testZeroAdditionsAndDeletions() {
        let diff = Diff(files: [], totalAdditions: 0, totalDeletions: 0, status: "clean", snippet: "")
        XCTAssertEqual(diff.totalAdditions, 0)
        XCTAssertEqual(diff.totalDeletions, 0)
    }

    /// BUG DOCUMENTATION: totalAdditions/totalDeletions are not computed from files array.
    /// The model allows inconsistent totals vs. per-file sums. This test documents the behavior.
    func testTotalsCanBeInconsistentWithFileStats() {
        let files = [DiffFile(name: "x.swift", additions: 5, deletions: 3)]
        let diff = Diff(files: files, totalAdditions: 999, totalDeletions: 0, status: "", snippet: "")
        // totals are stored as-is, not validated against file sums
        XCTAssertEqual(diff.totalAdditions, 999)
        XCTAssertEqual(diff.totalDeletions, 0)
        XCTAssertEqual(diff.files[0].additions, 5)
    }
}

// MARK: - DiffFile Tests

final class DiffFileTests: XCTestCase {

    func testInit() {
        let f = DiffFile(name: "README.md", additions: 3, deletions: 1)
        XCTAssertEqual(f.name, "README.md")
        XCTAssertEqual(f.additions, 3)
        XCTAssertEqual(f.deletions, 1)
    }

    func testZeroStats() {
        let f = DiffFile(name: "", additions: 0, deletions: 0)
        XCTAssertEqual(f.name, "")
        XCTAssertEqual(f.additions, 0)
        XCTAssertEqual(f.deletions, 0)
    }
}

// MARK: - Agent Tests

final class AgentTests: XCTestCase {

    // MARK: - AgentStatus enum (MODEL_AGENT_WITH_STATUS)

    func testAgentStatusRawValues() {
        XCTAssertEqual(Agent.AgentStatus.idle.rawValue, "idle")
        XCTAssertEqual(Agent.AgentStatus.working.rawValue, "working")
        XCTAssertEqual(Agent.AgentStatus.completed.rawValue, "completed")
        XCTAssertEqual(Agent.AgentStatus.failed.rawValue, "failed")
    }

    func testAgentStatusFromRawValue() {
        XCTAssertEqual(Agent.AgentStatus(rawValue: "idle"), .idle)
        XCTAssertEqual(Agent.AgentStatus(rawValue: "working"), .working)
        XCTAssertEqual(Agent.AgentStatus(rawValue: "completed"), .completed)
        XCTAssertEqual(Agent.AgentStatus(rawValue: "failed"), .failed)
    }

    func testAgentStatusInvalidRawValue() {
        XCTAssertNil(Agent.AgentStatus(rawValue: ""))
        XCTAssertNil(Agent.AgentStatus(rawValue: "running"))
        XCTAssertNil(Agent.AgentStatus(rawValue: "Idle"))
    }

    // MARK: - Initialization

    func testInitAllFields() {
        let agent = Agent(id: "a1", name: "Builder", status: .working, task: "Build project", changes: 42)
        XCTAssertEqual(agent.id, "a1")
        XCTAssertEqual(agent.name, "Builder")
        XCTAssertEqual(agent.status, .working)
        XCTAssertEqual(agent.task, "Build project")
        XCTAssertEqual(agent.changes, 42)
    }

    func testZeroChanges() {
        let agent = Agent(id: "a2", name: "", status: .idle, task: "", changes: 0)
        XCTAssertEqual(agent.changes, 0)
    }

    // MARK: - Identifiable

    func testIdentifiable() {
        let agent = Agent(id: "xyz", name: "A", status: .completed, task: "", changes: 0)
        XCTAssertEqual(agent.id, "xyz")
    }
}

// MARK: - JJChange Tests

final class JJChangeTests: XCTestCase {

    /// JJChange derives its id from the file property.
    func testIdDerivedFromFile() {
        let change = JJChange(file: "src/main.swift", status: "modified", additions: 5, deletions: 2)
        XCTAssertEqual(change.id, "src/main.swift")
        XCTAssertEqual(change.id, change.file)
    }

    func testInitAllFields() {
        let change = JJChange(file: "test.txt", status: "added", additions: 10, deletions: 0)
        XCTAssertEqual(change.file, "test.txt")
        XCTAssertEqual(change.status, "added")
        XCTAssertEqual(change.additions, 10)
        XCTAssertEqual(change.deletions, 0)
    }

    func testEmptyFile() {
        let change = JJChange(file: "", status: "", additions: 0, deletions: 0)
        XCTAssertEqual(change.id, "")
        XCTAssertEqual(change.file, "")
    }

    /// BUG DOCUMENTATION: Two JJChange values with the same file path will have the same id,
    /// which can cause SwiftUI List/ForEach rendering issues if both appear in the same collection.
    func testDuplicateFilesMeanDuplicateIds() {
        let a = JJChange(file: "dup.swift", status: "added", additions: 1, deletions: 0)
        let b = JJChange(file: "dup.swift", status: "deleted", additions: 0, deletions: 1)
        XCTAssertEqual(a.id, b.id, "Two JJChange with same file have same id -- potential SwiftUI bug")
    }
}
