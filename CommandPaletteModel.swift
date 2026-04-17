import Foundation

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
            return ParsedCommandPaletteQuery(
                mode: .openAnything,
                prefix: nil,
                rawText: raw,
                searchText: ""
            )
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

        if mode == .openAnything {
            return ParsedCommandPaletteQuery(
                mode: .openAnything,
                prefix: nil,
                rawText: raw,
                searchText: raw.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let remainder = String(trimmedLeading.dropFirst())
        return ParsedCommandPaletteQuery(
            mode: mode,
            prefix: mode.prefix,
            rawText: raw,
            searchText: remainder.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case newChat
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

enum CommandPaletteBuilder {
    private struct ScoredItem {
        let score: Int
        let item: CommandPaletteItem
    }

    private struct Candidate {
        let item: CommandPaletteItem
        let baseScore: Int
    }

    static func items(for rawQuery: String, context: CommandPaletteContext, limit: Int = 120) -> [CommandPaletteItem] {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        let searchText = parsed.searchText

        let candidates: [Candidate]
        switch parsed.mode {
        case .openAnything:
            candidates = openAnythingCandidates(searchText: searchText, context: context)
        case .command:
            candidates = commandModeCandidates(searchText: searchText, context: context)
        case .askAI:
            candidates = askAICandidates(searchText: searchText)
        case .mentionFile:
            candidates = fileCandidates(files: context.files)
        case .slash:
            candidates = slashCandidates(searchText: searchText, context: context)
        case .workItem:
            candidates = workItemCandidates(searchText: searchText, context: context)
        }

        var bestByID: [String: ScoredItem] = [:]
        for candidate in candidates {
            if !candidate.item.isEnabled && parsed.mode != .command {
                continue
            }
            guard let score = score(
                item: candidate.item,
                query: searchText,
                base: candidate.baseScore
            ) else {
                continue
            }
            if let existing = bestByID[candidate.item.id], existing.score <= score {
                continue
            }
            bestByID[candidate.item.id] = ScoredItem(score: score, item: candidate.item)
        }

        return bestByID.values
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.item.section != rhs.item.section { return lhs.item.section < rhs.item.section }
                return lhs.item.title < rhs.item.title
            }
            .prefix(limit)
            .map(\.item)
    }

    static func routeItems(developerToolsEnabled: Bool) -> [CommandPaletteItem] {
        let routes: [NavDestination] = [
            .dashboard,
            .chat,
            .terminal(id: "default"),
            .runs,
            .workflows,
            .approvals,
            .prompts,
            .search,
            .memory,
            .scores,
            .sql,
            .logs,
            .workspaces,
            .changes,
            .jjhubWorkflows,
            .landings,
            .tickets,
            .issues,
            .settings,
        ]

        var items = routes.map { destination in
            CommandPaletteItem(
                id: "route:\(destination.label.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: destination.label,
                subtitle: "Navigate to \(destination.label).",
                icon: destination.icon,
                section: "Destinations",
                keywords: [destination.label, String(describing: destination)],
                shortcut: routeShortcut(for: destination),
                action: .navigate(destination),
                isEnabled: true
            )
        }

        if developerToolsEnabled {
            items.append(
                CommandPaletteItem(
                    id: "route:developer-debug",
                    title: "Developer Debug",
                    subtitle: "Toggle the developer debug panel.",
                    icon: "wrench.and.screwdriver",
                    section: "Destinations",
                    keywords: ["debug", "developer", "diagnostics"],
                    shortcut: "Cmd+Shift+D",
                    action: .toggleDeveloperDebug,
                    isEnabled: true
                )
            )
        }

        return items
    }

    static func commandItems(developerToolsEnabled: Bool) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = [
            CommandPaletteItem(
                id: "command.ask-ai",
                title: "Ask AI",
                subtitle: "Open the launcher in Ask AI mode.",
                icon: "sparkles",
                section: "Commands",
                keywords: ["ai", "question", "chat"],
                shortcut: "Cmd+K",
                action: .askAI(""),
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.new-chat",
                title: "New Chat",
                subtitle: "Create a new chat session.",
                icon: "plus.bubble",
                section: "Commands",
                keywords: ["chat", "session", "thread"],
                shortcut: "Cmd+N",
                action: .newChat,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.new-terminal",
                title: "New Terminal Workspace",
                subtitle: "Create a new terminal workspace and make it active.",
                icon: "terminal.fill",
                section: "Commands",
                keywords: ["terminal", "shell", "workspace", "tmux"],
                shortcut: "Cmd+T",
                action: .newTerminal,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.open-markdown-file",
                title: "Open Markdown File…",
                subtitle: "Render a local markdown file in the workspace.",
                icon: "doc.richtext",
                section: "Commands",
                keywords: ["markdown", "md", "mermaid", "preview", "viewer", "file"],
                shortcut: nil,
                action: .openMarkdownFilePicker,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.close-workspace",
                title: "Close Current Workspace",
                subtitle: "Close the active chat/run/terminal workspace when applicable.",
                icon: "xmark.circle",
                section: "Commands",
                keywords: ["close", "workspace", "session", "terminal"],
                shortcut: "Cmd+W",
                action: .closeCurrentTab,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.reopen-workspace",
                title: "Reopen Closed Workspace",
                subtitle: "Closed workspace history is not available in this build.",
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90",
                section: "Commands",
                keywords: ["reopen", "closed", "workspace"],
                shortcut: "Cmd+Shift+T",
                action: .unsupported("Reopen closed workspace is not available yet."),
                isEnabled: false
            ),
            CommandPaletteItem(
                id: "command.next-workspace",
                title: "Next Visible Workspace",
                subtitle: "Move to the next visible workspace.",
                icon: "chevron.right.circle",
                section: "Commands",
                keywords: ["next", "workspace", "cycle"],
                shortcut: "Cmd+Shift+]",
                action: .nextVisibleTab,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.previous-workspace",
                title: "Previous Visible Workspace",
                subtitle: "Move to the previous visible workspace.",
                icon: "chevron.left.circle",
                section: "Commands",
                keywords: ["previous", "workspace", "cycle"],
                shortcut: "Cmd+Shift+[",
                action: .previousVisibleTab,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.global-search",
                title: "Global Search",
                subtitle: "Open the global search route.",
                icon: "magnifyingglass",
                section: "Commands",
                keywords: ["search", "find"],
                shortcut: "Cmd+Shift+F",
                action: .globalSearch(""),
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.refresh",
                title: "Refresh Current View",
                subtitle: "Reload the active route view.",
                icon: "arrow.clockwise",
                section: "Commands",
                keywords: ["refresh", "reload"],
                shortcut: "Cmd+R",
                action: .refreshCurrentView,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.cancel",
                title: "Cancel Current Operation",
                subtitle: "Stop an active chat turn or running workflow action.",
                icon: "stop.circle",
                section: "Commands",
                keywords: ["cancel", "stop", "interrupt"],
                shortcut: "Cmd+.",
                action: .cancelCurrentOperation,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.shortcut-cheatsheet",
                title: "Keyboard Shortcut Cheat Sheet",
                subtitle: "Show common launcher and navigation shortcuts.",
                icon: "keyboard",
                section: "Commands",
                keywords: ["shortcut", "keys", "help", "cheatsheet"],
                shortcut: "Cmd+/",
                action: .showShortcutCheatSheet,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.workspaces.switcher",
                title: "Open Workspace Switcher",
                subtitle: "Open the launcher scoped to workspaces.",
                icon: "square.on.square",
                section: "Commands",
                keywords: ["workspace", "switcher", "tmux", "ctrl+b w"],
                shortcut: "Ctrl+B w",
                action: .openTabSwitcher,
                isEnabled: true
            ),
            CommandPaletteItem(
                id: "command.workspaces.find",
                title: "Find Workspace",
                subtitle: "Open the launcher and search for workspaces.",
                icon: "magnifyingglass",
                section: "Commands",
                keywords: ["workspace", "find", "tmux", "ctrl+b f"],
                shortcut: "Ctrl+B f",
                action: .findTab,
                isEnabled: true
            ),
        ]

        items.append(contentsOf: (1...9).map { index in
            CommandPaletteItem(
                id: "command.switch-workspace-\(index)",
                title: "Switch to Workspace \(index)",
                subtitle: "Switch to the \(index.ordinalLabel) visible sidebar workspace.",
                icon: "number.square",
                section: "Commands",
                keywords: ["workspace", "switch", "\(index)"],
                shortcut: "Cmd+\(index)",
                action: .switchToTabIndex(index - 1),
                isEnabled: true
            )
        })

        if developerToolsEnabled {
            items.append(
                CommandPaletteItem(
                    id: "command.developer-debug",
                    title: "Toggle Developer Debug",
                    subtitle: "Show or hide the developer diagnostics panel.",
                    icon: "wrench.and.screwdriver",
                    section: "Commands",
                    keywords: ["debug", "developer"],
                    shortcut: "Cmd+Shift+D",
                    action: .toggleDeveloperDebug,
                    isEnabled: true
                )
            )
        }

        return items
    }

    static func slashItems(
        commands: [SlashCommandItem],
        query: String
    ) -> [CommandPaletteItem] {
        let input = "/\(query)"
        return SlashCommandRegistry.matches(for: input, commands: commands).map { command in
            CommandPaletteItem(
                id: "slash:\(command.name)",
                title: "/\(command.name)",
                subtitle: command.description,
                icon: slashIcon(for: command.category),
                section: "Slash Commands",
                keywords: [command.name, command.title, command.description] + command.aliases,
                shortcut: nil,
                action: .slashCommand(command.name),
                isEnabled: true
            )
        }
    }

    private static func openAnythingCandidates(searchText: String, context: CommandPaletteContext) -> [Candidate] {
        var candidates: [Candidate] = []

        candidates.append(contentsOf: tabCandidates(tabs: context.sidebarTabs, base: 0))
        candidates.append(contentsOf: fileCandidates(files: context.files, base: 100))
        candidates.append(contentsOf: runCandidates(runTabs: context.runTabs, base: 200))
        candidates.append(contentsOf: workflowPromptCandidates(
            slashCommands: context.slashCommands,
            workflows: context.workflows,
            prompts: context.prompts,
            base: 300
        ))
        candidates.append(contentsOf: routeItems(developerToolsEnabled: context.developerToolsEnabled).map {
            Candidate(item: $0, baseScore: 400)
        })
        candidates.append(contentsOf: workItemCandidates(searchText: searchText, context: context, base: 500))
        candidates.append(contentsOf: commandItems(developerToolsEnabled: context.developerToolsEnabled).map {
            Candidate(item: $0, baseScore: 700)
        })

        if !searchText.isEmpty {
            candidates.append(
                Candidate(
                    item: CommandPaletteItem(
                        id: "ask-ai:\(searchText)",
                        title: "Ask AI: \(searchText)",
                        subtitle: "Send this query to the active chat session.",
                        icon: "sparkles",
                        section: "AI",
                        keywords: [searchText, "ask", "ai", "chat"],
                        shortcut: "Cmd+K",
                        action: .askAI(searchText),
                        isEnabled: true
                    ),
                    baseScore: 650
                )
            )
        }

        return candidates
    }

    private static func commandModeCandidates(searchText: String, context: CommandPaletteContext) -> [Candidate] {
        var candidates = commandItems(developerToolsEnabled: context.developerToolsEnabled).map {
            Candidate(item: $0, baseScore: 0)
        }
        candidates.append(contentsOf: routeItems(developerToolsEnabled: context.developerToolsEnabled).map {
            Candidate(item: $0, baseScore: 200)
        })
        candidates.append(contentsOf: slashItems(commands: context.slashCommands, query: searchText).map {
            Candidate(item: $0, baseScore: 400)
        })
        return candidates
    }

    private static func askAICandidates(searchText: String) -> [Candidate] {
        let content = searchText.isEmpty ? "Ask the main AI session…" : searchText
        let item = CommandPaletteItem(
            id: "ask-ai-direct:\(content)",
            title: searchText.isEmpty ? "Ask AI" : "Ask AI: \(searchText)",
            subtitle: "Send a prompt to the active chat session.",
            icon: "sparkles",
            section: "AI",
            keywords: [content, "ask", "ai", "chat", "question"],
            shortcut: "Cmd+K",
            action: .askAI(searchText),
            isEnabled: true
        )
        return [Candidate(item: item, baseScore: 0)]
    }

    private static func slashCandidates(searchText: String, context: CommandPaletteContext) -> [Candidate] {
        slashItems(commands: context.slashCommands, query: searchText).map {
            Candidate(item: $0, baseScore: 0)
        }
    }

    private static func workItemCandidates(
        searchText _: String,
        context: CommandPaletteContext,
        base: Int = 0
    ) -> [Candidate] {
        var items: [CommandPaletteItem] = context.runTabs.map { runTab in
            CommandPaletteItem(
                id: "work.run:\(runTab.runId)",
                title: runTab.title,
                subtitle: runTab.preview,
                icon: "play.circle",
                section: "Runs",
                keywords: [runTab.runId, runTab.title, runTab.preview],
                shortcut: nil,
                action: .navigate(.liveRun(runId: runTab.runId, nodeId: nil)),
                isEnabled: true
            )
        }

        items.append(
            CommandPaletteItem(
                id: "work.route.approvals",
                title: "Approvals",
                subtitle: "Open pending approval queue.",
                icon: "checkmark.shield",
                section: "Work Items",
                keywords: ["approvals", "queue", "g a"],
                shortcut: "g a",
                action: .navigate(.approvals),
                isEnabled: true
            )
        )

        items.append(contentsOf: context.issues.map { issue in
            CommandPaletteItem(
                id: "work.issue:\(issue.id)",
                title: issueTitle(issue),
                subtitle: issue.state ?? "Issue",
                icon: "exclamationmark.circle",
                section: "Issues",
                keywords: [issue.id, issue.title, issue.state ?? "issue"],
                shortcut: nil,
                action: .navigate(.issues),
                isEnabled: true
            )
        })

        items.append(contentsOf: context.tickets.map { ticket in
            CommandPaletteItem(
                id: "work.ticket:\(ticket.id)",
                title: ticketTitle(ticket),
                subtitle: ticket.status ?? "Ticket",
                icon: "ticket",
                section: "Tickets",
                keywords: [ticket.id, ticket.status ?? "ticket", ticket.content ?? ""],
                shortcut: nil,
                action: .navigate(.tickets),
                isEnabled: true
            )
        })

        items.append(contentsOf: context.landings.map { landing in
            CommandPaletteItem(
                id: "work.landing:\(landing.id)",
                title: landingTitle(landing),
                subtitle: landing.state ?? "Landing",
                icon: "arrow.down.to.line",
                section: "Landings",
                keywords: [landing.id, landing.title, landing.state ?? "landing"],
                shortcut: nil,
                action: .navigate(.landings),
                isEnabled: true
            )
        })

        if items.isEmpty {
            items.append(
                CommandPaletteItem(
                    id: "work.route.runs",
                    title: "Open Runs",
                    subtitle: "Browse runs, approvals, tickets, issues, and landings.",
                    icon: "play.circle",
                    section: "Work Items",
                    keywords: ["runs", "work items", "approvals", "issues", "tickets", "landings"],
                    shortcut: "g r",
                    action: .navigate(.runs),
                    isEnabled: true
                )
            )
        }

        return items.map { Candidate(item: $0, baseScore: base) }
    }

    private static func tabCandidates(tabs: [SidebarTab], base: Int) -> [Candidate] {
        tabs.enumerated().map { offset, tab in
            let action: CommandPaletteAction
            switch tab.kind {
            case .chat:
                action = .selectSidebarTab(tab.id)
            case .run:
                action = .selectSidebarTab(tab.id)
            case .terminal:
                action = .selectSidebarTab(tab.id)
            }

            return Candidate(
                item: CommandPaletteItem(
                    id: "workspace:\(tab.id)",
                    title: tab.title,
                    subtitle: tab.preview,
                    icon: tab.kind.icon,
                    section: "Open Workspaces",
                    keywords: [tab.title, tab.preview, tab.sessionIdentifier ?? "", tab.id],
                    shortcut: offset < 9 ? "Cmd+\(offset + 1)" : nil,
                    action: action,
                    isEnabled: true
                ),
                baseScore: base + min(offset, 30)
            )
        }
    }

    private static func runCandidates(runTabs: [RunTab], base: Int) -> [Candidate] {
        runTabs.map { tab in
            Candidate(
                item: CommandPaletteItem(
                    id: "run:\(tab.runId)",
                    title: tab.title,
                    subtitle: tab.preview,
                    icon: "dot.radiowaves.left.and.right",
                    section: "Runs",
                    keywords: [tab.runId, tab.title, tab.preview, "run"],
                    shortcut: nil,
                    action: .navigate(.liveRun(runId: tab.runId, nodeId: nil)),
                    isEnabled: true
                ),
                baseScore: base
            )
        }
    }

    private static func fileCandidates(files: [String], base: Int = 0) -> [Candidate] {
        files.map { path in
            Candidate(
                item: CommandPaletteItem(
                    id: "file:\(path)",
                    title: path,
                    subtitle: "Workspace file",
                    icon: "doc.text",
                    section: "Files",
                    keywords: [path, path.lastPathComponent],
                    shortcut: nil,
                    action: .openFile(path),
                    isEnabled: true
                ),
                baseScore: base
            )
        }
    }

    private static func workflowPromptCandidates(
        slashCommands: [SlashCommandItem],
        workflows: [Workflow],
        prompts: [SmithersPrompt],
        base: Int
    ) -> [Candidate] {
        var candidates: [Candidate] = []

        let workflowCommands = slashCommands.filter { $0.category == .workflow }
        candidates.append(contentsOf: workflowCommands.map {
            Candidate(
                item: CommandPaletteItem(
                    id: "workflow:\($0.name)",
                    title: $0.title,
                    subtitle: $0.description,
                    icon: "arrow.triangle.branch",
                    section: "Workflows",
                    keywords: [$0.name, $0.title, $0.description] + $0.aliases,
                    shortcut: nil,
                    action: .slashCommand($0.name),
                    isEnabled: true
                ),
                baseScore: base
            )
        })

        let promptCommands = slashCommands.filter { $0.category == .prompt }
        candidates.append(contentsOf: promptCommands.map {
            Candidate(
                item: CommandPaletteItem(
                    id: "prompt:\($0.name)",
                    title: $0.title,
                    subtitle: $0.description,
                    icon: "doc.text",
                    section: "Prompts",
                    keywords: [$0.name, $0.title, $0.description] + $0.aliases,
                    shortcut: nil,
                    action: .slashCommand($0.name),
                    isEnabled: true
                ),
                baseScore: base + 20
            )
        })

        // If dynamic slash command generation has not completed yet, still expose
        // workflow/prompt surfaces so open-anything searches can route users quickly.
        if workflowCommands.isEmpty {
            candidates.append(contentsOf: workflows.map { workflow in
                Candidate(
                    item: CommandPaletteItem(
                        id: "workflow.fallback:\(workflow.id)",
                        title: workflow.name,
                        subtitle: workflow.relativePath ?? "Workflow",
                        icon: "arrow.triangle.branch",
                        section: "Workflows",
                        keywords: [workflow.id, workflow.name, workflow.relativePath ?? ""],
                        shortcut: nil,
                        action: .navigate(.workflows),
                        isEnabled: true
                    ),
                    baseScore: base + 40
                )
            })
        }

        if promptCommands.isEmpty {
            candidates.append(contentsOf: prompts.map { prompt in
                Candidate(
                    item: CommandPaletteItem(
                        id: "prompt.fallback:\(prompt.id)",
                        title: prompt.id,
                        subtitle: prompt.entryFile ?? "Prompt",
                        icon: "doc.text",
                        section: "Prompts",
                        keywords: [prompt.id, prompt.entryFile ?? ""],
                        shortcut: nil,
                        action: .navigate(.prompts),
                        isEnabled: true
                    ),
                    baseScore: base + 60
                )
            })
        }

        return candidates
    }

    private static func score(item: CommandPaletteItem, query: String, base: Int) -> Int? {
        let normalizedQuery = query.normalizedCommandPaletteQuery
        guard !normalizedQuery.isEmpty else {
            return base
        }

        let haystacks = [item.title, item.subtitle] + item.keywords
        var bestScore: Int?

        for value in haystacks {
            let candidate = value.normalizedCommandPaletteQuery
            guard !candidate.isEmpty else { continue }

            let score: Int?
            if candidate == normalizedQuery {
                score = 0
            } else if candidate.hasPrefix(normalizedQuery) {
                score = 8
            } else if candidate.contains(normalizedQuery) {
                score = 24
            } else if let fuzzy = fuzzySubsequenceScore(query: normalizedQuery, candidate: candidate) {
                score = 64 + fuzzy
            } else {
                score = nil
            }

            if let score {
                if let currentBest = bestScore {
                    bestScore = min(currentBest, score)
                } else {
                    bestScore = score
                }
            }
        }

        guard let bestScore else { return nil }
        return base + bestScore
    }

    private static func fuzzySubsequenceScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var queryIndex = 0
        var positions: [Int] = []

        for (candidateIndex, candidateChar) in candidateChars.enumerated() where queryIndex < queryChars.count {
            guard candidateChar == queryChars[queryIndex] else { continue }
            positions.append(candidateIndex)
            queryIndex += 1
        }

        guard queryIndex == queryChars.count,
              let first = positions.first,
              let last = positions.last
        else {
            return nil
        }

        let span = last - first + 1
        let gaps = span - positions.count
        return max(0, first + (gaps * 6))
    }

    private static func slashIcon(for category: SlashCommandCategory) -> String {
        switch category {
        case .codex:
            return "sparkles"
        case .smithers:
            return "square.grid.2x2"
        case .workflow:
            return "arrow.triangle.branch"
        case .prompt:
            return "doc.text"
        case .action:
            return "slider.horizontal.3"
        }
    }

    private static func routeShortcut(for destination: NavDestination) -> String? {
        switch destination {
        case .chat: return "g c"
        case .dashboard: return "g h"
        case .terminal: return "g t"
        case .runs: return "g r"
        case .workflows: return "g w"
        case .approvals: return "g a"
        case .issues: return "g i"
        case .search: return "g s"
        case .logs: return "g l"
        case .memory: return "g m"
        default: return nil
        }
    }

    private static func issueTitle(_ issue: SmithersIssue) -> String {
        if let number = issue.number {
            return "#\(number) \(issue.title)"
        }
        return issue.title
    }

    private static func ticketTitle(_ ticket: Ticket) -> String {
        let trimmedContent = (ticket.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContent.isEmpty {
            return ticket.id
        }
        return "\(ticket.id) \(trimmedContent.prefix(42))"
    }

    private static func landingTitle(_ landing: Landing) -> String {
        if let number = landing.number {
            return "LR-\(number) \(landing.title)"
        }
        return landing.title
    }
}

@MainActor
final class WorkspaceFileSearchIndex: ObservableObject {
    @Published private(set) var files: [String] = []
    private var loadTask: Task<Void, Never>?
    private var rootPath: String
    private var hasLoaded = false

    init(rootPath: String) {
        self.rootPath = rootPath
    }

    deinit {
        loadTask?.cancel()
    }

    func updateRootPath(_ path: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != rootPath else { return }
        rootPath = normalized
        hasLoaded = false
        files = []
    }

    func ensureLoaded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadTask?.cancel()

        let root = rootPath
        loadTask = Task { [weak self] in
            let discovered = await Self.discoverFiles(rootPath: root)
            guard !Task.isCancelled, let self else { return }
            self.files = discovered
        }
    }

    func matches(for query: String, limit: Int = 80) -> [String] {
        let normalized = query.normalizedCommandPaletteQuery
        guard !normalized.isEmpty else {
            return Array(files.prefix(limit))
        }

        return files
            .compactMap { path -> (Int, String)? in
                let score = Self.fileMatchScore(query: normalized, path: path)
                if score == Int.max { return nil }
                return (score, path)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1 < rhs.1
            }
            .prefix(limit)
            .map(\.1)
    }

    nonisolated private static func discoverFiles(rootPath: String) async -> [String] {
        await Task.detached(priority: .utility) {
            if let rgPaths = discoverFilesWithRipgrep(rootPath: rootPath), !rgPaths.isEmpty {
                return rgPaths
            }
            return discoverFilesWithFileManager(rootPath: rootPath)
        }.value
    }

    nonisolated private static func discoverFilesWithRipgrep(rootPath: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
        process.arguments = [
            "rg",
            "--files",
            "--hidden",
            "--glob", "!.git",
            "--glob", "!.build",
            "--glob", "!.swiftpm",
            "--glob", "!.smithers/node_modules/**",
            "--glob", "!**/DerivedData/**",
            "--glob", "!**/node_modules/**",
            "--glob", "!**/.jj/**",
            "--glob", "!**/.DS_Store",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    nonisolated private static func discoverFilesWithFileManager(rootPath: String) -> [String] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let excludedDirectoryNames: Set<String> = [
            ".git",
            ".build",
            ".swiftpm",
            "DerivedData",
            "node_modules",
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants],
            errorHandler: nil
        ) else {
            return []
        }

        var paths: [String] = []
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: "\(rootPath)/", with: "")
            if relative.hasPrefix(".smithers/node_modules/") {
                enumerator.skipDescendants()
                continue
            }

            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) {
                if values.isDirectory == true {
                    if excludedDirectoryNames.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                } else if values.isRegularFile == true {
                    paths.append(relative)
                }
            }
        }

        return paths.sorted()
    }

    nonisolated private static func fileMatchScore(query: String, path: String) -> Int {
        let normalizedPath = path.normalizedCommandPaletteQuery
        let fileName = path.lastPathComponent.normalizedCommandPaletteQuery

        if fileName == query { return 0 }
        if fileName.hasPrefix(query) { return 4 }
        if normalizedPath.hasPrefix(query) { return 8 }
        if fileName.contains(query) { return 16 }
        if normalizedPath.contains(query) { return 24 }
        if let fuzzyScore = fuzzySubsequenceScore(query: query, candidate: normalizedPath) {
            return 60 + fuzzyScore
        }

        return Int.max
    }

    nonisolated private static func fuzzySubsequenceScore(query: String, candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        let queryChars = Array(query)
        let candidateChars = Array(candidate)
        var queryIndex = 0
        var positions: [Int] = []

        for (candidateIndex, candidateChar) in candidateChars.enumerated() where queryIndex < queryChars.count {
            guard candidateChar == queryChars[queryIndex] else { continue }
            positions.append(candidateIndex)
            queryIndex += 1
        }

        guard queryIndex == queryChars.count,
              let first = positions.first,
              let last = positions.last
        else {
            return nil
        }

        let span = last - first + 1
        let gaps = span - positions.count
        return max(0, first + (gaps * 6))
    }
}

private extension String {
    var normalizedCommandPaletteQuery: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}

private extension Int {
    var ordinalLabel: String {
        switch self {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(self)th"
        }
    }
}
