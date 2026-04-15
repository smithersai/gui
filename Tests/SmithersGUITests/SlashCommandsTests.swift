import XCTest
@testable import SmithersGUI

final class SlashCommandsTests: XCTestCase {

    // MARK: - Helpers

    private var builtIn: [SlashCommandItem] { SlashCommandRegistry.builtInCommands }

    private func cmd(named name: String) -> SlashCommandItem? {
        builtIn.first { $0.name == name }
    }

    // MARK: - SLASH_CMD_* (every individual command exists)

    func testSlashCmdModel() {
        let c = cmd(named: "model")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.model")
        XCTAssertEqual(c?.category, .codex)
    }

    func testSlashCmdApprovals() {
        let c = cmd(named: "codex-approvals")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.approvals")
    }

    func testSlashCmdReview() {
        let c = cmd(named: "review")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.review")
    }

    func testSlashCmdNew() {
        let c = cmd(named: "new")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.new")
    }

    func testSlashCmdInit() {
        let c = cmd(named: "init")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.init")
    }

    func testSlashCmdCompact() {
        let c = cmd(named: "compact")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.compact")
    }

    func testSlashCmdDiff() {
        let c = cmd(named: "diff")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.diff")
    }

    func testSlashCmdMention() {
        let c = cmd(named: "mention")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.mention")
    }

    func testSlashCmdStatus() {
        let c = cmd(named: "status")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.status")
    }

    func testSlashCmdMcp() {
        let c = cmd(named: "mcp")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.mcp")
    }

    func testSlashCmdLogout() {
        let c = cmd(named: "logout")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.logout")
    }

    func testSlashCmdQuit() {
        let c = cmd(named: "quit")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.quit")
    }

