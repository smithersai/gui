import Foundation

enum SlashCommandCategory: String {
    case codex = "Codex"
    case smithers = "Smithers"
    case workflow = "Workflow"
    case prompt = "Prompt"
    case action = "Action"
}

enum CodexSlashCommand {
    case model
    case approvals
    case review
    case new
    case initialize
    case compact
    case diff
    case mention
    case status
    case mcp
    case logout
    case quit
    case feedback
}

enum SlashCommandAction {
    case codex(CodexSlashCommand)
    case navigate(NavDestination)
    case clearChat
    case showHelp
    case runWorkflow(Workflow)
    case runSmithersPrompt(String)
}

struct SlashCommandItem: Identifiable {
    let id: String
    let name: String
    let title: String
    let description: String
    let category: SlashCommandCategory
    let aliases: [String]
    let action: SlashCommandAction

    var displayName: String { "/\(name)" }

    func matches(_ query: String) -> Bool {
        let normalized = query.lowercased()
        guard !normalized.isEmpty else { return true }

        let haystacks = [name, title, description] + aliases
        return haystacks.contains { $0.lowercased().contains(normalized) }
    }

    func score(for query: String) -> Int {
        let normalized = query.lowercased()
        guard !normalized.isEmpty else { return 100 }

        if name.lowercased() == normalized { return 0 }
        if aliases.contains(where: { $0.lowercased() == normalized }) { return 1 }
        if name.lowercased().hasPrefix(normalized) { return 10 }
        if aliases.contains(where: { $0.lowercased().hasPrefix(normalized) }) { return 20 }
        if title.lowercased().hasPrefix(normalized) { return 30 }
        return 50
    }
}

struct ParsedSlashCommand {
    let name: String
    let args: String
}

enum SlashCommandRegistry {
    static let initPrompt = """
Generate a file named AGENTS.md that serves as a contributor guide for this repository.
Your goal is to produce a clear, concise, and well-structured document with descriptive headings and actionable explanations for each section.
Follow the outline below, but adapt as needed; add sections if relevant, and omit those that do not apply to this project.

Document Requirements

- Title the document "Repository Guidelines".
- Use Markdown headings (#, ##, etc.) for structure.
- Keep the document concise. 200-400 words is optimal.
- Keep explanations short, direct, and specific to this repository.
- Provide examples where helpful (commands, directory paths, naming patterns).
- Maintain a professional, instructional tone.

Recommended Sections

Project Structure & Module Organization

- Outline the project structure, including where the source code, tests, and assets are located.

Build, Test, and Development Commands

- List key commands for building, testing, and running locally.
- Briefly explain what each command does.

Coding Style & Naming Conventions

- Specify indentation rules, language-specific style preferences, and naming patterns.
- Include any formatting or linting tools used.

Testing Guidelines

- Identify testing frameworks and coverage requirements.
- State test naming conventions and how to run tests.

Commit & Pull Request Guidelines

- Summarize commit message conventions found in the project's Git history.
- Outline pull request requirements.

Optional: Add other sections if relevant, such as Security & Configuration Tips, Architecture Overview, or Agent-Specific Instructions.
"""

