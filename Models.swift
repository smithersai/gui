import Foundation
import SwiftUI
#if canImport(Darwin)
import Darwin
#endif

enum AppPreferenceKeys {
    static let vimModeEnabled = "settings.vimModeEnabled"
    static let developerToolsEnabled = "settings.developerToolsEnabled"
    static let guiControlSidebarEnabled = "settings.guiControlSidebarEnabled"
    static let externalAgentUnsafeFlagsEnabled = "settings.externalAgentUnsafeFlagsEnabled"
    static let browserSearchEngine = "settings.browserSearchEngine"
    static let shortcutCheatSheetFooterEnabled = "settings.shortcutCheatSheetFooterEnabled"
    static let defaultShellPath = "settings.defaultShellPath"
}

enum TerminalShellPreference {
    static let systemDefaultValue = ""
    static let commonShellPaths = [
        "/bin/zsh",
        "/bin/bash",
        "/bin/sh",
        "/opt/homebrew/bin/fish",
        "/usr/local/bin/fish",
        "/opt/homebrew/bin/nu",
        "/usr/local/bin/nu",
    ]

    static func resolvedShellPath(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        detectedLoginShellPath: String? = loginShellPath()
    ) -> String? {
        resolvedShellPath(
            configuredPath: userDefaults.string(forKey: AppPreferenceKeys.defaultShellPath),
            environment: environment,
            fileManager: fileManager,
            detectedLoginShellPath: detectedLoginShellPath
        )
    }

    static func resolvedShellPath(
        configuredPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        detectedLoginShellPath: String? = loginShellPath()
    ) -> String? {
        let candidates = [
            normalizedPath(configuredPath),
            normalizedPath(detectedLoginShellPath),
            normalizedPath(environment["SHELL"]),
        ] + commonShellPaths.map(Optional.some)

        return firstUsablePath(in: candidates, fileManager: fileManager)
    }

    static func availableShellPaths(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        detectedLoginShellPath: String? = loginShellPath()
    ) -> [String] {
        let candidates = [
            normalizedPath(userDefaults.string(forKey: AppPreferenceKeys.defaultShellPath)),
            normalizedPath(detectedLoginShellPath),
            normalizedPath(environment["SHELL"]),
        ] + commonShellPaths.map(Optional.some)

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard let path = normalizedPath(candidate),
                  isUsableShellPath(path, fileManager: fileManager),
                  !seen.contains(path)
            else {
                return nil
            }
            seen.insert(path)
            return path
        }
    }

    static func isUsableShellPath(_ path: String, fileManager: FileManager = .default) -> Bool {
        guard let normalized = normalizedPath(path),
              normalized.hasPrefix("/")
        else {
            return false
        }
        return fileManager.isExecutableFile(atPath: normalized)
    }

    static func displayName(for path: String) -> String {
        let name = shellName(for: path)
        let displayPath = (path as NSString).abbreviatingWithTildeInPath
        return "\(name) (\(displayPath))"
    }

    static func loginShellLaunchCommand(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        detectedLoginShellPath: String? = loginShellPath()
    ) -> String? {
        guard let shell = resolvedShellPath(
            userDefaults: userDefaults,
            environment: environment,
            fileManager: fileManager,
            detectedLoginShellPath: detectedLoginShellPath
        ) else {
            return nil
        }
        return "\(shellQuote(shell)) -l"
    }

    static func shellName(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func normalizedPath(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func firstUsablePath(in candidates: [String?], fileManager: FileManager) -> String? {
        var seen = Set<String>()
        for candidate in candidates {
            guard let path = normalizedPath(candidate),
                  !seen.contains(path)
            else {
                continue
            }
            seen.insert(path)
            if isUsableShellPath(path, fileManager: fileManager) {
                return path
            }
        }
        return nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func loginShellPath() -> String? {
        #if canImport(Darwin)
        guard let passwd = getpwuid(getuid()),
              let shell = passwd.pointee.pw_shell
        else {
            return nil
        }
        return normalizedPath(String(cString: shell))
        #else
        return nil
        #endif
    }
}

enum NeovimDetector {
    static let commonExecutablePaths = [
        "/opt/homebrew/bin/nvim",
        "/usr/local/bin/nvim",
        "/usr/bin/nvim",
    ]

    static func executablePath(environment: [String: String]? = nil) -> String? {
        Smithers.Terminal.neovimExecutablePath(environment: environment)
    }

    static func isAvailable(environment: [String: String]? = nil) -> Bool {
        Smithers.Terminal.neovimIsAvailable(environment: environment)
    }
}

struct RunWorkspace: Identifiable, Hashable, Codable {
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
    case native

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "ghostty":
            self = .ghostty
        case "native", "tmux":
            self = .native
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown terminal backend: \(rawValue)"
            )
        }
    }
}