    func testSlashCmdFeedback() {
        let c = cmd(named: "feedback")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "codex.feedback")
    }

    func testSlashCmdDashboard() {
        let c = cmd(named: "dashboard")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.dashboard")
    }

    func testSlashCmdAgents() {
        let c = cmd(named: "agents")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.agents")
    }

    func testSlashCmdChanges() {
        let c = cmd(named: "changes")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.changes")
    }

    func testSlashCmdRuns() {
        let c = cmd(named: "runs")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.runs")
    }

    func testSlashCmdWorkflows() {
        let c = cmd(named: "workflows")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.workflows")
    }

    func testSlashCmdTriggers() {
        let c = cmd(named: "triggers")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.triggers")
    }

    func testSlashCmdJJHubWorkflows() {
        let c = cmd(named: "jjhub-workflows")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.jjhub-workflows")
    }

    func testSlashCmdApprovalQueue() {
        let c = cmd(named: "approvals")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.approvals")
    }

    func testSlashCmdPrompts() {
        let c = cmd(named: "prompts")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.prompts")
    }

    func testSlashCmdScores() {
        let c = cmd(named: "scores")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.scores")
    }

    func testSlashCmdMemory() {
        let c = cmd(named: "memory")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.memory")
    }

    func testSlashCmdSearch() {
        let c = cmd(named: "search")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.search")
    }

    func testSlashCmdSQL() {
        let c = cmd(named: "sql")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.sql")
    }

    func testSlashCmdLandings() {
        let c = cmd(named: "landings")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.landings")
    }

    func testSlashCmdTickets() {
        let c = cmd(named: "tickets")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.tickets")
    }

    func testSlashCmdIssues() {
        let c = cmd(named: "issues")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.issues")
    }

    func testSlashCmdWorkspaces() {
        let c = cmd(named: "workspaces")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.workspaces")
    }

    func testSlashCmdChat() {
        let c = cmd(named: "chat")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.chat")
    }

    func testSlashCmdTerminal() {
        let c = cmd(named: "terminal")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "smithers.terminal")
    }

    func testSlashCmdClear() {
        let c = cmd(named: "clear")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "action.clear")
    }

    func testSlashCmdHelp() {
        let c = cmd(named: "help")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.id, "action.help")
    }

    // MARK: - SLASH_COMMAND_ALIASES

    func testAliasModelReasoning() {
        let c = cmd(named: "model")
        XCTAssertTrue(c?.aliases.contains("reasoning") ?? false)
    }

    func testAliasCodexApprovalsSandbox() {
        let c = cmd(named: "codex-approvals")
        XCTAssertTrue(c?.aliases.contains("sandbox") ?? false)
        XCTAssertTrue(c?.aliases.contains("permissions") ?? false)
    }

    func testAliasQuitExit() {
        let c = cmd(named: "quit")
        XCTAssertTrue(c?.aliases.contains("exit") ?? false)
    }

    func testAliasChatHome() {
        let c = cmd(named: "chat")
        XCTAssertTrue(c?.aliases.contains("home") ?? false)
        XCTAssertTrue(c?.aliases.contains("console") ?? false)
    }

    func testAliasChangesVCS() {
        let c = cmd(named: "changes")
        XCTAssertTrue(c?.aliases.contains("change") ?? false)
        XCTAssertTrue(c?.aliases.contains("vcs") ?? false)
    }

    func testAliasIssuesTickets() {
        let c = cmd(named: "issues")
        XCTAssertTrue(c?.aliases.contains("tickets") ?? false)
        XCTAssertTrue(c?.aliases.contains("work-items") ?? false)
    }

    func testAliasClearChat() {
        let c = cmd(named: "clear")
        XCTAssertTrue(c?.aliases.contains("clear-chat") ?? false)
    }

    func testAliasHelpCommands() {
        let c = cmd(named: "help")
        XCTAssertTrue(c?.aliases.contains("commands") ?? false)
    }

    func testDebugCommandTogglesDeveloperPanel() {
        let c = cmd(named: "debug")
        XCTAssertEqual(c?.id, "action.debug")
        XCTAssertTrue(c?.aliases.contains("dev") ?? false)
        if case .toggleDeveloperDebug = c?.action {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected /debug to toggle developer debug")
        }
    }

    // MARK: - SLASH_COMMAND_CATEGORY_*

    func testCategoryCodex() {
        let codexCommands = builtIn.filter { $0.category == .codex }
        XCTAssertEqual(codexCommands.count, 13)
    }

    func testCategorySmithers() {
        let smithersCommands = builtIn.filter { $0.category == .smithers }
        XCTAssertEqual(smithersCommands.count, 19)
    }

    func testCategoryAction() {
        let actionCommands = builtIn.filter { $0.category == .action }
        XCTAssertEqual(actionCommands.count, 3)
    }

    func testCategoryWorkflowFromWorkflows() {
        let workflows = [
            Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: "deploy.yaml", status: nil, updatedAt: nil),
            Workflow(id: "test", workspaceId: nil, name: "Test", relativePath: nil, status: nil, updatedAt: nil),
        ]
        let cmds = SlashCommandRegistry.workflowCommands(from: workflows)
        XCTAssertEqual(cmds.count, 2)
        XCTAssertTrue(cmds.allSatisfy { $0.category == .workflow })
        XCTAssertEqual(cmds[0].name, "workflow:deploy")
        XCTAssertEqual(cmds[1].description, "Run Smithers workflow.")
    }

    func testCategoryPromptFromPrompts() {
        let prompts = [
            SmithersPrompt(id: "greet", entryFile: "greet.md", source: nil, inputs: nil),
            SmithersPrompt(id: "summarize", entryFile: nil, source: nil, inputs: nil),
        ]
        let cmds = SlashCommandRegistry.promptCommands(from: prompts)
        XCTAssertEqual(cmds.count, 2)
        XCTAssertTrue(cmds.allSatisfy { $0.category == .prompt })
        XCTAssertEqual(cmds[0].name, "prompt:greet")
        XCTAssertEqual(cmds[0].description, "greet.md")
        XCTAssertEqual(cmds[1].description, "Send Smithers prompt.")
    }

    // MARK: - SLASH_COMMAND_FUZZY_MATCHING

    func testFuzzyMatchByNameSubstring() {
        let item = builtIn.first!
        XCTAssertTrue(item.matches(String(item.name.prefix(3))))
    }

    func testFuzzyMatchByNameSubsequence() {
        let model = cmd(named: "model")!
        XCTAssertTrue(model.matches("mdl"))
        XCTAssertGreaterThan(model.score(for: "mdl"), 50)
        XCTAssertLessThan(model.score(for: "mdl"), Int.max)
    }

    func testFuzzyMatchAcrossSeparators() {
        let workflows = cmd(named: "jjhub-workflows")!
        XCTAssertTrue(workflows.matches("jhwf"))
    }

    func testFuzzyMatchRejectsOutOfOrderSubsequence() {
        let item = SlashCommandItem(
            id: "test.abc",
            name: "abc",
            title: "Alpha",
            description: "",
            category: .action,
            aliases: [],
            action: .showHelp
        )
        XCTAssertTrue(item.matches("ac"))
        XCTAssertFalse(item.matches("ca"))
    }

    func testFuzzyMatchByDescriptionSubstring() {
        let model = cmd(named: "model")!
        XCTAssertTrue(model.matches("Choose"))
    }

    func testFuzzyMatchByAlias() {
        let model = cmd(named: "model")!
        XCTAssertTrue(model.matches("reasoning"))
    }

    func testFuzzyMatchCaseInsensitive() {
        let model = cmd(named: "model")!
        XCTAssertTrue(model.matches("MODEL"))
        XCTAssertTrue(model.matches("REASONING"))
    }

    func testFuzzyMatchEmptyQueryMatchesAll() {
        let item = builtIn.first!
        XCTAssertTrue(item.matches(""))
    }

    func testFuzzyMatchNoMatch() {
        let model = cmd(named: "model")!
        XCTAssertFalse(model.matches("zzzznothing"))
    }

    func testFuzzyMatchByTitle() {
        let model = cmd(named: "model")!
        XCTAssertTrue(model.matches("Switch"))
    }

    // MARK: - SLASH_COMMAND_TAB_COMPLETION (matches for partial input)

    func testTabCompletionPartialPrefix() {
        let results = SlashCommandRegistry.matches(for: "/mo", commands: builtIn)
        XCTAssertTrue(results.contains { $0.name == "model" })
    }

    func testTabCompletionSlashOnly() {
        let results = SlashCommandRegistry.matches(for: "/", commands: builtIn)
        XCTAssertEqual(results.count, builtIn.count)
    }

    func testTabCompletionNoSlashReturnsEmpty() {
        let results = SlashCommandRegistry.matches(for: "model", commands: builtIn)
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - SLASH_COMMAND_SCORING_AND_RANKING

    func testScoreExactNameIsZero() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "model"), 0)
    }

    func testScoreExactAliasIsOne() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "reasoning"), 1)
    }

    func testScoreNamePrefixIsTen() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "mod"), 10)
    }

    func testScoreAliasPrefixIsTwenty() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "reas"), 20)
    }

    func testScoreTitlePrefixIsThirty() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "swit"), 30)
    }

    func testScoreOtherMatchIsFifty() {
        let model = cmd(named: "model")!
        // "effort" appears in description but not as a prefix of name/alias/title
        XCTAssertEqual(model.score(for: "effort"), 50)
    }

    func testScoreEmptyQueryIs100() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: ""), 100)
    }

    func testScoreCaseInsensitive() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.score(for: "MODEL"), 0)
        XCTAssertEqual(model.score(for: "REASONING"), 1)
    }

    // MARK: - SLASH_COMMAND_CATEGORY_RANKING

    func testCategoryRankingOrder() {
        // When scores tie, codex < smithers < workflow < prompt < action
        let results = SlashCommandRegistry.matches(for: "/", commands: builtIn)
        var lastCategory: SlashCommandCategory?
        var sawTransition = false
        for item in results {
            if let last = lastCategory, last != item.category {
                sawTransition = true
                // Verify ordering: codex before smithers before action
                // (no workflow/prompt in builtIn)
            }
            lastCategory = item.category
        }
        XCTAssertTrue(sawTransition, "Expected multiple categories in results")

        // More specific: first result should be codex, last should be action
        XCTAssertEqual(results.first?.category, .codex)
        XCTAssertEqual(results.last?.category, .action)
    }

    func testExactMatchRanksFirst() {
        let results = SlashCommandRegistry.matches(for: "/status", commands: builtIn)
        XCTAssertEqual(results.first?.name, "status")
    }

    // MARK: - SLASH_COMMAND_NAME_ARGS_PARSING

    func testParseCommandWithArgs() {
        let parsed = SlashCommandRegistry.parse("/model gpt-4 reasoning=high")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "model")
        XCTAssertEqual(parsed?.args, "gpt-4 reasoning=high")
    }

    func testParseCommandNoArgs() {
        let parsed = SlashCommandRegistry.parse("/help")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "help")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseSlashOnly() {
        let parsed = SlashCommandRegistry.parse("/")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseNoSlashReturnsNil() {
        XCTAssertNil(SlashCommandRegistry.parse("help"))
    }

    func testParseEmptyStringReturnsNil() {
        XCTAssertNil(SlashCommandRegistry.parse(""))
    }

    func testParseTrimsWhitespace() {
        let parsed = SlashCommandRegistry.parse("  /model  arg1  arg2  ")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "model")
        XCTAssertEqual(parsed?.args, "arg1  arg2")
    }

    func testParseMultipleArgs() {
        let parsed = SlashCommandRegistry.parse("/workflow:deploy env=prod region=us-east-1")
        XCTAssertEqual(parsed?.name, "workflow:deploy")
        XCTAssertEqual(parsed?.args, "env=prod region=us-east-1")
    }

    // MARK: - SLASH_COMMAND_EXACT_MATCH_EXECUTION

    func testExactMatchByName() {
        let match = SlashCommandRegistry.exactMatch(for: "/model", commands: builtIn)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "model")
    }

    func testExactMatchByAlias() {
        let match = SlashCommandRegistry.exactMatch(for: "/reasoning", commands: builtIn)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "model")
    }

    func testExactMatchCaseInsensitive() {
        let match = SlashCommandRegistry.exactMatch(for: "/MODEL", commands: builtIn)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "model")
    }

    func testExactMatchNoResult() {
        let match = SlashCommandRegistry.exactMatch(for: "/nonexistent", commands: builtIn)
        XCTAssertNil(match)
    }

    func testExactMatchSlashOnlyReturnsNil() {
        let match = SlashCommandRegistry.exactMatch(for: "/", commands: builtIn)
        XCTAssertNil(match)
    }

    func testExactMatchWithArgsStillWorks() {
        let match = SlashCommandRegistry.exactMatch(for: "/model gpt-4", commands: builtIn)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.name, "model")
    }

    func testExactMatchAgentsPrefersSmithersNavigationCommand() {
        let match = SlashCommandRegistry.exactMatch(for: "/agents", commands: builtIn)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.id, "smithers.agents")
    }

    func testExactMatchDynamicPrefixedCommandStillWorksWhenAliasConflicts() {
        let workflows = [
            Workflow(id: "permissions", workspaceId: nil, name: "Permissions", relativePath: nil, status: nil, updatedAt: nil),
        ]
        let dynamic = SlashCommandRegistry.workflowCommands(from: workflows)
        let commands = builtIn + dynamic

        XCTAssertEqual(dynamic.first?.aliases, [])
        XCTAssertEqual(SlashCommandRegistry.exactMatch(for: "/permissions", commands: commands)?.id, "codex.approvals")
        XCTAssertEqual(SlashCommandRegistry.exactMatch(for: "/workflow:permissions", commands: commands)?.id, "workflow.permissions")
    }

    // MARK: - SLASH_COMMAND_HELP_TEXT_GENERATION

    func testHelpTextContainsAllCategories() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("Smithers"))
        XCTAssertTrue(text.contains("Action"))
    }

    func testHelpTextContainsDisplayNames() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        XCTAssertTrue(text.contains("/model"))
        XCTAssertTrue(text.contains("/help"))
        XCTAssertTrue(text.contains("/changes"))
        XCTAssertTrue(text.contains("/dashboard"))
    }

    func testHelpTextContainsDescriptions() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        XCTAssertTrue(text.contains("Choose the Codex model"))
        XCTAssertTrue(text.contains("Show available slash commands."))
    }

    // MARK: - SLASH_COMMAND_HELP_GROUPED_BY_CATEGORY

    func testHelpGroupedByCategoryOrder() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        let codexRange = text.range(of: "Codex")
        let smithersRange = text.range(of: "Smithers")
        let actionRange = text.range(of: "Action")
        XCTAssertNotNil(codexRange)
        XCTAssertNotNil(smithersRange)
        XCTAssertNotNil(actionRange)
        XCTAssertTrue(codexRange!.lowerBound < smithersRange!.lowerBound)
        XCTAssertTrue(smithersRange!.lowerBound < actionRange!.lowerBound)
    }

    func testHelpTextOmitsEmptyCategories() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        // No workflow or prompt commands in builtIn
        XCTAssertFalse(text.contains("Workflow\n"))
        XCTAssertFalse(text.contains("Prompt\n"))
    }

    func testHelpTextIncludesWorkflowWhenPresent() {
        let workflows = [Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: "deploy.yaml", status: nil, updatedAt: nil)]
        let all = builtIn + SlashCommandRegistry.workflowCommands(from: workflows)
        let text = SlashCommandRegistry.helpText(for: all)
        XCTAssertTrue(text.contains("Workflow"))
        XCTAssertTrue(text.contains("/workflow:deploy"))
    }

    func testHelpTextIncludesEveryBuiltInCommand() {
        let text = SlashCommandRegistry.helpText(for: builtIn)
        for command in builtIn {
            XCTAssertTrue(
                text.contains("\(command.displayName) - \(command.description)"),
                "Missing \(command.displayName) from help text"
            )
        }
    }

    // MARK: - CHAT_PALETTE_MAX_8_RESULTS

    func testPaletteMax8Results() {
        // The palette should limit to 8 results; matches() returns all,
        // so the caller is expected to take prefix(8).
        let results = SlashCommandRegistry.matches(for: "/", commands: builtIn)
        // All built-in commands match "/", verify we can take 8
        XCTAssertGreaterThan(results.count, 8)
        let paletteResults = Array(results.prefix(8))
        XCTAssertEqual(paletteResults.count, 8)
    }

    // MARK: - ACTION_* types

    func testActionCodex() {
        let model = cmd(named: "model")!
        if case .codex(let codexCmd) = model.action {
            XCTAssertTrue(true)
            // Verify it's .model
            if case .model = codexCmd {} else { XCTFail("Expected .model") }
        } else {
            XCTFail("Expected .codex action")
        }
    }

    func testActionNavigate() {
        let dashboard = cmd(named: "dashboard")!
        if case .navigate(let dest) = dashboard.action {
            XCTAssertEqual(dest, .dashboard)
        } else {
            XCTFail("Expected .navigate action")
        }
    }

    func testActionClearChat() {
        let clear = cmd(named: "clear")!
        if case .clearChat = clear.action {} else {
            XCTFail("Expected .clearChat action")
        }
    }

    func testActionShowHelp() {
        let help = cmd(named: "help")!
        if case .showHelp = help.action {} else {
            XCTFail("Expected .showHelp action")
        }
    }

    func testActionRunWorkflow() {
        let workflows = [Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: ".smithers/workflows/deploy.yaml", status: nil, updatedAt: nil)]
        let cmds = SlashCommandRegistry.workflowCommands(from: workflows)
        if case .runWorkflow(let workflow) = cmds[0].action {
            XCTAssertEqual(workflow.id, "deploy")
            XCTAssertEqual(workflow.relativePath, ".smithers/workflows/deploy.yaml")
        } else {
            XCTFail("Expected .runWorkflow action")
        }
    }

    func testActionRunSmithersPrompt() {
        let prompts = [SmithersPrompt(id: "greet", entryFile: nil, source: nil, inputs: nil)]
        let cmds = SlashCommandRegistry.promptCommands(from: prompts)
        if case .runSmithersPrompt(let id) = cmds[0].action {
            XCTAssertEqual(id, "greet")
        } else {
            XCTFail("Expected .runSmithersPrompt action")
        }
    }

    // MARK: - CHAT_KEY_VALUE_ARGS_PARSING

    func testKeyValueArgsBasic() {
        let result = SlashCommandRegistry.keyValueArgs("env=prod region=us-east-1")
        XCTAssertEqual(result["env"], "prod")
        XCTAssertEqual(result["region"], "us-east-1")
    }

    func testKeyValueArgsStripsQuotes() {
        let result = SlashCommandRegistry.keyValueArgs("name=\"hello\" other='world'")
        XCTAssertEqual(result["name"], "hello")
        XCTAssertEqual(result["other"], "world")
    }

    func testKeyValueArgsQuotedValuesWithSpaces() {
        let result = SlashCommandRegistry.keyValueArgs("title=\"release notes\" summary='ship notes'")
        XCTAssertEqual(result["title"], "release notes")
        XCTAssertEqual(result["summary"], "ship notes")
    }

    func testKeyValueArgsEmptyQuotedValue() {
        let result = SlashCommandRegistry.keyValueArgs("name=\"\" other=value")
        XCTAssertEqual(result["name"], "")
        XCTAssertEqual(result["other"], "value")
    }

    func testKeyValueArgsEscapedQuotes() {
        let result = SlashCommandRegistry.keyValueArgs("path=\"a \\\"quoted\\\" value\"")
        XCTAssertEqual(result["path"], "a \"quoted\" value")
    }

    func testKeyValueArgsDuplicateKeysUseLastValue() {
        let result = SlashCommandRegistry.keyValueArgs("name=old name=\"new value\"")
        XCTAssertEqual(result["name"], "new value")
    }

    func testKeyValueArgsMalformedQuoteUsesBestEffortToken() {
        let result = SlashCommandRegistry.keyValueArgs("title=\"release notes")
        XCTAssertEqual(result["title"], "release notes")
    }

    func testKeyValueArgsEmptyString() {
        let result = SlashCommandRegistry.keyValueArgs("")
        XCTAssertTrue(result.isEmpty)
    }

    func testKeyValueArgsIgnoresTokensWithoutEquals() {
        let result = SlashCommandRegistry.keyValueArgs("standalone key=value")
        XCTAssertNil(result["standalone"])
        XCTAssertEqual(result["key"], "value")
    }

    func testKeyValueArgsMultipleEquals() {
        // "key=val=ue" should split on first = only
        let result = SlashCommandRegistry.keyValueArgs("key=val=ue")
        XCTAssertEqual(result["key"], "val=ue")
    }

    func testKeyValueArgsExtraWhitespace() {
        let result = SlashCommandRegistry.keyValueArgs("  a=1   b=2  ")
        XCTAssertEqual(result["a"], "1")
        XCTAssertEqual(result["b"], "2")
    }

    // MARK: - DisplayName

    func testDisplayNameHasSlashPrefix() {
        let model = cmd(named: "model")!
        XCTAssertEqual(model.displayName, "/model")
    }

    // MARK: - Unique IDs

    func testAllBuiltInCommandsHaveUniqueIds() {
        let ids = builtIn.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate IDs found")
    }

    func testAllBuiltInCommandsHaveUniqueNames() {
        let names = builtIn.map(\.name)
        XCTAssertEqual(names.count, Set(names).count, "Duplicate names found")
    }
}

