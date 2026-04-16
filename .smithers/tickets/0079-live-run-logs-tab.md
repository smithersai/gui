# Live Run Inspector — Logs Tab

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §2.2 "Logs".

Per-task chat transcript in the inspector — the one piece we carry over
mostly unchanged from the old `LiveRunChatView`. Covers assistant messages,
tool calls, tool results, stderr, and user/prompt blocks.

## Scope

### 1. `LogsTab` view

Input: selected node.

Streams chat blocks for the task via the existing
`smithers.streamChat(runId)` plus per-node filtering (see
`LiveRunChatView.swift:blocksForNode`).

### 2. Port existing renderer

Lift these from `LiveRunChatView.swift`:
- Block rendering switch (assistant/agent, user/prompt, tool/tool_result,
  system/stderr/status).
- Streaming merge logic (match by `lifecycleId`, replace on merge,
  append otherwise).
- Deduplication.

These become standalone types so `LogsTab` is not coupled to
`LiveRunChatView`. The old view gets deleted in ticket 0082.

### 3. Controls

- **Follow-to-bottom toggle**: auto-scroll on new blocks when on.
- **Noise filter toggle**: hide stderr/system blocks matching the existing
  noise regex.
- **Copy transcript**: copy the entire rendered transcript to clipboard.

### 4. Integration with store

- Subscribe only while the Logs tab is active (cancel stream on tab
  switch or node change).
- Show streaming indicator in header while live.

## Files (expected)

- `LogsTab.swift` (new)
- `ChatBlockRenderer.swift` (new — extracted from LiveRunChatView)
- `ChatBlockMerger.swift` (new — streaming merge + dedup, extracted)
- `Tests/SmithersGUITests/ChatBlockMergerTests.swift` (new — the existing
  merger logic has no unit coverage; fix that while we're here)

## Acceptance

- Switching between tasks swaps the transcript cleanly, no cross-talk.
- Streaming merge: duplicate `lifecycleId` results in replacement, not
  duplication.
- Follow-to-bottom sticks while on; stops when user scrolls up.
- Noise filter hides stderr rows.
- Unit test: merger handles out-of-order deltas correctly.

## Blocked by

- gui/0076 (inspector shell).
