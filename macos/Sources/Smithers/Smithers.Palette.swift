import Foundation
import CSmithersKit

extension Smithers {
    @MainActor
    final class Palette: ObservableObject {
        @Published var query = "" {
            didSet { setQuery(query) }
        }
        @Published var mode: CommandPaletteMode = .openAnything {
            didSet { setMode(mode) }
        }

        private let app: App
        private var palette: smithers_palette_t?
        nonisolated(unsafe) private let paletteHandle = MainThreadPaletteHandle()
        private let decoder = JSONDecoder()

        init(app: App? = nil) {
            self.app = app ?? App()
            if let cApp = self.app.app {
                let created = smithers_palette_new(cApp)
                palette = created
                paletteHandle.replace(created)
            }
        }

        deinit {
            paletteHandle.replace(nil)
        }

        func items(limit: Int = 120) -> [CommandPaletteItem] {
            guard let palette else { return [] }
            let data = Data(Smithers.string(from: smithers_palette_items_json(palette)).utf8)
            guard let rawItems = try? decoder.decode([PaletteItemPayload].self, from: data) else {
                return []
            }
            return rawItems.prefix(limit).map(CommandPaletteItem.init(payload:))
        }

        func activate(_ itemID: String) throws {
            guard let palette else {
                throw SmithersError.notAvailable("libsmithers palette is unavailable")
            }
            let error = itemID.withCString { smithers_palette_activate(palette, $0) }
            if let message = Smithers.message(from: error) {
                throw SmithersError.api(message)
            }
        }

        private func setMode(_ mode: CommandPaletteMode) {
            guard let palette else { return }
            smithers_palette_set_mode(palette, mode.cValue)
        }

        private func setQuery(_ query: String) {
            guard let palette else { return }
            query.withCString { smithers_palette_set_query(palette, $0) }
        }
    }
}

private final class MainThreadPaletteHandle {
    private var palette: smithers_palette_t?

    func replace(_ newValue: smithers_palette_t?) {
        if let palette {
            Self.free(palette)
        }
        palette = newValue
    }

    deinit {
        if let palette {
            Self.free(palette)
        }
    }

    private static func free(_ palette: smithers_palette_t) {
        if Thread.isMainThread {
            smithers_palette_free(palette)
        } else {
            DispatchQueue.main.sync {
                smithers_palette_free(palette)
            }
        }
    }
}

enum CommandPaletteMode: String, CaseIterable, Hashable {
    case openAnything
    case command
    case askAI
    case mentionFile
    case slash
    case workItem

    var prefix: Character? {
        switch self {
        case .openAnything: return nil
        case .command: return ">"
        case .askAI: return "?"
        case .mentionFile: return "@"
        case .slash: return "/"
        case .workItem: return "#"
        }
    }

    var title: String {
        switch self {
        case .openAnything: return "Open Anything"
        case .command: return "Command Mode"
        case .askAI: return "Ask AI"
        case .mentionFile: return "Files"
        case .slash: return "Slash Commands"
        case .workItem: return "Work Items"
        }
    }

    var cValue: smithers_palette_mode_e {
        switch self {
        case .openAnything, .askAI, .workItem: return SMITHERS_PALETTE_MODE_ALL
        case .command, .slash: return SMITHERS_PALETTE_MODE_COMMANDS
        case .mentionFile: return SMITHERS_PALETTE_MODE_FILES
        }
    }
}

struct ParsedCommandPaletteQuery: Equatable {
    let mode: CommandPaletteMode
    let prefix: Character?
    let rawText: String
    let searchText: String
}

