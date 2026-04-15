# Add Universal Command Palette and Power-User Keyboard Shortcuts

## Problem

Smithers GUI has useful app surfaces, chat slash commands, terminal tabs, workflow
runs, issues, prompts, and search, but keyboard-driven navigation is still thin.
Power users should be able to drive the app like VS Code, Linear, and tmux:
open anything, run commands, switch tabs, open terminals, and ask the main AI
without reaching for the mouse.

The user specifically asked for:

- `Cmd+P` behavior similar to VS Code.
- `>` inside the palette to search common commands.
- No prefix to search files/open things.
- A way to ask the main AI a question directly from the launcher.
- Common tmux-like sequences for tab switching and creating a new terminal tab.
- A broader shortcut system that makes the app feel like a power-user tool.

## Current State

- `ContentView.swift` owns root navigation and currently registers hidden
  shortcut buttons for:
  - `Cmd+N` new chat.
  - `Cmd+Shift+D` developer debug toggle when debug mode is enabled.
- `SidebarView.swift` defines `NavDestination`, sidebar routes, session/run/
  terminal tab selection, and actions for starting a new chat or terminal.
- `SessionStore.swift` owns:
  - Chat sessions: `newSession`, `ensureActiveSession`, `selectSession`,
    `sendMessage`.
  - Run tabs: `addRunTab`.
  - Terminal tabs: `addTerminalTab`, `ensureTerminalTab`, `removeTerminalTab`.
  - `sidebarTabs(matching:)`, which already unifies chat/run/terminal tab search.
- `SlashCommands.swift` already has a good command registry and executor for
  Codex, Smithers navigation, workflow commands, prompt commands, and actions.
  Reuse this instead of creating a separate hard-coded command list.
- `ChatView.swift` already supports inline slash command completion and dispatch.
- `TerminalView.swift` embeds Ghostty and forwards keyboard input. It has
  `TerminalKeyForwardingPolicy` and raw terminal event forwarding, so app-level
  tmux shortcuts must avoid breaking real terminal use by default.

## Proposed Product Design

Add a root-level Universal Launcher presented by `Cmd+P`.

Launcher modes:

- No prefix: open anything. Search open tabs first, then files, sessions, runs,
  issues/tickets, workflows, prompts, and app destinations.
- `>`: command mode. Search app commands and route actions, matching VS Code.
- `?`: ask AI mode. Submit the query to the active main chat session. If no
  chat session exists, create one.
- `@`: file/mention mode. Search files and expose file references. Depending on
  context, either open the file-related result or insert a file mention into chat.
- `/`: slash command mode. Reuse `SlashCommandRegistry` results.
- `#`: work-item mode. Search issues, tickets, runs, approvals, and landings.

Shortcut entry points:

- `Cmd+P`: open launcher empty.
- `Cmd+Shift+P`: open launcher prefilled with `>`.
- `Cmd+K`: open launcher prefilled with `?`.

No-prefix ranking should prioritize currently useful local context:

1. Open tabs from `store.sidebarTabs(matching:)`.
2. Files from the current workspace.
3. Active/running runs and pending approvals.
4. Recent chats/sessions.
5. Workflows and prompts.
6. App destinations.
7. "Ask AI: <query>" fallback when there is no strong match.

## Keyboard Shortcuts to Add

Global shortcuts:

- `Cmd+P`: Open Anything launcher.
- `Cmd+Shift+P`: Command Palette (`>` mode).
- `Cmd+K`: Ask AI (`?` mode).
- `Cmd+T`: New terminal tab; terminal should be the active destination.
- `Cmd+N`: New chat; preserve existing behavior.
- `Cmd+W`: Close current app tab/session/terminal when applicable. Do not quit
  the app. If the focused terminal wants raw `Cmd+W`, preserve terminal behavior
  unless app-level close is clearly active.
- `Cmd+Shift+T`: Reopen most recently closed app tab if a closed-tab stack is
  implemented. If this is too large for the first pass, include the palette
  command but mark it unavailable.
- `Cmd+1` through `Cmd+9`: Switch to nth visible sidebar tab.
- `Cmd+Shift+[` and `Cmd+Shift+]`: Previous/next visible sidebar tab.
- `Cmd+[` and `Cmd+]`: Back/forward navigation history if history is added.
  If history is too large for the first pass, leave this out rather than adding
  broken shortcuts.
- `Cmd+F`: Search current view if the current view exposes search; otherwise
  open launcher scoped to current view.
- `Cmd+Shift+F`: Global search route.
- `Cmd+R`: Refresh current view when the view supports refresh.
- `Cmd+.`: Cancel/stop current running chat agent or active run action when
  available.