final class SlashCommandDynamicRegistrationTests: XCTestCase {

    func testWorkflowCommandsDeduplicateCommandNames() {
        let workflows = [
            Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: "deploy.yml", status: nil, updatedAt: nil),
            Workflow(id: "deploy", workspaceId: nil, name: "Duplicate Deploy", relativePath: "deploy-again.yml", status: nil, updatedAt: nil),
        ]

        let commands = SlashCommandRegistry.workflowCommands(from: workflows)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.id, "workflow.deploy")
        XCTAssertEqual(commands.first?.name, "workflow:deploy")
    }

    func testDynamicCommandsSlugUnsafeIdentifiersAndHideUnsafeBareAlias() {
        let workflows = [
            Workflow(id: "release notes", workspaceId: nil, name: "Release Notes", relativePath: nil, status: nil, updatedAt: nil),
        ]

        let commands = SlashCommandRegistry.workflowCommands(from: workflows)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.name, "workflow:release-notes")
        XCTAssertEqual(commands.first?.aliases, [])
    }

    func testDynamicCommandsSkipEmptyIdentifiers() {
        let prompts = [
            SmithersPrompt(id: "   ", entryFile: nil, source: nil, inputs: nil),
            SmithersPrompt(id: "daily", entryFile: nil, source: nil, inputs: nil),
        ]

        let commands = SlashCommandRegistry.promptCommands(from: prompts)

        XCTAssertEqual(commands.map(\.name), ["prompt:daily"])
    }

    func testDynamicCommandsReserveBareAliasesAcrossWorkflowsAndPrompts() {
        let workflows = [
            Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: nil, status: nil, updatedAt: nil),
        ]
        let prompts = [
            SmithersPrompt(id: "deploy", entryFile: nil, source: nil, inputs: nil),
        ]

        let commands = SlashCommandRegistry.dynamicCommands(workflows: workflows, prompts: prompts)

        XCTAssertEqual(commands.workflows.first?.aliases, ["deploy"])
        XCTAssertEqual(commands.prompts.first?.aliases, [])
        XCTAssertEqual(commands.prompts.first?.name, "prompt:deploy")
    }
}

