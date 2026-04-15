import XCTest
@testable import SmithersGUI

// MARK: - SlashCommandItem Match & Score Tests

final class SlashCommandMatchTests: XCTestCase {

    private var builtIn: [SlashCommandItem] { SlashCommandRegistry.builtInCommands }

    // MARK: - matches()

    func testMatchesEmptyQueryMatchesAll() {
        let cmd = builtIn.first!
        XCTAssertTrue(cmd.matches(""))
    }

    func testMatchesByName() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertTrue(cmd.matches("model"))
    }

    func testMatchesByAlias() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertTrue(cmd.matches("reasoning"))
    }

    func testMatchesByTitle() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertTrue(cmd.matches("Switch"))
    }

    func testMatchesByDescription() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertTrue(cmd.matches("reasoning"))
    }

    func testMatchesCaseInsensitive() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertTrue(cmd.matches("MODEL"))
    }

    func testNoMatchForUnrelated() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertFalse(cmd.matches("zzzzunrelated"))
    }

    // MARK: - score()

    func testScoreExactNameIsZero() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertEqual(cmd.score(for: "model"), 0)
    }

    func testScoreExactAliasIsOne() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertEqual(cmd.score(for: "reasoning"), 1)
    }

    func testScoreNamePrefixIsTen() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertEqual(cmd.score(for: "mod"), 10)
    }

    func testScoreEmptyQueryIs100() {
        let cmd = builtIn.first!
        XCTAssertEqual(cmd.score(for: ""), 100)
    }

    func testScorePartialMatchIs50() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        // "witch" matches description "Switch Model" but not as prefix
        XCTAssertEqual(cmd.score(for: "witch"), 50)
    }

    // MARK: - displayName

    func testDisplayNameHasSlashPrefix() {
        let cmd = builtIn.first(where: { $0.name == "model" })!
        XCTAssertEqual(cmd.displayName, "/model")
    }
}

// MARK: - SlashCommandRegistry Parse Tests

final class SlashCommandParseTests: XCTestCase {

    func testParseSimpleCommand() {
        let parsed = SlashCommandRegistry.parse("/model")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "model")
        XCTAssertEqual(parsed?.args, "")
    }

    func testParseCommandWithArgs() {
        let parsed = SlashCommandRegistry.parse("/workflow:run key=value")
        XCTAssertEqual(parsed?.name, "workflow:run")
        XCTAssertEqual(parsed?.args, "key=value")
    }

    func testParseSlashOnly() {
        let parsed = SlashCommandRegistry.parse("/")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.name, "")
    }

    func testParseNonSlash() {
        XCTAssertNil(SlashCommandRegistry.parse("model"))
    }

    func testParseTrimsWhitespace() {
        let parsed = SlashCommandRegistry.parse("  /model  ")
        XCTAssertEqual(parsed?.name, "model")
    }

    func testParseWithMultipleSpaces() {
        let parsed = SlashCommandRegistry.parse("/cmd  arg1  arg2")
        XCTAssertEqual(parsed?.name, "cmd")
        XCTAssertEqual(parsed?.args, "arg1  arg2")
    }
}

// MARK: - SlashCommandRegistry Matches Tests

final class SlashCommandMatchesTests: XCTestCase {

    private var builtIn: [SlashCommandItem] { SlashCommandRegistry.builtInCommands }

    func testMatchesAllForSlash() {
        let results = SlashCommandRegistry.matches(for: "/", commands: builtIn)
        XCTAssertEqual(results.count, builtIn.count)
    }

    func testMatchesFiltersByQuery() {
        let results = SlashCommandRegistry.matches(for: "/model", commands: builtIn)
        XCTAssertTrue(results.first?.name == "model")
    }

    func testMatchesReturnsEmptyForNonSlash() {
        let results = SlashCommandRegistry.matches(for: "model", commands: builtIn)
        XCTAssertTrue(results.isEmpty)
    }

    func testExactMatchFindsCommand() {
        let cmd = SlashCommandRegistry.exactMatch(for: "/model", commands: builtIn)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "model")
    }

    func testExactMatchFindsAlias() {
        let cmd = SlashCommandRegistry.exactMatch(for: "/reasoning", commands: builtIn)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.name, "model")
    }

    func testExactMatchNilForPartial() {
        let cmd = SlashCommandRegistry.exactMatch(for: "/mod", commands: builtIn)
        XCTAssertNil(cmd)
    }

    func testExactMatchNilForEmpty() {
        let cmd = SlashCommandRegistry.exactMatch(for: "/", commands: builtIn)
        XCTAssertNil(cmd)
    }
}

// MARK: - SlashCommandRegistry keyValueArgs Tests

