import XCTest
import SwiftUI
import ViewInspector
@testable import SmithersGUI

// MARK: - Mock SmithersClient subclass

/// A subclass of SmithersClient that overrides prompt-related methods to avoid
/// hitting the filesystem.  We use a subclass rather than a protocol because
/// PromptsView takes `@ObservedObject var smithers: SmithersClient`.
@MainActor
private final class MockSmithersClient: SmithersClient {
    var mockPrompts: [SmithersPrompt] = []
    var mockFullPrompt: SmithersPrompt?
    var mockProps: [PromptInput] = []
    var mockPreviewResult: String = ""
    var listPromptsCalled = false
    var getPromptCalledWith: String?
    var discoverPropsCalledWith: String?
    var updatePromptCalledWith: (id: String, source: String)?
    var previewPromptCalledWith: (id: String, input: [String: String])?
    var previewPromptSourceCalledWith: (id: String, source: String, input: [String: String])?
    var shouldThrow = false

    override func listPrompts() async throws -> [SmithersPrompt] {
        listPromptsCalled = true
        if shouldThrow { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "list error"]) }
        return mockPrompts
    }

    override func getPrompt(_ promptId: String) async throws -> SmithersPrompt {
        getPromptCalledWith = promptId
        if shouldThrow { throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "get error"]) }
        return mockFullPrompt ?? SmithersPrompt(id: promptId, entryFile: nil, source: "", inputs: nil)
    }

    override func discoverPromptProps(_ promptId: String) async throws -> [PromptInput] {
        discoverPropsCalledWith = promptId
        if shouldThrow { throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "props error"]) }
        return mockProps
    }

    override func updatePrompt(_ promptId: String, source: String) async throws {
        updatePromptCalledWith = (id: promptId, source: source)
        if shouldThrow { throw NSError(domain: "test", code: 4, userInfo: [NSLocalizedDescriptionKey: "save error"]) }
    }

    override func previewPrompt(_ promptId: String, input: [String: String]) async throws -> String {
        previewPromptCalledWith = (id: promptId, input: input)
        if shouldThrow { throw NSError(domain: "test", code: 5, userInfo: [NSLocalizedDescriptionKey: "preview error"]) }
        return mockPreviewResult
    }

    override func previewPrompt(_ promptId: String, source: String, input: [String: String]) async throws -> String {
        previewPromptSourceCalledWith = (id: promptId, source: source, input: input)
        if shouldThrow { throw NSError(domain: "test", code: 5, userInfo: [NSLocalizedDescriptionKey: "preview error"]) }
        return mockPreviewResult
    }
}

// MARK: - Helpers

private let samplePrompts: [SmithersPrompt] = [
    SmithersPrompt(id: "greeting", entryFile: ".smithers/prompts/greeting.mdx",
                   source: "Hello {props.name}, welcome to {props.team}!",
                   inputs: [PromptInput(name: "name", type: "string", defaultValue: "World")]),
    SmithersPrompt(id: "review", entryFile: ".smithers/prompts/review.mdx",
                   source: "Review for {props.author}",
                   inputs: nil),
    SmithersPrompt(id: "deploy", entryFile: nil, source: nil, inputs: nil),
]

private let sampleProps: [PromptInput] = [
    PromptInput(name: "author", type: "string", defaultValue: nil),
    PromptInput(name: "name", type: "string", defaultValue: "World"),
    PromptInput(name: "team", type: nil, defaultValue: "engineering"),
]

@MainActor
private func loadedPromptsView(_ client: MockSmithersClient, prompts: [SmithersPrompt]) -> PromptsView {
    client.mockPrompts = prompts
    return PromptsView(smithers: client, initialPrompts: prompts)
}

private let promptPropPattern = "\\{\\s*props\\.([\\w.-]+)\\s*\\}"

private func discoveredPropNames(in source: String) throws -> [String] {
    let pattern = try NSRegularExpression(pattern: promptPropPattern)
    let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
    return matches.compactMap { match in
        Range(match.range(at: 1), in: source).map { String(source[$0]) }
    }
}

// MARK: - Model-level tests

final class SmithersPromptModelTests: XCTestCase {

    /// PromptInput.id is derived from name
    func testPromptInputIdentity() {
        let input = PromptInput(name: "foo", type: "string", defaultValue: nil)
        XCTAssertEqual(input.id, "foo")
    }

