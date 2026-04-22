# Chat And Codex Review

Review scope: `CHAT_AND_CODEX` feature group, focused on `ChatView.swift`, `LiveRunView.swift`, `AgentService.swift`, `Tests/SmithersGUITests/ChatViewTests.swift`, and `Tests/SmithersGUITests/LiveRunViewTests.swift`.

Requested features reviewed: `CHAT_MESSAGE_INPUT`, `CHAT_MESSAGE_DISPLAY`, `CHAT_MESSAGE_TYPES`, `CHAT_MULTI_LINE_INPUT`, `CHAT_AUTO_SCROLL`, `CHAT_THINKING_INDICATOR`, `CHAT_WELCOME_EMPTY_STATE`, `CHAT_SEND_STOP_TOGGLE`, `CHAT_BUBBLE_RENDERING`, `CHAT_COMPOSER_TOOLBAR`, `CHAT_PAPERCLIP_ATTACHMENT`, `CHAT_FILE_MENTION`, `CHAT_SLASH_TRIGGER`, `CHAT_KEYBOARD_SHORTCUTS`, `CHAT_COMMAND_OUTPUT`, `CHAT_STREAMING`, `CHAT_GIT_DIFF`, `CHAT_CODEX_COMMANDS`, `CHAT_SLASH_INTEGRATIONS`, and `CHAT_STUB_STATUS_MESSAGES`.

## Findings

### High: Chat auto-scroll does not follow streaming updates

`ChatView.swift:329` only scrolls on `agent.messages.count` changes. Several core streaming paths update an existing message in place without changing the count:

- `AgentService.swift:586` replaces the last assistant message as partial text grows.
- `AgentService.swift:649` replaces an existing command message for the same Codex item.
- `AgentService.swift:688` replaces an existing status/tool message for the same Codex item.
- `AgentService.swift:815` replaces an existing thinking message.

That means `CHAT_AUTO_SCROLL`, `CHAT_STREAMING`, `CHAT_COMMAND_OUTPUT`, and `CHAT_THINKING_INDICATOR` can update below the fold without scrolling after the first row is created.

Recommendation: publish a monotonic transcript update token from `AgentService`, or derive a lightweight scroll key from the last visible message id/content/status and observe that instead of only `messages.count`. Add a regression test around an in-place assistant or command update, not just appending a new message.

### High: Pasted image attachments are not actually delivered to Codex

Image paste creates an in-memory generated attachment at `ChatView.swift:1450` through `ChatView.swift:1456`, and `addGeneratedAttachment` stores the bytes only in `ChatComposerAttachment.content` at `ChatView.swift:1418` through `ChatView.swift:1444`. When sending, `composePrompt` emits only a local image path marker at `ChatView.swift:1552` through `ChatView.swift:1559`.

For generated paste images, that path is a synthetic name like `paste_1.png`; no file is written and no image bytes are embedded in the prompt. The agent gets a reference to a file that does not exist.

Recommendation: either persist pasted images into a temporary attachment directory and send that real path, or use a Codex bridge API that can pass image bytes. Until then, disable image paste or show a status explaining that pasted images are unsupported.

### High: Live run streaming can drop events during initial load

`LiveRunView.loadBlocks()` starts streaming before loading the initial snapshot at `LiveRunView.swift:587` through `LiveRunView.swift:591`. If SSE events arrive before `getChatOutput` returns, `appendStreamBlock` adds them to `allBlocks`; then `rebuildAttempts(with:)` replaces `allBlocks` with the snapshot at `LiveRunView.swift:674` through `LiveRunView.swift:675`.

Any streamed block not yet present in the snapshot is lost. This directly affects `CHAT_STREAMING`, `CHAT_COMMAND_OUTPUT`, and live run reliability.

Recommendation: load the snapshot first, then start streaming from a cursor if available. If streaming must start early, keep streamed blocks in a side buffer and merge them with the snapshot by lifecycle id instead of replacing `allBlocks`.

### Medium: Chat diff rendering exists but `/diff` only emits plain status text

`MessageRow` has a dedicated `.diff` rendering branch at `ChatView.swift:2725` through `ChatView.swift:2755`, but `/diff` clears the input and calls `showGitDiff()` at `ChatView.swift:1024` through `ChatView.swift:1026`. `showGitDiff()` appends the result as a status message at `ChatView.swift:1098` through `ChatView.swift:1104`.

So `CHAT_GIT_DIFF` is implemented as monospaced status text, not as the structured diff bubble that the view already supports. The tests manually construct `.diff` messages, but no reviewed production path creates them.

