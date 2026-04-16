# Live Run Inspector — Logs Tab

> Quality bar: spec §9.

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Logs".

Per-task chat transcript. Only surviving piece from the old
`LiveRunChatView`. Extract + harden the existing merge logic; it had no
unit coverage.

## Scope

### `LogsTab`

Input: selected node.

Streams blocks for the task via existing `smithers.streamChat(runId)`
with per-node filtering (today: `LiveRunChatView.blocksForNode`).

### Port existing block renderer

Lift from `LiveRunChatView.swift`:

- Block rendering switch (assistant/agent, user/prompt, tool/tool_result,
  system/stderr/status).
- Streaming merge logic (match by `lifecycleId`, replace on merge,
  append otherwise).
- Deduplication.

Move to standalone types: `ChatBlockRenderer`, `ChatBlockMerger`.

### Controls

- Follow-to-bottom toggle; auto-scroll on new blocks while on; stops
  when user scrolls up; resumes when user scrolls to bottom.
- Noise filter toggle; hides stderr / system matching existing regex.
- Copy transcript → full rendered plain text to pasteboard.

### Integration with store

- Subscribe only while Logs tab active; cancel on tab switch / node
  change.
- Show streaming indicator when live.

## Files (expected)

- `LogsTab.swift` (new)
- `ChatBlockRenderer.swift` (new — extracted)
- `ChatBlockMerger.swift` (new — extracted)
- `ChatBlockFilter.swift` (new — noise regex extracted)
- `Tests/SmithersGUITests/ChatBlockMergerTests.swift` (new — was
  untested)
- `Tests/SmithersGUITests/ChatBlockFilterTests.swift`
- `Tests/SmithersGUITests/ChatBlockRendererTests.swift`
- `Tests/SmithersGUITests/LogsTabTests.swift`
- `Tests/SmithersGUIUITests/LogsTabE2ETests.swift`

## Testing & Validation

### Unit tests — ChatBlockMerger

Parametric over delta sequences:

- Empty stream → empty transcript.
- Single block → appended.
- Two blocks different lifecycleIds → both appended.
- Two blocks same lifecycleId → second replaces first.
- Out-of-order (seq=3 then seq=2 for same lifecycleId) → final state
  matches highest seq's content (or per existing protocol — test the
  observed behavior explicitly, document it).
- Streaming assistant partials (same lifecycleId, growing text) →
  final text is the last variant.
- 1,000 blocks arriving in 1s → all appear exactly once.
- Duplicate blocks (same id same content) → deduplicated to one.
- Block with missing lifecycleId → appended (never merged).
- Block with missing id → appended as separate entry.

### Unit tests — ChatBlockFilter

- Empty stderr block → hidden with filter on.
- Stderr "warning: foo" → hidden.
- Assistant block → never hidden.
- Tool blocks → never hidden.
- Regex anchored correctly (non-greedy); counter-examples preserved.
- Invalid regex in setting → falls back to default (does not crash).

### Unit tests — ChatBlockRenderer

- Assistant block → bubble with timestamp.
- User/prompt block → muted bubble, lineLimit(8).
- Tool call block → monospace, compact.
- Tool result block → separate styling.
- Very long block (10,000 lines) → lineLimit honored; expand control
  present.
- Unicode / emoji / code fences preserved.
- Markdown in assistant blocks → rendered (if spec supports) or raw
  (current behavior — test matches).

### Unit tests — LogsTab

- Select task → subscribe to stream.
- Switch task → previous subscription cancelled; new one started.
- Switch tab away → subscription cancelled; re-enter → resubscribe.
- Follow-to-bottom: new block arrives → scroll to bottom when on; no
  scroll when off.
- User scrolls up → follow auto-disables.
- User scrolls to bottom → follow auto-enables (opt-in, with setting).
- Copy transcript → pasteboard has full text.
- Noise toggle → filter reapplied instantly.

### Input-boundary tests

| Case                             | Expected                          |
|----------------------------------|-----------------------------------|
| 0 blocks                          | empty state                      |
| 10,000 blocks                     | virtualized; smooth scroll        |
| Single block 1 MB text            | truncated with expand            |
| 100 blocks/sec for 30s            | no frame drops > 5%; all appear  |
| Multiple consecutive merges (streaming assistant) | single bubble that grows |
| Out-of-order delivery             | deterministic final state        |
| Non-UTF8 tool output              | rendered as "[N bytes]" fallback |
| Block with null timestamp         | renders without crashing         |
| Block from different run (bug)    | ignored + log warn                |

### Integration / UI tests

- Live workflow → blocks stream in → visible.
- Switch tasks → transcript swaps cleanly.
- Follow toggle behaves as specified.
- Noise filter hides stderr.
- Copy → pasteboard verified.

### Accessibility

- Each block announced with role (assistant / user / tool / system).
- Keyboard: ↑/↓ between blocks; Enter to expand; Cmd+C copies selected.
- Follow toggle is a switch with clear label.

### Performance

- 10,000-block transcript: first paint < 1s, scroll 60fps.
- Rapid stream: 100 blocks/sec for 30s, drop count < 5%.
- Merge operation on existing block: O(1) lookup via
  `lifecycleId → index` dictionary.

## Observability

- `debug` on subscribe / unsubscribe: `runId`, `nodeId`, duration.
- `debug` on merge: counts.
- `warn` on block from wrong run / missing required fields.
- Signposts around merge and render.
- Never log block content.

## Error handling

- Stream error → banner + retry, no crash, existing blocks preserved.
- Malformed block → logged, not rendered (no partial crash).

## Acceptance

- [ ] Merger tests exhaustive (previously zero coverage — this ticket
      fixes that).
- [ ] Boundary cases all handled.
- [ ] UI tests pass.
- [ ] Accessibility tests pass.
- [ ] Performance budgets met.
- [ ] Manual verification in a live workflow.
- [ ] Block content never in logs.

## Blocked by

- gui/0076
