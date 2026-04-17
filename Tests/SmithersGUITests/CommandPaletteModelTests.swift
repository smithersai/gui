import XCTest
@testable import SmithersGUI

final class CommandPaletteParserTests: XCTestCase {
    func testPrefixParserModes() {
        XCTAssertEqual(CommandPaletteQueryParser.parse("").mode, .openAnything)
        XCTAssertEqual(CommandPaletteQueryParser.parse("hello").mode, .openAnything)
        XCTAssertEqual(CommandPaletteQueryParser.parse(">runs").mode, .command)
        XCTAssertEqual(CommandPaletteQueryParser.parse("?what's new").mode, .askAI)
        XCTAssertEqual(CommandPaletteQueryParser.parse("@contentview").mode, .mentionFile)
        XCTAssertEqual(CommandPaletteQueryParser.parse("/review").mode, .slash)
        XCTAssertEqual(CommandPaletteQueryParser.parse("#issue").mode, .workItem)
    }

    func testPrefixParserStripsPrefixSearchText() {
        XCTAssertEqual(CommandPaletteQueryParser.parse(">runs").searchText, "runs")
        XCTAssertEqual(CommandPaletteQueryParser.parse("?  explain status").searchText, "explain status")
        XCTAssertEqual(CommandPaletteQueryParser.parse("@  src/app.swift").searchText, "src/app.swift")
    }
}

@MainActor
final class CommandPaletteProviderTests: XCTestCase {
    func testOpenAnythingRanksOpenTabsAheadOfRoutes() {
        let tab = SidebarTab(
            id: "chat:session-1",
            kind: .chat,
            chatSessionId: "session-1",
            runId: nil,
            terminalId: nil,
            title: "Runs Notes",
            preview: "Investigate runner output",
            timestamp: "just now",
            group: "Today",
            sortDate: Date()
        )
        let context = makeContext(sidebarTabs: [tab])

        let items = CommandPaletteBuilder.items(for: "runs", context: context)
        XCTAssertFalse(items.isEmpty)
        XCTAssertEqual(items.first?.id, "workspace:chat:session-1")
    }

    func testRouteProviderIncludesExpectedDestinations() {
        let labels = Set(CommandPaletteBuilder.routeItems(developerToolsEnabled: true).map(\.title))
        XCTAssertTrue(labels.contains("Dashboard"))
        XCTAssertTrue(labels.contains("Chat"))
        XCTAssertTrue(labels.contains("Runs"))
        XCTAssertTrue(labels.contains("Workflows"))
        XCTAssertTrue(labels.contains("Approvals"))
        XCTAssertTrue(labels.contains("Search"))
        XCTAssertTrue(labels.contains("Terminal"))
    }

    func testSlashProviderIncludesBuiltIns() {
        let items = CommandPaletteBuilder.slashItems(
            commands: SlashCommandRegistry.builtInCommands,
            query: ""
        )
        let names = Set(items.map(\.title))
        XCTAssertTrue(names.contains("/model"))
        XCTAssertTrue(names.contains("/review"))
        XCTAssertTrue(names.contains("/runs"))
        XCTAssertTrue(names.contains("/workflows"))
        XCTAssertTrue(names.contains("/approvals"))
        XCTAssertTrue(names.contains("/search"))
        XCTAssertTrue(names.contains("/terminal"))
        XCTAssertTrue(names.contains("/debug"))
    }

    func testOpenAnythingAddsAskAIFallbackForUnmatchedQuery() {
        let items = CommandPaletteBuilder.items(for: "how do I deploy", context: makeContext())
        XCTAssertTrue(items.contains(where: {
            if case .askAI(let query) = $0.action {
                return query == "how do I deploy"
            }
            return false
        }))
    }

    func testCommandModeIncludesOpenMarkdownFileCommand() {
        let items = CommandPaletteBuilder.items(for: ">markdown", context: makeContext())
        let item = items.first { $0.id == "command.open-markdown-file" }

        XCTAssertEqual(item?.title, "Open Markdown File…")
        if case .some(.openMarkdownFilePicker) = item?.action {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected open markdown file action")
        }
    }

