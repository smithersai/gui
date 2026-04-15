import Foundation
import SwiftUI
import Combine

struct Session: Identifiable {
    let id: String
    var title: String
    var preview: String
    var timestamp: Date
    var agent: AgentService
    var codexSelection: CodexModelSelection = .fallback
    var codexApprovalSelection: CodexApprovalSelection = .fallback
    var isPinned: Bool = false
    var isArchived: Bool = false
    var isUnread: Bool = false
}

enum SessionForkError: LocalizedError {
    case sessionNotFound
    case gitUnavailable
    case gitCommandFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotFound:
            return "Session not found."
        case .gitUnavailable:
            return "git is not available at /usr/bin/git."
        case .gitCommandFailed(let message):
            return message
        }
    }
}

@MainActor
class SessionStore: ObservableObject {
    nonisolated static let defaultChatTitle = "Claude Code"

    @Published var sessions: [Session] = []
    @Published var runTabs: [RunTab] = []
    @Published var terminalTabs: [TerminalTab] = []
    @Published var activeSessionId: String?
    @Published var codexSelectionDefaults: CodexModelSelection
    @Published var codexApprovalDefaults: CodexApprovalSelection

    private struct PersistedMessageState {
        var dbMessageID: String
        var role: PersistedChatRole
        var text: String
    }

    private struct PersistableMessage {
        let chatID: String
        let role: PersistedChatRole
        let text: String
    }

    private let persistence: SessionPersisting?
    private let workingDirectory: String
    private var messageCancellables: [String: AnyCancellable] = [:]
    private var loadedSessionMessageIDs: Set<String> = []
    private var persistenceSuppressedSessionIDs: Set<String> = []
    private var persistedMessageStateBySessionID: [String: [String: PersistedMessageState]] = [:]

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    var activeAgent: AgentService? {
        activeSession?.agent
    }

    var activeCodexSelection: CodexModelSelection? {
        activeSession?.codexSelection
    }

    var activeCodexApprovalSelection: CodexApprovalSelection? {
        activeSession?.codexApprovalSelection
    }

    init(workingDirectory: String? = nil, persistence: SessionPersisting? = nil) {
        let cwd = CWDResolver.resolve(workingDirectory)
        self.workingDirectory = cwd
        codexSelectionDefaults = CodexModelConfigStore.loadSelection(cwd: cwd)
        codexApprovalDefaults = CodexApprovalConfigStore.loadSelection(cwd: cwd)
        if let persistence {
            self.persistence = persistence
        } else if UITestSupport.isRunningUnitTests {
            self.persistence = nil
        } else {
            self.persistence = SQLiteSessionPersistence(workingDirectory: cwd)
        }

        AppLogger.state.info("SessionStore init")
        if !loadPersistedSessions() {
            newSession()
        }
    }

    @discardableResult
    func newSession(reusingEmptyPlaceholder: Bool = false) -> String {
        if reusingEmptyPlaceholder, let idx = emptyPlaceholderIndex() {
            var session = sessions.remove(at: idx)
            session.timestamp = Date()
            sessions.insert(session, at: 0)
            activeSessionId = session.id
            persistSessionRecord(id: session.id, title: session.title)
            return session.id
        }

        let id = UUID().uuidString
        AppLogger.state.info("SessionStore newSession", metadata: ["id": String(id.prefix(8))])
        let initialSelection = codexSelectionDefaults
        let initialApprovalSelection = codexApprovalDefaults
        let agent = AgentService(
            workingDir: workingDirectory,
            modelOverride: initialSelection.model,
            reasoningEffortOverride: initialSelection.reasoningEffort,
            approvalPolicyOverride: initialApprovalSelection.approvalPolicy,
            sandboxModeOverride: initialApprovalSelection.sandboxMode
        )
        let session = Session(
            id: id,
            title: Self.defaultChatTitle,
            preview: "",
            timestamp: Date(),
            agent: agent,
            codexSelection: initialSelection,
            codexApprovalSelection: initialApprovalSelection
        )
        sessions.insert(session, at: 0)
        observeMessages(for: session.id, agent: session.agent)
        activeSessionId = id
        return id
    }

