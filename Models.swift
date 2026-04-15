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

struct TerminalTab: Identifiable, Hashable {
    let terminalId: String
    var title: String
    var preview: String
    var timestamp: Date

    var id: String { terminalId }
}

enum SidebarTabKind: Hashable {
    case chat
    case run
    case terminal

    var icon: String {
        switch self {
        case .chat: return "message"
        case .run: return "dot.radiowaves.left.and.right"
        case .terminal: return "terminal.fill"
        }
    }
}

struct SidebarTab: Identifiable, Hashable {
    let id: String
    let kind: SidebarTabKind
    let chatSessionId: String?
    let runId: String?
    let terminalId: String?
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
    let assistant: AssistantMessageMetadata?
    let tool: ToolMessagePayload?

    init(
        id: String,
        type: MessageType,
        content: String,
        timestamp: String,
        command: Command?,
        diff: Diff?,
        assistant: AssistantMessageMetadata? = nil,
        tool: ToolMessagePayload? = nil
    ) {
        self.id = id
        self.type = type
        self.content = content
        self.timestamp = timestamp
        self.command = command
        self.diff = diff
        self.assistant = assistant
        self.tool = tool
    }
    
    enum MessageType: String {
        case user, assistant, command, diff, status, tool
    }
}

struct AssistantMessageMetadata {
    let thinking: String?
    let errorMessage: String?
    let errorDetails: String?

    init(
        thinking: String? = nil,
        errorMessage: String? = nil,
        errorDetails: String? = nil
    ) {
        self.thinking = thinking
        self.errorMessage = errorMessage
        self.errorDetails = errorDetails
    }
}

enum ToolCategory: String {
    case bash
    case file
    case search
    case fetch
    case agent
    case diagnostics
    case references
    case lspRestart = "lsp_restart"
    case todos
    case mcp
    case generic
}

enum ToolExecutionStatus: String {
    case pending
    case running
    case success
    case error
    case canceled
    case unknown
}

struct ToolMessagePayload {
    let itemID: String?
    let category: ToolCategory
    let title: String
    let subtitle: String?
    let input: String?
    let output: String?
    let details: String?
    let status: ToolExecutionStatus
    let compact: Bool

    init(
        itemID: String? = nil,
        category: ToolCategory,
        title: String,
        subtitle: String? = nil,
        input: String? = nil,
        output: String? = nil,
        details: String? = nil,
        status: ToolExecutionStatus,
        compact: Bool = false
    ) {
        self.itemID = itemID
        self.category = category
        self.title = title
        self.subtitle = subtitle
        self.input = input
        self.output = output
        self.details = details
        self.status = status
        self.compact = compact
    }

    var copyText: String {
        var parts: [String] = []
        parts.append(title)
        if let subtitle, !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let input, !input.isEmpty {
            parts.append("Input:\n\(input)")
        }
        if let output, !output.isEmpty {
            parts.append("Output:\n\(output)")
        }
        if let details, !details.isEmpty {
            parts.append("Details:\n\(details)")
        }
        return parts.joined(separator: "\n\n")
    }
}

struct Command {
    let itemID: String?
    let cmd: String
    let cwd: String
    let output: String
    let exitCode: Int?
    let running: Bool?
    let toolCategory: ToolCategory?
    let toolDisplayName: String?
    let details: String?
    let compact: Bool

    init(
        itemID: String? = nil,
        cmd: String,
        cwd: String,
        output: String,
        exitCode: Int?,
        running: Bool?,
        toolCategory: ToolCategory? = nil,
        toolDisplayName: String? = nil,
        details: String? = nil,
        compact: Bool = false
    ) {
        self.itemID = itemID
        self.cmd = cmd
        self.cwd = cwd
        self.output = output
        self.exitCode = exitCode
        self.running = running
        self.toolCategory = toolCategory
        self.toolDisplayName = toolDisplayName
        self.details = details
        self.compact = compact
    }
}

func deduplicatedChatMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
    var result: [ChatMessage] = []
    var commandIndexByItemID: [String: Int] = [:]

    for message in messages {
        let commandItemID = message.command?.itemID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let toolItemID = message.tool?.itemID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemID = [commandItemID, toolItemID]
            .compactMap { $0 }
            .first { !$0.isEmpty }

        guard let itemID else {
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

struct Diff: Sendable {
    let files: [DiffFile]
    let totalAdditions: Int
    let totalDeletions: Int
    let status: String
    let snippet: String
}

struct DiffFile: Sendable {
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
    var id: String { "\(status):\(file)" }
    let file: String
    let status: String
    let additions: Int
    let deletions: Int
}
