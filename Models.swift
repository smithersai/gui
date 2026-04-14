import SwiftUI

struct ChatSession: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let timestamp: String
    let group: String
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
    let cmd: String
    let cwd: String
    let output: String
    let exitCode: Int
    let running: Bool?
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

