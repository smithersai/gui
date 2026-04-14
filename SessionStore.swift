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
    @Published var sessions: [Session] = []
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

    func newSession() {
        let id = UUID().uuidString
        let agent = AgentService()
        let session = Session(
            id: id,
            title: "New Chat",
            preview: "",
            timestamp: Date(),
            agent: agent
        )
        sessions.insert(session, at: 0)
        activeSessionId = id
    }

    func selectSession(_ id: String) {
        activeSessionId = id
    }

    func sendMessage(_ text: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == activeSessionId }) else { return }

        // Update session title from first message
        if sessions[idx].title == "New Chat" {
            sessions[idx].title = String(text.prefix(40))
        }
        sessions[idx].preview = String(text.prefix(80))
        sessions[idx].timestamp = Date()

        sessions[idx].agent.sendMessage(text)
    }

    func chatSessions() -> [ChatSession] {
        let now = Date()
        let calendar = Calendar.current
        return sessions.map { s in
            let group: String
            if calendar.isDateInToday(s.timestamp) {
                group = "Today"
            } else if calendar.isDateInYesterday(s.timestamp) {
                group = "Yesterday"
            } else {
                group = "Older"
            }
            let ago = Self.relativeTime(from: s.timestamp, to: now)
            return ChatSession(id: s.id, title: s.title, preview: s.preview, timestamp: ago, group: group)
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