- `Cmd+/`: Shortcut cheat sheet.

Linear-style navigation chords:

- `g h`: Dashboard.
- `g c`: Chat.
- `g t`: Terminal.
- `g r`: Runs.
- `g w`: Workflows.
- `g a`: Approvals.
- `g i`: Issues.
- `g s`: Search.
- `g l`: Logs.
- `g m`: Memory.

These chords should only fire when focus is not inside a text input and not
inside the terminal's raw keyboard input path.

List/detail shortcuts:

- `j` / `k`: move selection in list-heavy views that have a selected row model.
- `Enter`: open selected item.
- `Esc`: dismiss modal/palette, go back, or clear local selection.
- `r`: refresh the current list.
- `e`: edit/rename selected item where supported.
- `p`: pin/unpin selected chat session where supported.
- In approval queues: consider `a` approve and `d` deny, but only with clear
  focus and confirmation rules for destructive actions.

## Tmux-Style Shortcut Support

Support tmux-like app sequences outside terminal raw input:

- `Ctrl+B c`: create a new terminal tab and switch to it.
- `Ctrl+B n`: next app tab.
- `Ctrl+B p`: previous app tab.
- `Ctrl+B 0` through `Ctrl+B 9`: switch to numbered app tab.
- `Ctrl+B w`: open tab switcher/launcher scoped to tabs.
- `Ctrl+B ,`: rename current chat session or terminal tab when supported.
- `Ctrl+B &`: close current app tab, with confirmation when needed.
- `Ctrl+B f`: find tab.

Important terminal rule:

Do not steal `Ctrl+B` from an active terminal by default. Users may be running
real tmux, vim, fzf, or shell applications that need raw control keys.

Suggested behavior:

- App-level tmux sequences work globally when focus is outside terminal input.
- Add a setting later for "Capture tmux-style shortcuts in terminal".
- If terminal capture is enabled, `Ctrl+B Ctrl+B` should pass a literal prefix
  through to the terminal.
- For the initial implementation, document this behavior in code/tests and keep
  terminal raw input safe.

## Suggested Architecture

Introduce a command/action model that backs both the launcher and shortcut
dispatch. Every keyboard shortcut should map to an action that can also appear
in the launcher, so shortcuts remain discoverable.

Suggested model:

```swift
struct CommandPaletteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let section: String
    let keywords: [String]
    let shortcut: String?
    let action: CommandPaletteAction
    let isEnabled: Bool
}
```

Suggested action enum:

```swift
enum CommandPaletteAction: Hashable {
    case navigate(NavDestination)
    case selectSidebarTab(String)
    case newChat
    case newTerminal
    case closeCurrentTab
    case askAI(String)
    case slashCommand(String)
    case openFile(String)
    case globalSearch(String)
    case refreshCurrentView
    case cancelCurrentOperation
    case toggleDeveloperDebug
}
```

Suggested providers:

- `TabCommandProvider`: wraps `SessionStore.sidebarTabs(matching:)`.
- `RouteCommandProvider`: wraps static `NavDestination` entries.
- `SlashCommandProvider`: wraps `SlashCommandRegistry.builtInCommands` and
  dynamic workflow/prompt commands.
- `FileCommandProvider`: uses `rg --files` or an existing file-search helper
  if one exists. Exclude `.git`, `.smithers/node_modules`, Xcode derived data,
  build outputs, and nested vendored repos by default.
- `WorkflowPromptCommandProvider`: can be separate or part of slash provider.
- `AICommandProvider`: generates "Ask AI" fallback items.
- `TerminalCommandProvider`: new terminal, close terminal, next/previous tab,
  numbered tab selection.

Suggested views/files:

- Add a new `CommandPaletteView.swift` for the launcher UI.
- Add a new `CommandPalette.swift` or `CommandPaletteModel.swift` for item,
  action, scoring, prefix parsing, and provider composition.
- Add a new `KeyboardShortcutController.swift` if root keyboard dispatch grows
  beyond simple hidden SwiftUI buttons.
- Wire presentation and actions from `ContentView.swift`.
- Keep `SlashCommands.swift` as the source of truth for slash-command metadata.
- Use `SessionStore.swift` for tab/session/terminal mutations.
- Use `SidebarView.swift`'s `NavDestination` instead of duplicating route IDs.

## UI Requirements

- Palette should be a centered overlay or sheet-like panel that is fast to open
  and dismiss.
- It should keep keyboard focus in its search field when opened.
- `Esc` closes the palette.
- `Return` executes the selected item.
- Arrow keys move selection.
- `Tab` may accept/complete the selected mode prefix or selected item text.
- Show shortcut hints on command results where available.
- Results should be grouped by section but still support global ranking.
- Empty state should offer useful fallbacks, especially "Ask AI".
- The palette must not look like a marketing surface; it is a functional tool.

