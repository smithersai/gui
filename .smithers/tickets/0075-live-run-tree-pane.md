# Live Run Tree Pane (Virtualized XML Tree)

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.1.

Left pane of the new live-run view. Renders the `DevToolsNode` tree as an
indented, virtualized, React-DevTools-style XML tree with state colors,
error bubble-up, search, keyboard navigation, and mount/unmount animations.

## Scope

### 1. `LiveRunTreeView` (SwiftUI)

Input: `LiveRunDevToolsStore` (from ticket 0074).

Layout:
- Top: search input (filters by tag + nodeId + label in v1; no prop
  content search).
- Body: `ScrollView` with `LazyVStack` of `TreeRowView`, keyed by
  `node.id` so SwiftUI can diff mount/unmount.

Each row:
- Chevron (`▶`/`▼`) — only for nodes with children.
- `<Tag>` in angle brackets, monospaced.
- Key-props summary: one-line, e.g. `id="fetch" agent="claude-opus-4-7"`.
- State badge (running/finished/failed/etc.).
- Timing (elapsed for running, duration for finished).

### 2. State colors (from spec §2.1)

Map `TaskExecutionState` → color:
- `pending` → muted foreground
- `running` → accent blue, pulsing tag
- `finished` → foreground + subtle ✓
- `blocked` / `waitingApproval` → amber
- `failed` → red tag + faint red row background
- `cancelled` → strikethrough muted

### 3. Error bubble-up

If any descendant has state `failed`, ancestor rows show a **red dot** on
the chevron (visible whether expanded or collapsed). Precompute per snapshot
in the store (or in a computed property) so render stays cheap.

### 4. Collapse state

- Default: collapsed for everything.
- Auto-expand: path from root to currently-running task.
- Persist user's explicit collapse choices per session (dict keyed by
  `node.id`). Don't re-expand a node the user collapsed.

### 5. Search

- Input at pane top, Cmd+F focuses.
- Matches: tag name, `task.nodeId`, `task.label`, `task.agent`.
- Matching rows highlighted; non-matches dimmed (not removed — structure
  stays intact).

### 6. Keyboard navigation

Mirror React DevTools:
- ↑/↓ move selection.
- ←/→ collapse/expand (← on already-collapsed goes to parent; → on
  already-expanded goes to first child).
- Enter focuses the inspector pane.
- Cmd+F focuses search.

### 7. Animations

- Mount: fade + slide-in from left (120ms ease-out).
- Unmount: fade + slide-out (120ms), dim for ~1s before removing.
- State transition: badge color crossfade (200ms).
- Always animate; no throttling even on big re-renders.

### 8. Virtualization

`LazyVStack` is sufficient for v1. Verify with a 500-node fixture. If
frames drop, swap in a custom virtualized list (e.g. `List` with
`buffer-based` rendering) — but default to LazyVStack.

## Files (expected)

- `LiveRunTreeView.swift` (new)
- `TreeRowView.swift` (new)
- `TreeRowState.swift` (new — color + icon mapping)
- `Tests/SmithersGUITests/LiveRunTreeViewTests.swift` (new)
- `Tests/SmithersGUIUITests/LiveRunTreeE2ETests.swift` (new)

## Acceptance

- Unit test: error bubble-up — a tree with one failed leaf shows red dots
  on every ancestor.
- Unit test: collapse persistence — user-collapsed node stays collapsed
  across frame updates.
- UI test: search narrows visible highlighting.
- UI test: keyboard nav moves selection without mouse.
- Manual: 500-node fixture renders at 60fps while receiving deltas.

## Blocked by

- gui/0074 (store).

## Blocks

- gui/0081 (time-travel scrubber uses same tree).
- gui/0082 (integration).