    static var builtInCommands: [SlashCommandItem] {
        [
            SlashCommandItem(
                id: "codex.model",
                name: "model",
                title: "Switch Model",
                description: "Choose the Codex model and reasoning effort.",
                category: .codex,
                aliases: ["reasoning"],
                action: .codex(.model)
            ),
            SlashCommandItem(
                id: "codex.approvals",
                name: "codex-approvals",
                title: "Codex Approvals",
                description: "Choose what Codex can do without approval.",
                category: .codex,
                aliases: ["sandbox", "permissions"],
                action: .codex(.approvals)
            ),
            SlashCommandItem(
                id: "codex.review",
                name: "review",
                title: "Review Changes",
                description: "Ask Codex to review current changes and find issues.",
                category: .codex,
                aliases: ["code-review"],
                action: .codex(.review)
            ),
            SlashCommandItem(
                id: "codex.new",
                name: "new",
                title: "New Chat",
                description: "Start a fresh chat session.",
                category: .codex,
                aliases: ["new-chat"],
                action: .codex(.new)
            ),
            SlashCommandItem(
                id: "codex.init",
                name: "init",
                title: "Initialize Project",
                description: "Create an AGENTS.md contributor guide.",
                category: .codex,
                aliases: ["agents"],
                action: .codex(.initialize)
            ),
            SlashCommandItem(
                id: "codex.compact",
                name: "compact",
                title: "Compact Conversation",
                description: "Summarize context before continuing.",
                category: .codex,
                aliases: ["summarize"],
                action: .codex(.compact)
            ),
            SlashCommandItem(
                id: "codex.diff",
                name: "diff",
                title: "Show Git Diff",
                description: "Show the current git diff summary.",
                category: .codex,
                aliases: ["changes"],
                action: .codex(.diff)
            ),
            SlashCommandItem(
                id: "codex.mention",
                name: "mention",
                title: "Mention File",
                description: "Insert a file mention marker.",
                category: .codex,
                aliases: ["file"],
                action: .codex(.mention)
            ),
            SlashCommandItem(
                id: "codex.status",
                name: "status",
                title: "Session Status",
                description: "Show current chat and workspace status.",
                category: .codex,
                aliases: ["info"],
                action: .codex(.status)
            ),
            SlashCommandItem(
                id: "codex.mcp",
                name: "mcp",
                title: "MCP Tools",
                description: "List configured MCP tools.",
                category: .codex,
                aliases: ["tools"],
                action: .codex(.mcp)
            ),
            SlashCommandItem(
                id: "codex.logout",
                name: "logout",
                title: "Log Out",
                description: "Log out of Codex.",
                category: .codex,
                aliases: [],
                action: .codex(.logout)
            ),
            SlashCommandItem(
                id: "codex.quit",
                name: "quit",
                title: "Quit",
                description: "Quit the app.",
                category: .codex,
                aliases: ["exit"],
                action: .codex(.quit)
            ),
            SlashCommandItem(
                id: "codex.feedback",
                name: "feedback",
                title: "Feedback",
                description: "Prepare feedback for maintainers.",
                category: .codex,
                aliases: [],
                action: .codex(.feedback)
            ),

            SlashCommandItem(
                id: "smithers.dashboard",
                name: "dashboard",
                title: "Dashboard",
                description: "Open the Smithers overview.",
                category: .smithers,
                aliases: ["overview"],
                action: .navigate(.dashboard)
            ),
            SlashCommandItem(
                id: "smithers.agents",
                name: "agents",
                title: "Agents",
                description: "Browse available Smithers/external agents.",
                category: .smithers,
                aliases: ["agent"],
                action: .navigate(.agents)
            ),
            SlashCommandItem(
                id: "smithers.changes",
                name: "changes",
                title: "Changes",
                description: "Open JJHub changes and repository status.",
                category: .smithers,
                aliases: ["change", "vcs"],
                action: .navigate(.changes)
            ),
            SlashCommandItem(
                id: "smithers.runs",
                name: "runs",
                title: "Runs",
                description: "Browse workflow runs.",
                category: .smithers,
                aliases: ["run"],
                action: .navigate(.runs)
            ),
            SlashCommandItem(
                id: "smithers.workflows",
                name: "workflows",
                title: "Workflows",
                description: "Browse registered workflows.",
                category: .smithers,
                aliases: ["workflow"],
                action: .navigate(.workflows)
            ),
            SlashCommandItem(
                id: "smithers.triggers",
                name: "triggers",
                title: "Triggers",
                description: "Manage cron workflow triggers.",
                category: .smithers,
                aliases: ["trigger", "crons", "cron"],
                action: .navigate(.triggers)
            ),
            SlashCommandItem(
                id: "smithers.jjhub-workflows",
                name: "jjhub-workflows",
                title: "JJHub Workflows",
                description: "Browse and run JJHub workflows for the current repo.",
                category: .smithers,
                aliases: ["jjhub_workflows", "jjhub-workflow"],
                action: .navigate(.jjhubWorkflows)
            ),
            SlashCommandItem(
                id: "smithers.approvals",
                name: "approvals",
                title: "Approval Queue",
                description: "Show pending Smithers approvals.",
                category: .smithers,
                aliases: ["approval-queue", "smithers-approvals"],
                action: .navigate(.approvals)
            ),
            SlashCommandItem(
                id: "smithers.prompts",
                name: "prompts",
                title: "Prompts",
                description: "Open the prompt editor and previewer.",
                category: .smithers,
                aliases: ["prompt"],
                action: .navigate(.prompts)
            ),
            SlashCommandItem(
                id: "smithers.scores",
                name: "scores",
                title: "Scores",
                description: "Open the scores dashboard.",
                category: .smithers,
                aliases: ["score"],
                action: .navigate(.scores)
            ),
            SlashCommandItem(
                id: "smithers.memory",
                name: "memory",
                title: "Memory",
                description: "Browse stored memory facts.",
                category: .smithers,
                aliases: ["memories"],
                action: .navigate(.memory)
            ),
            SlashCommandItem(
                id: "smithers.search",
                name: "search",
                title: "Search",
                description: "Search Smithers data.",
                category: .smithers,
                aliases: ["find"],
                action: .navigate(.search)
            ),
            SlashCommandItem(
                id: "smithers.sql",
                name: "sql",
                title: "SQL Browser",
                description: "Inspect Smithers tables and run read queries.",
                category: .smithers,
                aliases: ["database", "tables"],
                action: .navigate(.sql)
            ),
            SlashCommandItem(
                id: "smithers.landings",
                name: "landings",
                title: "Landings",
                description: "Open landing activity.",
                category: .smithers,
                aliases: ["landing"],
                action: .navigate(.landings)
            ),
            SlashCommandItem(
                id: "smithers.tickets",
                name: "tickets",
                title: "Tickets",
                description: "Open local Smithers tickets.",
                category: .smithers,
                aliases: ["ticket"],
                action: .navigate(.tickets)
            ),
            SlashCommandItem(
                id: "smithers.issues",
                name: "issues",
                title: "Issues",
                description: "Open work items.",
                category: .smithers,
                aliases: ["tickets", "work-items"],
                action: .navigate(.issues)
            ),
            SlashCommandItem(
                id: "smithers.workspaces",
                name: "workspaces",
                title: "Workspaces",
                description: "Open JJHub workspaces.",
                category: .smithers,
                aliases: ["workspace"],
                action: .navigate(.workspaces)
            ),
            SlashCommandItem(
                id: "smithers.chat",
                name: "chat",
                title: "Chat",
                description: "Return to chat.",
                category: .smithers,
                aliases: ["home", "console"],
                action: .navigate(.chat)
            ),
            SlashCommandItem(
                id: "smithers.terminal",
                name: "terminal",
                title: "Terminal",
                description: "Open the terminal pane.",
                category: .smithers,
                aliases: ["shell"],
                action: .navigate(.terminal)
            ),
            SlashCommandItem(
                id: "action.clear",
                name: "clear",
                title: "Clear Chat",
                description: "Clear visible chat messages.",
                category: .action,
                aliases: ["clear-chat"],
                action: .clearChat
            ),
            SlashCommandItem(
                id: "action.help",
                name: "help",
                title: "Help",
                description: "Show available slash commands.",
                category: .action,
                aliases: ["commands"],
                action: .showHelp
            ),
        ]
    }