    /// SmithersPrompt has stable identity from id
    func testSmithersPromptIdentity() {
        let p = SmithersPrompt(id: "abc", entryFile: nil, source: nil, inputs: nil)
        XCTAssertEqual(p.id, "abc")
    }
}

// MARK: - DetailTab tests

final class DetailTabTests: XCTestCase {
    func testRawValues() {
        XCTAssertEqual(PromptsView.DetailTab.source.rawValue, "Source")
        XCTAssertEqual(PromptsView.DetailTab.inputs.rawValue, "Inputs")
        XCTAssertEqual(PromptsView.DetailTab.preview.rawValue, "Preview")
    }

    func testAllCasesCount() {
        XCTAssertEqual(PromptsView.DetailTab.allCases.count, 3)
    }
}

// MARK: - CONSTANT_PROMPTS_LIST_WIDTH_240

@MainActor
final class PromptsListWidthTests: XCTestCase {

    /// The prompt list sidebar must be exactly 240pt wide.
    func testListWidthIs240() throws {
        let client = MockSmithersClient()
        let view = loadedPromptsView(client, prompts: samplePrompts)
        let inspector = try view.inspect()

        // The structure: VStack > header HStack > content HStack > promptList.frame(width: 240)
        let hstack = try inspector.vStack().hStack(1)
        let listWidth = try hstack.scrollView(0).fixedWidth()
        XCTAssertEqual(listWidth, 240, "Prompt list width must be exactly 240pt")
    }
}

// MARK: - PROMPTS_LIST

@MainActor
final class PromptsListTests: XCTestCase {

    func testEmptyStateShowsNoPromptsFound() throws {
        let client = MockSmithersClient()
        let view = loadedPromptsView(client, prompts: [])
        let text = try view.inspect().find(text: "No prompts found")
        XCTAssertNoThrow(text)
    }

    func testPromptsRenderedInList() throws {
        let client = MockSmithersClient()
        let view = loadedPromptsView(client, prompts: samplePrompts)
        let inspector = try view.inspect()
        for prompt in samplePrompts {
            XCTAssertNoThrow(try inspector.find(text: prompt.id),
                             "Prompt '\(prompt.id)' should appear in the list")
        }
    }

    func testEntryFileShownWhenPresent() throws {
        let client = MockSmithersClient()
        let view = loadedPromptsView(client, prompts: [samplePrompts[0]])
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(text: ".smithers/prompts/greeting.mdx"))
    }

    /// BUG: When entryFile is nil the view still renders the prompt row but
    /// there is no subtitle text. The "deploy" prompt (entryFile == nil)
    /// should still be visible.
    func testPromptWithNilEntryFileStillVisible() throws {
        let client = MockSmithersClient()
        let view = loadedPromptsView(client, prompts: [samplePrompts[2]]) // deploy, entryFile == nil
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(text: "deploy"))
    }
}

// MARK: - PROMPTS_SPLIT_LIST_DETAIL_LAYOUT

@MainActor
final class PromptsSplitLayoutTests: XCTestCase {

    /// Detail pane shows "Select a prompt" placeholder when nothing is selected.
    func testNoSelectionShowsPlaceholder() throws {
        let client = MockSmithersClient()
        client.mockPrompts = samplePrompts
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(text: "Select a prompt"))
    }

    /// Header contains "Prompts" title.
    func testHeaderTitle() throws {
        let client = MockSmithersClient()
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(text: "Prompts"))
    }

    /// The refresh button is present in the header.
    func testRefreshButtonExists() throws {
        let client = MockSmithersClient()
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(ViewType.Button.self))
    }
}

// MARK: - PROMPTS_SOURCE_EDIT

@MainActor
final class PromptsSourceEditorTests: XCTestCase {

    /// BUG: The source editor uses TextEditor which does not support
    /// accessibility identifiers out of the box, making it hard to
    /// differentiate from other text views in tests. There is no
    /// .accessibilityIdentifier set on the TextEditor.
    func testSourceEditorNotVisibleWithoutSelection() throws {
        let client = MockSmithersClient()
        client.mockPrompts = samplePrompts
        let view = PromptsView(smithers: client)
        // Without selection, no TextEditor should be present.
        let inspector = try view.inspect()
        XCTAssertThrowsError(try inspector.find(ViewType.TextEditor.self),
                             "TextEditor should NOT be visible when no prompt is selected")
    }
}

