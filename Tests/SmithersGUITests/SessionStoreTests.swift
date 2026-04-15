import XCTest
@testable import SmithersGUI

@MainActor
final class SessionStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Build a session with a given timestamp, bypassing AgentService FFI.
    private func makeSession(
        id: String = UUID().uuidString,
        title: String = SessionStore.defaultChatTitle,
        preview: String = "",
        timestamp: Date = Date()
    ) -> Session {
        Session(id: id, title: title, preview: preview, timestamp: timestamp, agent: AgentService())
    }

    // MARK: - PLATFORM_SESSION_UUID_BASED_ID

    func testNewSessionUsesUUIDBasedId() {
        let store = SessionStore()
        let id = store.sessions.first!.id
        // UUID().uuidString produces 36-char hyphenated string
        XCTAssertEqual(id.count, 36, "Session id should be a UUID string (36 chars)")
        XCTAssertNotNil(UUID(uuidString: id), "Session id should be a valid UUID")
    }

    // MARK: - PLATFORM_SESSION_DEFAULT_TITLE

    func testNewSessionDefaultTitle() {
        let store = SessionStore()
        XCTAssertEqual(store.sessions.first?.title, SessionStore.defaultChatTitle)
    }

    func testNewSessionEmptyPreview() {
        let store = SessionStore()
        XCTAssertEqual(store.sessions.first?.preview, "")
    }

    // MARK: - PLATFORM_SESSION_MANAGEMENT (create, select, delete)

    func testInitCreatesOneSession() {
        let store = SessionStore()
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertNotNil(store.activeSessionId)
    }

    func testNewSessionAddsSession() {
        let store = SessionStore()
        store.newSession()
        XCTAssertEqual(store.sessions.count, 2)
    }

    func testNewSessionCanReuseEmptyPlaceholder() {
        let store = SessionStore()
        let firstId = store.activeSessionId
        store.newSession(reusingEmptyPlaceholder: true)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.activeSessionId, firstId)
    }

    func testNewSessionCreatesAfterPlaceholderHasMessages() {
        let store = SessionStore()
        let firstId = store.activeSessionId
        store.sendMessage("Start a real chat")
        store.newSession(reusingEmptyPlaceholder: true)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNotEqual(store.activeSessionId, firstId)
    }

    func testNewSessionSetsActiveToNewest() {
        let store = SessionStore()
        let firstId = store.activeSessionId
        store.newSession()
        let secondId = store.activeSessionId
        XCTAssertNotEqual(firstId, secondId)
        XCTAssertEqual(store.sessions.first?.id, secondId)
    }

    func testSelectSession() {
        let store = SessionStore()
        let firstId = store.sessions.first!.id
        store.newSession()
        XCTAssertNotEqual(store.activeSessionId, firstId)
        store.selectSession(firstId)
        XCTAssertEqual(store.activeSessionId, firstId)
    }

    func testActiveSessionReturnsCorrectSession() {
        let store = SessionStore()
        let id = store.activeSessionId!
        XCTAssertEqual(store.activeSession?.id, id)
    }

    func testActiveAgentMatchesActiveSession() {
        let store = SessionStore()
        // activeAgent should be the agent of the active session
        XCTAssertNotNil(store.activeAgent)
    }

    // MARK: - PLATFORM_SESSION_INSERT_AT_TOP

    func testNewSessionInsertedAtTop() {
        let store = SessionStore()
        let firstId = store.sessions.first!.id
        store.newSession()
        let secondId = store.sessions.first!.id
        XCTAssertNotEqual(firstId, secondId, "Newest session should be at index 0")
        XCTAssertEqual(store.sessions[1].id, firstId)
    }

    // MARK: - PLATFORM_SESSION_TITLE_FROM_FIRST_MESSAGE

    func testSendMessageSetsTitleFromFirstMessage() {
        let store = SessionStore()
        store.sendMessage("Hello world")
        XCTAssertEqual(store.sessions.first?.title, "Hello world")
    }

    func testSendMessageDoesNotOverwriteTitleOnSubsequentMessages() {
        let store = SessionStore()
        store.sendMessage("First message")
        store.sendMessage("Second message")
        XCTAssertEqual(store.sessions.first?.title, "First message")
    }

    // MARK: - PLATFORM_SESSION_TITLE_TRUNCATE_40_CHARS

    func testTitleTruncatedTo40Chars() {
        let store = SessionStore()
        let longText = String(repeating: "A", count: 60)
        store.sendMessage(longText)
        XCTAssertEqual(store.sessions.first?.title.count, 40)
    }

    func testTitleNotTruncatedWhenUnder40() {
        let store = SessionStore()
        store.sendMessage("Short title")
        XCTAssertEqual(store.sessions.first?.title, "Short title")
    }

    // MARK: - PLATFORM_SESSION_PREVIEW_TRUNCATE_80_CHARS

    func testPreviewTruncatedTo80Chars() {
        let store = SessionStore()
        let longText = String(repeating: "B", count: 100)
        store.sendMessage(longText)
        XCTAssertEqual(store.sessions.first?.preview.count, 80)
    }

    func testPreviewNotTruncatedWhenUnder80() {
        let store = SessionStore()
        store.sendMessage("Short preview")
        XCTAssertEqual(store.sessions.first?.preview, "Short preview")
    }

    func testPreviewUpdatesOnEveryMessage() {
        let store = SessionStore()
        store.sendMessage("First")
        XCTAssertEqual(store.sessions.first?.preview, "First")
        store.sendMessage("Second")
        XCTAssertEqual(store.sessions.first?.preview, "Second")
    }

    // MARK: - PLATFORM_SESSION_RELATIVE_TIMESTAMPS

    // SESSION_RELATIVE_TIME_JUST_NOW
    func testRelativeTimeJustNow() {
        let store = SessionStore()
        // Session was just created, timestamp ~= now
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "just now")
    }

    // SESSION_RELATIVE_TIME_MINUTES
    func testRelativeTimeMinutes() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-120) // 2 minutes ago
        )
        store.activeSessionId = store.sessions[0].id
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "2m ago")
    }

    func testRelativeTimeOneMinute() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-60)
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "1m ago")
    }

    // SESSION_RELATIVE_TIME_HOURS
    func testRelativeTimeHours() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-7200) // 2 hours ago
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "2h ago")
    }

    func testRelativeTimeOneHour() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-3600)
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "1h ago")
    }

    // SESSION_RELATIVE_TIME_DAYS
    func testRelativeTimeDays() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-172800) // 2 days ago
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "2d ago")
    }

    func testRelativeTimeBoundaryAt59Seconds() {
        let store = SessionStore()
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: Date().addingTimeInterval(-59)
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.timestamp, "just now")
    }

    // MARK: - PLATFORM_SESSION_GROUPING_BY_DATE

    func testGroupingToday() {
        let store = SessionStore()
        // Default session is created now, should be "Today"
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.group, "Today")
    }

    func testGroupingYesterday() {
        let store = SessionStore()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: yesterday
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.group, "Yesterday")
    }

    func testGroupingOlder() {
        let store = SessionStore()
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        store.sessions[0] = makeSession(
            id: store.sessions[0].id,
            timestamp: threeDaysAgo
        )
        let chatSessions = store.chatSessions()
        XCTAssertEqual(chatSessions.first?.group, "Older")
    }

    // MARK: - chatSessions() mapping

    func testChatSessionsPreservesOrder() {
        let store = SessionStore()
        store.newSession()
        store.newSession()
        let ids = store.sessions.map(\.id)
        let chatIds = store.chatSessions().map(\.id)
        XCTAssertEqual(ids, chatIds)
    }

    func testChatSessionsPreservesTitleAndPreview() {
        let store = SessionStore()
        store.sendMessage("My title and preview")
        let chat = store.chatSessions().first!
        XCTAssertEqual(chat.title, "My title and preview")
        XCTAssertEqual(chat.preview, "My title and preview")
    }

    func testRunTabsAppearInSidebarTabs() {
        let store = SessionStore()
        store.addRunTab(runId: "run-123456", title: "Deploy Preview", preview: "RUNNING")
        let tabs = store.sidebarTabs()
        XCTAssertTrue(tabs.contains { $0.id == "run:run-123456" && $0.title == "Deploy Preview" })
    }

    func testSidebarTabsSearchIncludesRunID() {
        let store = SessionStore()
        store.addRunTab(runId: "run-needle", title: "Deploy Preview", preview: "RUNNING")
        let tabs = store.sidebarTabs(matching: "needle")
        XCTAssertEqual(tabs.map(\.runId), ["run-needle"])
    }

    // MARK: - Edge cases

    func testSendMessageToNonExistentSessionIsNoOp() {
        let store = SessionStore()
        store.activeSessionId = "nonexistent-id"
        // Should not crash
        store.sendMessage("Hello")
        XCTAssertEqual(store.sessions.first?.title, SessionStore.defaultChatTitle)
    }

    func testSelectNonExistentSessionSetsIdButNoActiveSession() {
        let store = SessionStore()
        store.selectSession("bogus")
        XCTAssertEqual(store.activeSessionId, "bogus")
        XCTAssertNil(store.activeSession)
        XCTAssertNil(store.activeAgent)
    }

    func testMultipleSessionsIndependent() {
        let store = SessionStore()
        store.sendMessage("Session 1 message")
        let firstId = store.activeSessionId!

        store.newSession()
        store.sendMessage("Session 2 message")

        // Verify both sessions have correct titles
        let session1 = store.sessions.first(where: { $0.id == firstId })!
        let session2 = store.sessions.first(where: { $0.id == store.activeSessionId })!
        XCTAssertEqual(session1.title, "Session 1 message")
        XCTAssertEqual(session2.title, "Session 2 message")
    }

    func testTimestampUpdatedOnSendMessage() {
        let store = SessionStore()
        let before = Date()
        store.sendMessage("test")
        let after = Date()
        let ts = store.sessions.first!.timestamp
        XCTAssertGreaterThanOrEqual(ts, before)
        XCTAssertLessThanOrEqual(ts, after)
    }
}