final class SlashCommandExecutorTests: XCTestCase {

    private var builtIn: [SlashCommandItem] { SlashCommandRegistry.builtInCommands }

    private func command(named name: String) -> SlashCommandItem {
        builtIn.first { $0.name == name }!
    }

    private func context(
        input: String,
        commands: [SlashCommandItem]? = nil,
        chatReady: Bool = true,
        developerDebugEnabled: Bool = true,
        canNavigate: Bool = true,
        canToggleDeveloperDebug: Bool = true,
        canStartNewChat: Bool = true,
        canTerminateApp: Bool = false
    ) -> SlashCommandExecutionContext {
        SlashCommandExecutionContext(
            inputText: input,
            commands: commands ?? builtIn,
            chatReady: chatReady,
            developerDebugEnabled: developerDebugEnabled,
            canNavigate: canNavigate,
            canToggleDeveloperDebug: canToggleDeveloperDebug,
            canStartNewChat: canStartNewChat,
            canTerminateApp: canTerminateApp,
            statusText: "status text"
        )
    }

    func testExecuteNavigationCommandTriggersNavigateAndStatus() {
        var inputText: String?
        var navigated: NavDestination?
        var statuses: [String] = []
        var effects = SlashCommandExecutionEffects()
        effects.setInputText = { inputText = $0 }
        effects.navigate = { navigated = $0 }
        effects.appendStatusMessage = { statuses.append($0) }

        SlashCommandExecutor.execute(
            command(named: "dashboard"),
            context: context(input: "/dashboard"),
            effects: effects
        )

        XCTAssertEqual(inputText, "")
        XCTAssertEqual(navigated, .dashboard)
        XCTAssertEqual(statuses, ["Opened Dashboard."])
    }

