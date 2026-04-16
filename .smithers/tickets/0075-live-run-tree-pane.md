# Live Run Tree Pane (Virtualized XML Tree)

> Quality bar: spec §9. UI ticket — accessibility, performance, and E2E
> coverage are non-negotiable.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.1.

Left pane: virtualized React-DevTools-style XML tree with state colors,
error bubble-up, search, keyboard navigation, mount/unmount animations.

## Scope

### 1. `LiveRunTreeView`

Input: `LiveRunDevToolsStore`.

Layout: search input at top + `LazyVStack` of `TreeRowView` rows, keyed
by `node.id`. Stable keys are required for animation continuity.

### 2. `TreeRowView`

- Chevron (`▶`/`▼`) only for parents; hidden for leaves.
- `<Tag>` with angle brackets, monospaced.
- Key props summary — deterministic one-line string, truncated at
  120 chars.
- State badge (running/finished/failed/blocked/waitingApproval/
  cancelled/pending).
- Timing (elapsed for running, duration for finished).
- Red dot on chevron if any descendant is `failed` (precomputed;
  see §3).

### 3. Error bubble-up

A descendant `failed` makes every ancestor row display a red dot on its
chevron. Computed per snapshot (cached by `snapshotSeq` to avoid
recomputing every SwiftUI body).

### 4. Collapse state

- Default collapsed; auto-expand the path to the running task.
- Per-session user collapse overrides (in-memory dict keyed by
  `node.id`).
- Explicit user-collapsed nodes are never auto-expanded.

### 5. Search

- Cmd+F focuses.
- Matches on tag, `task.nodeId`, `task.label`, `task.agent` —
  case-insensitive substring.
- Matched rows highlighted; non-matches dimmed (not removed).
- Empty query = no filtering.

### 6. Keyboard navigation

- ↑/↓ moves selection (roving focus).
- ← collapses (or goes to parent if already collapsed / leaf).
- → expands (or goes to first child if already expanded).
- Enter focuses inspector.
- Cmd+F focuses search.
- Esc clears search or deselects.
- Home / End to first / last visible row.

### 7. Animations

- Mount: fade + slide-in 120ms ease-out.
- Unmount: fade + slide-out 120ms; dimmed for 1s then removed.
- State transition: badge color crossfade 200ms.
- Always animate. Respect `reduceMotion` — instant transitions when on.

### 8. Virtualization

`LazyVStack` (SwiftUI). Verified with 1,000-node fixture.

## Files (expected)

- `LiveRunTreeView.swift` (new)
- `TreeRowView.swift` (new)
- `TreeRowState.swift` (new — color + icon mapping)
- `TreeSearchIndex.swift` (new — precomputed search matches)
- `AncestorErrorIndex.swift` (new — precomputed bubble-up)
- `TreeKeyboardHandler.swift` (new — key routing)
- `Tests/SmithersGUITests/TreeSearchIndexTests.swift`
- `Tests/SmithersGUITests/AncestorErrorIndexTests.swift`
- `Tests/SmithersGUITests/TreeKeyboardHandlerTests.swift`
- `Tests/SmithersGUITests/TreeRowStateTests.swift`
- `Tests/SmithersGUITests/LiveRunTreeViewTests.swift`
- `Tests/SmithersGUIUITests/LiveRunTreeE2ETests.swift`
- `Tests/SmithersGUIUITests/LiveRunTreeAccessibilityTests.swift`
- `Tests/SmithersGUIUITests/LiveRunTreePerformanceTests.swift`

## Testing & Validation

### Unit tests — state / index helpers

- `AncestorErrorIndex`: for every node in a sample tree, returns the
  expected ancestor set with red dots. Cases:
  - No failures → empty set.
  - Single leaf failed → every ancestor in set.
  - Two sibling failures → both ancestor chains merged.
  - Nested failures → both marked.
  - Failure at root → only root (no ancestors).
- Rebuilt on snapshot change; cached by `seq`.

