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
    case toggleDeveloperDebug
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
        let normalized = query.normalizedSlashCommandQuery
        guard !normalized.isEmpty else { return true }

        return score(for: normalized) < Int.max
    }

    func score(for query: String) -> Int {
        let normalized = query.normalizedSlashCommandQuery
        guard !normalized.isEmpty else { return 100 }

        if name.normalizedSlashCommandQuery == normalized { return 0 }
        if aliases.contains(where: { $0.normalizedSlashCommandQuery == normalized }) { return 1 }
        if name.normalizedSlashCommandQuery.hasPrefix(normalized) { return 10 }
        if aliases.contains(where: { $0.normalizedSlashCommandQuery.hasPrefix(normalized) }) { return 20 }
        if title.normalizedSlashCommandQuery.hasPrefix(normalized) { return 30 }

        let haystacks = [name, title, description] + aliases
        if haystacks.contains(where: { $0.normalizedSlashCommandQuery.contains(normalized) }) {
            return 50
        }

        let fuzzyScores = haystacks.compactMap {
            Self.fuzzySubsequenceScore(query: normalized, candidate: $0.normalizedSlashCommandQuery)
        }
        guard let bestFuzzyScore = fuzzyScores.min() else { return Int.max }
        return 60 + min(bestFuzzyScore, 1_000)
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
        let adjacencyBonus = positions.dropFirst().enumerated().reduce(0) { total, pair in
            let previousPosition = positions[pair.offset]
            return total + (pair.element == previousPosition + 1 ? 1 : 0)
        }
        let boundaryBonus: Int
        if first == 0 {
            boundaryBonus = 8
        } else if candidateChars.indices.contains(first - 1),
                  Self.isSearchBoundary(candidateChars[first - 1]) {
            boundaryBonus = 4
        } else {
            boundaryBonus = 0
        }

        return max(0, first + (gaps * 6) - adjacencyBonus - boundaryBonus)
    }

    private static func isSearchBoundary(_ character: Character) -> Bool {
        character == "-" ||
            character == "_" ||
            character == "." ||
            character == ":" ||
            character == "/" ||
            character.isWhitespace
    }
}

struct ParsedSlashCommand {
    let name: String
    let args: String
}

struct SlashCommandExecutionContext {
    let inputText: String
    let commands: [SlashCommandItem]
    let chatReady: Bool
    let developerDebugEnabled: Bool
    let canNavigate: Bool
    let canToggleDeveloperDebug: Bool
    let canStartNewChat: Bool
    let canTerminateApp: Bool
    let helpText: String
    let statusText: String
}

struct SlashCommandExecutionEffects {
    var setInputText: (String) -> Void = { _ in }
    var appendStatusMessage: (String) -> Void = { _ in }
    var clearMessages: () -> Void = {}
    var navigate: (NavDestination) -> Void = { _ in }
    var toggleDeveloperDebug: () -> Void = {}
    var startNewChat: () -> Void = {}
    var sendPromptIfReady: (String) -> Void = { _ in }
    var showGitDiff: () -> Void = {}
    var refreshMentionCompletions: () -> Void = {}
    var showModelSelection: () -> Void = {}
    var showApprovalSelection: () -> Void = {}
    var showMCPStatus: () -> Void = {}
    var performCodexLogout: () -> Void = {}
    var terminateApp: () -> Void = {}
    var startFeedbackFlow: () -> Void = {}
    var runWorkflow: (Workflow, String) -> Void = { _, _ in }
    var runSmithersPrompt: (String, String) -> Void = { _, _ in }
}

