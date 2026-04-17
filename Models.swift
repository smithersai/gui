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
        let fileManager = FileManager.default
        let pathCandidates = environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { directory in
                ((String(directory) as NSString).appendingPathComponent("nvim") as NSString).standardizingPath
            }

        var seen = Set<String>()
        for candidate in pathCandidates + commonExecutablePaths {
            let standardized = (candidate as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { continue }
            if fileManager.isExecutableFile(atPath: standardized) {
                return standardized
            }
        }

        return nil
    }

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        executablePath(environment: environment) != nil
    }
}

struct ChatSession: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let timestamp: String
    let group: String
    var isPinned: Bool = false
    var isArchived: Bool = false
    var isUnread: Bool = false
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
        let fileManager = FileManager.default
        let pathCandidates = environment["PATH", default: ""]
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { directory in
                ((String(directory) as NSString).appendingPathComponent("tmux") as NSString).standardizingPath
            }

        var seen = Set<String>()
        for candidate in pathCandidates + commonExecutablePaths {
            let standardized = (candidate as NSString).standardizingPath
            guard seen.insert(standardized).inserted else { continue }
            if fileManager.isExecutableFile(atPath: standardized) {
                return standardized
            }
        }

        return nil
    }

    static func isAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        executablePath(environment: environment) != nil
    }

    static func socketName(for workingDirectory: String) -> String {
        "smithers-\(stableHash(workingDirectory))"
    }

    static func rootSurfaceId(for terminalId: String) -> String {
        "\(terminalId)-root"
    }

    static func sessionName(for surfaceId: String) -> String {
        let sanitized = sanitizeIdentifier(surfaceId)
        return "smt-\(sanitized.isEmpty ? stableHash(surfaceId) : sanitized)"
    }

    static func attachCommand(
        socketName: String?,
        sessionName: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let executable = executablePath(environment: environment),
              let socketName = normalized(socketName),
              let sessionName = normalized(sessionName)
        else {
            return nil
        }

        return "\(shellQuoted(executable)) -L \(shellQuoted(socketName)) attach-session -t \(shellQuoted(sessionName))"
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
        guard let executable = executablePath(environment: environment) else {
            AppLogger.terminal.warning("tmux executable not found; falling back to direct Ghostty shell")
            return false
        }

        if runTmux(executable: executable, arguments: ["-L", socketName, "has-session", "-t", sessionName]).success {
            renameWindow(
                executable: executable,
                socketName: socketName,
                sessionName: sessionName,
                title: title
            )
            return true
        }

        var arguments = ["-L", socketName, "new-session", "-d", "-s", sessionName]
        if let title = normalized(title) {
            arguments += ["-n", title]
        }
        if let workingDirectory = normalized(workingDirectory) {
            arguments += ["-c", workingDirectory]
        }
        if let command = normalized(command) {
            arguments.append(command)
        }

        let result = runTmux(executable: executable, arguments: arguments)
        if !result.success {
            AppLogger.terminal.warning("tmux new-session failed", metadata: [
                "session": sessionName,
                "error": result.error,
            ])
            return false
        }

        return true
    }

    static func terminateSession(
        socketName: String?,
        sessionName: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let executable = executablePath(environment: environment),
              let socketName = normalized(socketName),
              let sessionName = normalized(sessionName)
        else {
            return
        }
        _ = runTmux(executable: executable, arguments: ["-L", socketName, "kill-session", "-t", sessionName])
    }

    static func capturePane(socketName: String, sessionName: String, lines: Int = 200) throws -> String {
        guard let executable = executablePath() else {
            throw TmuxControllerError.tmuxUnavailable
        }
        let startLine = "-\(max(lines, 1))"
        let result = runTmux(
            executable: executable,
            arguments: ["-L", socketName, "capture-pane", "-p", "-S", startLine, "-t", sessionName]
        )
        guard result.success else {
            throw TmuxControllerError.commandFailed(result.error)
        }
        return result.output
    }

    static func sendText(socketName: String, sessionName: String, text: String, enter: Bool = false) throws {
        guard let executable = executablePath() else {
            throw TmuxControllerError.tmuxUnavailable
        }
        let literal = runTmux(
            executable: executable,
            arguments: ["-L", socketName, "send-keys", "-t", sessionName, "-l", "--", text]
        )
        guard literal.success else {
            throw TmuxControllerError.commandFailed(literal.error)
        }
        if enter {
            let enterResult = runTmux(
                executable: executable,
                arguments: ["-L", socketName, "send-keys", "-t", sessionName, "Enter"]
            )
            guard enterResult.success else {
                throw TmuxControllerError.commandFailed(enterResult.error)
            }
        }
    }

    private static func renameWindow(
        executable: String,
        socketName: String,
        sessionName: String,
        title: String?
    ) {
        guard let title = normalized(title) else { return }
        _ = runTmux(
            executable: executable,
            arguments: ["-L", socketName, "rename-window", "-t", sessionName, title]
        )
    }

    private static func runTmux(executable: String, arguments: [String]) -> (success: Bool, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (false, "", error.localizedDescription)
        }

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output, error.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func sanitizeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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

typealias SidebarTabKind = SidebarWorkspaceKind

struct SidebarWorkspace: Identifiable, Hashable {
    let id: String
    let kind: SidebarWorkspaceKind
    let chatSessionId: String?
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
        if let chatSessionId {
            return WorkspaceID(chatSessionId)
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