- `TreeRowState`: every `TaskExecutionState` maps to the exact color
  and icon defined by the spec. Enum exhaustiveness enforced by a
  test that iterates all cases.

- `TreeSearchIndex`:
  - Empty query → all rows visible, none highlighted.
  - Query matches tag, nodeId, label, agent independently.
  - Case insensitive.
  - Unicode normalization (precomposed vs decomposed) matches.
  - Regex metacharacters in query treated literally.
  - Query longer than any field → empty match set.
  - 10,000-node tree indexed in < 100ms.

- `TreeKeyboardHandler`: state-machine-style transitions.
  - ↓ on row N → row N+1 (if exists).
  - ↓ on last row → stays.
  - ← on expanded → collapses.
  - ← on collapsed → moves to parent.
  - → on leaf → moves to first sibling at same depth? (spec decision)
  - Full matrix enumerated in a parametric test.

### Input-boundary tests

| Case                                | Expected                          |
|-------------------------------------|-----------------------------------|
| Empty tree (root only)              | one row rendered                  |
| 1,000-node tree                     | renders < 500ms first frame       |
| Depth 50                            | indentation caps at visible width; no crash |
| Long tag / label (500 chars)        | truncates with ellipsis at row width |
| Unicode / emoji / RTL               | renders correctly; search matches |
| All nodes failed                    | every ancestor + row shows red    |
| All nodes pending                   | all muted, no red dots            |
| Rapid updates (10 events/sec)       | animations do not stack; no jank  |
| User collapses all, new running task auto-expanded | the user-collapsed ones stay collapsed |
| Selected node unmounts               | selection cleared or moved to nearest sibling (decide + test both) |

### Integration / UI tests (XCUITest)

- Open live run → tree renders.
- Click row → inspector selection updates.
- Keyboard nav ↑↓←→ works without mouse.
- Cmd+F focuses search; typing filters; Esc clears.
- Collapse a node → children hidden; expand → restored.
- Tree updates in real time as mock events stream in.

### Accessibility tests

- Every row announces: label, state, iteration, isSelected, hasChildren,
  isExpanded.
- Red-dot ancestor announces: "1 failed descendant" (or exact count).
- Keyboard-only run-through completes without touching mouse.
- ColorContrast: every state badge hits WCAG AA (asserted via
  programmatic contrast check against both light and dark theme
  backgrounds).
- `reduceMotion` honored → animations replaced with instant transitions;
  assert in UI test with simulated accessibility setting.

### Performance tests (XCTest Metrics)

- 1,000 nodes: first-paint < 500ms, scroll 60fps.
- 10,000 nodes: first-paint < 2s, scroll degrades gracefully (no lock).
- Sustained 100 events/sec for 30s: drop count < 5%, no main-thread
  stalls > 100ms.

## Observability

- Log tree render events sparingly — only `debug`: `rowCount`,
  `buildDurationMs`.
- Log keyboard command rate at `debug`.
- Use `os_signpost` around tree build, search index rebuild, and
  row render for Instruments profiling.
- Never log prop values or labels that may contain user content.

## Error handling

- Missing data (node without state) → renders as "unknown" badge, logs
  `warn`, never crashes.
- Empty tree during error state → inline placeholder "Tree unavailable.
  Retry." with a button that calls `store.connect(runId:)`.

## Acceptance

- [ ] Every unit test passes.
- [ ] Every boundary case handled.
- [ ] XCUITest suite passes on macOS 14+.
- [ ] Accessibility tests pass (VoiceOver, keyboard-only, contrast).
- [ ] Performance XCTMetrics within budget.
- [ ] `reduceMotion` respected.
- [ ] No main-thread stall > 100ms in sustained-event test.
- [ ] Manual verification per standing instruction (run app, drive a real
      live workflow, confirm real-time updates visually).

## Blocked by

- gui/0074

## Blocks

- gui/0081 (scrubber renders same tree)
- gui/0082 (integration)
