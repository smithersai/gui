# Live Run Inspector Pane Shell

> Quality bar: spec §9.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2.

Right pane: header, props table, ghost banner, error banner, tab switcher
hosting Output / Diff / Logs.

## Scope

### 1. `NodeInspectorView`

Inputs: `LiveRunDevToolsStore`, tab selection binding.

### 2. Header

- `<Tag>` + nodeId + state badge + iteration + timing.
- Click nodeId → copy to pasteboard + announce via VoiceOver.

### 3. Props table (`PropsTableView`)

- Scalar props inline, type-colored.
- Object / array props collapsible tree with `▶`/`▼`.
- Lazy expansion (children of a collapsed object are not rendered in
  SwiftUI body until expand).
- Long strings (> 200 chars) truncated + inline `[expand]` → full.
- Copy affordance per value; copies raw unformatted value.

### 4. Ghost state

`LiveRunDevToolsStore.isGhost == true`:

- Amber banner atop props: "This node is no longer in the running tree."
- Inspector still renders last-known data.
- Banner has "Clear" button that deselects.

### 5. Error banner

Node state `failed`:

- Red banner above tabs with summary + expandable stack + Retry action.
- Persists across tab switches.
- Retry disabled when run does not support retry (check
  `store.runSupportsRetry`).

### 6. Tab switcher (`InspectorTabSwitcher`)

Default selection rules:

- Task finished → Output.
- Task running → Logs.
- Task has diff but no output → Diff.
- Non-Task node → no tabs shown.

### 7. Non-Task nodes

Show header + props only. Hide tab switcher; instead render a small
footer explaining the node's role (one sentence).

## Files (expected)

- `NodeInspectorView.swift` (new)
- `NodeInspectorHeader.swift` (new)
- `PropsTableView.swift` (new)
- `PropValueView.swift` (new)
- `GhostBanner.swift` (new)
- `NodeErrorBanner.swift` (new)
- `InspectorTabSwitcher.swift` (new)
- `DefaultTabPicker.swift` (new — pure function, unit-testable)
- `Tests/SmithersGUITests/PropsTableViewTests.swift`
- `Tests/SmithersGUITests/PropValueViewTests.swift`
- `Tests/SmithersGUITests/DefaultTabPickerTests.swift`
- `Tests/SmithersGUITests/NodeInspectorViewTests.swift`
- `Tests/SmithersGUIUITests/NodeInspectorE2ETests.swift`
- `Tests/SmithersGUIUITests/NodeInspectorAccessibilityTests.swift`

## Testing & Validation

### Unit tests — `DefaultTabPicker` (pure function)

Parametric test over matrix: (state, hasOutput, hasDiff, hasLogs) → tab.

- finished + hasOutput → Output.
- finished + noOutput + hasDiff → Diff.
- finished + noOutput + noDiff → Logs.
- running + any → Logs.
- failed + hasOutput → Output (show what we got).
- failed + noOutput → Logs.
- pending → Logs.
- No tabs applicable (non-Task) → nil.

### Unit tests — PropValueView

- String < 200 chars → inline.
- String 200–10,000 chars → truncated, expand works.
- String > 1 MB → truncated with warning; expand shows full (paginated
  if necessary).
- Object with 0 keys → `{}`.
- Array with 0 items → `[]`.
- Nested 10 levels → lazy expansion keeps body fast.
- Nested 100 levels → depth-limit marker at level 50 (configurable).
- `null` / `true` / `false` / number styled distinctly.
- Copy button copies unformatted raw value (verified via
  `NSPasteboard` fake).
- Non-UTF8 bytes in values → rendered as `"[Binary N bytes]"` without
  crashing the string conversion.

### Unit tests — PropsTableView

- 0 props → empty-state placeholder.
- 1 prop → renders.
- 100 props → all renderable, lazy.
- Props in declared order (stable, not dictionary-order).
- Prop rename (same key, new value) → value updates; copy button
  still works.

### Unit tests — Ghost banner

- isGhost = false → hidden.
- isGhost = true → visible.
- Clear button → calls `store.clearSelection()`; verified via mock.

### Unit tests — Error banner

- Task state = failed → visible.
- Tab switch → banner still visible (persists).
- Retry button calls `store.retryNode(nodeId:)` when supported.
- Retry button disabled when `runSupportsRetry == false`.

### Input-boundary tests

| Case                              | Expected                          |
|-----------------------------------|-----------------------------------|
| Node with 0 props                  | placeholder                      |
| Node with 500 props                | all renderable; scroll works      |
| Prop with 10 MB string             | truncated, expand works, scrollable |
| Circular reference in prop (from bad server) | "[Circular]" marker; no crash |
| ghost + error simultaneously       | both banners visible; error first |
| Long tag name in header            | truncates with tooltip            |
| Rapid selection changes (10/sec)   | inspector keeps up; no flicker    |

### Integration / UI tests

- Select task → inspector populates.
- Select non-Task → tabs hidden, role description visible.
- Unmount selected node → ghost banner appears; Clear deselects.
- Failed task → red banner with Retry; click → store called.
- Long prompt → [expand] reveals full; [collapse] restores.

### Accessibility tests

- Ghost banner announces via VoiceOver.
- Error banner announces as "alert" role.
- Tab switcher keyboard-navigable (Tab / Shift+Tab / Enter).
- Copy buttons have accessible labels ("Copy agent value").
- Every prop row announces its key + value (or marker).
- Contrast: ghost amber, error red, tab badges — all WCAG AA.

### Performance tests

- Props table for 100-prop node: render < 50ms.
- Inspector switch to a different node: < 100ms.
- Tab switch: < 50ms (content caching if needed).

## Observability

- `debug` on selection change: `nodeId`, `propCount`, `buildMs`.
- `debug` on tab switch.
- `warn` on truncation triggers (very long string, deep nesting).
- Signposts around inspector build for Instruments.

## Error handling

- Every error from child tab views is caught and displayed inline in the
  tab without corrupting the inspector shell.
- Store disconnect → inspector shows neutral empty state, not a crash
  dialog.

## Acceptance

- [ ] All unit + UI tests pass.
- [ ] Boundary cases handled.
- [ ] Accessibility tests pass (VoiceOver, keyboard, contrast).
- [ ] Performance budgets met.
- [ ] Manual verification — real workflow, drive inspector interaction.
- [ ] No prop values logged above `debug`.

## Blocked by

- gui/0074

## Blocks

- gui/0077, 0078, 0079 (tabs need host)
- gui/0082 (integration)
