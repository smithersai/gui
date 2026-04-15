import Foundation
import SwiftUI

struct Session: Identifiable {
    let id: String
    var title: String
    var preview: String
    var timestamp: Date
    var agent: AgentService
}

@MainActor
class SessionStore: ObservableObject {
    nonisolated static let defaultChatTitle = "Claude Code"

    @Published var sessions: [Session] = []
    @Published var runTabs: [RunTab] = []
    @Published var activeSessionId: String?

    var activeSession: Session? {
        sessions.first { $0.id == activeSessionId }
    }

    var activeAgent: AgentService? {
        activeSession?.agent
    }

    init() {
        newSession()
    }

    @discardableResult
    func newSession(reusingEmptyPlaceholder: Bool = false) -> String {
        if reusingEmptyPlaceholder, let idx = emptyPlaceholderIndex() {
            var session = sessions.remove(at: idx)
            session.timestamp = Date()
            sessions.insert(session, at: 0)
            activeSessionId = session.id
            return session.id
        }

        let id = UUID().uuidString
        let agent = AgentService()
        let session = Session(
            id: id,
            title: Self.defaultChatTitle,
            preview: "",
            timestamp: Date(),
            agent: agent
        )
        sessions.insert(session, at: 0)
        activeSessionId = id
        return id
    }

    @discardableResult
    func ensureActiveSession() -> String {
        if let activeSessionId, sessions.contains(where: { $0.id == activeSessionId }) {
            return activeSessionId
        }

        if let first = sessions.first {
            activeSessionId = first.id
            return first.id
        }

        return newSession()
    }

    func selectSession(_ id: String) {
        activeSessionId = id
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

    func sendMessage(_ text: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }

        if isPlaceholderTitle(sessions[idx].title) {
            sessions[idx].title = ChatTitleGenerator.title(for: text)
        }
        sessions[idx].preview = String(text.prefix(80))
        sessions[idx].timestamp = Date()

        sessions[idx].agent.sendMessage(text)
    }

    func sidebarTabs(matching searchText: String = "") -> [SidebarTab] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let chatTabs = sessions.map { session in
            makeSidebarTab(
                id: "chat:\(session.id)",
                kind: .chat,
                chatSessionId: session.id,
                runId: nil,
                title: session.title,
                preview: session.preview,
                date: session.timestamp,
                now: now
            )
        }
        let runTabs = runTabs.map { tab in
            makeSidebarTab(
                id: "run:\(tab.runId)",
                kind: .run,
                chatSessionId: nil,
                runId: tab.runId,
                title: tab.title,
                preview: tab.preview,
                date: tab.timestamp,
                now: now
            )
        }

        return (chatTabs + runTabs)
            .filter { tab in
                needle.isEmpty ||
                    tab.title.localizedCaseInsensitiveContains(needle) ||
                    tab.preview.localizedCaseInsensitiveContains(needle) ||
                    (tab.runId?.localizedCaseInsensitiveContains(needle) ?? false)
            }
            .sorted { $0.sortDate > $1.sortDate }
    }

    func chatSessions() -> [ChatSession] {
        let now = Date()
        return sessions.map { s in
            let group = Self.groupLabel(for: s.timestamp)
            let ago = Self.relativeTime(from: s.timestamp, to: now)
            return ChatSession(id: s.id, title: s.title, preview: s.preview, timestamp: ago, group: group)
        }
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
        title: String,
        preview: String,
        date: Date,
        now: Date
    ) -> SidebarTab {
        SidebarTab(
            id: id,
            kind: kind,
            chatSessionId: chatSessionId,
            runId: runId,
            title: title,
            preview: preview,
            timestamp: Self.relativeTime(from: date, to: now),
            group: Self.groupLabel(for: date),
            sortDate: date
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
