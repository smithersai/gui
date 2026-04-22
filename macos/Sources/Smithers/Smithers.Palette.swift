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
    case newTab(NewTabSelection)
    case expandNewTabs
    case openMarkdownFilePicker
    case closeCurrentTab
    case askAI(String)
    case slashCommand(String)
    case runWorkflow(Workflow)
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
    static func items(
        for rawQuery: String,
        context: CommandPaletteContext,
        limit: Int = 120,
        primaryItems: [CommandPaletteItem]? = nil
    ) -> [CommandPaletteItem] {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        let libItems = resolvedPrimaryItems(
            override: primaryItems,
            parsed: parsed,
            workflows: context.workflows,
            limit: limit
        )

        // Supplement libsmithers results with app-local routes and tabs so
        // navigation remains complete even when core discovery is partial.
        let query = parsed.searchText.normalizedCommandPaletteQuery
        let supplementalCandidates: [CommandPaletteItem]
        switch parsed.mode {
        case .command:
            supplementalCandidates = commandItems(developerToolsEnabled: context.developerToolsEnabled)
        case .slash:
            supplementalCandidates = slashItems(commands: context.slashCommands, query: parsed.searchText)
        case .mentionFile:
            supplementalCandidates = context.files.prefix(limit).map { fileItem($0) }
        case .askAI:
            supplementalCandidates = [CommandPaletteItem(
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
            supplementalCandidates = routeItems(developerToolsEnabled: context.developerToolsEnabled) +
                context.sidebarTabs.map(tabItem) +
                context.runTabs.map(runItem) +
                context.workflows.map(workflowItem) +
                context.files.prefix(20).map(fileItem)
        }

        let filteredSupplemental: [CommandPaletteItem]
        if query.isEmpty {
            filteredSupplemental = Array(supplementalCandidates.prefix(limit))
        } else {
            filteredSupplemental = supplementalCandidates
                .filter { matches($0, query: query) }
                .prefix(limit)
                .map { $0 }
        }

        return mergedItems(primary: libItems, supplemental: filteredSupplemental, limit: limit)
    }

    private static func mergedItems(
        primary: [CommandPaletteItem],
        supplemental: [CommandPaletteItem],
        limit: Int
    ) -> [CommandPaletteItem] {
        guard !primary.isEmpty else { return Array(supplemental.prefix(limit)) }

        var merged = primary
        var seen = Set(primary.map(deduplicationKey(for:)))
        for item in supplemental where seen.insert(deduplicationKey(for: item)).inserted {
            merged.append(item)
            if merged.count == limit {
                break
            }
        }
        return merged
    }

    private static func deduplicationKey(for item: CommandPaletteItem) -> String {
        switch item.action {
        case .navigate(let destination):
            return "navigate:\(destination.label.normalizedCommandPaletteQuery)"
        case .selectSidebarTab(let id):
            return "tab:\(id)"
        case .slashCommand(let name):
            return "slash:\(name)"
        case .runWorkflow(let workflow):
            return "workflow:\((workflow.filePath ?? workflow.id).normalizedCommandPaletteQuery)"
        case .openFile(let path):
            return "file:\(path)"
        case .askAI(let query):
            return "ask:\(query)"
        default:
            if isWorkflowCandidate(item) {
                return "workflow:\(workflowIdentity(for: item))"
            }
            return "id:\(item.id.normalizedCommandPaletteQuery)"
        }
    }

    static func routeItems(developerToolsEnabled: Bool) -> [CommandPaletteItem] {
        let routes: [NavDestination] = [
            .dashboard, .vcsDashboard, .agents, .terminal(id: "default"), .runs, .snapshots,
            .workflows, .triggers,
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

    static func workflowItem(_ workflow: Workflow) -> CommandPaletteItem {
        CommandPaletteItem(
            id: "workflow:\(workflow.filePath ?? workflow.id)",
            title: workflow.name,
            subtitle: workflowSubtitle(for: workflow),
            icon: "arrow.triangle.branch",
            section: "Workflows",
            keywords: workflowMatchTokens(for: workflow),
            shortcut: nil,
            action: .runWorkflow(workflow),
            isEnabled: true
        )
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

    private static func resolvedPrimaryItems(
        override: [CommandPaletteItem]?,
        parsed: ParsedCommandPaletteQuery,
        workflows: [Workflow],
        limit: Int
    ) -> [CommandPaletteItem] {
        let items: [CommandPaletteItem]
        if let override {
            items = override
        } else {
            let palette = Smithers.Palette()
            palette.mode = parsed.mode
            palette.query = parsed.searchText
            items = palette.items(limit: limit)
        }
        return items.map { resolvedWorkflowItem($0, workflows: workflows) }
    }

    private static func resolvedWorkflowItem(_ item: CommandPaletteItem, workflows: [Workflow]) -> CommandPaletteItem {
        guard !matchesKnownWorkflowAction(item) else { return item }
        guard isWorkflowCandidate(item) else { return item }
        guard let workflow = workflows.first(where: { workflowMatches($0, item: item) }) else {
            return item
        }

        return CommandPaletteItem(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle.isEmpty ? workflowSubtitle(for: workflow) : item.subtitle,
            icon: item.icon,
            section: item.section,
            keywords: uniqued(item.keywords + workflowMatchTokens(for: workflow)),
            shortcut: item.shortcut,
            action: .runWorkflow(workflow),
            isEnabled: item.isEnabled
        )
    }

    private static func matches(_ item: CommandPaletteItem, query: String) -> Bool {
        let searchableValues = ([item.title, item.subtitle] + item.keywords)
            .map(\.normalizedCommandPaletteQuery)
            .filter { !$0.isEmpty }
        if searchableValues.contains(where: { $0.contains(query) }) {
            return true
        }
        guard case .runWorkflow(let workflow) = item.action else { return false }
        guard let leadingToken = leadingToken(in: query) else { return false }
        return workflowMatchTokens(for: workflow).contains {
            $0.normalizedCommandPaletteQuery.contains(leadingToken)
        }
    }

    fileprivate static func workflowMatchTokens(for workflow: Workflow) -> [String] {
        uniqued([workflow.name] + workflowAliases(for: workflow))
    }

    fileprivate static func workflowSubtitle(for workflow: Workflow) -> String {
        if let path = workflow.filePath {
            return "Workflow · \(path)"
        }
        return "Workflow"
    }

    private static func workflowAliases(for workflow: Workflow) -> [String] {
        var aliases = [workflow.id]
        if let path = workflow.filePath {
            aliases.append(path)
            let lastPathComponent = path.lastPathComponent
            aliases.append(lastPathComponent)
            let stem = (lastPathComponent as NSString).deletingPathExtension
            aliases.append(stem)
        }
        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.normalizedCommandPaletteQuery != workflow.name.normalizedCommandPaletteQuery }
    }

    private static func workflowMatches(_ workflow: Workflow, item: CommandPaletteItem) -> Bool {
        let title = item.title.normalizedCommandPaletteQuery
        let subtitle = item.subtitle.normalizedCommandPaletteQuery
        let identifier = item.id.normalizedCommandPaletteQuery

        if workflowMatchTokens(for: workflow).contains(where: { $0.normalizedCommandPaletteQuery == title }) {
            return true
        }

        guard let path = workflow.filePath?.normalizedCommandPaletteQuery else {
            return false
        }

        return subtitle == path || identifier.contains(path)
    }

    private static func matchesKnownWorkflowAction(_ item: CommandPaletteItem) -> Bool {
        if case .runWorkflow = item.action {
            return true
        }
        return false
    }

    private static func isWorkflowCandidate(_ item: CommandPaletteItem) -> Bool {
        let normalizedSection = item.section.normalizedCommandPaletteQuery
        let normalizedID = item.id.normalizedCommandPaletteQuery
        return normalizedSection == "workflows" ||
            item.icon == "arrow.triangle.branch" ||
            normalizedID.hasPrefix("workflow")
    }

    private static func workflowIdentity(for item: CommandPaletteItem) -> String {
        let normalizedTitle = item.title.normalizedCommandPaletteQuery
        if !normalizedTitle.isEmpty {
            return normalizedTitle
        }
        let normalizedSubtitle = item.subtitle.normalizedCommandPaletteQuery
        if !normalizedSubtitle.isEmpty {
            return normalizedSubtitle
        }
        return item.id.normalizedCommandPaletteQuery
    }

    private static func leadingToken(in query: String) -> String? {
        query
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .normalizedCommandPaletteQuery
            .nilIfEmpty
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            guard !value.isEmpty else { return false }
            return seen.insert(value.normalizedCommandPaletteQuery).inserted
        }
    }
}

struct CommandPaletteQuickLaunchRequest: Equatable {
    let workflow: Workflow
    let prompt: String
}

@MainActor
enum CommandPaletteQuickLaunchResolver {
    static func request(
        for action: CommandPaletteAction,
        rawQuery: String,
        slashCommands: [SlashCommandItem]
    ) -> CommandPaletteQuickLaunchRequest? {
        switch action {
        case .runWorkflow(let workflow):
            return CommandPaletteQuickLaunchRequest(
                workflow: workflow,
                prompt: trailingPrompt(
                    from: rawQuery,
                    matchedTokens: CommandPaletteBuilder.workflowMatchTokens(for: workflow)
                ) ?? ""
            )
        case .slashCommand(let name):
            guard let command = slashCommands.first(where: { $0.name == name }) else { return nil }
            guard case .runWorkflow(let workflow) = command.action else { return nil }
            guard let prompt = trailingPrompt(
                from: rawQuery,
                matchedTokens: [name, command.title] + command.aliases
            ), !prompt.isEmpty else {
                return nil
            }
            return CommandPaletteQuickLaunchRequest(workflow: workflow, prompt: prompt)
        default:
            return nil
        }
    }

    static func trailingPrompt(from rawQuery: String, matchedTokens: [String]) -> String? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let stripped: String = {
            if trimmed.hasPrefix("/") || trimmed.hasPrefix(">") {
                return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            return trimmed
        }()

        guard let firstSpace = stripped.firstIndex(of: " ") else { return nil }
        let first = String(stripped[..<firstSpace])
        let rest = stripped[firstSpace...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        let lowered = first.lowercased()
        for token in matchedTokens where token.lowercased() == lowered {
            return rest
        }
        return nil
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
    let section: String?
    let score: Double?
    let icon: String?
    let shortcut: String?
}

private extension CommandPaletteItem {
    init(payload: PaletteItemPayload) {
        self.id = payload.id
        self.title = payload.title
        self.subtitle = payload.subtitle ?? ""
        self.icon = payload.icon ?? Self.icon(for: payload)
        self.section = payload.section ?? payload.kind?.capitalized ?? "Results"
        self.keywords = [payload.id, payload.title, payload.subtitle].compactMap { $0 }
        self.shortcut = payload.shortcut
        self.action = Self.action(for: payload)
        self.isEnabled = true
    }

    static func icon(for payload: PaletteItemPayload) -> String {
        if let route = NavDestination.paletteRoute(id: payload.id, title: payload.title) {
            return route.icon
        }
        switch payload.id {
        case "command.ask-ai":
            return "sparkles"
        case "command.new-terminal":
            return "terminal.fill"
        case "command.close-workspace":
            return "xmark"
        case "command.global-search":
            return "magnifyingglass"
        case "command.refresh":
            return "arrow.clockwise"
        case "command.cancel":
            return "xmark.circle"
        default:
            break
        }
        switch payload.kind?.lowercased() {
        case "destination":
            return "square.grid.2x2"
        case "file", "files":
            return "doc.text"
        case "workflow", "workflows":
            return "arrow.triangle.branch"
        case "workspace", "workspaces":
            return "desktopcomputer"
        case "run", "runs":
            return "dot.radiowaves.left.and.right"
        case "slash":
            return "square.grid.2x2"
        default:
            return "magnifyingglass"
        }
    }

    static func action(for payload: PaletteItemPayload) -> CommandPaletteAction {
        switch payload.id {
        case "command.ask-ai":
            return .askAI("")
        case "command.new-terminal":
            return .newTerminal
        case "command.close-workspace":
            return .closeCurrentTab
        case "command.global-search":
            return .globalSearch("")
        case "command.refresh":
            return .refreshCurrentView
        case "command.cancel":
            return .cancelCurrentOperation
        case "runs.active":
            return .navigate(.runs)
        case "workflows.local":
            return .navigate(.workflows)
        default:
            break
        }
        if payload.id.hasPrefix("file:") {
            return .openFile(String(payload.id.dropFirst(5)))
        }
        if payload.id.hasPrefix("slash:") {
            return .slashCommand(String(payload.id.dropFirst(6)))
        }
        if payload.id.hasPrefix("workspace:") {
            return .navigate(.workspaces)
        }
        if let route = NavDestination.paletteRoute(id: payload.id, title: payload.title) {
            return .navigate(route)
        }
        return .unsupported(payload.id)
    }
}

private extension NavDestination {
    static func paletteRoute(id: String, title: String) -> NavDestination? {
        let token = id
            .replacingOccurrences(of: "route:", with: "")
            .replacingOccurrences(of: "nav:", with: "")
            .normalizedCommandPaletteQuery
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

    var nilIfEmpty: String? {
        isEmpty ? nil : self
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