    static func workflowCommands(from workflows: [Workflow]) -> [SlashCommandItem] {
        workflows.map { workflow in
            SlashCommandItem(
                id: "workflow.\(workflow.id)",
                name: "workflow:\(workflow.id)",
                title: workflow.name,
                description: workflow.relativePath ?? "Run Smithers workflow.",
                category: .workflow,
                aliases: [workflow.id],
                action: .runWorkflow(workflow)
            )
        }
    }

    static func promptCommands(from prompts: [SmithersPrompt]) -> [SlashCommandItem] {
        prompts.map { prompt in
            SlashCommandItem(
                id: "prompt.\(prompt.id)",
                name: "prompt:\(prompt.id)",
                title: prompt.id,
                description: prompt.entryFile ?? "Send Smithers prompt.",
                category: .prompt,
                aliases: [prompt.id],
                action: .runSmithersPrompt(prompt.id)
            )
        }
    }

    static func parse(_ input: String) -> ParsedSlashCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let body = trimmed.dropFirst()
        guard !body.isEmpty else {
            return ParsedSlashCommand(name: "", args: "")
        }

        if let space = body.firstIndex(where: { $0.isWhitespace }) {
            let name = String(body[..<space])
            let args = String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedSlashCommand(name: name, args: args)
        }

        return ParsedSlashCommand(name: String(body), args: "")
    }

    static func matches(for input: String, commands: [SlashCommandItem]) -> [SlashCommandItem] {
        guard let parsed = parse(input) else { return [] }
        let query = parsed.name

        return commands
            .filter { $0.matches(query) }
            .sorted {
                let lhsScore = $0.score(for: query)
                let rhsScore = $1.score(for: query)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                if $0.category.rawValue != $1.category.rawValue {
                    return categoryRank($0.category) < categoryRank($1.category)
                }
                return $0.name < $1.name
            }
    }

    static func exactMatch(for input: String, commands: [SlashCommandItem]) -> SlashCommandItem? {
        guard let parsed = parse(input), !parsed.name.isEmpty else { return nil }
        let name = parsed.name.lowercased()
        return matches(for: input, commands: commands).first {
            $0.name.lowercased() == name || $0.aliases.contains(where: { $0.lowercased() == name })
        }
    }

    static func keyValueArgs(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]

        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            result[parts[0]] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return result
    }

    static func helpText(for commands: [SlashCommandItem]) -> String {
        let grouped = Dictionary(grouping: commands) { $0.category }
        let categories: [SlashCommandCategory] = [.codex, .smithers, .workflow, .prompt, .action]

        return categories.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            let rows = items
                .sorted { $0.name < $1.name }
                .map { "\($0.displayName) - \($0.description)" }
                .joined(separator: "\n")
            return "\(category.rawValue)\n\(rows)"
        }
        .joined(separator: "\n\n")
    }

    private static func categoryRank(_ category: SlashCommandCategory) -> Int {
        switch category {
        case .codex: return 0
        case .smithers: return 1
        case .workflow: return 2
        case .prompt: return 3
        case .action: return 4
        }
    }
}