enum SlashCommandExecutor {
    static func execute(
        _ command: SlashCommandItem,
        context: SlashCommandExecutionContext,
        effects: SlashCommandExecutionEffects
    ) {
        let args = SlashCommandRegistry.parse(context.inputText)?.args ?? ""

        switch command.action {
        case .codex(let codexCommand):
            executeCodexCommand(codexCommand, args: args, context: context, effects: effects)
        case .navigate(let destination):
            effects.setInputText("")
            if context.canNavigate {
                effects.navigate(destination)
                effects.appendStatusMessage("Opened \(destination.label).")
            } else {
                effects.appendStatusMessage("Navigation to \(destination.label) is not wired into this chat view.")
            }
        case .toggleDeveloperDebug:
            effects.setInputText("")
            if context.developerDebugEnabled, context.canToggleDeveloperDebug {
                effects.toggleDeveloperDebug()
                effects.appendStatusMessage("Toggled developer debug.")
            } else {
                effects.appendStatusMessage("Developer debug mode is not enabled for this launch.")
            }
        case .clearChat:
            effects.setInputText("")
            effects.clearMessages()
        case .showHelp:
            effects.setInputText("")
            effects.appendStatusMessage(context.helpText)
        case .runWorkflow(let workflow):
            effects.setInputText("")
            effects.runWorkflow(workflow, args)
        case .runSmithersPrompt(let promptId):
            effects.setInputText("")
            effects.runSmithersPrompt(promptId, args)
        }
    }

