# smithers.json Project Config with Global + Local Merging

## Problem

We already have a growing set of places that want project-local configuration:
command palette custom commands, URL intercept rules (ticket 0087), keyboard
shortcut overrides (ticket 0084), agent hooks. Today each feature reads from a
different file or has nothing. A single well-defined config file scoped per
repo and per user solves this uniformly.

cmux ships `cmux.json` discovered by walking up from the workspace cwd, merged
on top of `~/.config/cmux/cmux.json`, both file-watched via DispatchSource.
Ported in `vendor/cmux/Sources/CmuxConfig.swift`.

## Proposed Design

### 1. File Locations

- Global: `~/.config/smithers/smithers.json`
- Local: nearest `smithers.json` found walking up from the current workspace's
  cwd.

Local overrides global by merging at the top-level key. Command lists are
deduped by `name` with local-first precedence (matches cmux).

### 2. Schema (v1)

```json
{
  "commands": [
    {
      "name": "Dev: start backend",
      "description": "Boot the dev server with debug flags",
      "keywords": ["backend", "server"],
      "workspace": {
        "name": "Backend",
        "cwd": "./packages/api",
        "color": "#5a82ff",
        "layout": {
          "direction": "horizontal",
          "split": 0.5,
          "children": [
            { "pane": { "surfaces": [{ "type": "terminal", "command": "npm run dev" }] } },
            { "pane": { "surfaces": [{ "type": "browser", "url": "http://localhost:3000" }] } }
          ]
        }
      }
    },
    {
      "name": "Quick: rebuild assets",
      "command": "npm run build",
      "confirm": true,
      "restart": "confirm"
    }
  ],

  "browser": {
    "intercept": [
      { "pattern": "localhost:*", "target": "in-app" },
      { "pattern": "*",           "target": "default-browser" }
    ]
  },

  "shortcuts": {
    "toggleSidebar": { "key": "b", "command": true }
  }
}
```

- Each command must define either `workspace` or `command`, not both.
- Layout nodes mirror cmux: `pane` leaves or `{direction, split, children[2]}`
  splits.
- `restart` ∈ `recreate | ignore | confirm` controls behavior when the same
  command is triggered while it's already running.

### 3. ConfigStore

```swift
@MainActor
final class SmithersConfigStore: ObservableObject {
    @Published private(set) var loadedCommands: [SmithersCommandDefinition]
    @Published private(set) var browserIntercept: [URLInterceptRule]
    @Published private(set) var shortcutOverrides: [String: StoredShortcut]
    @Published private(set) var configRevision: UInt64
}
```

- Start a global file watcher at launch.
- Rewire local watcher when the active workspace's cwd changes.
- On any file change, reparse both and reload in one pass.
- If parsing fails, keep the previous good state and surface a warning.

### 4. Consumers

- **Command palette** (0073): renders each command as a palette item; dispatch
  opens workspace or runs a shell command.
- **URL router** (0087): `browser.intercept` feeds the rule table.
- **Shortcut settings** (0084): overrides merged on top.

### 5. Scope-Aware Semantics

- Walk up from the workspace cwd to find the nearest `smithers.json`.
- If none found, use `~/.config/smithers/smithers.json` only.
- Writes always go to a specific file (never merged back automatically).

## Non-Goals for First Pass

- JSON Schema validation UI. A good error log is enough.
- Multi-file includes / `extends`.
- Per-workspace overrides beyond cwd walk-up.
- Encrypted secrets; agents should load secrets from the shell environment.

## Files Likely to Change

- New `Sources/Config/SmithersConfig.swift`
- New `Sources/Config/SmithersConfigStore.swift`
- New `Sources/Config/SmithersConfigExecutor.swift` (run command entries)
- `CommandPaletteModel.swift`
- `SessionStore.swift` (wire workspace cwd changes)
- Settings view
- Tests under `Tests/SmithersGUITests`

## Test Plan

- Loads global only when no local exists.
- Loads local only when no global exists.
- Local wins on name collision; global fills the rest.
- Invalid local JSON keeps the previous state and logs.
- File-watch sees write, delete-and-recreate, atomic rename.
- Dir-watch picks up the file appearing for the first time.
- Command with both `command` and `workspace` is rejected.
- Command with neither is rejected.
- Layout split must have exactly 2 children.
- Color hex normalization matches cmux behavior.
- cwd walk-up stops at filesystem root.

## Acceptance Criteria

- A `smithers.json` in a project exposes custom commands in the palette.
- Global overrides are applied when no local config exists.
- Live reload works without app restart.
- Other features (URL intercept, shortcuts) read from the same config source.