## Implementation Notes

- Root-level shortcuts can start as hidden SwiftUI `Button(...).keyboardShortcut`
  entries in `ContentView.swift`, matching the existing `Cmd+N` pattern. If
  chord handling is awkward in SwiftUI, use an AppKit event monitor carefully.
- Chord handling needs a small timeout window, roughly 1 second, so pressing `g`
  alone does not permanently trap the next key.
- Do not handle plain-key chords while any `TextField`, `TextEditor`, secure
  field, rename alert, sheet input, or terminal surface owns focus.
- `Cmd+T` should call `store.addTerminalTab()` and set
  `destination = .terminal(id: terminalId)`.
- `Cmd+Shift+F` can route to `.search`.
- `Cmd+1` through `Cmd+9` should use the visible tab ordering from
  `store.sidebarTabs(matching: "")`.
- Selecting a chat tab should call `store.selectSession`.
- Selecting a terminal tab should route to `.terminal(id:)`.
- Selecting a run tab should route to `.liveRun(runId:nodeId:nil)`.
- Asking AI should call `store.ensureActiveSession()`, route to `.chat`, and
  call `store.sendMessage(query)` once chat readiness behavior is respected.
  If there are auth/readiness constraints, match the existing `ChatView` behavior
  as closely as possible and surface a status message instead of silently failing.
- For file search, prefer a structured or existing helper if available. If using
  `rg --files`, run it asynchronously and debounce query updates.

## Non-Goals for First Pass

- Fully user-editable keybindings.
- Complete per-view `Cmd+F` implementations across every screen.
- Capturing tmux prefix inside the embedded terminal by default.
- Rebuilding slash command execution logic outside `SlashCommands.swift`.
- Implementing a full file editor. File results can initially copy/insert/open
  references depending on existing app capabilities.

## Files Likely to Change

- `ContentView.swift`
- `SidebarView.swift`
- `SessionStore.swift`
- `SlashCommands.swift`
- `TerminalView.swift`
- `ChatView.swift`
- New `CommandPaletteView.swift`
- New `CommandPaletteModel.swift` or similar
- Tests under `Tests/SmithersGUITests`
- UI tests under `Tests/SmithersGUIUITests`

## Test Plan

Unit tests:

- Prefix parser maps empty, `>`, `?`, `@`, `/`, and `#` queries to the expected
  launcher mode.
- Scoring prioritizes exact/prefix/fuzzy matches and active tabs over broad
  destinations.
- Route provider includes expected `NavDestination` entries.
- Slash provider reuses `SlashCommandRegistry` and includes built-ins like
  model, review, runs, workflows, approvals, search, terminal, and debug when
  available.
- Tab provider returns chat/run/terminal tabs from `SessionStore`.
- Keyboard chord parser handles `g c`, timeout reset, unknown second key, and
  tmux prefix sequences.
- Terminal-safe policy does not capture plain chords or tmux prefix when
  terminal raw input is focused.

UI/E2E tests:

- `Cmd+P` opens the launcher and `Esc` closes it.
- `Cmd+Shift+P` opens launcher in command mode with `>`.
- `Cmd+K` opens launcher in ask-AI mode with `?`.
- Typing a command query and pressing `Return` navigates to a route, for example
  `>runs`.
- `Cmd+T` creates a terminal tab and navigates to it.
- `Cmd+1` switches to the first visible sidebar tab when tabs exist.
- `Cmd+Shift+]` and `Cmd+Shift+[` move between visible tabs.
- `g c` navigates to Chat when focus is not in a text field.
- `g c` typed into chat input remains literal text and does not navigate.
- `Ctrl+B c` creates a terminal tab outside terminal focus.
- `Ctrl+B c` inside an active terminal is not stolen by default.
- `Cmd+/` opens a shortcut cheat sheet or launcher entry listing common
  shortcuts.

## Acceptance Criteria

- Users can open a universal launcher with `Cmd+P`.
- Users can open command mode with `Cmd+Shift+P` or by typing `>`.
- Users can ask the main AI from the launcher with `Cmd+K` or `?query`.
- Users can create a new terminal tab with `Cmd+T`; terminal is active by
  default after creation.
- Users can switch visible app tabs using numbered and previous/next shortcuts.
- Common tmux-like sequences work outside terminal raw input without breaking
  real terminal tmux/vim/fzf usage.
- Existing slash commands remain the source of truth for slash-command actions.
- The palette exposes shortcuts alongside actions so the system is discoverable.
- Tests cover prefix parsing, provider results, shortcut dispatch, and terminal
  safety.