final class SlashCommandKeyValueArgsTests: XCTestCase {

    func testParseKeyValuePairs() {
        let result = SlashCommandRegistry.keyValueArgs("key=value name=test")
        XCTAssertEqual(result["key"], "value")
        XCTAssertEqual(result["name"], "test")
    }

    func testStripsQuotes() {
        let result = SlashCommandRegistry.keyValueArgs("key=\"value\" name='test'")
        XCTAssertEqual(result["key"], "value")
        XCTAssertEqual(result["name"], "test")
    }

    func testSkipsTokensWithoutEquals() {
        let result = SlashCommandRegistry.keyValueArgs("key=value standalone")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["key"], "value")
    }

    func testEmptyString() {
        XCTAssertTrue(SlashCommandRegistry.keyValueArgs("").isEmpty)
    }

    func testSkipsEmptyKey() {
        let result = SlashCommandRegistry.keyValueArgs("=value")
        XCTAssertTrue(result.isEmpty)
    }
}

// MARK: - SlashCommandRegistry helpText Tests

final class SlashCommandHelpTextTests: XCTestCase {

    func testHelpTextContainsAllCategories() {
        let text = SlashCommandRegistry.helpText(for: SlashCommandRegistry.builtInCommands)
        XCTAssertTrue(text.contains("Codex"))
        XCTAssertTrue(text.contains("Smithers"))
        XCTAssertTrue(text.contains("Action"))
    }

    func testHelpTextContainsCommandNames() {
        let text = SlashCommandRegistry.helpText(for: SlashCommandRegistry.builtInCommands)
        XCTAssertTrue(text.contains("/model"))
        XCTAssertTrue(text.contains("/help"))
        XCTAssertTrue(text.contains("/dashboard"))
    }

    func testHelpTextEmptyCommands() {
        let text = SlashCommandRegistry.helpText(for: [])
        XCTAssertTrue(text.isEmpty)
    }
}

// MARK: - SlashCommandRegistry workflowCommands Tests

final class SlashCommandWorkflowTests: XCTestCase {

    func testWorkflowCommandsGenerated() {
        let workflows = [
            Workflow(id: "wf1", workspaceId: nil, name: "Deploy", relativePath: "deploy.yml", status: .active, updatedAt: nil),
            Workflow(id: "wf2", workspaceId: nil, name: "Test", relativePath: nil, status: .draft, updatedAt: nil),
        ]
        let cmds = SlashCommandRegistry.workflowCommands(from: workflows)
        XCTAssertEqual(cmds.count, 2)
        XCTAssertEqual(cmds[0].name, "workflow:wf1")
        XCTAssertEqual(cmds[0].category, .workflow)
        XCTAssertEqual(cmds[1].title, "Test")
    }

    func testPromptCommandsGenerated() {
        let prompts = [
            SmithersPrompt(id: "p1", entryFile: "prompt.md", source: nil, inputs: nil),
        ]
        let cmds = SlashCommandRegistry.promptCommands(from: prompts)
        XCTAssertEqual(cmds.count, 1)
        XCTAssertEqual(cmds[0].name, "prompt:p1")
        XCTAssertEqual(cmds[0].category, .prompt)
    }
}

// MARK: - SlashCommandCategory Tests

final class SlashCommandCategoryTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(SlashCommandCategory.codex.rawValue, "Codex")
        XCTAssertEqual(SlashCommandCategory.smithers.rawValue, "Smithers")
        XCTAssertEqual(SlashCommandCategory.workflow.rawValue, "Workflow")
        XCTAssertEqual(SlashCommandCategory.prompt.rawValue, "Prompt")
        XCTAssertEqual(SlashCommandCategory.action.rawValue, "Action")
    }
}

// MARK: - BuiltIn Commands Completeness Tests

final class BuiltInCommandsCompletenessTests: XCTestCase {

    func testBuiltInHasMinimumCount() {
        XCTAssertGreaterThanOrEqual(SlashCommandRegistry.builtInCommands.count, 25)
    }

    func testAllBuiltInIdsUnique() {
        let ids = SlashCommandRegistry.builtInCommands.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testAllBuiltInNamesUnique() {
        let names = SlashCommandRegistry.builtInCommands.map(\.name)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testEveryCommandHasDescription() {
        for cmd in SlashCommandRegistry.builtInCommands {
            XCTAssertFalse(cmd.description.isEmpty, "\(cmd.name) has empty description")
        }
    }

    func testEveryCommandHasTitle() {
        for cmd in SlashCommandRegistry.builtInCommands {
            XCTAssertFalse(cmd.title.isEmpty, "\(cmd.name) has empty title")
        }
    }
}