Recommendation: make `LocalGitDiff` return a structured `Diff` or introduce a `ChatMessage.diff` append path. If plain status is intentional, remove or de-emphasize the unused `.diff` branch and update the tests to match product behavior.

### Medium: MessageRow and its test disagree on assistant messages that carry commands

`MessageRow` handles `.assistant` before checking `.command` at `ChatView.swift:2714` through `ChatView.swift:2720`, so an assistant message with a non-nil `command` renders only the assistant bubble. `ChatViewTests.swift:1167` through `ChatViewTests.swift:1186` expects the command block to render for exactly that shape.

The model currently allows this inconsistent state, and the test appears to assert behavior the production view does not have.

Recommendation: decide the invariant. If commands must always be `type == .command`, enforce that through construction and remove the test. If assistant messages can carry command payloads, change `MessageRow` to render attached command content.

### Medium: File mention suggestions include directories that cannot be attached

Mention indexing appends directory candidates with a trailing slash at `ChatView.swift:1693`. Selecting any mention calls `attachMentionCompletion` at `ChatView.swift:1282`, which calls `addAttachment`; directories are rejected with a status message at `ChatView.swift:1380` through `ChatView.swift:1382`.

This makes a selectable completion produce an error and close the palette. It also prevents a normal folder drill-down interaction because selecting `folder/` inserts a trailing space and ends the active mention.

Recommendation: either exclude directories from selectable mention results, or treat directory selection as navigation/filtering by inserting `folder/` without a trailing space and without attempting attachment.

### Medium: Unknown command exit status is rendered as success

`updateOrAppendCommandMessage` defaults missing exit codes to `0` at `AgentService.swift:627` through `AgentService.swift:633`. `toolExecutionStatus` also treats `item.completed` with no exit code as success at `AgentService.swift:1056` through `AgentService.swift:1060`.

If Codex emits a completed command item without an exit code, the UI shows a successful `exit 0` badge even though the exit status is unknown.

Recommendation: make `Command.exitCode` optional or add an `.unknown` status. Render "completed" separately from "exit 0" unless the bridge actually provides `exit_code: 0`.

### Medium (historical, obsolete after 65255682): FFI callback lifetime depends on a synchronous C contract

This finding applied to the deleted `AgentService` + `CodexBridge` path
(`codex_send` callback ownership and `codex_cancel` concurrency). Those files
were removed in commit `65255682` during the libsmithers cutover, so this is
not actionable in the current tree.

If Codex streaming is reintroduced through a new Zig/FFI bridge, re-run this
review against the new callback lifetime and send/cancel thread-safety
contract.

### Low: Send button can be enabled when there is nothing to send

`sendActionAllowed` returns `chatReady` for non-slash idle input at `ChatView.swift:198` through `ChatView.swift:209`. It does not check whether the trimmed input or attachments are non-empty, so the idle send button can be enabled even though `send()` later returns without sending at `ChatView.swift:910` through `ChatView.swift:912`.

Recommendation: include `!trimmed.isEmpty || !composerAttachments.isEmpty` in the idle send enabled state.

### Low: Several chat target launch states and helpers are dead code

`launchingTargetID` and `targetLaunchStatus` are declared at `ChatView.swift:139` through `ChatView.swift:141`; the picker renders them at `ChatView.swift:768` and `ChatView.swift:806`, but they are never set. `ExternalChatLauncher` at `ChatView.swift:2552` through `ChatView.swift:2585` is also unused because external chat now navigates through `.terminalCommand`.

Recommendation: remove the dead state/helper, or wire it back into an async launch path. Keeping unused launch states makes it harder to tell whether the target picker is supposed to navigate immediately or show progress.

## Coverage Review

The reviewed tests cover a useful set of static rendering checks: welcome copy, message text, toolbar icons, command output, slash registry parsing, basic diff row rendering, and many live-run pure logic cases. The main risk is that the most important behaviors are either not exercised or are tested through duplicated/source-inspection logic.

Specific gaps:

- `CHAT_MESSAGE_INPUT` and `CHAT_SEND_STOP_TOGGLE`: `ChatViewTests.swift:692` through `ChatViewTests.swift:708` instantiate `ChatView` but never drive `inputText`, Return, the send button, or `onSendRequest`. It calls `AgentService.sendMessage` directly and then asserts the view callback was not called, so it does not cover ChatView send behavior.
- `CHAT_KEYBOARD_SHORTCUTS` and `CHAT_MULTI_LINE_INPUT`: tests only verify that a `TextField` exists at `ChatViewTests.swift:780` through `ChatViewTests.swift:789`. They do not exercise Return-to-send, Shift+Return newline insertion, arrow navigation, Tab completion, Escape dismissal, or disabled send behavior.
- `CHAT_AUTO_SCROLL`: `ChatViewTests.swift:753` through `ChatViewTests.swift:773` only checks that inspection does not crash and that appending a status increments count. It misses in-place streaming updates, which is where the implementation currently has a bug.
- `CHAT_PAPERCLIP_ATTACHMENT` and `CHAT_FILE_MENTION`: `ChatViewTests.swift:1189` through `ChatViewTests.swift:1221` use source-string checks for wiring. They do not validate prompt composition, duplicate attachment handling, file size rejection, directory rejection, relative paths, pasted large text, pasted images, MIME detection, model capability filtering, or mention candidate ranking.
- `CHAT_SLASH_TRIGGER`, `CHAT_CODEX_COMMANDS`, and `CHAT_SLASH_INTEGRATIONS`: registry parsing is covered, but ChatView execution is not. There are no behavior tests for `/new`, `/init`, `/review`, `/compact`, `/diff`, `/status`, `/model`, `/approvals`, `/mcp`, `/logout`, workflow commands, prompt commands, or auth-gated command sending.
- `CHAT_MESSAGE_TYPES`: the tests cover user, assistant, status, command, and manually constructed diff messages. They do not cover `ToolMessagePayload` rendering, assistant thinking metadata, assistant error metadata, details expansion, copied text, or compact tool messages.
- `CHAT_STREAMING`: `LiveRunViewTests.swift:74` through `LiveRunViewTests.swift:292` duplicate the view logic in `LiveRunChatLogic` instead of exercising production methods. `LiveRunViewTests.swift:717` through `LiveRunViewTests.swift:734` also duplicates `decodeStreamEvent`. These tests can pass while production logic drifts.
- `LiveRunView` UI behavior is largely untested: no fake `SmithersClient` drives `loadAll`, stream events, stream cancellation, refresh errors, attempt buttons, follow toggling, context pane, hijack banners, or row rendering through the actual view.
- `CHAT_STUB_STATUS_MESSAGES`: stubs such as `/feedback` and auth/target status messages are not covered as user-visible product decisions. Tests should lock down which stub messages are temporary and which are intended UX.

## Code Quality And Visibility

- `ChatView.swift` is doing too much: target selection, auth onboarding, model/approval sheets, composer state, paste handling, file indexing, slash command execution, local git diff shelling, and message rendering all live in one file. The private helpers make direct testing hard, which is why the tests fall back to source inspection.
- Good extraction candidates are a `ChatComposerModel` or `ChatPromptComposer`, a `FileMentionIndex`, a `LocalGitDiffProvider`, and a `ChatTranscriptView`. Those would allow real unit tests without widening all SwiftUI internals.
- Internal visibility is broader than necessary for production. `SlashCommandPalette`, `MessageRow`, `CommandBlock`, `RoundedCorner`, `RectCorner`, `ChatTargetKind`, `ChatTargetOption`, `buildChatTargets`, and `chatTargetStatusLabel` are all module-internal. Some of this is useful for `@testable` tests, but the current shape exposes implementation details because tests need them. Prefer extracting pure internal helpers that are intentionally testable and making rendering-only helpers `private` where practical.
- `AgentService` should likely be `final`. It is `@MainActor` and owns bridge lifecycle state; subclassing would make those invariants harder to reason about.
- `LiveRunViewTests` are a sign that important production logic wants to be a real model. Move attempt indexing, stream merging, and event decoding into an internal `LiveRunChatModel` or reducer and have the view bind to it.
- Source-string tests in `ChatViewTests.swift:560` through `ChatViewTests.swift:580` and `ChatViewTests.swift:1189` through `ChatViewTests.swift:1221` are brittle. They are useful as temporary guardrails, but they should not be the primary coverage for user-facing behavior.

## Feature Coverage Summary

- Implemented visibly: message input, message display, basic message types, multi-line text field, thinking indicator, welcome empty state, send/stop icon toggle, bubble rendering, composer toolbar, slash palette, command output blocks, live-run transcript streaming, model/approval/MCP command surfaces, and basic status messages.
- Partially implemented or risky: auto-scroll for in-place streaming updates, generated image attachments, file mention directory behavior, `/diff` structured rendering, slash command execution tests, auth-gated send behavior, external target picker progress state, and live-run initial stream/snapshot merging.
- Under-tested: keyboard shortcuts, attachment prompt semantics, mention completion, actual ChatView send callback path, actual LiveRunView async load/stream lifecycle, tool/thinking/error rendering, and Codex bridge lifecycle edge cases.

## Verification

Per request, `swift test` was not run. Review used source inspection only (`rg`, `nl`, `sed`, `wc`, and `git status`).