    func testSessionStoreSidebarTabsIncludesChatRunAndTerminal() {
        let store = SessionStore()
        let runId = "run-test-1"
        store.addRunTab(runId: runId, title: "Run Test")
        let terminalId = store.addTerminalTab()

        let tabs = store.sidebarTabs(matching: "")
        XCTAssertTrue(tabs.contains(where: { $0.kind == .chat }))
        XCTAssertTrue(tabs.contains(where: { $0.kind == .run && $0.runId == runId }))
        XCTAssertTrue(tabs.contains(where: { $0.kind == .terminal && $0.terminalId == terminalId }))
    }

    private func makeContext(sidebarTabs: [SidebarTab] = []) -> CommandPaletteContext {
        CommandPaletteContext(
            destination: .dashboard,
            sidebarTabs: sidebarTabs,
            runTabs: [],
            workflows: [],
            prompts: [],
            issues: [],
            tickets: [],
            landings: [],
            slashCommands: SlashCommandRegistry.builtInCommands,
            files: [],
            developerToolsEnabled: true
        )
    }
}

final class KeyboardChordParserTests: XCTestCase {
    func testLinearChordNavigatesToChat() {
        var parser = KeyboardChordParser()
        let now = Date()

        XCTAssertEqual(
            parser.handle(
                key: "g",
                shiftedKey: "g",
                modifiers: [],
                now: now,
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .consumed
        )
        XCTAssertEqual(
            parser.handle(
                key: "c",
                shiftedKey: "c",
                modifiers: [],
                now: now.addingTimeInterval(0.2),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .action(.navigate(.chat))
        )
    }

    func testChordTimeoutResetsPendingState() {
        var parser = KeyboardChordParser()
        parser.timeout = 1.0
        let now = Date()

        XCTAssertEqual(
            parser.handle(
                key: "g",
                shiftedKey: "g",
                modifiers: [],
                now: now,
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .consumed
        )

        XCTAssertEqual(
            parser.handle(
                key: "c",
                shiftedKey: "c",
                modifiers: [],
                now: now.addingTimeInterval(1.5),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .ignored
        )
    }

    func testUnknownSecondChordKeyResetsParser() {
        var parser = KeyboardChordParser()
        let now = Date()

        XCTAssertEqual(
            parser.handle(
                key: "g",
                shiftedKey: "g",
                modifiers: [],
                now: now,
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .consumed
        )
        XCTAssertEqual(
            parser.handle(
                key: "x",
                shiftedKey: "x",
                modifiers: [],
                now: now.addingTimeInterval(0.1),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .ignored
        )
        XCTAssertEqual(
            parser.handle(
                key: "c",
                shiftedKey: "c",
                modifiers: [],
                now: now.addingTimeInterval(0.2),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .ignored
        )
    }

    func testTmuxPrefixSequences() {
        var parser = KeyboardChordParser()
        let now = Date()

        XCTAssertEqual(
            parser.handle(
                key: "b",
                shiftedKey: "b",
                modifiers: [.control],
                now: now,
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .consumed
        )
        XCTAssertEqual(
            parser.handle(
                key: "c",
                shiftedKey: "c",
                modifiers: [],
                now: now.addingTimeInterval(0.1),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .action(.newTerminal)
        )

        XCTAssertEqual(
            parser.handle(
                key: "b",
                shiftedKey: "b",
                modifiers: [.control],
                now: now.addingTimeInterval(0.2),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .consumed
        )
        XCTAssertEqual(
            parser.handle(
                key: "7",
                shiftedKey: "&",
                modifiers: [.shift],
                now: now.addingTimeInterval(0.3),
                isTextInputFocused: false,
                isTerminalFocused: false
            ),
            .action(.closeCurrentTab)
        )
    }

    func testTerminalFocusedDoesNotCaptureChords() {
        var parser = KeyboardChordParser()

        XCTAssertEqual(
            parser.handle(
                key: "g",
                shiftedKey: "g",
                modifiers: [],
                isTextInputFocused: false,
                isTerminalFocused: true
            ),
            .ignored
        )
        XCTAssertEqual(
            parser.handle(
                key: "b",
                shiftedKey: "b",
                modifiers: [.control],
                isTextInputFocused: false,
                isTerminalFocused: true
            ),
            .ignored
        )
    }
}