struct TerminalWorkspaceRecord: Identifiable, Hashable, Codable {
    struct HijackBinding: Hashable, Codable {
        let agent: String
        let autoHijacked: Bool
        let resumeToken: String?
    }

    let terminalId: String
    var title: String
    var preview: String
    var timestamp: Date
    let createdAt: Date
    var workingDirectory: String? = nil
    var command: String? = nil
    var backend: TerminalBackend = .native
    var rootSurfaceId: String? = nil
    var sessionId: String? = nil
    var runId: String? = nil
    var hijack: HijackBinding? = nil
    var isPinned: Bool = false
    var rootKind: WorkspaceSurfaceKind = .terminal
    var browserURLString: String? = nil
    var agentKind: ExternalAgentKind? = nil
    var agentSessionId: String? = nil
    var snapshot: TerminalWorkspaceSnapshot? = nil

    var id: String { terminalId }
    var workspaceID: WorkspaceID { WorkspaceID(terminalId) }

    enum CodingKeys: String, CodingKey {
        case terminalId
        case title
        case preview
        case timestamp
        case createdAt
        case workingDirectory
        case command
        case backend
        case rootSurfaceId
        case sessionId
        case runId
        case hijack
        case isPinned
        case rootKind
        case browserURLString
        case agentKind
        case agentSessionId
        case snapshot
    }

    init(
        terminalId: String,
        title: String,
        preview: String,
        timestamp: Date,
        createdAt: Date,
        workingDirectory: String? = nil,
        command: String? = nil,
        backend: TerminalBackend = .native,
        rootSurfaceId: String? = nil,
        sessionId: String? = nil,
        runId: String? = nil,
        hijack: HijackBinding? = nil,
        isPinned: Bool = false,
        rootKind: WorkspaceSurfaceKind = .terminal,
        browserURLString: String? = nil,
        agentKind: ExternalAgentKind? = nil,
        agentSessionId: String? = nil,
        snapshot: TerminalWorkspaceSnapshot? = nil
    ) {
        self.terminalId = terminalId
        self.title = title
        self.preview = preview
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.workingDirectory = workingDirectory
        self.command = command
        self.backend = backend
        self.rootSurfaceId = rootSurfaceId
        self.sessionId = sessionId
        self.runId = runId
        self.hijack = hijack
        self.isPinned = isPinned
        self.rootKind = rootKind
        self.browserURLString = browserURLString
        self.agentKind = agentKind
        self.agentSessionId = agentSessionId
        self.snapshot = snapshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = try container.decode(String.self, forKey: .terminalId)
        title = try container.decode(String.self, forKey: .title)
        preview = try container.decode(String.self, forKey: .preview)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        backend = try container.decodeIfPresent(TerminalBackend.self, forKey: .backend) ?? .native
        rootSurfaceId = try container.decodeIfPresent(String.self, forKey: .rootSurfaceId)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        hijack = try container.decodeIfPresent(HijackBinding.self, forKey: .hijack)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        rootKind = try container.decodeIfPresent(WorkspaceSurfaceKind.self, forKey: .rootKind) ?? .terminal
        browserURLString = try container.decodeIfPresent(String.self, forKey: .browserURLString)
        agentKind = try container.decodeIfPresent(ExternalAgentKind.self, forKey: .agentKind)
        agentSessionId = try container.decodeIfPresent(String.self, forKey: .agentSessionId)
        snapshot = try container.decodeIfPresent(TerminalWorkspaceSnapshot.self, forKey: .snapshot)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(terminalId, forKey: .terminalId)
        try container.encode(title, forKey: .title)
        try container.encode(preview, forKey: .preview)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encodeIfPresent(command, forKey: .command)
        try container.encode(backend, forKey: .backend)
        try container.encodeIfPresent(rootSurfaceId, forKey: .rootSurfaceId)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(runId, forKey: .runId)
        try container.encodeIfPresent(hijack, forKey: .hijack)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(rootKind, forKey: .rootKind)
        try container.encodeIfPresent(browserURLString, forKey: .browserURLString)
        try container.encodeIfPresent(agentKind, forKey: .agentKind)
        try container.encodeIfPresent(agentSessionId, forKey: .agentSessionId)
        try container.encodeIfPresent(snapshot, forKey: .snapshot)
    }
}

