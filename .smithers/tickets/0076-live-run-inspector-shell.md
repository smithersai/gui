# Live Run Inspector Pane Shell

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2.

Right pane of the new live-run view. Renders the selected node's header,
props table, ghost banner, error banner, and a tab switcher that hosts the
Output / Diff / Logs tabs (tickets 0077–0079).

## Scope

### 1. `NodeInspectorView` (SwiftUI)

Inputs: `LiveRunDevToolsStore` (for selection + ghost state), a tab
selection binding.

### 2. Header

- `<Tag>` + nodeId + state badge + iteration + timing.
- Click nodeId to copy to clipboard.

### 3. Props table

RDT `KeyValue.js` equivalent.

- Scalar props: `key: value` inline. Color-code type (string/num/bool/null).
- Object / array props: collapsible tree, `▶`/`▼` chevron, lazy expand.
- Long string props (> ~200 chars): truncated with an `[expand]` button.
  Expansion is **inline** — clicking replaces the truncated view with the
  full multi-line text, with `[collapse]` to go back. No modal.
- Per-value "Copy" affordance.

### 4. Ghost state

When the store's `isGhost` flag is true:

- Banner above the props table: *"This node is no longer in the running
  tree."* (subtle amber, not red).
- Inspector still renders last-known data — user can continue reading
  Output / Diff / Logs.
- Banner has a "Clear" button to deselect.

### 5. Error banner

When the node's state is `failed`:

- Red banner above the tabs.
- Summary line + expandable stack trace + "Retry" button (wired to the
  existing retry mechanism; disabled if the run doesn't support retry).
- Banner persists across tabs (errors are never buried inside a tab).

### 6. Tab switcher

Three tabs: Output · Diff · Logs. Default tab rules:
- Finished task → Output.
- Still running → Logs.
- No output yet but diff exists → Diff.

Tab contents are separate views provided by tickets 0077–0079. This ticket
only implements the shell that hosts them.

### 7. Non-Task nodes

For `<Workflow>`, `<Sequence>`, `<Parallel>`, etc. (no `task` sidecar),
show the header and props table only. Hide the tab switcher.

## Files (expected)

- `NodeInspectorView.swift` (new)
- `PropsTableView.swift` (new)
- `PropValueView.swift` (new — handles string/number/bool/object/array)
- `InspectorTabSwitcher.swift` (new)
- `Tests/SmithersGUITests/NodeInspectorViewTests.swift` (new)

## Acceptance

- Ghost banner appears when selected node unmounts; disappears when user
  picks another node.
- Long prompt truncated at ~200 chars with working inline expand/collapse.
- Error banner renders above tabs; Retry button wired.
- Non-Task node: no tab switcher.
- Unit test: default tab selection logic for the three cases above.

## Blocked by

- gui/0074 (store — selection + ghost state).

## Blocks

- gui/0077 (Output tab) — needs host container.
- gui/0078 (Diff tab) — needs host container.
- gui/0079 (Logs tab) — needs host container.
- gui/0082 (integration).