    @discardableResult
    func ensureActiveSession() -> String {
        if let activeSessionId,
           sessions.contains(where: { $0.id == activeSessionId && !$0.isArchived }) {
            return activeSessionId
        }

        if let first = sessions.first(where: { !$0.isArchived }) {
            activeSessionId = first.id
            loadSessionMessages(sessionID: first.id, force: false)
            return first.id
        }

        return newSession()
    }

    func selectSession(_ id: String) {
        AppLogger.state.debug("SessionStore selectSession", metadata: ["id": String(id.prefix(8))])
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isUnread = false
            persistSessionFlags(for: sessions[idx], ensureRecord: false)
        }
        activeSessionId = id
        loadSessionMessages(sessionID: id, force: false)
    }

    func loadSessionFromPersistence(_ id: String) {
        selectSession(id)
        loadSessionMessages(sessionID: id, force: true)
    }

    func renameSession(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }

        sessions[idx].title = trimmed
        persistRenameSession(id: id, title: trimmed)
    }

    func canDeleteSession(_ id: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == id }) else { return false }
        return !session.agent.isRunning
    }

    func canArchiveSession(_ id: String) -> Bool {
        canDeleteSession(id)
    }

    func toggleSessionPinned(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        persistSessionFlags(for: sessions[idx], ensureRecord: true)
    }

    func archiveSession(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard canArchiveSession(id) else { return }

        sessions[idx].isArchived = true
        sessions[idx].isPinned = false
        sessions[idx].isUnread = false
        persistSessionFlags(for: sessions[idx], ensureRecord: true)

        if activeSessionId == id {
            if let next = sessions.first(where: { !$0.isArchived }) {
                activeSessionId = next.id
                loadSessionMessages(sessionID: next.id, force: false)
            } else {
                _ = newSession()
            }
        }
    }

    func toggleSessionUnread(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isUnread.toggle()
        persistSessionFlags(for: sessions[idx], ensureRecord: true)
    }

    func sessionWorkingDirectory(_ id: String) -> String? {
        sessions.first(where: { $0.id == id })?.agent.workingDirectory
    }

    func sessionIdentifier(_ id: String) -> String? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        return normalizedOptionalText(session.agent.activeThreadID) ?? session.id
    }

    func sessionDeeplink(_ id: String) -> String? {
        guard sessions.contains(where: { $0.id == id }) else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        return "smithers://chat/\(encoded)"
    }

    func deleteSession(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard canDeleteSession(id) else { return }

        sessions.remove(at: idx)
        messageCancellables[id] = nil
        loadedSessionMessageIDs.remove(id)
        persistenceSuppressedSessionIDs.remove(id)
        persistedMessageStateBySessionID[id] = nil
        persistDeleteSession(id)

        if activeSessionId == id {
            if let next = sessions.first {
                activeSessionId = next.id
                loadSessionMessages(sessionID: next.id, force: false)
            } else {
                _ = newSession()
            }
        }
    }

    @discardableResult
    func addRunTab(runId: String, title: String?, preview: String? = nil) -> String {
        let displayTitle = runTabTitle(runId: runId, title: title)
        let displayPreview = runTabPreview(preview)
        let now = Date()

        if let idx = runTabs.firstIndex(where: { $0.runId == runId }) {
            var tab = runTabs.remove(at: idx)
            tab.title = displayTitle
            tab.preview = displayPreview
            tab.timestamp = now
            runTabs.insert(tab, at: 0)
        } else {
            runTabs.insert(
                RunTab(runId: runId, title: displayTitle, preview: displayPreview, timestamp: now),
                at: 0
            )
        }

        return runId
    }

    @discardableResult
    func addTerminalTab() -> String {
        let id = UUID().uuidString
        let tabNumber = terminalTabs.count + 1
        AppLogger.state.info("SessionStore addTerminalTab", metadata: ["id": String(id.prefix(8))])
        terminalTabs.insert(
            TerminalTab(
                terminalId: id,
                title: "Terminal \(tabNumber)",
                preview: "Shell session",
                timestamp: Date()
            ),
            at: 0
        )
        return id
    }

    @discardableResult
    func ensureTerminalTab() -> String {
        if let terminalId = terminalTabs.first?.terminalId {
            return terminalId
        }
        return addTerminalTab()
    }

    func removeTerminalTab(_ terminalId: String) {
        terminalTabs.removeAll { $0.terminalId == terminalId }
        TerminalSurfaceRegistry.shared.deregister(sessionId: terminalId)
    }

    @discardableResult
    func forkSessionIntoLocal(_ id: String) -> String? {
        forkSession(id, workingDirectory: nil)
    }

    func forkSessionIntoNewWorktree(_ id: String) async -> Result<String, SessionForkError> {
        guard let source = sessions.first(where: { $0.id == id }) else {
            return .failure(.sessionNotFound)
        }

        let sourceDirectory = source.agent.workingDirectory
        let sourceTitle = source.title

        do {
            let worktreePath = try await Task.detached {
                try Self.createForkWorktree(
                    from: sourceDirectory,
                    sessionID: id,
                    title: sourceTitle
                )
            }.value

            guard let forkedID = forkSession(id, workingDirectory: worktreePath) else {
                return .failure(.sessionNotFound)
            }
            return .success(forkedID)
        } catch let error as SessionForkError {
            return .failure(error)
        } catch {
            return .failure(.gitCommandFailed(error.localizedDescription))
        }
    }

    func autoPopulateActiveRunTabs(_ runs: [RunSummary]) {
        guard !runs.isEmpty else { return }

        let activeRuns = runs.filter { $0.status == .running || $0.status == .waitingApproval }
        guard !activeRuns.isEmpty else { return }

        let now = Date()
        for run in activeRuns {
            if let idx = runTabs.firstIndex(where: { $0.runId == run.runId }) {
                let existing = runTabs[idx]
                let newTitle = runTabTitle(runId: run.runId, title: run.workflowName)
                let newPreview = runPreview(for: run)
                if existing.title != newTitle || existing.preview != newPreview {
                    runTabs[idx] = RunTab(runId: existing.runId, title: newTitle, preview: newPreview, timestamp: existing.timestamp)
                }
                continue
            }

            runTabs.insert(
                RunTab(
                    runId: run.runId,
                    title: runTabTitle(runId: run.runId, title: run.workflowName),
                    preview: runPreview(for: run),
                    timestamp: now
                ),
                at: 0
            )
        }
    }

    func sendMessage(_ text: String, displayText: String? = nil) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else {
            AppLogger.state.warning("SessionStore sendMessage: no active session")
            return
        }

        let visibleText: String
        if let displayText, !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            visibleText = displayText
        } else {
            visibleText = text
        }
        let previousTitle = sessions[idx].title
        if isPlaceholderTitle(sessions[idx].title) {
            sessions[idx].title = ChatTitleGenerator.title(for: visibleText)
        }
        sessions[idx].preview = String(visibleText.prefix(80))
        sessions[idx].timestamp = Date()
        persistSessionRecord(id: sessions[idx].id, title: sessions[idx].title)
        if sessions[idx].title != previousTitle {
            persistRenameSession(id: sessions[idx].id, title: sessions[idx].title)
        }

        sessions[idx].agent.sendMessage(text, displayText: visibleText)
    }

    @discardableResult
    func applyCodexSelection(_ selection: CodexModelSelection) -> Result<CodexModelSelection, CodexModelSelectionError> {
        let normalized = CodexModelCatalog.normalized(selection)

        switch CodexModelConfigStore.persistSelection(normalized, cwd: activeAgent?.workingDirectory) {
        case .success(let persisted):

            codexSelectionDefaults = persisted
            if let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
                sessions[idx].codexSelection = persisted
                sessions[idx].agent.updateModelSelection(
                    model: persisted.model,
                    reasoningEffort: persisted.reasoningEffort
                )
            }
            return .success(persisted)

        case .failure(let error):
            return .failure(error)
        }
    }

    @discardableResult
    func applyCodexApprovalSelection(
        _ selection: CodexApprovalSelection
    ) -> Result<CodexApprovalSelection, CodexApprovalSelectionError> {
        codexApprovalDefaults = selection

        if let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) {
            sessions[idx].codexApprovalSelection = selection
            sessions[idx].agent.updateApprovalSelection(
                approvalPolicy: selection.approvalPolicy,
                sandboxMode: selection.sandboxMode
            )
        }

        return .success(selection)
    }

    func sidebarTabs(matching searchText: String = "") -> [SidebarTab] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let chatTabs = sessions.filter { !$0.isArchived }.map { session in
            makeSidebarTab(
                id: "chat:\(session.id)",
                kind: .chat,
                chatSessionId: session.id,
                runId: nil,
                terminalId: nil,
                title: session.title,
                preview: session.preview,
                date: session.timestamp,
                now: now,
                isPinned: session.isPinned,
                isArchived: session.isArchived,
                isUnread: session.isUnread,
                workingDirectory: session.agent.workingDirectory,
                sessionIdentifier: normalizedOptionalText(session.agent.activeThreadID) ?? session.id
            )
        }
        let runTabs = runTabs.map { tab in
            makeSidebarTab(
                id: "run:\(tab.runId)",
                kind: .run,
                chatSessionId: nil,
                runId: tab.runId,
                terminalId: nil,
                title: tab.title,
                preview: tab.preview,
                date: tab.timestamp,
                now: now
            )
        }
        let terminalTabs = terminalTabs.map { tab in
            makeSidebarTab(
                id: "terminal:\(tab.terminalId)",
                kind: .terminal,
                chatSessionId: nil,
                runId: nil,
                terminalId: tab.terminalId,
                title: tab.title,
                preview: tab.preview,
                date: tab.timestamp,
                now: now
            )
        }

        return (chatTabs + runTabs + terminalTabs)
            .filter { tab in
                needle.isEmpty ||
                    tab.title.localizedCaseInsensitiveContains(needle) ||
                    tab.preview.localizedCaseInsensitiveContains(needle) ||
                    (tab.sessionIdentifier?.localizedCaseInsensitiveContains(needle) ?? false) ||
                    (tab.runId?.localizedCaseInsensitiveContains(needle) ?? false) ||
                    (tab.terminalId?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                return $0.sortDate > $1.sortDate
            }
    }

    func chatSessions() -> [ChatSession] {
        let now = Date()
        return sessions.filter { !$0.isArchived }.map { s in
            let group = Self.groupLabel(for: s.timestamp)
            let ago = Self.relativeTime(from: s.timestamp, to: now)
            return ChatSession(
                id: s.id,
                title: s.title,
                preview: s.preview,
                timestamp: ago,
                group: group,
                isPinned: s.isPinned,
                isArchived: s.isArchived,
                isUnread: s.isUnread
            )
        }
    }

    @discardableResult
    private func loadPersistedSessions() -> Bool {
        guard let persistence else { return false }

        do {
            let persisted = try persistence.loadSessions()
            guard !persisted.isEmpty else { return false }

            sessions = persisted.map { summary in
                let agent = AgentService(
                    workingDir: workingDirectory,
                    modelOverride: codexSelectionDefaults.model,
                    reasoningEffortOverride: codexSelectionDefaults.reasoningEffort,
                    approvalPolicyOverride: codexApprovalDefaults.approvalPolicy,
                    sandboxModeOverride: codexApprovalDefaults.sandboxMode
                )
                return Session(
                    id: summary.id,
                    title: summary.title,
                    preview: summary.preview,
                    timestamp: summary.updatedAt,
                    agent: agent,
                    codexSelection: codexSelectionDefaults,
                    codexApprovalSelection: codexApprovalDefaults,
                    isPinned: summary.isPinned,
                    isArchived: summary.isArchived,
                    isUnread: summary.isUnread
                )
            }

            for session in sessions {
                observeMessages(for: session.id, agent: session.agent)
            }

            guard let firstVisibleSession = sessions.first(where: { !$0.isArchived }) else {
                return false
            }

            activeSessionId = firstVisibleSession.id
            loadSessionMessages(sessionID: firstVisibleSession.id, force: true)
            return true
        } catch {
            AppLogger.state.warning("SessionStore failed to load persisted sessions", metadata: [
                "error": String(describing: error),
            ])
            return false
        }
    }

    private func observeMessages(for sessionID: String, agent: AgentService) {
        messageCancellables[sessionID] = agent.$messages.sink { [weak self] messages in
            guard let self else { return }
            Task { @MainActor in
                self.handleMessageUpdate(sessionID: sessionID, messages: messages)
            }
        }
    }

    private func handleMessageUpdate(sessionID: String, messages: [ChatMessage]) {
        guard !persistenceSuppressedSessionIDs.contains(sessionID) else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        let persistable = messages.compactMap { persistableMessage(from: $0) }
        guard !persistable.isEmpty else { return }

        if let latest = persistable.last {
            sessions[idx].preview = String(latest.text.prefix(80))
            sessions[idx].timestamp = Date()
        }

        persistSessionRecord(id: sessionID, title: sessions[idx].title)
        persistMessages(persistable, for: sessionID)
    }

    private func persistableMessage(from message: ChatMessage) -> PersistableMessage? {
        let normalized = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        switch message.type {
        case .user:
            return PersistableMessage(chatID: message.id, role: .user, text: message.content)
        case .assistant:
            return PersistableMessage(chatID: message.id, role: .assistant, text: message.content)
        default:
            return nil
        }
    }

    private func persistMessages(_ messages: [PersistableMessage], for sessionID: String) {
        guard let persistence else { return }
        var stateByChatID = persistedMessageStateBySessionID[sessionID] ?? [:]

        for message in messages {
            if var existing = stateByChatID[message.chatID] {
                guard existing.role != message.role || existing.text != message.text else { continue }
                do {
                    try persistence.updateMessage(messageID: existing.dbMessageID, role: message.role, text: message.text)
                    existing.role = message.role
                    existing.text = message.text
                    stateByChatID[message.chatID] = existing
                } catch {
                    AppLogger.state.warning("SessionStore failed to update persisted message", metadata: [
                        "session_id": String(sessionID.prefix(8)),
                        "error": String(describing: error),
                    ])
                }
                continue
            }

            let dbMessageID = UUID(uuidString: message.chatID) != nil ? message.chatID : UUID().uuidString
            do {
                try persistence.createMessage(sessionID: sessionID, messageID: dbMessageID, role: message.role, text: message.text)
                stateByChatID[message.chatID] = PersistedMessageState(
                    dbMessageID: dbMessageID,
                    role: message.role,
                    text: message.text
                )
            } catch {
                AppLogger.state.warning("SessionStore failed to persist message", metadata: [
                    "session_id": String(sessionID.prefix(8)),
                    "error": String(describing: error),
                ])
            }
        }

        persistedMessageStateBySessionID[sessionID] = stateByChatID
    }

    private func loadSessionMessages(sessionID: String, force: Bool) {
        guard let persistence else { return }
        guard force || !loadedSessionMessageIDs.contains(sessionID) else { return }
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }

        do {
            let persisted = try persistence.loadMessages(sessionID: sessionID)
            var loadedMessages: [ChatMessage] = []
            var messageState: [String: PersistedMessageState] = [:]

            for message in persisted {
                let type: ChatMessage.MessageType = message.role == .user ? .user : .assistant
                loadedMessages.append(
                    ChatMessage(
                        id: message.id,
                        type: type,
                        content: message.text,
                        timestamp: DateFormatters.hourMinute.string(from: message.createdAt),
                        command: nil,
                        diff: nil
                    )
                )
                messageState[message.id] = PersistedMessageState(
                    dbMessageID: message.id,
                    role: message.role,
                    text: message.text
                )
            }

            persistenceSuppressedSessionIDs.insert(sessionID)
            sessions[idx].agent.messages = loadedMessages
            persistenceSuppressedSessionIDs.remove(sessionID)

            persistedMessageStateBySessionID[sessionID] = messageState
            loadedSessionMessageIDs.insert(sessionID)

            if let last = persisted.last {
                sessions[idx].preview = String(last.text.prefix(80))
                sessions[idx].timestamp = last.createdAt
            } else {
                sessions[idx].preview = ""
            }

            if isPlaceholderTitle(sessions[idx].title),
               let firstUserMessage = persisted.first(where: { $0.role == .user }) {
                let generated = ChatTitleGenerator.title(for: firstUserMessage.text)
                sessions[idx].title = generated
                persistRenameSession(id: sessionID, title: generated)
            }
        } catch {
            AppLogger.state.warning("SessionStore failed to load session messages", metadata: [
                "session_id": String(sessionID.prefix(8)),
                "error": String(describing: error),
            ])
        }
    }

    private func persistSessionRecord(id: String, title: String) {
        guard let persistence else { return }
        do {
            try persistence.createSession(id: id, title: title)
        } catch {
            AppLogger.state.warning("SessionStore failed to persist session", metadata: [
                "session_id": String(id.prefix(8)),
                "error": String(describing: error),
            ])
        }
    }

    private func persistRenameSession(id: String, title: String) {
        guard let persistence else { return }
        do {
            try persistence.renameSession(id: id, title: title)
        } catch {
            AppLogger.state.warning("SessionStore failed to rename session", metadata: [
                "session_id": String(id.prefix(8)),
                "error": String(describing: error),
            ])
        }
    }

    private func persistSessionFlags(for session: Session, ensureRecord: Bool) {
        guard let persistence else { return }
        do {
            if ensureRecord {
                try persistence.createSession(id: session.id, title: session.title)
            }
            try persistence.updateSessionFlags(
                id: session.id,
                isPinned: session.isPinned,
                isArchived: session.isArchived,
                isUnread: session.isUnread
            )
        } catch {
            AppLogger.state.warning("SessionStore failed to update session flags", metadata: [
                "session_id": String(session.id.prefix(8)),
                "error": String(describing: error),
            ])
        }
    }

    private func persistDeleteSession(_ id: String) {
        guard let persistence else { return }
        do {
            try persistence.deleteSession(id: id)
        } catch {
            AppLogger.state.warning("SessionStore failed to delete session", metadata: [
                "session_id": String(id.prefix(8)),
                "error": String(describing: error),
            ])
        }
    }

    @discardableResult
    private func forkSession(_ id: String, workingDirectory: String?) -> String? {
        guard let source = sessions.first(where: { $0.id == id }) else { return nil }

        let forkID = UUID().uuidString
        let cwd = workingDirectory ?? source.agent.workingDirectory
        let agent = AgentService(
            workingDir: cwd,
            modelOverride: source.codexSelection.model,
            reasoningEffortOverride: source.codexSelection.reasoningEffort,
            approvalPolicyOverride: source.codexApprovalSelection.approvalPolicy,
            sandboxModeOverride: source.codexApprovalSelection.sandboxMode
        )
        agent.messages = Self.copiedMessagesForFork(source.agent.messages)

        let session = Session(
            id: forkID,
            title: Self.forkedTitle(from: source.title),
            preview: source.preview,
            timestamp: Date(),
            agent: agent,
            codexSelection: source.codexSelection,
            codexApprovalSelection: source.codexApprovalSelection
        )

        sessions.insert(session, at: 0)
        observeMessages(for: forkID, agent: agent)
        activeSessionId = forkID
        persistSessionRecord(id: forkID, title: session.title)

        if !agent.messages.isEmpty {
            handleMessageUpdate(sessionID: forkID, messages: agent.messages)
        }

        return forkID
    }

    private static func copiedMessagesForFork(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            ChatMessage(
                id: UUID().uuidString,
                type: message.type,
                content: message.content,
                timestamp: message.timestamp,
                command: message.command,
                diff: message.diff,
                assistant: message.assistant,
                tool: message.tool
            )
        }
    }

    private static func forkedTitle(from title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultChatTitle : trimmed
        let forked = "\(base) fork"
        guard forked.count > 40 else { return forked }
        return "\(forked.prefix(37))..."
    }

    private nonisolated static func createForkWorktree(
        from workingDirectory: String,
        sessionID: String,
        title: String
    ) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
            throw SessionForkError.gitUnavailable
        }

        let repoRoot = try runGit(["-C", workingDirectory, "rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else {
            throw SessionForkError.gitCommandFailed("Could not resolve the git repository root.")
        }

        let shortID = String(sessionID.prefix(8)).lowercased()
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let sanitizedTitle = sanitizeWorktreeComponent(title)
        let slug = sanitizedTitle.isEmpty ? "thread" : sanitizedTitle
        let worktreesDirectory = URL(fileURLWithPath: repoRoot, isDirectory: true)
            .appendingPathComponent(".worktrees", isDirectory: true)
        try FileManager.default.createDirectory(
            at: worktreesDirectory,
            withIntermediateDirectories: true
        )

        let worktreeURL = worktreesDirectory
            .appendingPathComponent("\(slug)-\(shortID)-\(suffix)", isDirectory: true)
        let branchName = "smithers/fork/\(slug)-\(shortID)-\(suffix)"

        _ = try runGit([
            "-C", repoRoot,
            "worktree", "add",
            "-b", branchName,
            worktreeURL.path,
            "HEAD",
        ])

        return worktreeURL.path
    }

    private nonisolated static func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SessionForkError.gitCommandFailed(error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SessionForkError.gitCommandFailed(
                detail.isEmpty ? "git exited with status \(process.terminationStatus)." : detail
            )
        }

        return output
    }

    private nonisolated static func sanitizeWorktreeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String(collapsed.prefix(32))
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func emptyPlaceholderIndex() -> Int? {
        sessions.firstIndex { session in
            isPlaceholderTitle(session.title) &&
                session.preview.isEmpty &&
                session.agent.messages.isEmpty &&
                !session.agent.isRunning
        }
    }

    private func isPlaceholderTitle(_ title: String) -> Bool {
        title == Self.defaultChatTitle || title == "New Chat"
    }

    private func runTabTitle(runId: String, title: String?) -> String {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedTitle.isEmpty ? "Run \(String(runId.prefix(8)))" : trimmedTitle
    }

    private func runTabPreview(_ preview: String?) -> String {
        let normalized = preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "Workflow run" : normalized
    }

    private func runPreview(for run: RunSummary) -> String {
        let parts = [
            run.status.label,
            run.elapsedString.isEmpty ? nil : run.elapsedString,
        ].compactMap { $0 }
        return runTabPreview(parts.joined(separator: " · "))
    }

    private func makeSidebarTab(
        id: String,
        kind: SidebarTabKind,
        chatSessionId: String?,
        runId: String?,
        terminalId: String?,
        title: String,
        preview: String,
        date: Date,
        now: Date,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isUnread: Bool = false,
        workingDirectory: String? = nil,
        sessionIdentifier: String? = nil
    ) -> SidebarTab {
        SidebarTab(
            id: id,
            kind: kind,
            chatSessionId: chatSessionId,
            runId: runId,
            terminalId: terminalId,
            title: title,
            preview: preview,
            timestamp: Self.relativeTime(from: date, to: now),
            group: isPinned ? "Pinned" : Self.groupLabel(for: date),
            sortDate: date,
            isPinned: isPinned,
            isArchived: isArchived,
            isUnread: isUnread,
            workingDirectory: workingDirectory,
            sessionIdentifier: sessionIdentifier
        )
    }

    private static func groupLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            return "Older"
        }
    }

    private static func relativeTime(from date: Date, to now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }
}

enum ChatTitleGenerator {
    static func title(for text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.hasPrefix("/") {
            let parts = cleaned.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            cleaned = parts.count > 1 ? String(parts[1]) : cleaned
        }

        let lowercase = cleaned.lowercased()
        for prefix in ["can you ", "could you ", "please ", "help me ", "i need you to ", "i need to ", "we need to ", "let's "] {
            if lowercase.hasPrefix(prefix) {
                cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?:;\"'`"))
        guard !cleaned.isEmpty else { return SessionStore.defaultChatTitle }

        let words = cleaned.split(separator: " ").prefix(7).joined(separator: " ")
        if words.count <= 40 {
            return words
        }

        let prefix = String(words.prefix(37)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }
}