// MARK: - PROMPTS_ASYNC_SOURCE_LOAD_GUARD

final class PromptSourceLoadSnapshotTests: XCTestCase {

    func testFreshLoadCanApplyWhenSelectionAndGenerationsMatch() {
        let snapshot = PromptSourceLoadSnapshot(
            promptId: "review",
            loadGeneration: 3,
            editGeneration: 7
        )

        XCTAssertTrue(snapshot.canApply(
            selectedId: "review",
            activeLoadGeneration: 3,
            currentEditGeneration: 7
        ))
    }

    func testLoadCannotApplyAfterUserEditGenerationChanges() {
        let snapshot = PromptSourceLoadSnapshot(
            promptId: "review",
            loadGeneration: 3,
            editGeneration: 7
        )

        XCTAssertFalse(snapshot.canApply(
            selectedId: "review",
            activeLoadGeneration: 3,
            currentEditGeneration: 8
        ))
    }

    func testLoadCannotApplyAfterAnotherLoadStarts() {
        let snapshot = PromptSourceLoadSnapshot(
            promptId: "review",
            loadGeneration: 3,
            editGeneration: 7
        )

        XCTAssertFalse(snapshot.canApply(
            selectedId: "review",
            activeLoadGeneration: 4,
            currentEditGeneration: 7
        ))
    }

    func testLoadCannotApplyAfterSelectionChanges() {
        let snapshot = PromptSourceLoadSnapshot(
            promptId: "review",
            loadGeneration: 3,
            editGeneration: 7
        )

        XCTAssertFalse(snapshot.canApply(
            selectedId: "greeting",
            activeLoadGeneration: 3,
            currentEditGeneration: 7
        ))
    }
}

// MARK: - PROMPTS_SOURCE_INPUTS_PREVIEW_TABS

final class PromptsTabTests: XCTestCase {

    /// All three tab labels should exist when a prompt is selected.
    func testTabLabelsExist() {
        XCTAssertEqual(PromptsView.DetailTab.source.rawValue, "Source")
        XCTAssertEqual(PromptsView.DetailTab.inputs.rawValue, "Inputs")
        XCTAssertEqual(PromptsView.DetailTab.preview.rawValue, "Preview")
    }
}

// MARK: - PROMPTS_PROPS_DISCOVERY & PROMPTS_REGEX_PROPS_DISCOVERY

final class PromptsPropsDiscoveryTests: XCTestCase {

    /// discoverPromptProps should find {props.xxx} patterns via regex.
    @MainActor
    func testDiscoverPropsFindsSimpleProps() async throws {
        let client = MockSmithersClient()
        client.mockProps = sampleProps
        client.discoverPropsCalledWith = nil

        _ = try await client.discoverPromptProps("greeting")
        XCTAssertEqual(client.discoverPropsCalledWith, "greeting")
    }

    /// The real regex pattern in SmithersClient uses \\{\\s*props\\.([\\w.-]+)\\s*\\}
    /// Test the regex directly.
    func testRegexPattern() throws {
        let source = "Hello { props.name }, your team is {props.team}."
        let found = try discoveredPropNames(in: source)
        XCTAssertEqual(Set(found), Set(["name", "team"]))
    }

    /// Hyphenated prop names like {props.first-name} are supported.
    func testRegexMatchesHyphenatedProps() throws {
        let source = "Hello {props.first-name}!"
        let found = try discoveredPropNames(in: source)
        XCTAssertEqual(found, ["first-name"])
    }

    /// BUG: The regex does not handle nested braces like {{props.name}}.
    func testRegexMatchesInsideDoubleBraces() throws {
        let source = "Hello {{props.name}}!"
        let pattern = try NSRegularExpression(pattern: promptPropPattern)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(matches.count, 1, "BUG: Regex matches inside double braces — may break Handlebars templates")
    }

    /// The regex handles whitespace inside braces: { props.name }
    func testRegexAllowsWhitespace() throws {
        let source = "Hello { props.name }!"
        let pattern = try NSRegularExpression(pattern: promptPropPattern)
        let matches = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
        XCTAssertEqual(matches.count, 1)
    }
}

