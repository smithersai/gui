# Slash Commands Review

Review scope: `SLASH_COMMANDS` and `SLASH_COMMAND_SYSTEM`, focused on `SlashCommands.swift`, `Tests/SmithersGUITests/SlashCommandsTests.swift`, and `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift`. I also checked `ChatView.swift` where needed to evaluate command routing and dynamic command execution, and `docs/smithers-gui/features.ts` to compare the feature groups with the registry.

`swift test` was not run.

## Findings

### Medium: Feature group inventory is out of sync with the command registry

`docs/smithers-gui/features.ts:1018` to `docs/smithers-gui/features.ts:1046` lists the commands covered by `SLASH_COMMANDS`, but the registry includes additional built-in commands that are not represented in that feature group: `/agents`, `/changes`, `/triggers`, `/jjhub-workflows`, `/sql`, `/tickets`, and `/debug` in `SlashCommands.swift:247`, `SlashCommands.swift:256`, `SlashCommands.swift:283`, `SlashCommands.swift:292`, `SlashCommands.swift:346`, `SlashCommands.swift:364`, and `SlashCommands.swift:409`.

The tests know about several of these untracked commands. For example, `Tests/SmithersGUITests/SlashCommandsTests.swift:101`, `Tests/SmithersGUITests/SlashCommandsTests.swift:107`, `Tests/SmithersGUITests/SlashCommandsTests.swift:125`, `Tests/SmithersGUITests/SlashCommandsTests.swift:131`, `Tests/SmithersGUITests/SlashCommandsTests.swift:167`, `Tests/SmithersGUITests/SlashCommandsTests.swift:179`, and `Tests/SmithersGUITests/SlashCommandsTests.swift:267` assert them. The action category also has `/debug`, while the feature enum only calls out clear/help at `docs/smithers-gui/features.ts:237` to `docs/smithers-gui/features.ts:239`.

Impact: feature coverage can look complete while several shipped commands are not tracked by the feature map. Future reviewers may miss regressions because the feature group does not describe the actual command surface.

Recommendation: either add feature IDs for the missing commands or remove them from the registry if they are not product-supported. Add a single inventory test that derives expected built-ins from a maintained feature-command table instead of duplicating command existence checks by hand.

### Medium: Key-value parsing breaks common quoted input cases for dynamic commands

`SlashCommandRegistry.keyValueArgs` tokenizes through `quoteAwareTokens` at `SlashCommands.swift:513`, then strips quote characters at `SlashCommands.swift:516`. The tokenizer only treats double quotes as grouping syntax (`SlashCommands.swift:522` to `SlashCommands.swift:545`), so single-quoted values with spaces are split incorrectly. For example, `title='release notes'` becomes `title=release` and drops `notes'`.

This is not just parser polish. `ChatView.swift:1066` passes parsed key-value args into workflow runs, and `ChatView.swift:1087` passes them into prompt rendering. Workflow and prompt inputs commonly need values with spaces.

The current tests cover quote stripping only for values without spaces, such as `Tests/SmithersGUITests/SlashCommandsTests.swift:671` to `Tests/SmithersGUITests/SlashCommandsTests.swift:675` and `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:176` to `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:180`. They do not cover single-quoted spans, escaped quotes, empty quoted values, or malformed quotes.

Recommendation: either document that only double quotes group values, or replace the tokenizer with a small shell-style lexer that supports single quotes, double quotes, and escapes. Add tests for `name="release notes"`, `name='release notes'`, `name=""`, `path="a \"quoted\" value"`, duplicate keys, and malformed input.

### Medium: Dynamic command names and aliases are raw IDs with no conflict handling

Dynamic workflow and prompt commands are generated directly from IDs at `SlashCommands.swift:439` to `SlashCommands.swift:463`. The command name is `workflow:<id>` or `prompt:<id>`, and the bare ID is also registered as an alias. There is no validation, slugging, duplicate detection, or conflict policy.

That creates several edge cases:

- IDs containing whitespace produce command names that cannot be exact-matched as a single command name because `parse` splits at the first whitespace at `SlashCommands.swift:476`.
- Duplicate workflow/prompt IDs produce duplicate `SlashCommandItem.id` values, which can destabilize the SwiftUI palette `ForEach` keyed by item ID at `ChatView.swift:1924`.
- Bare aliases can conflict with built-ins. `exactMatch` checks aliases at `SlashCommands.swift:502` to `SlashCommands.swift:507`, after sorting by score/category/name at `SlashCommands.swift:489` to `SlashCommands.swift:499`, so a dynamic ID like `permissions`, `review`, `tickets`, or `status` may be shadowed by a built-in command or alias. The prefixed form still works, but the bare alias behavior is ambiguous.

The dynamic command tests only cover simple happy-path IDs like `deploy`, `test`, `greet`, and `p1` in `Tests/SmithersGUITests/SlashCommandsTests.swift:295` to `Tests/SmithersGUITests/SlashCommandsTests.swift:318` and `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:226` to `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:246`.

Recommendation: define a command-ID contract. Either reject/hide non-command-safe IDs, slug them, or require only the prefixed form for dynamic commands. Add conflict tests for dynamic IDs that match built-in names and aliases, duplicate dynamic IDs, empty IDs, and IDs with whitespace.

### Medium: The feature says fuzzy matching, but implementation is substring filtering