enum CommandPaletteQueryParser {
    static func parse(_ raw: String) -> ParsedCommandPaletteQuery {
        let trimmedLeading = raw.drop(while: { $0.isWhitespace })
        guard let first = trimmedLeading.first else {
            return ParsedCommandPaletteQuery(mode: .openAnything, prefix: nil, rawText: raw, searchText: "")
        }
        let mode: CommandPaletteMode
        switch first {
        case ">": mode = .command
        case "?": mode = .askAI
        case "@": mode = .mentionFile
        case "/": mode = .slash
        case "#": mode = .workItem
        default: mode = .openAnything
        }
        guard mode != .openAnything else {
            return ParsedCommandPaletteQuery(
                mode: mode,
                prefix: nil,
                rawText: raw,
                searchText: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return ParsedCommandPaletteQuery(
            mode: mode,
            prefix: mode.prefix,
            rawText: raw,
            searchText: String(trimmedLeading.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

struct CommandPaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let section: String
    let keywords: [String]
    let shortcut: String?
    let action: CommandPaletteAction
    let isEnabled: Bool
}

enum CommandPaletteAction: Hashable {
    case navigate(NavDestination)
    case selectSidebarTab(String)
    case newTerminal
    case openMarkdownFilePicker
    case closeCurrentTab
    case askAI(String)
    case slashCommand(String)
    case openFile(String)
    case globalSearch(String)
    case refreshCurrentView
    case cancelCurrentOperation
    case toggleDeveloperDebug
    case switchToTabIndex(Int)
    case nextVisibleTab
    case previousVisibleTab
    case showShortcutCheatSheet
    case openTabSwitcher
    case findTab
    case unsupported(String)
}

struct CommandPaletteContext {
    var destination: NavDestination
    var sidebarTabs: [SidebarTab]
    var runTabs: [RunTab]
    var workflows: [Workflow]
    var prompts: [SmithersPrompt]
    var issues: [SmithersIssue]
    var tickets: [Ticket]
    var landings: [Landing]
    var slashCommands: [SlashCommandItem]
    var files: [String]
    var developerToolsEnabled: Bool
}

@MainActor
enum CommandPaletteBuilder {
    static func items(for rawQuery: String, context: CommandPaletteContext, limit: Int = 120) -> [CommandPaletteItem] {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        let palette = Smithers.Palette()
        palette.mode = parsed.mode
        palette.query = parsed.searchText
        let libItems = palette.items(limit: limit)
        if !libItems.isEmpty {
            return libItems
        }

        // UI-only fallback for the empty/stub palette path. Core owns ranking
        // and discovery; this keeps keyboard navigation usable while it is absent.
        let query = parsed.searchText.normalizedCommandPaletteQuery
        let candidates: [CommandPaletteItem]
        switch parsed.mode {
        case .command:
            candidates = commandItems(developerToolsEnabled: context.developerToolsEnabled)
        case .slash:
            candidates = slashItems(commands: context.slashCommands, query: parsed.searchText)
        case .mentionFile:
            candidates = context.files.prefix(limit).map { fileItem($0) }
        case .askAI:
            candidates = [CommandPaletteItem(
                id: "ask:\(parsed.searchText)",
                title: parsed.searchText.isEmpty ? "Ask AI" : parsed.searchText,
                subtitle: "Ask about this workspace.",
                icon: "sparkles",
                section: "AI",
                keywords: [parsed.searchText],
                shortcut: nil,
                action: .askAI(parsed.searchText),
                isEnabled: true
            )]
        default:
            candidates = routeItems(developerToolsEnabled: context.developerToolsEnabled) +
                context.sidebarTabs.map(tabItem) +
                context.runTabs.map(runItem) +
                context.files.prefix(20).map(fileItem)
        }
        guard !query.isEmpty else { return Array(candidates.prefix(limit)) }
        return candidates
            .filter { item in
                ([item.title, item.subtitle] + item.keywords).contains {
                    $0.normalizedCommandPaletteQuery.contains(query)
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    static func routeItems(developerToolsEnabled: Bool) -> [CommandPaletteItem] {
        let routes: [NavDestination] = [
            .dashboard, .terminal(id: "default"), .runs, .workflows, .triggers,
            .approvals, .prompts, .search, .memory, .scores, .sql, .logs,
            .workspaces, .changes, .jjhubWorkflows, .landings, .tickets, .issues,
            .settings,
        ]
        var items = routes.map { routeItem($0) }
        if developerToolsEnabled {
            items.append(CommandPaletteItem(
                id: "route:developer-debug",
                title: "Developer Debug",
                subtitle: "Toggle developer diagnostics.",
                icon: "wrench.and.screwdriver",
                section: "Destinations",
                keywords: ["developer", "debug"],
                shortcut: "Cmd+Shift+D",
                action: .toggleDeveloperDebug,
                isEnabled: true
            ))
        }
        return items
    }

    static func commandItems(developerToolsEnabled: Bool) -> [CommandPaletteItem] {
        var items = [
            CommandPaletteItem(id: "command.new-terminal", title: "New Terminal Workspace", subtitle: "Open a terminal.", icon: "terminal.fill", section: "Commands", keywords: ["new", "terminal"], shortcut: "Cmd+N", action: .newTerminal, isEnabled: true),
            CommandPaletteItem(id: "command.close-tab", title: "Close Current Tab", subtitle: "Close the active workspace tab.", icon: "xmark", section: "Commands", keywords: ["close", "tab"], shortcut: "Cmd+W", action: .closeCurrentTab, isEnabled: true),
            CommandPaletteItem(id: "command.refresh", title: "Refresh Current View", subtitle: "Reload the active view.", icon: "arrow.clockwise", section: "Commands", keywords: ["refresh", "reload"], shortcut: "Cmd+R", action: .refreshCurrentView, isEnabled: true),
            CommandPaletteItem(id: "command.global-search", title: "Global Search", subtitle: "Search code, issues, and repos.", icon: "magnifyingglass", section: "Commands", keywords: ["search"], shortcut: "Cmd+Shift+F", action: .globalSearch(""), isEnabled: true),
            CommandPaletteItem(id: "command.shortcuts", title: "Keyboard Shortcuts", subtitle: "Show configured shortcuts.", icon: "keyboard", section: "Commands", keywords: ["keyboard", "shortcuts"], shortcut: "Cmd+/", action: .showShortcutCheatSheet, isEnabled: true),
        ]
        if developerToolsEnabled {
            items.append(CommandPaletteItem(id: "command.debug", title: "Toggle Developer Debug", subtitle: "Show diagnostics.", icon: "wrench.and.screwdriver", section: "Commands", keywords: ["developer", "debug"], shortcut: "Cmd+Shift+D", action: .toggleDeveloperDebug, isEnabled: true))
        }
        return items
    }

    static func slashItems(commands: [SlashCommandItem], query: String) -> [CommandPaletteItem] {
        SlashCommandRegistry.matches(for: "/\(query)", commands: commands).map { command in
            CommandPaletteItem(
                id: "slash:\(command.name)",
                title: command.displayName,
                subtitle: command.description,
                icon: command.category.icon,
                section: "Slash Commands",
                keywords: [command.name, command.title] + command.aliases,
                shortcut: nil,
                action: .slashCommand(command.name),
                isEnabled: true
            )
        }
    }

    private static func routeItem(_ destination: NavDestination) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "route:\(destination.label.normalizedCommandPaletteQuery)",
            title: destination.label,
            subtitle: "Navigate to \(destination.label).",
            icon: destination.icon,
            section: "Destinations",
            keywords: [destination.label],
            shortcut: nil,
            action: .navigate(destination),
            isEnabled: true
        )
    }

    private static func tabItem(_ tab: SidebarTab) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "tab:\(tab.id)",
            title: tab.title,
            subtitle: tab.preview,
            icon: tab.kind.icon,
            section: "Open Tabs",
            keywords: [tab.id, tab.title, tab.preview],
            shortcut: nil,
            action: .selectSidebarTab(tab.id),
            isEnabled: true
        )
    }

    private static func runItem(_ run: RunTab) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "run:\(run.runId)",
            title: run.title,
            subtitle: run.preview,
            icon: "dot.radiowaves.left.and.right",
            section: "Runs",
            keywords: [run.runId, run.title],
            shortcut: nil,
            action: .selectSidebarTab("run:\(run.runId)"),
            isEnabled: true
        )
    }

    private static func fileItem(_ path: String) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "file:\(path)",
            title: path.lastPathComponent,
            subtitle: path,
            icon: "doc.text",
            section: "Files",
            keywords: [path],
            shortcut: nil,
            action: .openFile(path),
            isEnabled: true
        )
    }
}