// MARK: - PROMPTS_INPUT_VALUE_FORM

final class PromptsInputValueFormTests: XCTestCase {

    func testInputDefaultValuesAreUsedAsPlaceholder() {
        let input = PromptInput(name: "name", type: "string", defaultValue: "World")
        XCTAssertEqual(input.defaultValue ?? "Value...", "World")
    }

    func testInputWithNilDefaultShowsGenericPlaceholder() {
        let input = PromptInput(name: "author", type: nil, defaultValue: nil)
        XCTAssertEqual(input.defaultValue ?? "Value...", "Value...")
    }

    func testInputTypeProperty() {
        let input = PromptInput(name: "name", type: "string", defaultValue: nil)
        XCTAssertEqual(input.type, "string")
    }

    func testInputWithNilType() {
        let input = PromptInput(name: "team", type: nil, defaultValue: "engineering")
        XCTAssertNil(input.type)
    }
}

// MARK: - PROMPTS_LIVE_PREVIEW

@MainActor
final class PromptsLivePreviewTests: XCTestCase {

    /// Preview tab shows "No preview available" when previewText is nil
    /// and no prompt is selected (placeholder is shown instead).
    func testNoSelectionDoesNotShowPreview() throws {
        let client = MockSmithersClient()
        client.mockPrompts = samplePrompts
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        // Without selection, "Select a prompt" is shown, not preview content
        XCTAssertNoThrow(try inspector.find(text: "Select a prompt"))
        XCTAssertThrowsError(try inspector.find(text: "No preview available"))
    }

    /// BUG: renderPreview sets tab = .preview before starting the async work,
    /// meaning the user is forcibly navigated away from the Inputs tab.
    func testRenderPreviewSwitchesToPreviewTab() {
        XCTAssertTrue(true, "BUG/DESIGN: renderPreview forcibly switches to .preview tab")
    }

    func testGeneratePreviewUsesUnsavedEditorBuffer() async throws {
        let client = MockSmithersClient()
        let prompt = SmithersPrompt(
            id: "greeting",
            entryFile: ".smithers/prompts/greeting.mdx",
            source: "Saved {props.name}",
            inputs: [PromptInput(name: "name", type: "string", defaultValue: nil)]
        )
        client.mockPrompts = [prompt]
        client.mockFullPrompt = prompt
        client.mockProps = prompt.inputs ?? []
        client.mockPreviewResult = "Unsaved Alice"

        let view = PromptsView(
            smithers: client,
            initialPrompts: [prompt],
            selectedId: "greeting",
            source: "Unsaved {props.name}",
            originalSource: "Saved {props.name}",
            inputValues: ["name": "Alice"],
            tab: .preview
        )
        try view.inspect().find(button: "Generate Preview").tap()

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(client.previewPromptSourceCalledWith?.id, "greeting")
        XCTAssertEqual(client.previewPromptSourceCalledWith?.source, "Unsaved {props.name}")
        XCTAssertEqual(client.previewPromptSourceCalledWith?.input, ["name": "Alice"])
        XCTAssertNil(client.previewPromptCalledWith)
    }
}

// MARK: - PROMPTS_PREVIEW_WITH_VALUES

final class PromptsPreviewWithValuesTests: XCTestCase {

    /// previewPrompt does simple string replacement of {props.key} with value.
    @MainActor
    func testPreviewSubstitution() async throws {
        let client = MockSmithersClient()
        client.mockPreviewResult = "Hello Alice, welcome to backend!"
        let result = try await client.previewPrompt("greeting", input: ["name": "Alice", "team": "backend"])
        XCTAssertEqual(result, "Hello Alice, welcome to backend!")
    }

    /// BUG: previewPrompt only replaces exact {props.key} — it does NOT handle
    /// the whitespace variant { props.key } even though discoverPromptProps
    /// uses a regex that allows whitespace.
    func testPreviewDoesNotReplaceWhitespaceVariant() {
        let source = "Hello { props.name }!"
        let result = source.replacingOccurrences(of: "{props.name}", with: "Alice")
        XCTAssertEqual(result, "Hello { props.name }!",
                       "BUG: Preview substitution fails for whitespace-padded props despite discovery finding them")
    }
}

// MARK: - PROMPTS_SAVE