    func testExecuteNavigationCommandReportsMissingNavigationCallback() {
        var navigated: NavDestination?
        var statuses: [String] = []
        var effects = SlashCommandExecutionEffects()
        effects.navigate = { navigated = $0 }
        effects.appendStatusMessage = { statuses.append($0) }

        SlashCommandExecutor.execute(
            command(named: "dashboard"),
            context: context(input: "/dashboard", canNavigate: false),
            effects: effects
        )

        XCTAssertNil(navigated)
        XCTAssertEqual(statuses, ["Navigation to Dashboard is not wired into this chat view."])
    }

    func testExecuteModelCommandShowsModelSelection() {
        var inputText: String?
        var showedModelSelection = false
        var effects = SlashCommandExecutionEffects()
        effects.setInputText = { inputText = $0 }
        effects.showModelSelection = { showedModelSelection = true }

        SlashCommandExecutor.execute(
            command(named: "model"),
            context: context(input: "/model"),
            effects: effects
        )

        XCTAssertEqual(inputText, "")
        XCTAssertTrue(showedModelSelection)
    }

    func testExecuteReviewCommandDispatchesPromptWithArgs() {
        var inputText: String?
        var sentPrompts: [String] = []
        var effects = SlashCommandExecutionEffects()
        effects.setInputText = { inputText = $0 }
        effects.sendPromptIfReady = { sentPrompts.append($0) }

        SlashCommandExecutor.execute(
            command(named: "review"),
            context: context(input: "/review persistence layer"),
            effects: effects
        )

        XCTAssertEqual(inputText, "")
        XCTAssertEqual(sentPrompts.count, 1)
        XCTAssertTrue(sentPrompts[0].contains("Focus: persistence layer"))
    }

