# Retire LiveRunChatView and Wire New View Into Navigation

> Quality bar: spec §9. Final integration — the system must be
> production-ready after this ticket merges, with full E2E coverage,
> accessibility, and memory profile.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §4.3.

The new DevTools-style view replaces the old `LiveRunChatView` task-card
dashboard. Logs tab (0079) is the only survivor. This ticket does the
wiring, the deletion, and the end-to-end certification.

## Scope

### 1. `LiveRunView` (new top-level composition)

Composes:

- `LiveRunHeaderView` (0080)
- `LiveRunTreeView` (0075) — left
- `NodeInspectorView` (0076) + `OutputTab` / `DiffTab` / `LogsTab`
  (0077–0079) — right
- `FrameScrubberView` (0081)

Layout:

- Wide (≥ 800pt): two-pane resizable (`HSplitView` or equivalent).
- Narrow (< 800pt): inspector as a bottom sheet over the tree.
- Resize → smooth transition between modes; selection preserved.

### 2. Navigation wiring

Replace `LiveRunChatView` at every entry point:

- `ContentView.swift` destination `.liveRun(runId:nodeId:)` → `LiveRunView`.
- `RunsView.swift` Live Chat button → unchanged callback, same route.
- Tab reopen via `SessionStore.addRunTab` → unchanged.

### 3. Preserve behavior

From old view:

- Hijack flow (AppleScript Terminal bridge).
- Cancel action.
- Approval flow for `waitingApproval`.
- `onOpenTerminalCommand` callback.
- `nodeId` deep-linking — auto-expand and select.

### 4. Delete

- `LiveRunChatView.swift` — remove.
- `Tests/SmithersGUITests/LiveRunChatViewTests.swift` — remove or
  repurpose.
- Any helper files only used by the old view — remove.
- Verify: `rg 'LiveRunChatView' /Users/williamcory/gui` returns nothing.

### 5. Memory + lifecycle guarantees

- Closing a live-run tab tears down the store (stream cancelled; no
  leaked Task).
- Navigating away pauses the scrubber subscription.
- Large runs do not retain more than documented: old frames dropped
  from store once > 100 back-frames (scrubber re-fetches on demand).

## Files (expected)

- `LiveRunView.swift` (new)
- `LiveRunLayout.swift` (new — wide vs narrow)
- `ContentView.swift` (update)
- `LiveRunChatView.swift` (delete)
- `Tests/SmithersGUIUITests/LiveRunDevToolsE2ETests.swift` (new)
- `Tests/SmithersGUIUITests/LiveRunDevToolsAccessibilityE2ETests.swift`
- `Tests/SmithersGUIUITests/LiveRunDevToolsResponsiveLayoutTests.swift`
- `Tests/SmithersGUIUITests/LiveRunDevToolsMemoryTests.swift`
- `Tests/SmithersGUITests/LiveRunChatViewTests.swift` (delete)

## Testing & Validation

### Integration / E2E

- Open live run → tree renders, inspector loads, header shows
  heartbeats.
- Select a task → props + tabs populate.
- Task finishes → Output tab auto-populates.
- Diff tab shows file changes.
- Logs tab streams.
- Scrub back → sepia overlay + historical view.
- Return to live.
- Rewind a test workflow end-to-end.
- Cancel run → header pill updates.
- Hijack run → Terminal.app opens with correct command.
- Approval flow → approve from header; run continues.
- Deep-link to run + nodeId → nodeId selected on load.
- Open two live runs in two tabs → each has its own store, no cross-talk.
- Close a tab → store torn down (verify via mem dump that no
  `LiveRunDevToolsStore` instance remains).
- Server goes down mid-session → reconnect banner; resumes when server
  returns.

### Responsive layout tests

- Window width 1400pt → side-by-side with drag divider.
- Window width 600pt → bottom sheet.
- Resize from 1400 → 600 while inspector has a selection → selection
  preserved in sheet.
- Resize back → side-by-side restored with same selection.
- Drag divider → smooth, no hitches.
- Divider position persisted across sessions (per user).

### Input-boundary tests

| Case                                   | Expected                       |
|----------------------------------------|--------------------------------|
| Open run with 0 tasks                   | empty tree placeholder        |
| Open run with 500 tasks                 | tree renders < 2s             |
| Open run that was deleted server-side   | `RunNotFound` error banner    |
| Open run mid-execution                  | tree renders, streaming works |
| Open finished run                       | scrubber works, rewind hidden |
| Rapidly open/close same run 20 times    | no crash, no leaked stores    |
| Network drops, user waits 10min, comes back | reconnect successful       |
| Very long workflow (24h run)            | elapsed formats as HH:MM:SS; no overflow |

### Accessibility — full-experience

- VoiceOver walk-through: every element announces (tree row, inspector
  field, tab name, scrubber, header).
- Keyboard-only full session: open run, navigate tree, open inspector,
  switch tabs, scrub, rewind (with confirmation), close tab — all
  without mouse.
- High-contrast theme: every surface renders legibly.
- Color-blind palette (deuteranopia simulated): state colors
  distinguishable (add shape / icon affordances where color alone is
  insufficient — test the whole view).

### Memory / performance

- Open → close → open → close 10× → RSS returns to baseline ± 5%
  (assert via `XCTMemoryMetric`).
- 10-minute session with continuous events → RSS growth < 50 MB.
- 500-task run rendering: sustained 60fps during active streaming
  (`XCTOSSignpostMetric`).
- No main-thread stall > 100ms throughout.

### Cleanup verification

- `rg 'LiveRunChatView' gui` returns zero hits (except the deletion
  commit itself).
- Tests for deleted helpers removed.
- No dead code detected by Xcode's analyzer in changed files.

## Observability

- `info` on LiveRunView lifecycle: open, close, duration.
- `info` on layout mode change: wide ↔ narrow.
- `warn` on store teardown anomalies (e.g. non-cancelled task).
- `error` on any uncaught exception (should not happen — guarded).

## Error handling

- Run not found → empty state with "Back to Runs" action.
- Store connection error → retry banner; does not crash.
- Any downstream view error → inline, does not break shell.

## Acceptance

- [ ] All E2E scenarios pass.
- [ ] Responsive layout tests pass at wide, narrow, and transition.
- [ ] Every boundary case handled.
- [ ] Accessibility suite passes (VoiceOver, keyboard-only, contrast,
      color-blind palette).
- [ ] Memory test passes (no leak, no growth > documented bounds).
- [ ] Performance metrics within budget.
- [ ] `rg 'LiveRunChatView'` returns no hits.
- [ ] Manual verification — per standing memory, run the app end-to-end
      on a real workflow, confirm every tab works, rewind works, hijack
      works, approval works. Do not declare done without this.

## Blocked by

- gui/0075, 0076, 0077, 0078, 0079, 0080, 0081