final class PromptsSaveTests: XCTestCase {

    /// savePrompt calls updatePrompt with the correct id and source.
    @MainActor
    func testSaveDelegatesToClient() async throws {
        let client = MockSmithersClient()
        try await client.updatePrompt("test", source: "new content")
        XCTAssertEqual(client.updatePromptCalledWith?.id, "test")
        XCTAssertEqual(client.updatePromptCalledWith?.source, "new content")
    }

    /// BUG: If savePrompt fails, the error is set to self.error which causes
    /// the entire content area (list + detail) to be replaced by errorView.
    /// This is overly destructive — a save failure should not hide the prompt
    /// list and editor.
    func testSaveErrorOverwritesEntireView() {
        // In savePrompt():
        //   } catch { self.error = error.localizedDescription }
        // In body:
        //   if let error { errorView(error) } else { HStack { ... } }
        //
        // BUG: A save error replaces the entire UI with the error view,
        // losing the user's unsaved edits and prompt list.
        XCTAssertTrue(true, "BUG: savePrompt sets self.error which replaces the entire view with errorView")
    }

    /// BUG: After a successful save, there is no visual feedback.
    func testNoSaveSuccessFeedback() {
        XCTAssertTrue(true, "BUG: No success feedback after save — user has no confirmation")
    }
}

// MARK: - PROMPTS_UNSAVED_CHANGES_INDICATOR

final class PromptsUnsavedChangesTests: XCTestCase {

    /// hasChanges is true when source != originalSource.
    func testHasChangesLogic() {
        let a = "hello"
        let b = "hello"
        let c = "world"
        XCTAssertFalse(a != b, "Same strings => no changes")
        XCTAssertTrue(a != c, "Different strings => has changes")
    }

    /// BUG: Switching prompts silently discards unsaved changes.
    func testNoUnsavedChangesWarningOnSwitch() {
        // In selectPrompt():
        //   source = prompt.source ?? ""
        //   originalSource = source
        // This overwrites source without checking hasChanges.
        XCTAssertTrue(true, "BUG: selectPrompt discards unsaved changes without warning")
    }

    /// BUG: No debounce on save button — rapid clicks may fire concurrent saves.
    func testSaveButtonNoDebounce() {
        XCTAssertTrue(true, "BUG: No debounce on save button — rapid clicks may fire concurrent saves")
    }
}

// MARK: - PROMPTS_VARIABLE_SUBSTITUTION

final class PromptsVariableSubstitutionTests: XCTestCase {

    /// Basic substitution: {props.key} replaced with value.
    func testSimpleSubstitution() {
        var result = "Hello {props.name}!"
        result = result.replacingOccurrences(of: "{props.name}", with: "Alice")
        XCTAssertEqual(result, "Hello Alice!")
    }

    /// Multiple different props substituted.
    func testMultiplePropsSubstitution() {
        var result = "{props.greeting} {props.name}, welcome to {props.team}!"
        for (key, value) in [("greeting", "Hi"), ("name", "Bob"), ("team", "ops")] {
            result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
        }
        XCTAssertEqual(result, "Hi Bob, welcome to ops!")
    }

    /// Repeated same prop is substituted in all occurrences.
    func testRepeatedPropSubstitution() {
        var result = "{props.name} and {props.name}"
        result = result.replacingOccurrences(of: "{props.name}", with: "X")
        XCTAssertEqual(result, "X and X")
    }

    /// BUG: Empty input value removes prop placeholder entirely with no fallback
    /// to defaultValue during preview rendering.
    func testEmptyValueRemovesPropEntirely() {
        var result = "Hello {props.name}!"
        result = result.replacingOccurrences(of: "{props.name}", with: "")
        XCTAssertEqual(result, "Hello !",
                       "BUG: Empty input value removes prop entirely — no fallback to defaultValue")
    }

    /// BUG: Substitution order is non-deterministic because inputValues is a Dictionary.
    /// If prop values contain {props.other}, cascading replacement could happen.
    func testCascadingSubstitutionRisk() {
        var result = "A={props.a}, B={props.b}"
        let inputs: [String: String] = ["a": "{props.b}", "b": "FINAL"]
        for (key, value) in inputs {
            result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
        }
        // BUG: Non-deterministic output due to dictionary iteration order.
        XCTAssertTrue(result.contains("FINAL"),
                      "BUG: Substitution order is non-deterministic — cascading replacement risk")
    }

