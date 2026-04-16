# Lock window/workspace/pane/surface Vocabulary with Stable IDs

## Problem

Our codebase has accreted ad-hoc names for roughly the same concepts: "tab",
"panel", "surface", "pane", "session", "workspace", "run tab", "terminal tab".
The names bleed between SwiftUI views, `SessionStore`, `TabManager`-style code,
and the early socket/CLI surface. As the app grows (browser pane, markdown
viewer, live-run devtools), this gets harder to refactor.

cmux (`vendor/cmux`) solved this by locking exactly five nouns and using them
consistently across menu actions, CLI, socket RPC, persistence, and tests.
Their `docs/agent-browser-port-spec.md` is explicit: any move/reorder operation
preserves handle identity, and this is covered by dedicated tests.

## Vocabulary to Adopt

| Term | Meaning |
|------|---------|
| `window` | Native macOS window |
| `workspace` | Sidebar entry within a window (what our code currently calls chat/run/terminal "tab" or "session" in some places) |
| `pane` | Split region inside a workspace |
| `surface` | Leaf inside a pane: terminal, browser, markdown, live-run, chat, etc. This is the primary automation target |
| `panel` | Internal implementation term only; public API uses `surface` |

## Current State

- `WorkspaceSurfaceModels.swift` already sketches surface types but does not
  enforce identity rules.
- `SessionStore.swift` treats chat/run/terminal as first-class but not as
  uniform `surface` records with stable IDs.
- `WorkspacesView.swift`, `WorkspaceContentView.swift`, and `SidebarView.swift`
  mix "tab", "session", "workspace".
- `BrowserSurfaceView.swift` uses "surface", but the owning container uses
  other terms.
- The growing live-run devtools work (tickets 0074–0082) introduces new
  inspector panels that will benefit from being modeled as surfaces.

## Proposed Design

1. Promote `window`, `workspace`, `pane`, `surface` to the canonical vocabulary
   in code, UI copy, tests, and any emerging socket/CLI surface.
2. Give every `surface` a stable `SurfaceID` UUID that is assigned at creation
   and **must not change** across:
   - Moving between panes.
   - Moving between workspaces.
   - Moving between windows.
   - Reordering within a pane or sidebar.
3. Give every `workspace` a stable `WorkspaceID` with the same rule.
4. Give every `pane` a stable `PaneID`.
5. Give every `window` a stable `WindowID`.
6. Keep legacy names as thin aliases during migration (e.g. `typealias TabID =
   SurfaceID`) so the rename can land incrementally.

## Short Refs (for CLI/logs)

Add human-friendly short refs backed by a monotonic counter per app launch:

- `window:1`, `workspace:3`, `pane:5`, `surface:12`.
- Refs are never reused until relaunch.
- Refs resolve to UUIDs via a `HandleResolver`.
- Default CLI/log output uses refs; JSON output includes both.

This mirrors cmux's `--id-format refs|uuids|both` behavior.

## Move/Reorder Operations

Introduce a small API on the workspace/surface store:

```swift
func moveSurface(_ id: SurfaceID, toPane: PaneID, placement: Placement) -> Result
func reorderSurface(_ id: SurfaceID, anchor: Anchor) -> Result
func moveWorkspace(_ id: WorkspaceID, toWindow: WindowID, placement: Placement) -> Result
func reorderWorkspace(_ id: WorkspaceID, anchor: Anchor) -> Result
```

Where `Placement` is one of `.beforeSurface(SurfaceID)`, `.afterSurface(SurfaceID)`,
`.start`, `.end`, and `Anchor` is the same minus start/end.

Each call returns a result describing the resolved final `window_id`,
`workspace_id`, `pane_id`, `surface_id`. Hard invariant: the surface's own ID
in the return value equals the input ID.

## Migration Plan

1. Add the new ID types + resolver; make existing model objects store them.
2. Add `typealias` aliases for old names so call sites compile.
3. Rename in `WorkspaceSurfaceModels.swift`, `SessionStore.swift`,
   `SidebarView.swift`, `WorkspacesView.swift`, `WorkspaceContentView.swift`,
   `BrowserSurfaceView.swift`.
4. Update test helpers and UI test accessibility IDs.
5. Remove aliases once the rename is stable.

## Non-Goals for First Pass

- Actually implementing split panes in the UI (separate ticket).
- CLI exposure of move/reorder (covered by the CLI ticket).
- Persisting stable IDs across app relaunch — that is a separate persistence
  story; first pass guarantees intra-session stability only.

## Files Likely to Change

- `WorkspaceSurfaceModels.swift`
- `SessionStore.swift`
- `SidebarView.swift`
- `WorkspacesView.swift`
- `WorkspaceContentView.swift`
- `BrowserSurfaceView.swift`
- `Models.swift`
- New `HandleResolver.swift`
- Tests under `Tests/SmithersGUITests`

## Test Plan

- ID stability: creating a surface and moving it across panes/workspaces/windows
  keeps the same UUID.
- Reorder stability: reordering surfaces within a pane keeps all IDs.
- Short ref allocator is monotonic per launch and never reuses refs.
- Handle resolver round-trips UUID ↔ short ref without loss.
- Every existing view renders correctly after rename (smoke UI tests).

## Acceptance Criteria

- Code, tests, and new public surfaces use window/workspace/pane/surface
  consistently.
- Surfaces have stable UUIDs that survive move and reorder.
- Short refs are available via a resolver for future CLI/log use.
- At least one move and one reorder test exists per handle type.
- No regressions in existing workspace/session behavior.
