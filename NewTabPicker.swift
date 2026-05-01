import Foundation

enum ChatTargetKind: String, Hashable {
    case externalAgent
}

struct ChatTargetOption: Identifiable, Equatable, Hashable {
    let kind: ChatTargetKind
    let id: String
    let name: String
    let description: String
    let status: String
    let roles: [String]
    let binary: String
    let recommended: Bool
    let usable: Bool
}

func chatTargetStatusLabel(_ status: String) -> String {
    switch status {
    case "likely-subscription": return "Signed in"
    case "api-key": return "API key"
    case "binary-only": return "Binary only"
    default: return "Available"
    }
}

enum NewTabSelection: Hashable {
    case terminal
    case browser
    case externalAgent(ChatTargetOption)
}

struct NewTabPaletteOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let selection: NewTabSelection
    let searchTokens: [String]

    var commandPaletteItem: CommandPaletteItem {
        CommandPaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            icon: icon,
            section: "New",
            keywords: searchTokens,
            shortcut: nil,
            action: .newTab(selection),
            isEnabled: true
        )
    }
}

enum NewTabPaletteCatalog {
    static let expandedQuery = "new "
    static let rootCommandItem = CommandPaletteItem(
        id: "command.new",
        title: "New",
        subtitle: "Create a new terminal, browser, or agent tab.",
        icon: "plus",
        section: "Commands",
        keywords: ["new", "tab", "terminal", "browser", "agent", "workspace"],
        shortcut: nil,
        action: .expandNewTabs,
        isEnabled: true
    )

    static func commandPaletteItems(agents: [SmithersAgent], query: String) -> [CommandPaletteItem] {
        options(agents: agents)
            .filter { matches($0, query: query) }
            .map(\.commandPaletteItem)
    }

    static func queryAfterExpandedPrefix(in rawQuery: String) -> String? {
        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        guard parsed.mode == .openAnything else { return nil }

        let text = rawQuery.trimmedLeadingWhitespace
        guard text.lowercased().hasPrefix(expandedQuery) else { return nil }
        return String(text.dropFirst(expandedQuery.count))
    }

    static func isExpandedQueryWithoutFilter(_ rawQuery: String) -> Bool {
        guard let query = queryAfterExpandedPrefix(in: rawQuery) else { return false }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func options(agents: [SmithersAgent]) -> [NewTabPaletteOption] {
        var options: [NewTabPaletteOption] = [
            NewTabPaletteOption(
                id: "new-tab.terminal",
                title: "New Terminal",
                subtitle: "Open a new shell in this workspace",
                icon: "terminal.fill",
                selection: .terminal,
                searchTokens: ["terminal", "shell", "new", "tab", "command"]
            ),
            NewTabPaletteOption(
                id: "new-tab.browser",
                title: "New Browser",
                subtitle: "Open a web browser in a new tab",
                icon: "safari",
                selection: .browser,
                searchTokens: ["browser", "web", "safari", "new", "tab", "url"]
            ),
        ]

        for agent in agents where agent.usable {
            let binary = agent.binaryPath.isEmpty ? agent.command : agent.binaryPath
            let target = ChatTargetOption(
                kind: .externalAgent,
                id: agent.id,
                name: agent.name,
                description: "Launch the \(agent.name) CLI in this terminal.",
                status: agent.status,
                roles: agent.roles,
                binary: binary,
                recommended: false,
                usable: true
            )
            options.append(
                NewTabPaletteOption(
                    id: "new-tab.agent.\(agent.id)",
                    title: agent.name,
                    subtitle: agentSubtitle(status: agent.status, roles: agent.roles),
                    icon: agentIconName(agent.name),
                    selection: .externalAgent(target),
                    searchTokens: [agent.name, agent.id, "new", "tab", "agent"] + agent.roles
                )
            )
        }

        return options
    }

    private static func matches(_ option: NewTabPaletteOption, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return true }

        if option.title.lowercased().contains(trimmed) { return true }
        if option.subtitle.lowercased().contains(trimmed) { return true }
        return option.searchTokens.contains { $0.lowercased().contains(trimmed) }
    }

    private static func agentIconName(_ name: String) -> String {
        switch name.lowercased() {
        case "claude code": return "chevron.left.forwardslash.chevron.right"
        case "codex": return "cpu"
        case "gemini": return "sparkles"
        case "opencode": return "curlybraces"
        case "amp": return "bolt.fill"
        case "forge": return "hammer.fill"
        case "kimi": return "globe.asia.australia.fill"
        case "aider": return "wrench.and.screwdriver.fill"
        default: return "terminal.fill"
        }
    }

    private static func agentSubtitle(status: String, roles: [String]) -> String {
        var parts = [chatTargetStatusLabel(status)]
        if !roles.isEmpty {
            parts.append(roles.map { $0.capitalized }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

enum ContentViewCommandPaletteModel {
    static func items(
        for rawQuery: String,
        baseItems: [CommandPaletteItem],
        agents: [SmithersAgent]
    ) -> [CommandPaletteItem] {
        if let newTabQuery = NewTabPaletteCatalog.queryAfterExpandedPrefix(in: rawQuery) {
            return NewTabPaletteCatalog.commandPaletteItems(agents: agents, query: newTabQuery)
        }

        let parsed = CommandPaletteQueryParser.parse(rawQuery)
        guard parsed.mode == .openAnything else { return baseItems }

        let agentMatches = NewTabPaletteCatalog.commandPaletteItems(
            agents: agents,
            query: parsed.searchText
        ).filter { item in
            guard case .newTab(let selection) = item.action else { return false }
            if case .externalAgent = selection { return !parsed.searchText.isEmpty }
            return false
        }

        var items = baseItems.filter { $0.id != NewTabPaletteCatalog.rootCommandItem.id }
        if shouldIncludeRootItem(for: parsed.searchText) {
            items.insert(NewTabPaletteCatalog.rootCommandItem, at: 0)
        }

        if !agentMatches.isEmpty {
            let existingIDs = Set(items.map(\.id))
            let newAgentItems = agentMatches.filter { !existingIDs.contains($0.id) }
            items.insert(contentsOf: newAgentItems, at: 0)
        }
        return items
    }

    static func followUpQuery(afterSelecting item: CommandPaletteItem, rawQuery: String) -> String? {
        _ = rawQuery
        guard case .expandNewTabs = item.action else { return nil }
        return NewTabPaletteCatalog.expandedQuery
    }

    static func preferredSelectionIndex(for rawQuery: String) -> Int {
        NewTabPaletteCatalog.isExpandedQueryWithoutFilter(rawQuery) ? -1 : 0
    }

    private static func shouldIncludeRootItem(for query: String) -> Bool {
        let normalized = query.normalizedCommandPaletteQuery
        guard !normalized.isEmpty else { return true }

        let root = NewTabPaletteCatalog.rootCommandItem
        return ([root.title, root.subtitle] + root.keywords).contains {
            $0.normalizedCommandPaletteQuery.contains(normalized)
        }
    }
}

private extension String {
    var trimmedLeadingWhitespace: String {
        String(drop(while: \.isWhitespace))
    }
}