@MainActor
final class WorkspaceFileSearchIndex: ObservableObject {
    @Published private(set) var files: [String] = []
    private var rootPath: String

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    func updateRootPath(_ path: String) {
        rootPath = path
        files = []
    }

    func ensureLoaded() {}

    func matches(for query: String, limit: Int = 80) -> [String] {
        let normalized = query.normalizedCommandPaletteQuery
        guard !normalized.isEmpty else { return Array(files.prefix(limit)) }
        return files.filter { $0.normalizedCommandPaletteQuery.contains(normalized) }.prefix(limit).map { $0 }
    }
}

private struct PaletteItemPayload: Decodable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: String?
    let score: Double?
    let icon: String?
    let shortcut: String?
}

private extension CommandPaletteItem {
    init(payload: PaletteItemPayload) {
        self.id = payload.id
        self.title = payload.title
        self.subtitle = payload.subtitle ?? ""
        self.icon = payload.icon ?? Self.icon(for: payload.kind)
        self.section = payload.kind?.capitalized ?? "Results"
        self.keywords = [payload.id, payload.title, payload.subtitle].compactMap { $0 }
        self.shortcut = payload.shortcut
        self.action = Self.action(for: payload)
        self.isEnabled = true
    }

    static func icon(for kind: String?) -> String {
        switch kind?.lowercased() {
        case "file", "files": return "doc.text"
        case "workflow", "workflows": return "arrow.triangle.branch"
        case "workspace", "workspaces": return "desktopcomputer"
        case "run", "runs": return "dot.radiowaves.left.and.right"
        default: return "magnifyingglass"
        }
    }

