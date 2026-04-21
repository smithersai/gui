import Foundation
import CSmithersKit

enum SlashCommandCategory: String, Codable {
    case smithers = "Smithers"
    case workflow = "Workflow"
    case prompt = "Prompt"
    case action = "Action"
}

enum SlashCommandAction {
    case navigate(NavDestination)
    case toggleDeveloperDebug
    case showHelp
    case quit
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
        score(for: query) < Int.max
    }

    func score(for query: String) -> Int {
        let normalized = query.normalizedSlashCommandQuery
        guard !normalized.isEmpty else { return 0 }
        if name.normalizedSlashCommandQuery == normalized { return 0 }
        if aliases.contains(where: { $0.normalizedSlashCommandQuery == normalized }) { return 1 }
        if name.normalizedSlashCommandQuery.hasPrefix(normalized) { return 10 }
        if title.normalizedSlashCommandQuery.hasPrefix(normalized) { return 20 }
        if ([name, title, description] + aliases).contains(where: { $0.normalizedSlashCommandQuery.contains(normalized) }) {
            return 30
        }
        return Int.max
    }
}

struct ParsedSlashCommand {
    let name: String
    let args: String
}

struct SlashCommandExecutionContext {
    let inputText: String
    let commands: [SlashCommandItem]
    let developerDebugEnabled: Bool
    let canNavigate: Bool
    let canToggleDeveloperDebug: Bool
    let canTerminateApp: Bool
    let statusText: String
}

struct SlashCommandExecutionEffects {
    var setInputText: (String) -> Void = { _ in }
    var appendStatusMessage: (String) -> Void = { _ in }
    var navigate: (NavDestination) -> Void = { _ in }
    var toggleDeveloperDebug: () -> Void = {}
    var terminateApp: () -> Void = {}
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
        effects.setInputText("")
        switch command.action {
        case .navigate(let destination):
            context.canNavigate ? effects.navigate(destination) : effects.appendStatusMessage("Navigation is not available here.")
        case .toggleDeveloperDebug:
            if context.developerDebugEnabled, context.canToggleDeveloperDebug {
                effects.toggleDeveloperDebug()
            } else {
                effects.appendStatusMessage("Developer debug mode is not enabled for this launch.")
            }
        case .showHelp:
            effects.appendStatusMessage(SlashCommandRegistry.helpText(for: context.commands))
        case .quit:
            context.canTerminateApp ? effects.terminateApp() : effects.appendStatusMessage("Quit is only available on macOS.")
        case .runWorkflow(let workflow):
            effects.runWorkflow(workflow, args)
        case .runSmithersPrompt(let promptId):
            effects.runSmithersPrompt(promptId, args)
        }
    }
}

enum SlashCommandRegistry {
    static var builtInCommands: [SlashCommandItem] {
        [
            command("dashboard", "Dashboard", "Open the Smithers overview.", .smithers, ["overview"], .navigate(.dashboard)),
            command("runs", "Runs", "Browse workflow runs.", .smithers, ["run"], .navigate(.runs)),
            command("workflows", "Workflows", "Browse workflows.", .smithers, ["workflow"], .navigate(.workflows)),
            command("approvals", "Approvals", "Review pending approvals.", .smithers, ["approval"], .navigate(.approvals)),
            command("prompts", "Prompts", "Browse prompt files.", .smithers, ["prompt"], .navigate(.prompts)),
            command("tickets", "Tickets", "Browse tickets.", .smithers, ["ticket"], .navigate(.tickets)),
            command("issues", "Issues", "Browse issues.", .smithers, ["issue"], .navigate(.issues)),
            command("changes", "Changes", "Open JJHub changes.", .smithers, ["vcs"], .navigate(.changes)),
            command("terminal", "Terminal", "Open a terminal.", .action, ["term", "shell"], .navigate(.terminal(id: "default"))),
            command("help", "Help", "Show available slash commands.", .action, ["?"], .showHelp),
            command("debug", "Developer Debug", "Toggle developer diagnostics.", .action, ["dev"], .toggleDeveloperDebug),
            command("quit", "Quit", "Quit SmithersGUI.", .action, ["exit"], .quit),
        ]
    }