    private static func executeCodexCommand(
        _ command: CodexSlashCommand,
        args: String,
        context: SlashCommandExecutionContext,
        effects: SlashCommandExecutionEffects
    ) {
        switch command {
        case .new:
            effects.setInputText("")
            if context.canStartNewChat {
                effects.startNewChat()
            } else {
                effects.clearMessages()
            }
        case .initialize:
            effects.setInputText("")
            effects.sendPromptIfReady(SlashCommandRegistry.initPrompt)
        case .review:
            effects.setInputText("")
            let suffix = args.isEmpty ? "" : "\n\nFocus: \(args)"
            effects.sendPromptIfReady("Review my current changes and find issues. Prioritize bugs, regressions, and missing tests.\(suffix)")
        case .compact:
            effects.setInputText("")
            effects.sendPromptIfReady("Summarize the important context from this conversation so we can continue with a shorter working history.")
        case .diff:
            effects.setInputText("")
            effects.showGitDiff()
        case .mention:
            effects.setInputText("@")
            effects.refreshMentionCompletions()
        case .status:
            effects.setInputText("")
            effects.appendStatusMessage(context.statusText)
        case .model:
            effects.setInputText("")
            effects.showModelSelection()
        case .approvals:
            effects.setInputText("")
            effects.showApprovalSelection()
        case .mcp:
            effects.setInputText("")
            effects.showMCPStatus()
        case .logout:
            effects.setInputText("")
            effects.performCodexLogout()
        case .quit:
            effects.setInputText("")
            if context.canTerminateApp {
                effects.terminateApp()
            } else {
                effects.appendStatusMessage("Quit is only available on macOS.")
            }
        case .feedback:
            effects.setInputText("")
            effects.startFeedbackFlow()
        }
    }
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
                action: .navigate(.terminal(id: "default"))
            ),
            SlashCommandItem(
                id: "action.debug",
                name: "debug",
                title: "Developer Debug",
                description: "Toggle the developer debug panel.",
                category: .action,
                aliases: ["dev", "developer"],
                action: .toggleDeveloperDebug
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
        var registration = DynamicCommandRegistrationState()
        return workflowCommands(from: workflows, registration: &registration)
    }

    static func promptCommands(from prompts: [SmithersPrompt]) -> [SlashCommandItem] {
        var registration = DynamicCommandRegistrationState()
        return promptCommands(from: prompts, registration: &registration)
    }

    static func dynamicCommands(
        workflows: [Workflow],
        prompts: [SmithersPrompt]
    ) -> (workflows: [SlashCommandItem], prompts: [SlashCommandItem]) {
        var registration = DynamicCommandRegistrationState()
        let workflowItems = workflowCommands(from: workflows, registration: &registration)
        let promptItems = promptCommands(from: prompts, registration: &registration)
        return (workflowItems, promptItems)
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

        for token in quoteAwareTokens(raw) {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            guard !key.isEmpty else { continue }
            let valueStart = token.index(after: separator)
            result[key] = String(token[valueStart...])
        }

        return result
    }

    /// Splits `raw` on whitespace while respecting single quotes, double quotes, and backslash escapes.
    static func quoteAwareTokens(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var tokenStarted = false

        for char in raw {
            if escaped {
                current.append(char)
                tokenStarted = true
                escaped = false
                continue
            }

            if char == "\\" {
                escaped = true
                tokenStarted = true
                continue
            }

            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                tokenStarted = true
                continue
            }

            if char == "\"" || char == "'" {
                quote = char
                tokenStarted = true
                continue
            }

            if char.isWhitespace {
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }

            current.append(char)
            tokenStarted = true
        }

        if escaped {
            current.append("\\")
        }
        if tokenStarted {
            tokens.append(current)
        }
        return tokens
    }

    static func helpText(for commands: [SlashCommandItem]) -> String {
        var seenNames: Set<String> = []
        let uniqueCommands = commands.filter { command in
            seenNames.insert(command.name.lowercased()).inserted
        }
        let grouped = Dictionary(grouping: uniqueCommands) { $0.category }
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

    private static func workflowCommands(
        from workflows: [Workflow],
        registration: inout DynamicCommandRegistrationState
    ) -> [SlashCommandItem] {
        workflows.compactMap { workflow in
            guard let suffix = commandIdentifier(from: workflow.id) else { return nil }
            let name = "workflow:\(suffix)"
            guard registration.reserveName(name) else { return nil }

            return SlashCommandItem(
                id: "workflow.\(suffix)",
                name: name,
                title: workflow.name,
                description: workflow.relativePath ?? "Run Smithers workflow.",
                category: .workflow,
                aliases: registration.aliases(forRawIdentifier: workflow.id, commandIdentifier: suffix),
                action: .runWorkflow(workflow)
            )
        }
    }

    private static func promptCommands(
        from prompts: [SmithersPrompt],
        registration: inout DynamicCommandRegistrationState
    ) -> [SlashCommandItem] {
        prompts.compactMap { prompt in
            guard let suffix = commandIdentifier(from: prompt.id) else { return nil }
            let name = "prompt:\(suffix)"
            guard registration.reserveName(name) else { return nil }

            return SlashCommandItem(
                id: "prompt.\(suffix)",
                name: name,
                title: prompt.id,
                description: prompt.entryFile ?? "Send Smithers prompt.",
                category: .prompt,
                aliases: registration.aliases(forRawIdentifier: prompt.id, commandIdentifier: suffix),
                action: .runSmithersPrompt(prompt.id)
            )
        }
    }

    private static func commandIdentifier(from rawIdentifier: String) -> String? {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var result = ""
        var previousWasSeparator = false
        for scalar in trimmed.lowercased().unicodeScalars {
            if isCommandIdentifierScalar(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let cleaned = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isCommandIdentifierScalar(_ scalar: UnicodeScalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57) ||
            (scalar.value >= 97 && scalar.value <= 122) ||
            scalar == "-" ||
            scalar == "_" ||
            scalar == "."
    }

    private struct DynamicCommandRegistrationState {
        private var names: Set<String> = []
        private var aliases: Set<String> = Set(
            builtInCommands.flatMap { [$0.name] + $0.aliases }
                .map(\.normalizedSlashCommandQuery)
        )

        mutating func reserveName(_ name: String) -> Bool {
            names.insert(name.normalizedSlashCommandQuery).inserted
        }

        mutating func aliases(forRawIdentifier rawIdentifier: String, commandIdentifier: String) -> [String] {
            let normalizedRaw = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).normalizedSlashCommandQuery
            guard normalizedRaw == commandIdentifier else { return [] }
            guard aliases.insert(commandIdentifier).inserted else { return [] }
            return [commandIdentifier]
        }
    }
}

private extension String {
    var normalizedSlashCommandQuery: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