`SlashCommandItem.matches` lowercases the query and checks `contains` against name, title, description, and aliases at `SlashCommands.swift:48` to `SlashCommands.swift:54`. `score(for:)` then ranks exact, alias, prefix, title prefix, and everything else through coarse numeric buckets at `SlashCommands.swift:56` to `SlashCommands.swift:66`.

That supports case-insensitive substring search, not fuzzy matching in the usual sense. It does not handle typos, subsequences, token initials, or generalized separator normalization. If `SLASH_COMMAND_FUZZY_MATCHING` is meant literally, inputs like `mdl` for `/model` or `cwflow` for `/codex-approvals` will not match.

The tests encode the current substring behavior rather than the feature name. Examples include `Tests/SmithersGUITests/SlashCommandsTests.swift:322` to `Tests/SmithersGUITests/SlashCommandsTests.swift:356` and `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:17` to `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:44`.

Recommendation: either rename the feature/expectation to substring filtering, or implement a real fuzzy scorer with explicit ranking rules. If real fuzzy matching is intended, add tests for subsequence matches, typo rejection thresholds, separator-insensitive matching, and deterministic ordering among equal fuzzy scores.

### Medium: Command routing side effects are mostly untested

The actual routing switch lives in `ChatView.executeSlashCommand` at `ChatView.swift:969` to `ChatView.swift:1002`, with Codex command effects at `ChatView.swift:1005` to `ChatView.swift:1055`, workflow execution at `ChatView.swift:1058` to `ChatView.swift:1077`, and prompt rendering at `ChatView.swift:1079` to `ChatView.swift:1095`.

The specified tests mainly assert that the enum payloads are present. For example, `Tests/SmithersGUITests/SlashCommandsTests.swift:608` to `Tests/SmithersGUITests/SlashCommandsTests.swift:660` verifies action cases, but not that they invoke the right callbacks, sheets, status messages, Smithers calls, prompt dispatch, or navigation destinations. `SlashCommandsAdditionalTests.swift` does not add routing coverage.

Impact: regressions in `/new`, `/model`, `/codex-approvals`, `/mcp`, `/logout`, `/diff`, `/mention`, dynamic workflow runs, dynamic prompt rendering, and navigation commands can pass these registry tests as long as the enum case remains unchanged.

Recommendation: extract the slash command executor into a small testable coordinator, or inject effect closures into `ChatView` and test the side effects. Cover at least navigation callback routing, model/approval/MCP sheet toggles, `/review` args, `/init` prompt dispatch, Smithers unavailable fallbacks, workflow success/failure, prompt render success/failure, and the developer-debug gate.

### Low: Ranking and category tests do not fully prove the ordering contract

`Tests/SmithersGUITests/SlashCommandsTests.swift:421` to `Tests/SmithersGUITests/SlashCommandsTests.swift:439` says it verifies category ranking, but it only checks that there is at least one category transition, the first result is Codex, and the last result is Action. It would still pass if categories were interleaved in the middle.

The count assertions at `Tests/SmithersGUITests/SlashCommandsTests.swift:280` to `Tests/SmithersGUITests/SlashCommandsTests.swift:292` also make ordinary command additions break category tests, while not explaining whether the count itself is a product requirement. `SlashCommandsAdditionalTests.swift` duplicates much of the same parse/match/score/help coverage, such as `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:49`, `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:94`, and `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:202`, without adding many new edge cases.

There are also a few misleading test comments. `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:69` to `Tests/SmithersGUITests/SlashCommandsAdditionalTests.swift:72` says `witch` matches the description, but it actually matches the title `Switch Model`.

Recommendation: replace broad count tests with table-driven inventory tests. For ranking, assert monotonic category rank across the entire result list and add focused tie-breaker cases for score, category, and name ordering. Deduplicate the additional tests or turn them into edge-case coverage.

## Coverage Notes

Strong existing coverage:

- Built-in command presence, IDs, categories, aliases, and a few action payloads are covered in `SlashCommandsTests.swift`.
- Parsing basics, exact match basics, help text generation, display names, and key-value basics are covered.
- Dynamic workflow and prompt command generation have simple happy-path tests.

Important gaps:

- No direct tests for route execution side effects in `ChatView`.
- No conflict tests between built-in names, built-in aliases, dynamic command names, and dynamic aliases.
- No dynamic command tests for unsafe IDs, duplicate IDs, or missing/empty IDs.
- No real fuzzy matching tests beyond substring matching.
- No tests for ranking across all categories once workflow and prompt commands are present.
- No tests for quoted args with spaces except double-quoted happy paths, and no escaped quote tests.
- No tests that `helpText` behaves safely with dynamic commands containing unusual names/descriptions.

## Code Quality Notes

- `SlashCommandRegistry.builtInCommands` is a computed property at `SlashCommands.swift:118`, so every access rebuilds the same command array. This is not a major performance issue at the current size, but `static let` would make the registry identity clearer.
- Matching and scoring each repeat lowercasing of names, aliases, title, and description. If fuzzy behavior grows, introduce a normalized searchable representation to keep ranking rules consistent.
- Magic scores (`0`, `1`, `10`, `20`, `30`, `50`, `100`) are readable in the tests but not self-documenting in the implementation. Named constants or a small `MatchRank` enum would make future ranking changes less brittle.
- `categoryRank` is private and tested indirectly. That is fine, but the indirect tests should be stronger if category ordering is a feature requirement.

## Verification

Commands run during review were limited to source inspection with `rg`, `nl`, and `sed`. Per request, `swift test` was not run.