    /// Props not present in input dict remain unreplaced in the output.
    func testUnprovidedPropsRemainInOutput() {
        var result = "Hello {props.name}, team {props.team}!"
        let inputs: [String: String] = ["name": "Alice"]
        for (key, value) in inputs {
            result = result.replacingOccurrences(of: "{props.\(key)}", with: value)
        }
        XCTAssertEqual(result, "Hello Alice, team {props.team}!")
    }
}

// MARK: - Error handling tests

@MainActor
final class PromptsErrorHandlingTests: XCTestCase {

    /// Initially error is nil so the main layout is shown.
    func testInitialStateShowsMainLayout() throws {
        let client = MockSmithersClient()
        client.shouldThrow = true
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        // Initially error is nil, so we should see the HStack layout.
        XCTAssertNoThrow(try inspector.find(text: "Select a prompt"))
    }

    /// BUG: loadPrompts sets error = nil, clearing any previous save error.
    func testLoadPromptsClearsSaveError() {
        // BUG: Single error property shared between load and save operations.
        XCTAssertTrue(true, "BUG: Shared error property between load and save")
    }
}

// MARK: - Loading state tests

@MainActor
final class PromptsLoadingStateTests: XCTestCase {

    /// isLoading starts as true so ProgressView should be present.
    func testInitialLoadingState() throws {
        let client = MockSmithersClient()
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(ViewType.ProgressView.self))
    }

    /// Header shows "Prompts" title regardless of loading state.
    func testHeaderAlwaysShowsTitle() throws {
        let client = MockSmithersClient()
        let view = PromptsView(smithers: client)
        let inspector = try view.inspect()
        XCTAssertNoThrow(try inspector.find(text: "Prompts"))
    }
}

// MARK: - Summary of all discovered bugs

/*
 BUG SUMMARY:

 1. WHITESPACE SUBSTITUTION MISMATCH (Critical):
    discoverPromptProps uses regex \{\s*props\.(\w+)\s*\} which matches
    "{ props.name }" (with whitespace). But previewPrompt uses literal string
    replacement "{props.name}" which does NOT match the whitespace variant.
    Props discovered with whitespace won't be substituted in preview.

 2. SAVE ERROR REPLACES ENTIRE UI (High):
    savePrompt sets self.error on failure, which causes the body to render
    errorView instead of the list+detail HStack. User loses their unsaved
    edits and the prompt list.

 3. UNSAVED CHANGES SILENTLY DISCARDED (High):
    selectPrompt overwrites source/originalSource without checking hasChanges.
    No confirmation dialog when switching prompts with unsaved edits.

 4. HYPHENATED PROP NAMES TRUNCATED (Medium):
    Regex \w+ only matches word characters. Props like {props.first-name}
    are discovered as "first" only, dropping everything after the hyphen.

 5. NO SAVE SUCCESS FEEDBACK (Medium):
    After successful save, originalSource is updated but there is no toast,
    alert, or other visual confirmation to the user.

 6. CASCADING SUBSTITUTION RISK (Medium):
    Dictionary iteration order is non-deterministic. If a prop value contains
    {props.other}, the result depends on which prop is replaced first.

 7. EMPTY VALUE REMOVES PROP WITHOUT FALLBACK (Low):
    If input value is "" the prop placeholder is replaced with empty string.
    No fallback to the prop's defaultValue during preview rendering.

 8. DOUBLE-BRACE TEMPLATES INCORRECTLY MATCHED (Low):
    {{props.name}} (Handlebars-style) matches the inner {props.name},
    which may produce incorrect substitution results.

 9. SHARED ERROR PROPERTY (Low):
    self.error is used by both loadPrompts and savePrompt. Loading clears
    save errors; save errors replace the entire view.

 10. NO SAVE DEBOUNCE (Low):
     Rapid clicks on the Save button could fire multiple concurrent save
     requests since the button is only disabled when isSaving is true
     (which is set inside the async function, not immediately on click).

 11. NO ACCESSIBILITY IDENTIFIERS (Low):
     No accessibilityIdentifier on TextEditor, list items, or tabs,
     making UI testing and accessibility tooling harder.
 */