    static func workflowCommands(from workflows: [Workflow]) -> [SlashCommandItem] {
        workflows.map { workflow in
            let suffix = commandSuffix(workflow.filePath ?? workflow.name)
            return command(
                "workflow:\(suffix)",
                workflow.name,
                workflow.filePath ?? "Run workflow.",
                .workflow,
                [],
                .runWorkflow(workflow)
            )
        }
    }

    static func promptCommands(from prompts: [SmithersPrompt]) -> [SlashCommandItem] {
        prompts.map { prompt in
            let name = prompt.entryFile.map { ($0 as NSString).lastPathComponent } ?? prompt.id
            let suffix = commandSuffix(name)
            return command(
                "prompt:\(suffix)",
                name,
                prompt.entryFile ?? "Run prompt.",
                .prompt,
                [],
                .runSmithersPrompt(prompt.id)
            )
        }
    }

    static func dynamicCommands(
        workflows: [Workflow],
        prompts: [SmithersPrompt]
    ) -> (workflows: [SlashCommandItem], prompts: [SlashCommandItem]) {
        (workflowCommands(from: workflows), promptCommands(from: prompts))
    }

    static func parse(_ input: String) -> ParsedSlashCommand? {
        let parsed = input.withCString { smithers_slashcmd_parse($0) }
        let json = Smithers.string(from: parsed)
        if let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(SlashParsePayload.self, from: data) {
            return ParsedSlashCommand(name: payload.command ?? "", args: payload.args.joined(separator: " "))
        }

        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        guard let space = body.firstIndex(where: { $0.isWhitespace }) else {
            return ParsedSlashCommand(name: String(body), args: "")
        }
        return ParsedSlashCommand(
            name: String(body[..<space]),
            args: String(body[space...]).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static func matches(for input: String, commands: [SlashCommandItem]) -> [SlashCommandItem] {
        guard let parsed = parse(input) else { return [] }
        return commands
            .map { ($0.score(for: parsed.name), $0) }
            .filter { $0.0 < Int.max }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1.name < rhs.1.name
            }
            .map(\.1)
    }

    static func exactMatch(for input: String, commands: [SlashCommandItem]) -> SlashCommandItem? {
        guard let parsed = parse(input), !parsed.name.isEmpty else { return nil }
        let name = parsed.name.normalizedSlashCommandQuery
        return commands.first {
            $0.name.normalizedSlashCommandQuery == name ||
                $0.aliases.contains { $0.normalizedSlashCommandQuery == name }
        }
    }

    static func keyValueArgs(_ raw: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: quoteAwareTokens(raw).compactMap { token in
            guard let separator = token.firstIndex(of: "="), separator != token.startIndex else { return nil }
            let key = String(token[..<separator])
            let value = String(token[token.index(after: separator)...])
            return (key, value)
        })
    }

    static func quoteAwareTokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: \.isWhitespace).map { token in
            String(token).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
    }

    static func helpText(for commands: [SlashCommandItem]) -> String {
        commands
            .sorted { $0.name < $1.name }
            .map { "\($0.displayName) - \($0.description)" }
            .joined(separator: "\n")
    }

    private static func command(
        _ name: String,
        _ title: String,
        _ description: String,
        _ category: SlashCommandCategory,
        _ aliases: [String],
        _ action: SlashCommandAction
    ) -> SlashCommandItem {
        SlashCommandItem(
            id: "\(category.rawValue.lowercased()).\(name)",
            name: name,
            title: title,
            description: description,
            category: category,
            aliases: aliases,
            action: action
        )
    }

    private static func commandSuffix(_ value: String) -> String {
        let last = (value as NSString).lastPathComponent
        let stem = (last as NSString).deletingPathExtension
        return stem.normalizedSlashCommandQuery.replacingOccurrences(of: " ", with: "-")
    }
}

private struct SlashParsePayload: Decodable {
    let command: String?
    let args: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        if let values = try? container.decodeIfPresent([String].self, forKey: .args) {
            args = values
        } else if let value = try? container.decodeIfPresent(String.self, forKey: .args) {
            args = [value]
        } else {
            args = []
        }
    }

    enum CodingKeys: String, CodingKey {
        case command
        case args
    }
}

extension String {
    var normalizedSlashCommandQuery: String {
        lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
