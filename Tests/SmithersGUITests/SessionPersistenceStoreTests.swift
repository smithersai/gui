import XCTest
@testable import SmithersGUI

final class SQLiteSessionPersistenceDirectTests: XCTestCase {
    private func requireSQLite3() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SQLiteSessionPersistence.sqliteBinaryPath)
        process.arguments = ["--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw XCTSkip("sqlite3 is required for SQLiteSessionPersistence tests")
        }

        guard process.terminationStatus == 0 else {
            throw XCTSkip("sqlite3 is required for SQLiteSessionPersistence tests")
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-session-persistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCreateLoadAndUpdateMessage() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        try persistence.createSession(id: "session-1", title: "Custom title")
        try persistence.createMessage(sessionID: "session-1", messageID: "message-1", role: .user, text: "Original")
        try persistence.updateMessage(messageID: "message-1", role: .assistant, text: "Edited response")

        let messages = try persistence.loadMessages(sessionID: "session-1")
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "message-1")
        XCTAssertEqual(messages.first?.role, .assistant)
        XCTAssertEqual(messages.first?.text, "Edited response")

        let summaries = try persistence.loadSessions()
        XCTAssertEqual(summaries.first?.id, "session-1")
        XCTAssertEqual(summaries.first?.title, "Custom title")
        XCTAssertEqual(summaries.first?.preview, "Edited response")
    }

    func testDefaultSessionTitleIsGeneratedFromFirstUserMessage() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        try persistence.createSession(id: "session-1", title: SessionStore.defaultChatTitle)
        try persistence.createMessage(
            sessionID: "session-1",
            messageID: "message-1",
            role: .user,
            text: "please name this chat"
        )

        let summary = try XCTUnwrap(persistence.loadSessions().first)
        XCTAssertEqual(summary.title, "name this chat")
        XCTAssertEqual(summary.preview, "please name this chat")
    }

    func testBlankPersistedMessagesAreNotLoaded() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        try persistence.createSession(id: "session-1", title: "Blank message session")
        try persistence.createMessage(sessionID: "session-1", messageID: "blank", role: .user, text: " \n\t ")

        XCTAssertTrue(try persistence.loadMessages(sessionID: "session-1").isEmpty)
        XCTAssertEqual(try persistence.loadSessions().first?.preview, "")
    }

    func testSessionFlagsArePersisted() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        try persistence.createSession(id: "session-1", title: "Flagged")
        try persistence.updateSessionFlags(
            id: "session-1",
            isPinned: true,
            isArchived: true,
            isUnread: true
        )

        let summary = try XCTUnwrap(persistence.loadSessions().first)
        XCTAssertTrue(summary.isPinned)
        XCTAssertTrue(summary.isArchived)
        XCTAssertTrue(summary.isUnread)
    }

    func testTerminalTabsArePersisted() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        let tab = PersistedTerminalTab(
            id: "terminal-1",
            title: "Build logs",
            preview: "1 terminal",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workingDirectory: "/tmp/project",
            command: "npm test",
            backend: .tmux,
            rootSurfaceId: "surface-1",
            tmuxSocketName: "smithers-test",
            tmuxSessionName: "smt-surface-1",
            workspaceStateJSON: #"{"title":"Build logs"}"#,
            isPinned: true
        )

        try persistence.upsertTerminalTab(tab)

        let loaded = try XCTUnwrap(persistence.loadTerminalTabs().first)
        XCTAssertEqual(loaded.id, "terminal-1")
        XCTAssertEqual(loaded.title, "Build logs")
        XCTAssertEqual(loaded.workingDirectory, "/tmp/project")
        XCTAssertEqual(loaded.command, "npm test")
        XCTAssertEqual(loaded.backend, .tmux)
        XCTAssertEqual(loaded.rootSurfaceId, "surface-1")
        XCTAssertEqual(loaded.tmuxSocketName, "smithers-test")
        XCTAssertEqual(loaded.tmuxSessionName, "smt-surface-1")
        XCTAssertEqual(loaded.workspaceStateJSON, #"{"title":"Build logs"}"#)
        XCTAssertTrue(loaded.isPinned)
    }

    func testDeleteSessionRemovesSessionAndMessages() throws {
        try requireSQLite3()
        let tempDirectory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let persistence = SQLiteSessionPersistence(workingDirectory: tempDirectory.path)

        try persistence.createSession(id: "session-1", title: "Delete me")
        try persistence.createMessage(sessionID: "session-1", messageID: "message-1", role: .user, text: "Remove me")
        try persistence.deleteSession(id: "session-1")

        XCTAssertTrue(try persistence.loadSessions().isEmpty)
        XCTAssertTrue(try persistence.loadMessages(sessionID: "session-1").isEmpty)
    }
}
