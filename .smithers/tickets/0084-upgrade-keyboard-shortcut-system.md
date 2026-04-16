# Upgrade Keyboard Shortcut System to User-Customizable Action Table

## Problem

`KeyboardShortcutController.swift` dispatches a handful of hardcoded shortcuts.
As we add split panes, directional pane focus, number-based workspace/surface
jumps, jump-to-unread, flash-focused-pane, and more (see cmux parity items),
this stops scaling and is not user-customizable.

cmux's `Sources/KeyboardShortcutSettings.swift` is the pattern to copy: a single
enum of actions, each with a localized label, a default shortcut, a defaults
key, and a `~/.config/cmux/settings.json`-backed override. Every shortcut is
discoverable in Settings and editable.

## Proposed Design

1. Introduce `ShortcutAction: String, CaseIterable, Identifiable` with every
   app-owned shortcut as a case. Each case provides:
   - `label`: localized display string.
   - `defaultsKey`: stable key for UserDefaults.
   - `defaultShortcut: StoredShortcut`.
2. Introduce `StoredShortcut` (key + command/shift/option/control flags) as a
   `Codable` struct.
3. Introduce `KeyboardShortcutSettings` as a static facade that:
   - Loads the default table.
   - Merges overrides from UserDefaults.
   - Merges overrides from `~/.config/smithers/settings.json` (same pattern as
     cmux's file store).
   - Posts a `didChange` notification when overrides mutate.
4. Route all app-level key handling through a dispatcher that looks up the
   current binding for an action instead of hardcoding a `Shortcut(...)`.
5. Add a Settings pane to view and re-bind shortcuts.

## Actions to Ship Initially

Existing (already present somewhere):

- `commandPalette`, `commandPaletteCommandMode`, `commandPaletteAskAI`
- `newChat`, `newTerminal`, `closeCurrentTab`
- `nextSidebarTab`, `prevSidebarTab`
- `selectWorkspaceByNumber` (Cmd+1..9)
- `toggleDeveloperDebug`

New from cmux parity:

- `toggleSidebar` (Cmd+B)
- `splitRight` (Cmd+D), `splitDown` (Cmd+Shift+D)
- `focusLeft`, `focusRight`, `focusUp`, `focusDown` (Opt+Cmd+Arrow)
- `toggleSplitZoom`
- `nextSurface`, `prevSurface`, `selectSurfaceByNumber` (Ctrl+1..9)
- `renameWorkspace`, `renameSurface`
- `jumpToUnread` (Cmd+Shift+U)
- `triggerFlash` (Cmd+Shift+H)
- `showNotifications` (Cmd+I)
- `toggleFullScreen`
- `focusBrowserAddressBar`, `browserBack`, `browserForward`, `browserReload`
- `find`, `findNext`, `findPrevious`, `hideFind`, `useSelectionForFind`

## Configuration File

`~/.config/smithers/settings.json` (file-watched via DispatchSource):

```json
{
  "shortcuts": {
    "toggleSidebar": { "key": "b", "command": true },
    "splitRight":    { "key": "d", "command": true },
    "splitDown":     { "key": "d", "command": true, "shift": true }
  }
}
```

Priority: file overrides UserDefaults overrides defaults. File-watch triggers
`didChangeNotification` so the UI updates live.

## Implementation Notes

- Keep the existing hidden-button `.keyboardShortcut` pattern where SwiftUI
  is happy, but read the binding from `KeyboardShortcutSettings.current(for:)`
  instead of hardcoding it.
- For modifier-only or chord-based shortcuts, use an AppKit event monitor
  guarded by text-field/terminal-focus detection (same policy as ticket 0073).
- Migrate the tmux-like chord handler from ticket 0073 to read its bindings
  from this settings source so chords are also customizable.
- Localize every `label` through `String(localized:defaultValue:)`.

## Non-Goals for First Pass

- In-UI drag-to-rebind. Editing via JSON and/or a picker cell is enough.
- Shortcut conflict UI; emit a log warning for now.
- Ghostty/terminal raw-input rebinding.

## Files Likely to Change

- New `KeyboardShortcutSettings.swift`
- New `KeyboardShortcutSettingsFileStore.swift`
- New `StoredShortcut.swift`
- `KeyboardShortcutController.swift`
- `ContentView.swift`
- Settings view (new or extended)
- Tests under `Tests/SmithersGUITests`

## Test Plan

- Default table loads correctly; every `ShortcutAction` has a unique defaults
  key and non-empty label.
- UserDefaults overrides replace defaults.
- File-based overrides replace UserDefaults.
- File changes on disk fire `didChangeNotification` within one watcher tick.
- Dispatcher fires the right action when the bound chord is pressed.
- Dispatcher does not fire when focus is inside a text field or terminal raw
  input path.

## Acceptance Criteria

- Every app-level keyboard shortcut is declared in one action enum.
- Users can override any shortcut via `~/.config/smithers/settings.json`.
- Settings UI surfaces all shortcuts with their current bindings.
- File-watching picks up changes without restart.
- No regression of shortcuts from ticket 0073.