    static func action(for payload: PaletteItemPayload) -> CommandPaletteAction {
        if payload.id.hasPrefix("file:") {
            return .openFile(String(payload.id.dropFirst(5)))
        }
        if payload.id.hasPrefix("slash:") {
            return .slashCommand(String(payload.id.dropFirst(6)))
        }
        if let route = NavDestination.paletteRoute(id: payload.id, title: payload.title) {
            return .navigate(route)
        }
        return .unsupported(payload.id)
    }
}

private extension NavDestination {
    static func paletteRoute(id: String, title: String) -> NavDestination? {
        let token = id.replacingOccurrences(of: "route:", with: "").normalizedCommandPaletteQuery
        switch token.isEmpty ? title.normalizedCommandPaletteQuery : token {
        case "dashboard": return .dashboard
        case "vcsdashboard", "vcs-dashboard": return .vcsDashboard
        case "agents": return .agents
        case "changes": return .changes
        case "runs": return .runs
        case "snapshots": return .snapshots
        case "workflows": return .workflows
        case "triggers": return .triggers
        case "jjhubworkflows", "jjhub-workflows": return .jjhubWorkflows
        case "approvals": return .approvals
        case "prompts": return .prompts
        case "scores": return .scores
        case "memory": return .memory
        case "search": return .search
        case "sqlbrowser", "sql-browser", "sql": return .sql
        case "landings": return .landings
        case "tickets": return .tickets
        case "issues": return .issues
        case "terminal": return .terminal(id: "default")
        case "workspaces": return .workspaces
        case "logs": return .logs
        case "settings": return .settings
        default: return nil
        }
    }
}

private extension SlashCommandCategory {
    var icon: String {
        switch self {
        case .smithers: return "square.grid.2x2"
        case .workflow: return "arrow.triangle.branch"
        case .prompt: return "doc.text"
        case .action: return "bolt"
        }
    }
}

extension String {
    var normalizedCommandPaletteQuery: String {
        lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

extension Int {
    var ordinalLabel: String {
        switch self {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(self)th"
        }
    }
}
