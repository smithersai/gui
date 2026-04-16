# Live Run Inspector — Output Tab

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Output".

Renders the task's structured JSON output in the inspector's Output tab.
v1 aims for "minimal and good-looking" — no smart field detection yet.

## Scope

### 1. `OutputTab` view

Input: selected node (from `NodeInspectorView`).

On mount: call `smithers.getNodeOutput(runId, nodeId, iteration)`.

Render based on the RPC's `status`:
- `"produced"` — render `row` using schema for field ordering.
- `"pending"` — *"Task has not produced output yet."*
- `"failed"` — error banner (error already shown at inspector level) +
  "Last partial output" collapsible section if present.

### 2. JSON renderer

Collapsible key-value tree. Reuse `PropsTableView` from ticket 0076 where
possible — same semantics:

- Fields rendered in order given by the schema descriptor.
- Scalar: `key: value`, type-colored.
- Object / array: collapsible (default collapsed beyond depth 1).
- Long strings: truncate + inline expand.
- Numbers / booleans / nulls styled distinctly.
- Copy affordance per value.

### 3. Loading / error / refresh

- Loading spinner while the RPC is in flight.
- Error state with retry button on RPC failure.
- Auto-refresh on task state transition (pending → produced) via
  `LiveRunDevToolsStore` update notification.

## Files (expected)

- `OutputTab.swift` (new)
- `SmithersClient.swift` — add `getNodeOutput` method.
- `Tests/SmithersGUITests/OutputTabTests.swift` (new)

## Acceptance

- Produced task: JSON renders with schema-ordered fields.
- Pending task: shows the pending message; updates automatically once the
  RPC starts returning data.
- Failed task: partial output section shown when present.
- Deep-nested objects: collapsed beyond depth 1 by default.
- Long string field: truncates with inline expand.

## Blocked by

- smithers/0012 (getNodeOutput RPC).
- gui/0076 (inspector shell).
