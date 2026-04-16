# Live Run Inspector — Output Tab

> Quality bar: spec §9.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Output".

Renders a task's structured JSON output in the inspector's Output tab.
v1: minimal and good-looking, no smart field detection yet. Schema-
ordered rendering using the descriptor from 0012.

## Scope

### `OutputTab`

Input: selected node.

On mount: `smithers.getNodeOutput(runId, nodeId, iteration)`.

Status-driven rendering:

- `produced` → render `row` in schema field order.
- `pending` → empty state.
- `failed` → empty state + collapsible "Last partial output" from
  `partial` field.

### Renderer

Reuse `PropValueView` from 0076 to keep cohesion (JSON tree has the same
semantics as prop tree).

Schema-driven:

- Fields in declared order (from descriptor).
- Field types annotate (string/number/bool/object/array/enum).
- Enum fields: highlight matching / non-matching.
- Description tooltip (from Zod `.describe()`) on hover.

Loading / error / refresh:

- Loading spinner while RPC in flight.
- Error state with retry button on RPC failure (typed `DevToolsClientError`).
- Auto-refresh on task state transition (pending → produced / failed)
  via store notification — no polling.

## Files (expected)

- `OutputTab.swift` (new)
- `OutputRenderer.swift` (new — takes (row, schema), returns view)
- `OutputPendingView.swift`, `OutputFailedView.swift`
- `SmithersClient.swift` (add `getNodeOutput`)
- `Tests/SmithersGUITests/OutputRendererTests.swift`
- `Tests/SmithersGUITests/OutputTabTests.swift`
- `Tests/SmithersGUIUITests/OutputTabE2ETests.swift`

## Testing & Validation

### Unit tests — renderer

Parametric tests over (schema, row) → rendered view tree (via snapshot
testing). Cases:

- Empty schema + empty row → empty state.
- 1-field schema, string row → string rendered.
- 3-field schema, schema order respected (verify visible order, not
  dictionary).
- Nested object renders with collapse controls.
- Enum field with value outside enum → warning marker (out-of-schema).
- Long string field (> 200 chars) → truncates + inline expand.
- Null field (declared nullable) → styled null marker.
- Missing field (declared non-optional) → warning + empty placeholder;
  does not crash.
- Description tooltip present when descriptor has description.

### Unit tests — transitions

- Tab mount → getNodeOutput called exactly once.
- Task transitions from pending → produced → tab auto-refetches.
- Task transitions to failed with partial → partial section visible.
- Manual retry button → getNodeOutput called again; loading state shown.
- Switching away from tab cancels in-flight RPC.

### Input-boundary tests

| Case                                  | Expected                           |
|---------------------------------------|------------------------------------|
| Null row + pending status             | "Task has not produced output yet." |
| 1 scalar field                        | renders                            |
| 100 fields                            | all rendered, lazy                 |
| Single field 1 MB string              | truncates, expand works            |
| Single field 10 MB string             | truncates with warning + expand by page |
| Deeply nested (10 levels)             | lazy render; no freeze             |
| Array of 10,000 items                 | lazy render or show count + head N |
| Unicode / emoji                       | round-trips                        |
| Schema descriptor is null             | fall back to unordered JSON render + info banner |
| Schema has fields row does not have   | marker "not produced"              |
| Row has fields schema does not have   | marker "out of schema"             |
| Status = failed, partial = null       | failed banner, no partial section  |
| Status = failed, partial populated    | partial shown + warning            |

### Integration / UI tests

- Finished task → output renders correctly.
- Task still running → pending state; then completes → auto-renders.
- Failed task with partial → failed state with partial view.
- Copy a field value → pasteboard check.
- Expand a nested object → children visible; collapse → hidden.

### Accessibility

- Every rendered field labeled for VoiceOver.
- Tab Order: top-to-bottom in field declaration order.
- Contrast on type badges.
- Descriptions announced if present.

### Performance

- 100-field render: < 100ms.
- 1 MB row render: < 300ms.
- 10k-element array: lazy — first 100 items rendered < 200ms.

## Observability

- `debug` on RPC call: duration, bytes, status.
- `warn` on out-of-schema row; log warn with field name (not value).
- `error` on decode error.
- Signposts around render.

## Error handling

- `NodeHasNoOutput` from server → render "This node has no output table"
  as empty state (not an error).
- `IterationNotFound` → iteration selector with suggestion of latest
  valid iteration.
- Any `DevToolsClientError` → inline error view with retry.

## Acceptance

- [ ] Unit test matrix passes.
- [ ] All boundary cases handled with the documented behavior.
- [ ] UI tests pass (snapshot + interaction).
- [ ] Accessibility tests pass.
- [ ] Performance budgets met.
- [ ] Manual verification — drive a real workflow, inspect outputs of
      various shapes.
- [ ] No output values in logs above `debug`.

## Blocked by

- smithers/0012
- gui/0076
