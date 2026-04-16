# Retire LiveRunChatView and Wire New View Into Navigation

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §4.3.

Final integration ticket. The new DevTools-style live-run view replaces
the old `LiveRunChatView` task-card dashboard. The Logs tab (ticket 0079)
is the only surviving piece of the old transcript renderer. This ticket
does the wiring and the deletion.

## Scope

### 1. New top-level view

Create `LiveRunView` that composes:
- `LiveRunHeaderView` (ticket 0080)
- `LiveRunTreeView` (ticket 0075) — left pane
- `NodeInspectorView` (ticket 0076) — right pane, with
  `OutputTab` / `DiffTab` / `LogsTab` (tickets 0077–0079)
- `FrameScrubberView` (ticket 0081)

Layout:
- Wide: two panes side-by-side, resizable divider.
- Narrow (< ~800px): inspector collapses to a bottom sheet.

### 2. Wire into navigation

Replace `LiveRunChatView` at every entry point:

- `ContentView.swift` destination `.liveRun(runId:nodeId:)` → render
  `LiveRunView` instead.
- `RunsView.swift` Live Chat button → unchanged callback, routes to
  `LiveRunView`.
- Tab reopening via `SessionStore.addRunTab` → no change.

### 3. Preserve behavior

Carry over from the old view:
- Hijack flow (AppleScript Terminal bridge).
- Cancel action.
- Approval bubbling for `waitingApproval` state.
- `onOpenTerminalCommand` callback.
- `nodeId` deep-linking (if a run is opened with a specific nodeId, the
  tree auto-expands to + selects that node).

### 4. Delete

- `LiveRunChatView.swift` — delete. Port any leftover helpers to new
  files first.
- `LiveRunChatViewTests.swift` — delete or repurpose.

Confirm no other file references `LiveRunChatView` before deletion:
`rg "LiveRunChatView" /Users/williamcory/gui` must come back clean
(except the delete itself).

### 5. E2E test

Add `Tests/SmithersGUIUITests/LiveRunDevToolsE2ETests.swift` covering:
- Opening a live run shows tree + inspector.
- Clicking a task selects it and populates the inspector.
- Scrubber navigates to a historical frame.
- Running a workflow end-to-end updates the tree in real time.

### 6. Manual verification (per user's standing instruction)

Run the app, open a live workflow, confirm:
- Tree renders and updates as tasks mount/unmount.
- Selecting a task shows props + tabs.
- Output tab populates when the task finishes.
- Diff tab shows file changes.
- Logs tab streams chat.
- Dual heartbeats animate.
- Scrubber moves through history.
- Rewind works on a test workflow.

## Files (expected)

- `LiveRunView.swift` (new)
- `ContentView.swift` (update destination wiring)
- `LiveRunChatView.swift` (delete)
- `Tests/SmithersGUIUITests/LiveRunDevToolsE2ETests.swift` (new)
- `Tests/SmithersGUITests/LiveRunChatViewTests.swift` (delete)

## Acceptance

- Every old entry point opens the new view.
- All E2E tests pass.
- Manual verification checklist complete.
- `rg LiveRunChatView` returns no hits.
- Hijack, cancel, approval, terminal-open, deep-link all still work.

## Blocked by

- gui/0075 (tree pane)
- gui/0076 (inspector shell)
- gui/0077 (Output tab)
- gui/0078 (Diff tab)
- gui/0079 (Logs tab)
- gui/0080 (header)
- gui/0081 (time travel)
