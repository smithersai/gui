import Foundation
import SwiftUI

struct ChatSession: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let timestamp: String
    let group: String
}

struct RunTab: Identifiable, Hashable {
    let runId: String
    var title: String
    var preview: String
    var timestamp: Date

    var id: String { runId }
}

enum SidebarTabKind: Hashable {
    case chat
    case run

    var icon: String {
        switch self {
        case .chat: return "message"
        case .run: return "dot.radiowaves.left.and.right"
        }
    }
}

struct SidebarTab: Identifiable, Hashable {
    let id: String
    let kind: SidebarTabKind
    let chatSessionId: String?
    let runId: String?
    let title: String
    let preview: String
    let timestamp: String
    let group: String
    let sortDate: Date
}

struct ChatMessage: Identifiable {
    let id: String
    let type: MessageType
    let content: String
    let timestamp: String
    let command: Command?
    let diff: Diff?
    
    enum MessageType: String {
        case user, assistant, command, diff, status
    }
}

struct Command {
    let itemID: String?
    let cmd: String
    let cwd: String
    let output: String
    let exitCode: Int
    let running: Bool?

    init(
        itemID: String? = nil,
        cmd: String,
        cwd: String,
        output: String,
        exitCode: Int,
        running: Bool?
    ) {
        self.itemID = itemID
        self.cmd = cmd
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.running = running
    }
}

func deduplicatedChatMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
    var result: [ChatMessage] = []
    var commandIndexByItemID: [String: Int] = [:]

    for message in messages {
        guard let itemID = message.command?.itemID, !itemID.isEmpty else {
            result.append(message)
            continue
        }

        if let existingIndex = commandIndexByItemID[itemID] {
            result[existingIndex] = message
        } else {
            commandIndexByItemID[itemID] = result.count
            result.append(message)
        }
    }

    return result
}

struct Diff {
    let files: [DiffFile]
    let totalAdditions: Int
    let totalDeletions: Int
    let status: String
    let snippet: String
}

struct DiffFile {
    let name: String
    let additions: Int
    let deletions: Int
}

struct Agent: Identifiable {
    let id: String
    let name: String
    let status: AgentStatus
    let task: String
    let changes: Int
    
    enum AgentStatus: String {
        case idle, working, completed, failed
    }
}

struct JJChange: Identifiable {
    var id: String { file }
    let file: String
    let status: String
    let additions: Int
    let deletions: Int
}
