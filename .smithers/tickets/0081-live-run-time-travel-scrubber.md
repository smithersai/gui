# Live Run Time-Travel Scrubber and Rewind

> Quality bar: spec §9. **Rewind is destructive — confirmation UX,
> error UX, and observability must be top-tier.**

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §7.

Header frame scrubber for view-only time travel plus a Rewind action
that actually mutates the engine.

## Scope

### Frame scrubber

Lives in header below status row.

- Horizontal slider from 0 to `latestFrameNo`.
- Displays: `frame N / M`; tick marks at notable events.
- Dragging → debounced `getDevToolsSnapshot(runId, frameNo)` calls
  (debounce 50ms). In between, keep showing the last successfully
  loaded frame.
- Banner when not at latest: "Viewing frame N of M (historical)." with
  "Return to live" button.

### Rewind action

Button in scrubber region, visible only when viewing a historical frame
of a **live** run.

Flow:

1. Click → confirmation dialog with exact text: "Rewind this run to
   frame N? This cannot be undone." + "Rewind" (destructive style) /
   "Cancel".
2. Confirm → `jumpToFrame(runId, frameNo, confirm: true)`.
3. Success → toast + snap to latest + resume live mode.
4. Error → error banner with the reason + remediation.

Finished runs: Rewind hidden (not eligible in v1).

### Store additions

- `mode: .live | .historical(frameNo: Int)`.
- `latestFrameNo: Int`.
- `scrubTo(frameNo:)` — fetches snapshot, sets `.historical`, suspends
  stream event application.
- `returnToLive()` — resumes stream, sets `.live`.
- `rewind(to frameNo:)` — calls `jumpToFrame`; on success → refresh
  latest + returnToLive; on failure → keep historical view + surface
  error.

### Visual cue

`.historical` mode: subtle sepia/desaturation overlay applied to tree +
inspector so user cannot miss it.

## Files (expected)

- `FrameScrubberView.swift` (new)
- `RewindConfirmationDialog.swift` (new)
- `HistoricalOverlay.swift` (new modifier)
- `LiveRunDevToolsStore.swift` (extend)
- `SmithersClient.swift` (add `jumpToFrame`)
- `Tests/SmithersGUITests/FrameScrubberTests.swift`
- `Tests/SmithersGUITests/ScrubberDebounceTests.swift`
- `Tests/SmithersGUITests/StoreScrubTests.swift`
- `Tests/SmithersGUITests/StoreRewindTests.swift`
- `Tests/SmithersGUIUITests/ScrubberE2ETests.swift`
- `Tests/SmithersGUIUITests/RewindFlowE2ETests.swift`

## Testing & Validation

### Unit tests — scrubbing

- `scrubTo(N)` calls `getDevToolsSnapshot` with N and sets mode
  historical.
- Multiple scrubTo calls within debounce window → only last one fires
  RPC.
- `returnToLive()` resubscribes to stream and clears historical tree
  to current live tree.
- Stream events arriving during historical mode are buffered (not
  applied); on returnToLive the UI jumps to latest.
- Scrub to N that fails → stay on previous good frame + error banner;
  mode remains historical.
- Scrub to frame 0 on empty run → typed `FrameOutOfRange` error
  surfaced.

### Unit tests — rewind

- Without confirmation → no RPC, no state change.
- With confirmation + success → store calls jumpToFrame, mode →
  live, tree updated, toast fired.
- With confirmation + `Busy` → banner "Another rewind is in progress",
  mode stays historical.
- With confirmation + `UnsupportedSandbox` → banner with explanation,
  mode stays historical.
- With confirmation + network error → retry prompt; underlying state
  unchanged.
- Rewind disabled when run is finished.
- Rewind disabled while another rewind in flight (local single-flight
  guard) — independent of server `Busy`.

### Unit tests — debounce

- 10 scrub events in 50ms → only 1 RPC.
- Steady drag at 100 events/sec for 1s → ~20 RPCs (every 50ms).
- Trailing edge: last scroll position always resolved (no ignored
  final value).

### Input-boundary tests

| Case                                       | Expected                     |
|--------------------------------------------|------------------------------|
| Run with 0 frames                           | scrubber disabled           |
| Run with 1 frame                            | scrubber disabled (no range)|
| Run with 10,000 frames                      | slider precision adequate; snapshot renders |
| Scrub to frameNo = latest                   | returnToLive auto-triggered |
| Scrub while disconnected                    | error banner + keep last good|
| Rapid scrubbing back and forth              | no crash; final position correct |
| Click Rewind, run finishes mid-confirmation | Rewind becomes disabled; dialog closes with warning |
| Two clients both Rewind on same run         | first succeeds; second `Busy`|
| Rewind + `reduceMotion`                     | no sepia animation; color still applied |

### Integration / UI tests

- Scrub to historical frame → tree shows past state.
- Return to live → resumes streaming.
- Rewind successful → toast + live mode.
- Rewind declined at prompt → no state change.
- Error banner → retry works.
- Rewind on finished run → button hidden.
- Sepia overlay visible in historical mode.

### Accessibility

- Scrubber announces current frame / total; supports keyboard (Left /
  Right / Home / End).
- Confirmation dialog focuses Rewind by default? or Cancel? Default to
  **Cancel** to prevent accidental destructive action via Enter — test.
- Dialog announces destructive nature ("alert" role).
- `reduceMotion` disables sepia animation; color difference retained.

### Performance

- Scrub debounce smooth at 60 fps.
- Snapshot RPC < 100ms (from 0010 budget) → UI updates feel instant.
- Rewind confirmation dialog opens < 100ms.

## Observability

- `info` on every scrub: `runId`, `fromFrame`, `toFrame`, result.
- `info` on every rewind confirm: `runId`, `toFrame`, result,
  `durationMs`.
- `warn` on rewind failure with error code.
- `error` on unexpected state (e.g. jumpToFrame succeeded but live
  resubscribe failed).
- Signposts around scrub and rewind.

## Error handling

- Every server error code from 0010 + 0013 mapped to user messages
  with hints.
- Local single-flight guard prevents double-submit even before server
  responds.
- Network partition during rewind → retry UI with exponential guidance.

## Acceptance

- [ ] Unit tests for scrub / rewind / debounce pass.
- [ ] Every boundary case yields documented behavior.
- [ ] UI tests verify full flow including destructive dialog.
- [ ] Accessibility: keyboard-only rewind + confirm works, Cancel is
      default-focused, announcements correct.
- [ ] `reduceMotion` respected.
- [ ] Performance budgets met.
- [ ] Manual verification: rewind a real test run end-to-end, confirm
      engine state matches UI expectation.
- [ ] Error code mapping exhaustive.

## Blocked by

- smithers/0010, 0013
- gui/0074, 0075