typealias TerminalTab = TerminalWorkspaceRecord

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
    var agentKind: ExternalAgentKind? = nil
    var agentSessionId: String? = nil
    var folderPath: String? = nil

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

struct SidebarWorkspaceFolder: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    var folders: [SidebarWorkspaceFolder]
    var workspaces: [SidebarWorkspace]

    var isEmpty: Bool {
        folders.isEmpty && workspaces.isEmpty
    }
}

enum SidebarWorkspaceTreeBuilder {
    static func build(workspaces: [SidebarWorkspace], rootPath: String) -> [SidebarWorkspaceFolder] {
        var root = MutableFolder(name: "", path: normalizedPath(rootPath))
        for workspace in workspaces {
            let path = normalizedPath(workspace.folderPath ?? workspace.workingDirectory ?? rootPath)
            let components = displayComponents(for: path, rootPath: root.path)
            root.insert(workspace, components: components, absolutePath: path)
        }
        return root.children
            .map { $0.value.materialized() }
            .sorted(by: sortFolders)
    }

    private static func displayComponents(for path: String, rootPath: String) -> [String] {
        if path == rootPath {
            return [lastPathComponent(path)]
        }
        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        if path.hasPrefix(rootWithSlash) {
            let relative = String(path.dropFirst(rootWithSlash.count))
            let pieces = relative.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            return pieces.isEmpty ? [lastPathComponent(path)] : pieces
        }
        let home = NSHomeDirectory()
        let homeWithSlash = home.hasSuffix("/") ? home : "\(home)/"
        if path.hasPrefix(homeWithSlash) {
            return ["~"] + path.dropFirst(homeWithSlash.count).split(separator: "/").map(String.init)
        }
        let pieces = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        return pieces.isEmpty ? [path] : pieces
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private static func lastPathComponent(_ path: String) -> String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func sortFolders(_ lhs: SidebarWorkspaceFolder, _ rhs: SidebarWorkspaceFolder) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private struct MutableFolder {
        let name: String
        let path: String
        var children: [String: MutableFolder] = [:]
        var workspaces: [SidebarWorkspace] = []

        mutating func insert(_ workspace: SidebarWorkspace, components: [String], absolutePath: String) {
            guard let head = components.first else {
                workspaces.append(workspace)
                return
            }
            let childPath = path.isEmpty || path == "/" ? "/\(head)" : "\(path)/\(head)"
            var child = children[head] ?? MutableFolder(name: head, path: components.count == 1 ? absolutePath : childPath)
            child.insert(workspace, components: Array(components.dropFirst()), absolutePath: absolutePath)
            children[head] = child
        }

        func materialized() -> SidebarWorkspaceFolder {
            SidebarWorkspaceFolder(
                id: path,
                name: name,
                path: path,
                folders: children.values.map { $0.materialized() }.sorted(by: SidebarWorkspaceTreeBuilder.sortFolders),
                workspaces: workspaces.sorted {
                    if $0.isPinned != $1.isPinned { return $0.isPinned && !$1.isPinned }
                    return $0.sortDate > $1.sortDate
                }
            )
        }
    }
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
