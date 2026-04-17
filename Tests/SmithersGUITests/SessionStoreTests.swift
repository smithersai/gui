import XCTest
@testable import SmithersGUI

@MainActor
final class SessionStoreTests: XCTestCase {
    // MARK: - Helpers

    private func makeIsolatedUserDefaults() -> UserDefaults {
        let suiteName = "SessionStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create isolated UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: AppPreferenceKeys.externalAgentUnsafeFlagsEnabled)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

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
            throw XCTSkip("sqlite3 is required for SessionStore persistence tests")
        }

        if process.terminationStatus != 0 {
            throw XCTSkip("sqlite3 is required for SessionStore persistence tests")
        }
    }

    private func makePersistentStore(tempDirectory: String) -> SessionStore {
        SessionStore(
            workingDirectory: tempDirectory,
            persistence: SQLiteSessionPersistence(workingDirectory: tempDirectory)
        )
    }

    private func flushMainActorWrites() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    /// Build a session with a given timestamp, bypassing AgentService FFI.
    private func makeSession(
        id: String = UUID().uuidString,
        title: String = SessionStore.defaultChatTitle,
        preview: String = "",
        timestamp: Date = Date()
    ) -> Session {
        Session(
            id: id,
            title: title,
            preview: preview,
            timestamp: timestamp,
            createdAt: timestamp,
            agent: AgentService(),
            codexSelection: .fallback
        )
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
        XCTAssertEqual(SessionStore.defaultChatTitle, "New Chat")
        XCTAssertTrue(SessionStore.isPlaceholderChatTitle("Claude Code"))
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

    func testNewSessionPassesResolvedWorkingDirectoryToAgent() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let store = SessionStore(workingDirectory: project.path, persistence: nil)

        XCTAssertEqual(store.activeAgent?.workingDirectory, project.path)
    }

    func testRestoredSessionPassesResolvedWorkingDirectoryToAgent() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let persistence = StubSessionPersistence(sessions: [
            PersistedSessionSummary(
                id: UUID().uuidString,
                title: "Restored",
                preview: "",
                updatedAt: Date(),
                createdAt: Date()
            ),
        ])
        let store = SessionStore(workingDirectory: project.path, persistence: persistence)

        XCTAssertEqual(store.activeAgent?.workingDirectory, project.path)
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

    func testPinnedChatSessionsSortBeforeNewerSessions() {
        let store = SessionStore()
        let pinnedId = store.activeSessionId!
        store.sendMessage("Pinned topic")
        store.toggleSessionPinned(pinnedId)

        store.newSession()
        store.sendMessage("Newer topic")

        let tabs = store.sidebarTabs()
        XCTAssertEqual(tabs.first?.chatSessionId, pinnedId)
        XCTAssertEqual(tabs.first?.isPinned, true)
        XCTAssertEqual(tabs.first?.group, "Pinned")
    }

    func testArchiveSessionHidesSessionAndMovesActiveSession() {
        let store = SessionStore()
        let firstId = store.activeSessionId!
        store.sendMessage("Archive me")
        store.newSession()
        let secondId = store.activeSessionId!

        store.archiveSession(secondId)

        XCTAssertEqual(store.activeSessionId, firstId)
        XCTAssertFalse(store.chatSessions().contains { $0.id == secondId })
        XCTAssertTrue(store.sessions.first(where: { $0.id == secondId })?.isArchived ?? false)
    }

    func testUnreadSessionClearsWhenSelected() {
        let store = SessionStore()
        let firstId = store.activeSessionId!
        store.newSession()

        store.toggleSessionUnread(firstId)
        XCTAssertTrue(store.sessions.first(where: { $0.id == firstId })?.isUnread ?? false)

        store.selectSession(firstId)
        XCTAssertFalse(store.sessions.first(where: { $0.id == firstId })?.isUnread ?? true)
    }

    func testForkSessionIntoLocalCopiesMessagesAndSelectsFork() {
        let store = SessionStore()
        let sourceId = store.activeSessionId!
        store.sendMessage("Fork this thread")

        let forkId = store.forkSessionIntoLocal(sourceId)

        XCTAssertNotNil(forkId)
        XCTAssertEqual(store.activeSessionId, forkId)
        XCTAssertEqual(store.sessions.first?.agent.workingDirectory, store.sessionWorkingDirectory(sourceId))
        XCTAssertTrue(
            store.activeAgent?.messages.contains(where: {
                $0.type == .user && $0.content == "Fork this thread"
            }) ?? false
        )
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

    func testTerminalTabsAppearInSidebarTabs() {
        let store = SessionStore()
        let terminalId = store.addTerminalTab()
        let tabs = store.sidebarTabs()
        XCTAssertTrue(tabs.contains { $0.id == "terminal:\(terminalId)" && $0.title == "Terminal 1" })
    }

    func testNewTerminalTabsHaveDistinctIds() {
        let store = SessionStore()
        let firstId = store.addTerminalTab()
        let secondId = store.addTerminalTab()

        XCTAssertNotEqual(firstId, secondId)
        XCTAssertEqual(store.terminalTabs.map(\.title), ["Terminal 2", "Terminal 1"])
    }

    func testLaunchExternalAgentTabReplacesEmptyChatPlaceholder() {
        let store = SessionStore(
            workingDirectory: "/tmp/smithers-codex-test",
            persistence: nil,
            userDefaults: makeIsolatedUserDefaults()
        )
        let chatId = store.activeSessionId!

        let terminalId = store.launchExternalAgentTab(name: "Codex", command: "codex")

        XCTAssertFalse(store.sessions.contains { $0.id == chatId })
        XCTAssertNil(store.activeSessionId)
        XCTAssertEqual(store.terminalTabs.first?.terminalId, terminalId)
        XCTAssertEqual(store.terminalTabs.first?.title, "Codex")
        XCTAssertEqual(store.terminalTabs.first?.command, "codex")
        XCTAssertEqual(store.sidebarTabs().map(\.title), ["Codex"])
    }

    func testLaunchExternalAgentTabKeepsNonEmptyChat() {
        let store = SessionStore(userDefaults: makeIsolatedUserDefaults())
        let chatId = store.activeSessionId!
        store.sendMessage("Keep this chat")

        let terminalId = store.launchExternalAgentTab(name: "Codex", command: "codex")

        XCTAssertTrue(store.sessions.contains { $0.id == chatId })
        XCTAssertEqual(store.activeSessionId, chatId)
        XCTAssertEqual(store.terminalTabs.first?.terminalId, terminalId)
        XCTAssertEqual(store.terminalTabs.first?.title, "Codex")
    }

    func testApplyDefaultAgentFlagsDisabledByDefault() {
        XCTAssertEqual(SessionStore.applyDefaultAgentFlags("claude", unsafeFlagsEnabled: false), "claude")
        XCTAssertEqual(SessionStore.applyDefaultAgentFlags("gemini", unsafeFlagsEnabled: false), "gemini")
        XCTAssertEqual(SessionStore.applyDefaultAgentFlags("codex", unsafeFlagsEnabled: false), "codex")
    }

    func testApplyDefaultAgentFlagsAppliesUnsafeFlagsWhenEnabled() {
        XCTAssertEqual(
            SessionStore.applyDefaultAgentFlags("claude", unsafeFlagsEnabled: true),
            "claude --dangerously-skip-permissions"
        )
        XCTAssertEqual(
            SessionStore.applyDefaultAgentFlags("gemini", unsafeFlagsEnabled: true),
            "gemini --yolo"
        )
        XCTAssertEqual(
            SessionStore.applyDefaultAgentFlags("codex", unsafeFlagsEnabled: true),
            "codex -c model_reasoning_effort=\"high\" --yolo"
        )
    }

    func testApplyDefaultAgentFlagsRespectsInjectedUserDefaultsPreference() {
        let suite = "SessionStoreTests.applyFlags.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Expected isolated user defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        defaults.set(false, forKey: AppPreferenceKeys.externalAgentUnsafeFlagsEnabled)
        XCTAssertEqual(SessionStore.applyDefaultAgentFlags("claude", userDefaults: defaults), "claude")

        defaults.set(true, forKey: AppPreferenceKeys.externalAgentUnsafeFlagsEnabled)
        XCTAssertEqual(
            SessionStore.applyDefaultAgentFlags("claude", userDefaults: defaults),
            "claude --dangerously-skip-permissions"
        )
    }

    func testTerminalTabsCanBeRenamedAndPinned() {
        let store = SessionStore()
        let terminalId = store.addTerminalTab()

        store.renameTerminalTab(terminalId, to: "Build logs")
        store.toggleTerminalPinned(terminalId)

        XCTAssertEqual(store.terminalTabs.first?.title, "Build logs")
        XCTAssertEqual(store.terminalTabs.first?.isPinned, true)
        XCTAssertEqual(store.sidebarTabs().first?.group, "Pinned")
    }

    func testTerminalTabsExposeTmuxMetadata() {
        let store = SessionStore(workingDirectory: "/tmp/smithers-terminal-test")
        let terminalId = store.addTerminalTab()
        let tab = store.terminalTabs.first

        XCTAssertEqual(tab?.backend, .tmux)
        XCTAssertNotNil(tab?.rootSurfaceId.flatMap { UUID(uuidString: $0) })
        XCTAssertEqual(tab?.tmuxSessionName, tab?.rootSurfaceId.map(TmuxController.sessionName(for:)))
        XCTAssertEqual(tab?.tmuxSocketName, store.terminalWorkingDirectory(terminalId).map(TmuxController.socketName(for:)))
    }

    func testRemoveTerminalTabCleansBrowserSurfaceRegistryAndNotifications() {
        let store = SessionStore()
        let terminalId = store.addTerminalTab()
        let workspace = store.ensureTerminalWorkspace(terminalId)
        let browserSurfaceId = workspace.addBrowser(urlString: "example.com")

        _ = BrowserSurfaceRegistry.shared.webView(for: browserSurfaceId)
        XCTAssertTrue(BrowserSurfaceRegistry.shared.contains(surfaceId: browserSurfaceId))
        XCTAssertEqual(SurfaceNotificationStore.shared.surfaceWorkspaceIds[browserSurfaceId], terminalId)

        store.removeTerminalTab(terminalId)

        XCTAssertFalse(BrowserSurfaceRegistry.shared.contains(surfaceId: browserSurfaceId))
        XCTAssertNil(SurfaceNotificationStore.shared.surfaceWorkspaceIds[browserSurfaceId])
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

    func testApplyCodexApprovalSelectionUpdatesDefaultsAndActiveSession() {
        let store = SessionStore()
        let selection = CodexApprovalSelection(
            approvalPolicy: .onRequest,
            sandboxMode: .workspaceWrite
        )

        let result = store.applyCodexApprovalSelection(selection)
        switch result {
        case .success(let applied):
            XCTAssertEqual(applied, selection)
            XCTAssertEqual(store.codexApprovalDefaults, selection)
            XCTAssertEqual(store.activeCodexApprovalSelection, selection)
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testNewSessionUsesCurrentApprovalDefaults() {
        let store = SessionStore()
        _ = store.applyCodexApprovalSelection(
            CodexApprovalSelection(
                approvalPolicy: .never,
                sandboxMode: .dangerFullAccess
            )
        )

        store.newSession()
        XCTAssertEqual(
            store.activeCodexApprovalSelection,
            CodexApprovalSelection(
                approvalPolicy: .never,
                sandboxMode: .dangerFullAccess
            )
        )
    }

    // MARK: - Persistence

    func testPersistentSessionsSurviveRestart() throws {
        try requireSQLite3()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store1 = makePersistentStore(tempDirectory: tempDirectory.path)
        let sessionID = store1.activeSessionId!
        store1.renameSession(sessionID, to: "Persistent Session")
        store1.sendMessage("Persist this message")
        store1.activeAgent?.cancel()
        flushMainActorWrites()

        let store2 = makePersistentStore(tempDirectory: tempDirectory.path)
        let restored = store2.sessions.first(where: { $0.id == sessionID })

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.title, "Persistent Session")
        XCTAssertEqual(restored?.preview, "Persist this message")
    }

    func testPersistentLoadSessionRestoresMessages() throws {
        try requireSQLite3()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store1 = makePersistentStore(tempDirectory: tempDirectory.path)
        let firstSessionID = store1.activeSessionId!
        store1.sendMessage("First persisted prompt")
        store1.activeAgent?.cancel()
        flushMainActorWrites()
        store1.newSession()
        store1.sendMessage("Second persisted prompt")
        store1.activeAgent?.cancel()
        flushMainActorWrites()

        let store2 = makePersistentStore(tempDirectory: tempDirectory.path)
        store2.loadSessionFromPersistence(firstSessionID)

        XCTAssertEqual(store2.activeSessionId, firstSessionID)
        XCTAssertTrue(
            store2.activeAgent?.messages.contains(where: {
                $0.type == .user && $0.content.contains("First persisted prompt")
            }) ?? false
        )
    }

    func testPersistentDeleteRemovesSessionAcrossRestart() throws {
        try requireSQLite3()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store1 = makePersistentStore(tempDirectory: tempDirectory.path)
        let sessionID = store1.activeSessionId!
        store1.renameSession(sessionID, to: "To Delete")
        store1.deleteSession(sessionID)

        let store2 = makePersistentStore(tempDirectory: tempDirectory.path)
        XCTAssertFalse(store2.sessions.contains(where: { $0.id == sessionID }))
    }

    func testPersistentTerminalTabsSurviveRestart() throws {
        try requireSQLite3()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let store1 = makePersistentStore(tempDirectory: tempDirectory.path)
        let terminalId = store1.addTerminalTab(title: "Server", workingDirectory: tempDirectory.path)
        store1.toggleTerminalPinned(terminalId)

        let store2 = makePersistentStore(tempDirectory: tempDirectory.path)
        let restored = try XCTUnwrap(store2.terminalTabs.first(where: { $0.terminalId == terminalId }))

        XCTAssertEqual(restored.title, "Server")
        XCTAssertTrue(restored.isPinned)
        XCTAssertEqual(restored.backend, .tmux)
        XCTAssertNotNil(restored.rootSurfaceId.flatMap { UUID(uuidString: $0) })
    }
}

private final class StubSessionPersistence: SessionPersisting {
    var sessions: [PersistedSessionSummary]
    var messagesBySessionID: [String: [PersistedSessionMessage]]
    var terminalTabs: [PersistedTerminalTab]

    init(
        sessions: [PersistedSessionSummary] = [],
        messagesBySessionID: [String: [PersistedSessionMessage]] = [:],
        terminalTabs: [PersistedTerminalTab] = []
    ) {
        self.sessions = sessions
        self.messagesBySessionID = messagesBySessionID
        self.terminalTabs = terminalTabs
    }

    func loadSessions() throws -> [PersistedSessionSummary] {
        sessions
    }

    func loadMessages(sessionID: String) throws -> [PersistedSessionMessage] {
        messagesBySessionID[sessionID] ?? []
    }

    func loadTerminalTabs() throws -> [PersistedTerminalTab] {
        terminalTabs
    }

    func createSession(id _: String, title _: String) throws {}

    func renameSession(id _: String, title _: String) throws {}

    func updateSessionFlags(id: String, isPinned: Bool, isArchived: Bool, isUnread: Bool) throws {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let current = sessions[idx]
        sessions[idx] = PersistedSessionSummary(
            id: current.id,
            title: current.title,
            preview: current.preview,
            updatedAt: current.updatedAt,
            createdAt: current.createdAt,
            isPinned: isPinned,
            isArchived: isArchived,
            isUnread: isUnread
        )
    }

    func deleteSession(id: String) throws {
        sessions.removeAll { $0.id == id }
        messagesBySessionID[id] = nil
    }

    func createMessage(sessionID: String, messageID: String, role: PersistedChatRole, text: String) throws {
        let message = PersistedSessionMessage(id: messageID, role: role, text: text, createdAt: Date())
        messagesBySessionID[sessionID, default: []].append(message)
    }

    func updateMessage(messageID: String, role: PersistedChatRole, text: String) throws {
        for sessionID in messagesBySessionID.keys {
            guard let idx = messagesBySessionID[sessionID]?.firstIndex(where: { $0.id == messageID }) else {
                continue
            }
            messagesBySessionID[sessionID]?[idx] = PersistedSessionMessage(
                id: messageID,
                role: role,
                text: text,
                createdAt: Date()
            )
            return
        }
    }

    func upsertTerminalTab(_ tab: PersistedTerminalTab) throws {
        if let idx = terminalTabs.firstIndex(where: { $0.id == tab.id }) {
            terminalTabs[idx] = tab
        } else {
            terminalTabs.insert(tab, at: 0)
        }
    }

    func deleteTerminalTab(id: String) throws {
        terminalTabs.removeAll { $0.id == id }
    }
}
