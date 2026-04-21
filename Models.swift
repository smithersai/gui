import Foundation
import SwiftUI

enum AppPreferenceKeys {
    static let vimModeEnabled = "settings.vimModeEnabled"
    static let developerToolsEnabled = "settings.developerToolsEnabled"
    static let guiControlSidebarEnabled = "settings.guiControlSidebarEnabled"
    static let externalAgentUnsafeFlagsEnabled = "settings.externalAgentUnsafeFlagsEnabled"
    static let browserSearchEngine = "settings.browserSearchEngine"
    static let smithersFeatureEnabled = "settings.smithersFeatureEnabled"
    static let vcsFeatureEnabled = "settings.vcsFeatureEnabled"
}

enum NeovimDetector {
    static let commonExecutablePaths = [
        "/opt/homebrew/bin/nvim",
        "/usr/local/bin/nvim",
        "/usr/bin/nvim",
    ]

    static func executablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        Smithers.Terminal.neovimExecutablePath(environment: environment)
    }

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        Smithers.Terminal.neovimIsAvailable(environment: environment)
    }
}

struct RunWorkspace: Identifiable, Hashable {
    let runId: String
    var title: String
    var preview: String
    var timestamp: Date
    let createdAt: Date

    var id: String { runId }
    var workspaceID: WorkspaceID { WorkspaceID(runId) }
}

typealias RunTab = RunWorkspace

enum TerminalBackend: String, Hashable, Codable {
    case ghostty
    case tmux
}

struct TerminalWorkspaceRecord: Identifiable, Hashable {
    let terminalId: String
    var title: String
    var preview: String
    var timestamp: Date
    let createdAt: Date
    var workingDirectory: String? = nil
    var command: String? = nil
    var backend: TerminalBackend = .tmux
    var rootSurfaceId: String? = nil
    var tmuxSocketName: String? = nil
    var tmuxSessionName: String? = nil
    var isPinned: Bool = false

    var id: String { terminalId }
    var workspaceID: WorkspaceID { WorkspaceID(terminalId) }
}

typealias TerminalTab = TerminalWorkspaceRecord

struct TmuxTerminalTarget: Hashable {
    let socketName: String
    let sessionName: String
}

enum TmuxController {
    static let commonExecutablePaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    static func executablePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        Smithers.Terminal.tmuxExecutablePath(environment: environment)
    }

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        Smithers.Terminal.tmuxIsAvailable(environment: environment)
    }

    static func socketName(for workingDirectory: String) -> String {
        Smithers.Terminal.tmuxSocketName(for: workingDirectory)
    }

    static func rootSurfaceId(for terminalId: String) -> String {
        Smithers.Terminal.tmuxRootSurfaceId(for: terminalId)
    }

    static func sessionName(for surfaceId: String) -> String {
        Smithers.Terminal.tmuxSessionName(for: surfaceId)
    }

    static func attachCommand(
        socketName: String?,
        sessionName: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        Smithers.Terminal.tmuxAttachCommand(
            socketName: socketName,
            sessionName: sessionName,
            environment: environment
        )
    }

    @discardableResult
    static func ensureSession(
        socketName: String,
        sessionName: String,
        workingDirectory: String?,
        command: String?,
        title: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let ok = Smithers.Terminal.tmuxEnsureSession(
            socketName: socketName,
            sessionName: sessionName,
            workingDirectory: workingDirectory,
            command: command,
            title: title,
            environment: environment
        )
        if !ok {
            AppLogger.terminal.warning("tmux session setup failed", metadata: ["session": sessionName])
        }
        return ok
    }

    static func terminateSession(
        socketName: String?,
        sessionName: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        Smithers.Terminal.tmuxTerminateSession(
            socketName: socketName,
            sessionName: sessionName,
            environment: environment
        )
    }

    static func capturePane(socketName: String, sessionName: String, lines: Int = 200) throws -> String {
        try Smithers.Terminal.tmuxCapturePane(socketName: socketName, sessionName: sessionName, lines: lines)
    }

    static func sendText(socketName: String, sessionName: String, text: String, enter: Bool = false) throws {
        try Smithers.Terminal.tmuxSendText(
            socketName: socketName,
            sessionName: sessionName,
            text: text,
            enter: enter
        )
    }
}

enum TmuxControllerError: LocalizedError {
    case tmuxUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .tmuxUnavailable:
            return "tmux is not available."
        case .commandFailed(let message):
            return message.isEmpty ? "tmux command failed." : message
        }
    }
}

enum SidebarWorkspaceKind: Hashable {
    case run
    case terminal

    var icon: String {
        switch self {
        case .run: return "dot.radiowaves.left.and.right"
        case .terminal: return "terminal.fill"
        }
    }
}

typealias SidebarTabKind = SidebarWorkspaceKind

struct SidebarWorkspace: Identifiable, Hashable {
    let id: String
    let kind: SidebarWorkspaceKind
    let runId: String?
    let terminalId: String?
    let title: String
    let preview: String
    let timestamp: String
    let group: String
    let sortDate: Date
    var isPinned: Bool = false
    var isArchived: Bool = false
    var isUnread: Bool = false
    var workingDirectory: String? = nil
    var sessionIdentifier: String? = nil

    var workspaceID: WorkspaceID {
        if let terminalId {
            return WorkspaceID(terminalId)
        }
        if let runId {
            return WorkspaceID(runId)
        }
        return WorkspaceID(id)
    }
}

typealias SidebarTab = SidebarWorkspace

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
    (try? Smithers.Models.deduplicatedChatMessages(messages)) ?? messages
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