    func testExecuteInitCommandReportsAuthWhenChatNotReady() {
        var sentPrompts: [String] = []
        var statuses: [String] = []
        var effects = SlashCommandExecutionEffects()
        effects.sendPromptIfReady = { sentPrompts.append($0) }
        effects.appendStatusMessage = { statuses.append($0) }

        SlashCommandExecutor.execute(
            command(named: "init"),
            context: context(input: "/init", chatReady: false),
            effects: effects
        )

        XCTAssertTrue(sentPrompts.isEmpty)
        XCTAssertEqual(statuses, ["Codex is not authenticated. Use the auth panel above to sign in or add an API key."])
    }

    func testExecuteNewCommandUsesNewChatCallbackWhenAvailable() {
        var startedNewChat = false
        var clearedMessages = false
        var effects = SlashCommandExecutionEffects()
        effects.startNewChat = { startedNewChat = true }
        effects.clearMessages = { clearedMessages = true }

        SlashCommandExecutor.execute(
            command(named: "new"),
            context: context(input: "/new", canStartNewChat: true),
            effects: effects
        )

        XCTAssertTrue(startedNewChat)
        XCTAssertFalse(clearedMessages)
    }

    func testExecuteWorkflowCommandRoutesWorkflowAndRawArgs() {
        let workflow = Workflow(id: "deploy", workspaceId: nil, name: "Deploy", relativePath: nil, status: nil, updatedAt: nil)
        let command = SlashCommandRegistry.workflowCommands(from: [workflow])[0]
        var routedWorkflow: Workflow?
        var routedArgs: String?
        var effects = SlashCommandExecutionEffects()
        effects.runWorkflow = { workflow, args in
            routedWorkflow = workflow
            routedArgs = args
        }

        SlashCommandExecutor.execute(
            command,
            context: context(input: "/workflow:deploy title='release notes'", commands: builtIn + [command]),
            effects: effects
        )

        XCTAssertEqual(routedWorkflow?.id, "deploy")
        XCTAssertEqual(routedArgs, "title='release notes'")
    }

    func testExecutePromptCommandRoutesPromptAndRawArgs() {
        let prompt = SmithersPrompt(id: "greet", entryFile: nil, source: nil, inputs: nil)
        let command = SlashCommandRegistry.promptCommands(from: [prompt])[0]
        var routedPromptId: String?
        var routedArgs: String?
        var effects = SlashCommandExecutionEffects()
        effects.runSmithersPrompt = { promptId, args in
            routedPromptId = promptId
            routedArgs = args
        }

        SlashCommandExecutor.execute(
            command,
            context: context(input: "/prompt:greet name=Will", commands: builtIn + [command]),
            effects: effects
        )

        XCTAssertEqual(routedPromptId, "greet")
        XCTAssertEqual(routedArgs, "name=Will")
    }
}
